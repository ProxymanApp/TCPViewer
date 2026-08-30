//
//  TCPViewerMCPCommandRouter.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore

protocol TCPViewerMCPCommandRouting: AnyObject {
    func route(_ request: TCPViewerMCPRequest, completion: @escaping (TCPViewerMCPResponse) -> Void)
}

enum TCPViewerMCPCommandRouterError: Error, LocalizedError {
    case invalidParameter(String)
    case noActiveWindow
    case proRequired
    case rawBytesRequireRedactionDisabled

    var errorDescription: String? {
        switch self {
        case .invalidParameter(let message):
            return message
        case .noActiveWindow:
            return "Open a TCP Viewer window before using packet or capture tools."
        case .proRequired:
            return "TCP Viewer MCP is a PRO feature. Activate a valid license in TCP Viewer to continue."
        case .rawBytesRequireRedactionDisabled:
            return "Raw packet bytes are unavailable while sensitive-data redaction is enabled. Disable redaction in MCP Settings only when it is safe to share the full capture."
        }
    }
}

struct TCPViewerMCPExportPathPolicy {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // Validate an explicit destination without creating directories or silently replacing files.
    func destination(
        path: String,
        format: CaptureFileFormat,
        overwrite: Bool
    ) throws -> URL {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              trimmedPath.utf8.count <= 4_096,
              !trimmedPath.contains("\0"),
              (trimmedPath as NSString).isAbsolutePath else {
            throw TCPViewerMCPCommandRouterError.invalidParameter("path must be an absolute file path.")
        }

        var destination = URL(fileURLWithPath: trimmedPath).standardizedFileURL
        if destination.pathExtension.isEmpty {
            destination.appendPathExtension(format.rawValue)
        } else if destination.pathExtension.lowercased() != format.rawValue {
            throw TCPViewerMCPCommandRouterError.invalidParameter(
                "path must use the .\(format.rawValue) extension for the selected format."
            )
        }

        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TCPViewerMCPCommandRouterError.invalidParameter("The destination directory does not exist.")
        }
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw TCPViewerMCPCommandRouterError.invalidParameter("The destination directory is not writable.")
        }

        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory != true else {
                throw TCPViewerMCPCommandRouterError.invalidParameter("path points to a directory, not a capture file.")
            }
            guard values.isSymbolicLink != true else {
                throw TCPViewerMCPCommandRouterError.invalidParameter("Refusing to export through a symbolic link.")
            }
            guard values.isRegularFile == true else {
                throw TCPViewerMCPCommandRouterError.invalidParameter(
                    "path must point to a regular file when replacing an existing item."
                )
            }
            guard overwrite else {
                throw TCPViewerMCPCommandRouterError.invalidParameter(
                    "The destination already exists. Set overwrite to true to replace it."
                )
            }
        }
        return destination
    }
}

final class TCPViewerMCPCommandRouter: TCPViewerMCPCommandRouting {
    static let shared = TCPViewerMCPCommandRouter()

    private enum Limit {
        static let maximumDetailDepth = 12
        static let maximumDetailNodes = 5_000
        static let defaultByteCount = 4_096
        static let maximumByteCount = 65_536
        static let maximumExportPacketCount = 100_000
        static let maximumSummaryGroups = 50
    }

    private let dataSourceProvider: () -> (any TCPViewerMCPDataSource)?
    private let isLicenseAuthorized: () -> Bool
    private let requiresAuthorizedLicense: Bool
    private let redactionEnabled: () -> Bool
    private let versionProvider: () -> TCPViewerLicenseAppVersion
    private let exportPathPolicy: TCPViewerMCPExportPathPolicy
    private let workerQueue: DispatchQueue
    private let redactor: TCPViewerMCPSensitiveDataRedactor

    init(
        dataSourceProvider: @escaping () -> (any TCPViewerMCPDataSource)? = {
            TCPViewerMCPServiceProvider.shared.activeSource()
        },
        isLicenseAuthorized: @escaping () -> Bool = {
            TCPViewerLicenseService.shared.isLicenseAuthorized
        },
        requiresAuthorizedLicense: Bool = true,
        redactionEnabled: @escaping () -> Bool = {
            (NSApp.delegate as? AppDelegate)?.appConfiguration.mcpRedactsSensitiveData ?? true
        },
        versionProvider: @escaping () -> TCPViewerLicenseAppVersion = {
            TCPViewerLicenseAppVersion.current
        },
        exportPathPolicy: TCPViewerMCPExportPathPolicy = TCPViewerMCPExportPathPolicy(),
        workerQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.mcp.commands", qos: .userInitiated),
        redactor: TCPViewerMCPSensitiveDataRedactor = TCPViewerMCPSensitiveDataRedactor()
    ) {
        self.dataSourceProvider = dataSourceProvider
        self.isLicenseAuthorized = isLicenseAuthorized
        self.requiresAuthorizedLicense = requiresAuthorizedLicense
        self.redactionEnabled = redactionEnabled
        self.versionProvider = versionProvider
        self.exportPathPolicy = exportPathPolicy
        self.workerQueue = workerQueue
        self.redactor = redactor
    }

    // Route one authenticated bridge request and keep all controller access on the main thread.
    func route(_ request: TCPViewerMCPRequest, completion: @escaping (TCPViewerMCPResponse) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.route(request, completion: completion)
            }
            return
        }
        guard !requiresAuthorizedLicense || isLicenseAuthorized() else {
            completion(failure(TCPViewerMCPCommandRouterError.proRequired))
            return
        }
        guard let command = TCPViewerMCPCommand(rawValue: request.command) else {
            completion(.failure("Unsupported MCP command."))
            return
        }

        switch command {
        case .getAppStatus:
            getAppStatus(completion: completion)
        case .getCaptureOverview:
            withSnapshot(completion: completion) { snapshot, redactsSensitiveData in
                .success(self.captureOverview(snapshot, redactsSensitiveData: redactsSensitiveData))
            }
        case .listInterfaces:
            withSnapshot(completion: completion) { snapshot, redactsSensitiveData in
                .success(self.interfaceList(snapshot, redactsSensitiveData: redactsSensitiveData))
            }
        case .queryPackets:
            queryPackets(request, completion: completion)
        case .summarizeCapture:
            summarizeCapture(request, completion: completion)
        case .getPacketDetails:
            getPacketDetails(request, completion: completion)
        case .getPacketBytes:
            getPacketBytes(request, completion: completion)
        case .listStreamPackets:
            listStreamPackets(request, completion: completion)
        case .exportPackets:
            exportPackets(request, completion: completion)
        case .startCapture:
            controlCapture(request, action: .startCapture, completion: completion)
        case .pauseCapture:
            controlCapture(request, action: .pauseCapture, completion: completion)
        case .resumeCapture:
            controlCapture(request, action: .resumeCapture, completion: completion)
        case .stopCapture:
            controlCapture(request, action: .stopCapture, completion: completion)
        case .clearPackets:
            clearPackets(request, completion: completion)
        case .revealPacket:
            revealPacket(request, completion: completion)
        }
    }

    private func getAppStatus(completion: @escaping (TCPViewerMCPResponse) -> Void) {
        DispatchQueue.main.async {
            let version = self.versionProvider()
            let snapshot = self.dataSourceProvider()?.mcpWorkspaceSnapshot()
            completion(.success([
                "app": .string("TCP Viewer"),
                "version": .string(version.appVersion),
                "build": .string(version.buildNumber),
                "pro_authorized": .bool(self.isLicenseAuthorized()),
                "redaction_enabled": .bool(self.redactionEnabled()),
                "has_active_window": .bool(snapshot != nil),
                "capture_phase": .string(snapshot?.capturePhase ?? "unavailable"),
                "packet_count": .int(snapshot?.totalPacketCount ?? 0),
            ]))
        }
    }

    private func queryPackets(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        do {
            let query = try TCPViewerMCPPacketQueryService.query(from: request)
            withPacketSnapshot(query: query, completion: completion) { snapshot, redactsSensitiveData in
                let result = TCPViewerMCPPacketQueryService.execute(
                    query,
                    packets: snapshot.packets,
                    totalPacketCount: snapshot.totalPacketCount
                )
                let serializer = TCPViewerMCPPacketSerializer(redactsSensitiveData: redactsSensitiveData)
                return .success(self.queryResult(result, serializer: serializer))
            }
        } catch {
            completion(failure(error))
        }
    }

    private func summarizeCapture(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        do {
            let query = try TCPViewerMCPPacketQueryService.query(from: request)
            withPacketSnapshot(query: query, completion: completion) { snapshot, redactsSensitiveData in
                .success(self.captureSummary(
                    snapshot,
                    query: query,
                    redactsSensitiveData: redactsSensitiveData
                ))
            }
        } catch {
            completion(failure(error))
        }
    }

    private func getPacketDetails(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        do {
            let id = try packetID(from: request)
            let maximumDepth = try boundedInteger(
                request.int("max_depth") ?? 8,
                named: "max_depth",
                range: 0...Limit.maximumDetailDepth
            )
            let maximumNodes = try boundedInteger(
                request.int("max_nodes") ?? 1_000,
                named: "max_nodes",
                range: 1...Limit.maximumDetailNodes
            )
            withDataSource(completion: completion) { source in
                source.mcpInspectPacket(id: id) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let inspection):
                            let serializer = TCPViewerMCPPacketSerializer(redactsSensitiveData: self.redactionEnabled())
                            completion(.success([
                                "packet": serializer.inspection(
                                    inspection,
                                    maximumDepth: maximumDepth,
                                    maximumNodeCount: maximumNodes
                                ),
                            ]))
                        case .failure(let error):
                            completion(self.failure(error))
                        }
                    }
                }
            }
        } catch {
            completion(failure(error))
        }
    }

    private func getPacketBytes(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        guard !redactionEnabled() else {
            completion(failure(TCPViewerMCPCommandRouterError.rawBytesRequireRedactionDisabled))
            return
        }

        do {
            let id = try packetID(from: request)
            let offset = try boundedInteger(request.int("offset") ?? 0, named: "offset", range: 0...Int.max)
            let length = try boundedInteger(
                request.int("length") ?? Limit.defaultByteCount,
                named: "length",
                range: 1...Limit.maximumByteCount
            )
            let encoding = request.string("encoding") ?? "hex"
            guard encoding == "hex" || encoding == "base64" else {
                throw TCPViewerMCPCommandRouterError.invalidParameter("encoding must be hex or base64.")
            }
            withDataSource(completion: completion) { source in
                source.mcpInspectPacket(id: id) { result in
                    DispatchQueue.main.async {
                        guard !self.redactionEnabled() else {
                            completion(self.failure(TCPViewerMCPCommandRouterError.rawBytesRequireRedactionDisabled))
                            return
                        }
                        switch result {
                        case .success(let inspection):
                            let serializer = TCPViewerMCPPacketSerializer(redactsSensitiveData: false)
                            completion(.success([
                                "bytes": serializer.bytes(
                                    inspection,
                                    offset: offset,
                                    length: length,
                                    encoding: encoding
                                ),
                            ]))
                        case .failure(let error):
                            completion(self.failure(error))
                        }
                    }
                }
            }
        } catch {
            completion(failure(error))
        }
    }

    private func listStreamPackets(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        guard request.int("stream_id") != nil else {
            completion(failure(TCPViewerMCPCommandRouterError.invalidParameter("stream_id is required.")))
            return
        }
        queryPackets(request, completion: completion)
    }

    private func exportPackets(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        do {
            guard let path = request.string("path") else {
                throw TCPViewerMCPCommandRouterError.invalidParameter("path is required.")
            }
            let formatName = request.string("format") ?? CaptureFileFormat.defaultExportFormat.rawValue
            guard let format = CaptureFileFormat(rawValue: formatName.lowercased()) else {
                throw TCPViewerMCPCommandRouterError.invalidParameter("format must be pcap or pcapng.")
            }
            let destination = try exportPathPolicy.destination(
                path: path,
                format: format,
                overwrite: request.bool("overwrite") ?? false
            )
            let query = try TCPViewerMCPPacketQueryService.query(from: request)
            let exportsAll = request.bool("all") ?? false
            guard exportsAll || hasPacketSelection(request) else {
                throw TCPViewerMCPCommandRouterError.invalidParameter(
                    "Select packets with packet_ids, stream_id, protocols, domains, or filters; or set all to true."
                )
            }

            withDataSource(completion: completion) { source in
                let snapshot = source.mcpWorkspaceSnapshot(
                    packetLimit: query.scanLimit,
                    packetOffset: query.scanOffset,
                    packetOrder: query.order
                )
                let selection = self.exportSelection(
                    query: query,
                    packets: snapshot.packets,
                    totalPacketCount: snapshot.totalPacketCount,
                    appliesResultPagination: request.bool("apply_result_pagination") == true && !exportsAll
                )
                guard !selection.ids.isEmpty else {
                    completion(self.failure(TCPViewerMCPCommandRouterError.invalidParameter("No packets matched the export selection.")))
                    return
                }
                source.mcpExportPackets(ids: selection.ids, to: destination, format: format) { result in
                    switch result {
                    case .success:
                        DispatchQueue.main.async {
                            let path = self.redactionEnabled()
                                ? self.redactor.redact(destination.path)
                                : destination.path
                            completion(.success([
                                "path": .string(path),
                                "format": .string(format.rawValue),
                                "exported_packet_count": .int(selection.ids.count),
                                "selection_truncated": .bool(selection.isTruncated),
                                "next_offset": selection.nextOffset.map(TCPViewerMCPValue.int) ?? .null,
                                "next_scan_offset": selection.nextScanOffset.map(TCPViewerMCPValue.int) ?? .null,
                            ]))
                        }
                    case .failure(let error):
                        DispatchQueue.main.async {
                            completion(self.failure(error))
                        }
                    }
                }
            }
        } catch {
            completion(failure(error))
        }
    }

    private func controlCapture(
        _ request: TCPViewerMCPRequest,
        action: TCPViewerMCPCommand,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        withDataSource(completion: completion) { source in
            let controlCompletion: (Result<Void, Error>) -> Void = { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        var response: [String: TCPViewerMCPValue] = [
                            "action": .string(action.rawValue),
                            "completed": .bool(true),
                        ]
                        if action == .startCapture {
                            let captureFilter = request.string("capture_filter")
                            let filterAction: String
                            if captureFilter == nil {
                                filterAction = "preserved"
                            } else if captureFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                                filterAction = "cleared"
                            } else {
                                filterAction = "set"
                            }
                            response["previous_packets_cleared"] = .bool(true)
                            response["bpf_capture_filter_action"] = .string(filterAction)
                        }
                        completion(.success(response))
                    case .failure(let error):
                        completion(self.failure(error))
                    }
                }
            }

            switch action {
            case .startCapture:
                do {
                    let interfaceID = try self.optionalString(
                        request.value("interface_id"),
                        named: "interface_id",
                        maximumByteCount: 256
                    )
                    let captureFilter = try self.optionalString(
                        request.value("capture_filter"),
                        named: "capture_filter",
                        maximumByteCount: 4_096
                    )
                    if captureFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                       request.bool("confirm_bpf_filter") != true {
                        throw TCPViewerMCPCommandRouterError.invalidParameter(
                            "capture_filter is a persistent BPF capture filter that excludes nonmatching future traffic; it is not a packet query or TCP Viewer's Filter field. Explain this distinction and obtain explicit user confirmation, then retry with confirm_bpf_filter=true. For filtering packets already captured, use query_packets."
                        )
                    }
                    source.mcpStartCapture(
                        interfaceID: interfaceID,
                        captureFilter: captureFilter,
                        completion: controlCompletion
                    )
                } catch {
                    completion(self.failure(error))
                }
            case .pauseCapture:
                source.mcpPauseCapture(completion: controlCompletion)
            case .resumeCapture:
                source.mcpResumeCapture(completion: controlCompletion)
            case .stopCapture:
                source.mcpStopCapture(completion: controlCompletion)
            default:
                completion(self.failure(TCPViewerMCPCommandRouterError.invalidParameter("Unsupported capture action.")))
            }
        }
    }

    private func clearPackets(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        guard request.bool("confirm") == true else {
            completion(failure(TCPViewerMCPCommandRouterError.invalidParameter(
                "clear_packets requires confirm=true because this action removes every packet in the active window."
            )))
            return
        }
        withDataSource(completion: completion) { source in
            switch source.mcpClearPackets() {
            case .success(let count):
                completion(.success(["cleared_packet_count": .int(count)]))
            case .failure(let error):
                completion(self.failure(error))
            }
        }
    }

    private func revealPacket(
        _ request: TCPViewerMCPRequest,
        completion: @escaping (TCPViewerMCPResponse) -> Void
    ) {
        do {
            let id = try packetID(from: request)
            withDataSource(completion: completion) { source in
                switch source.mcpRevealPacket(id: id) {
                case .success:
                    completion(.success(["packet_id": .string(String(id)), "revealed": .bool(true)]))
                case .failure(let error):
                    completion(self.failure(error))
                }
            }
        } catch {
            completion(failure(error))
        }
    }

    private func withDataSource(
        completion: @escaping (TCPViewerMCPResponse) -> Void,
        work: @escaping (any TCPViewerMCPDataSource) -> Void
    ) {
        DispatchQueue.main.async {
            guard let source = self.dataSourceProvider() else {
                completion(self.failure(TCPViewerMCPCommandRouterError.noActiveWindow))
                return
            }
            work(source)
        }
    }

    private func withSnapshot(
        completion: @escaping (TCPViewerMCPResponse) -> Void,
        work: @escaping (TCPViewerMCPWorkspaceSnapshot, Bool) -> TCPViewerMCPResponse
    ) {
        withDataSource(completion: completion) { source in
            let snapshot = source.mcpWorkspaceSnapshot()
            let redactsSensitiveData = self.redactionEnabled()
            self.workerQueue.async {
                completion(work(snapshot, redactsSensitiveData))
            }
        }
    }

    private func withPacketSnapshot(
        query: TCPViewerMCPPacketQuery,
        completion: @escaping (TCPViewerMCPResponse) -> Void,
        work: @escaping (TCPViewerMCPWorkspaceSnapshot, Bool) -> TCPViewerMCPResponse
    ) {
        withDataSource(completion: completion) { source in
            let snapshot = source.mcpWorkspaceSnapshot(
                packetLimit: query.scanLimit,
                packetOffset: query.scanOffset,
                packetOrder: query.order
            )
            let redactsSensitiveData = self.redactionEnabled()
            self.workerQueue.async {
                completion(work(snapshot, redactsSensitiveData))
            }
        }
    }

    private func captureOverview(
        _ snapshot: TCPViewerMCPWorkspaceSnapshot,
        redactsSensitiveData: Bool
    ) -> [String: TCPViewerMCPValue] {
        let protectedStatus = redactsSensitiveData ? redactor.redact(snapshot.statusMessage) : snapshot.statusMessage
        var data: [String: TCPViewerMCPValue] = [
            "capture_phase": .string(snapshot.capturePhase),
            "packet_count": .int(snapshot.totalPacketCount),
            "capture_filter": .string(redactsSensitiveData ? redactor.redact(snapshot.captureFilter) : snapshot.captureFilter),
            "capture_filter_language": .string("libpcap_bpf"),
            "status": .string(protectedStatus),
            "can_start": .bool(snapshot.canStart),
            "can_pause": .bool(snapshot.canPause),
            "can_resume": .bool(snapshot.canResume),
            "can_stop": .bool(snapshot.canStop),
            "dropped_packet_count": .string(String(snapshot.droppedPacketCount)),
            "truncated_packet_count": .int(snapshot.truncatedPacketCount),
            "decode_issue_count": .int(snapshot.decodeIssueCount),
        ]
        if let source = snapshot.source {
            data["source"] = .string(source.rawValue)
        }
        if let selectedInterfaceID = snapshot.selectedInterfaceID {
            data["selected_interface_id"] = .string(selectedInterfaceID)
        }
        if let activeInterfaceID = snapshot.activeInterfaceID {
            data["active_interface_id"] = .string(activeInterfaceID)
        }
        if let documentURL = snapshot.documentURL {
            let documentName = redactsSensitiveData
                ? redactor.redact(documentURL.lastPathComponent)
                : documentURL.lastPathComponent
            data["document_name"] = .string(documentName)
        }
        return data
    }

    private func interfaceList(
        _ snapshot: TCPViewerMCPWorkspaceSnapshot,
        redactsSensitiveData: Bool
    ) -> [String: TCPViewerMCPValue] {
        let interfaces = snapshot.interfaces.map { interface -> TCPViewerMCPValue in
            let addresses = interface.addresses.map { address in
                TCPViewerMCPValue.object([
                    "family": .string(address.family.rawValue),
                    "value": .string(redactsSensitiveData ? redactor.redact(address.value) : address.value),
                ])
            }
            var value: [String: TCPViewerMCPValue] = [
                "id": .string(interface.id),
                "technical_name": .string(interface.technicalName),
                "display_name": .string(interface.displayName),
                "is_loopback": .bool(interface.isLoopback),
                "is_selectable": .bool(interface.isSelectable),
                "link_type": .string(interface.linkType.rawValue),
                "availability": .string(interface.availability.rawValue),
                "addresses": .array(addresses),
                "supports_promiscuous_mode": .bool(interface.capabilities.supportsPromiscuousMode),
                "requires_permission_setup": .bool(interface.capabilities.requiresBPFPermissionSetup),
            ]
            if let friendlyName = interface.friendlyName {
                value["friendly_name"] = .string(friendlyName)
            }
            if let reason = interface.availabilityReason {
                value["availability_reason"] = .string(reason)
            }
            if let packetsPerSecond = interface.activityPreview.packetsPerSecond {
                value["packets_per_second"] = .double(packetsPerSecond)
            }
            return .object(value)
        }
        return [
            "interfaces": .array(interfaces),
            "count": .int(interfaces.count),
            "selected_interface_id": snapshot.selectedInterfaceID.map(TCPViewerMCPValue.string) ?? .null,
            "active_interface_id": snapshot.activeInterfaceID.map(TCPViewerMCPValue.string) ?? .null,
        ]
    }

    private func queryResult(
        _ result: TCPViewerMCPPacketQueryResult,
        serializer: TCPViewerMCPPacketSerializer
    ) -> [String: TCPViewerMCPValue] {
        [
            "packets": .array(result.packets.map(serializer.summary)),
            "returned_count": .int(result.packets.count),
            "matched_count": .int(result.matchedPacketCount),
            "scanned_count": .int(result.scannedPacketCount),
            "total_packet_count": .int(result.totalPacketCount),
            "offset": .int(result.offset),
            "next_offset": result.nextOffset.map(TCPViewerMCPValue.int) ?? .null,
            "scan_offset": .int(result.scanOffset),
            "next_scan_offset": result.nextScanOffset.map(TCPViewerMCPValue.int) ?? .null,
            "has_more_unscanned_packets": .bool(result.hasMoreUnscannedPackets),
        ]
    }

    private func captureSummary(
        _ snapshot: TCPViewerMCPWorkspaceSnapshot,
        query: TCPViewerMCPPacketQuery,
        redactsSensitiveData: Bool
    ) -> [String: TCPViewerMCPValue] {
        let scannedCount = min(snapshot.packets.count, query.scanLimit)
        let candidates: ArraySlice<PacketSummary> = query.order == .recent
            ? snapshot.packets.suffix(scannedCount)
            : snapshot.packets.prefix(scannedCount)
        var protocolCounts: [String: Int] = [:]
        var domainCounts: [String: Int] = [:]
        var clientCounts: [String: Int] = [:]
        var matchedCount = 0
        var capturedBytes = 0
        var earliestDate: Date?
        var latestDate: Date?

        // Aggregate only the bounded scan window selected by the caller.
        for packet in candidates where TCPViewerMCPPacketQueryService.matches(packet, query: query) {
            matchedCount += 1
            capturedBytes += packet.capturedLength
            let protocolName = packet.protocolSummary ?? packet.transportHint.rawValue
            protocolCounts[protocolName, default: 0] += 1
            if let domain = packet.domainName {
                let value = redactsSensitiveData ? redactor.redact(domain) : domain
                domainCounts[value, default: 0] += 1
            }
            if let client = packet.client?.displayName {
                let value = redactsSensitiveData ? redactor.redact(client) : client
                clientCounts[value, default: 0] += 1
            }
            earliestDate = min(earliestDate ?? packet.timestamp, packet.timestamp)
            latestDate = max(latestDate ?? packet.timestamp, packet.timestamp)
        }

        var data: [String: TCPViewerMCPValue] = [
            "matched_packet_count": .int(matchedCount),
            "scanned_packet_count": .int(scannedCount),
            "total_packet_count": .int(snapshot.totalPacketCount),
            "scan_offset": .int(query.scanOffset),
            "next_scan_offset": nextScanOffset(
                totalPacketCount: snapshot.totalPacketCount,
                scanOffset: query.scanOffset,
                scannedCount: scannedCount
            ).map(TCPViewerMCPValue.int) ?? .null,
            "has_more_unscanned_packets": .bool(hasMorePackets(
                totalPacketCount: snapshot.totalPacketCount,
                scanOffset: query.scanOffset,
                scannedCount: scannedCount
            )),
            "captured_byte_count": .int(capturedBytes),
            "protocols": countValues(protocolCounts),
            "domains": countValues(domainCounts),
            "clients": countValues(clientCounts),
        ]
        if let earliestDate {
            data["earliest_timestamp"] = .double(earliestDate.timeIntervalSince1970)
        }
        if let latestDate {
            data["latest_timestamp"] = .double(latestDate.timeIntervalSince1970)
        }
        if let earliestDate, let latestDate {
            data["duration_seconds"] = .double(max(0, latestDate.timeIntervalSince(earliestDate)))
        }
        return data
    }

    private func countValues(_ counts: [String: Int]) -> TCPViewerMCPValue {
        let values = counts.sorted { left, right in
            left.value == right.value ? left.key.localizedCaseInsensitiveCompare(right.key) == .orderedAscending : left.value > right.value
        }.prefix(Limit.maximumSummaryGroups).map { name, count in
            TCPViewerMCPValue.object(["name": .string(name), "count": .int(count)])
        }
        return .array(Array(values))
    }

    private func exportSelection(
        query: TCPViewerMCPPacketQuery,
        packets: [PacketSummary],
        totalPacketCount: Int,
        appliesResultPagination: Bool
    ) -> (ids: [PacketSummary.ID], isTruncated: Bool, nextOffset: Int?, nextScanOffset: Int?) {
        let scannedCount = min(packets.count, query.scanLimit)
        let candidates = query.order == .recent && appliesResultPagination
            ? Array(packets.suffix(scannedCount).reversed())
            : Array(packets.prefix(scannedCount))
        var ids: [PacketSummary.ID] = []
        ids.reserveCapacity(min(scannedCount, Limit.maximumExportPacketCount))
        let maximumSelectedCount = appliesResultPagination
            ? min(query.limit, Limit.maximumExportPacketCount)
            : Limit.maximumExportPacketCount
        var matchedCount = 0
        var matchedBeyondLimit = false
        for packet in candidates where TCPViewerMCPPacketQueryService.matches(packet, query: query) {
            let matchIndex = matchedCount
            matchedCount += 1
            if appliesResultPagination && matchIndex < query.offset {
                continue
            }
            if ids.count < maximumSelectedCount {
                ids.append(packet.id)
            } else {
                matchedBeyondLimit = true
                break
            }
        }
        let hasMoreUnscannedPackets = hasMorePackets(
            totalPacketCount: totalPacketCount,
            scanOffset: query.scanOffset,
            scannedCount: scannedCount
        )
        return (
            ids,
            matchedBeyondLimit || hasMoreUnscannedPackets,
            matchedBeyondLimit && appliesResultPagination ? query.offset + ids.count : nil,
            !matchedBeyondLimit && hasMoreUnscannedPackets ? query.scanOffset + scannedCount : nil
        )
    }

    // Report whether another bounded scan window exists in the selected order.
    private func hasMorePackets(
        totalPacketCount: Int,
        scanOffset: Int,
        scannedCount: Int
    ) -> Bool {
        let remainingAfterOffset = max(0, totalPacketCount - min(scanOffset, totalPacketCount))
        return scannedCount < remainingAfterOffset
    }

    // Advance by the actual scanned count so the final short window terminates cleanly.
    private func nextScanOffset(
        totalPacketCount: Int,
        scanOffset: Int,
        scannedCount: Int
    ) -> Int? {
        hasMorePackets(
            totalPacketCount: totalPacketCount,
            scanOffset: scanOffset,
            scannedCount: scannedCount
        ) ? scanOffset + scannedCount : nil
    }

    private func hasPacketSelection(_ request: TCPViewerMCPRequest) -> Bool {
        !(request.array("packet_ids") ?? []).isEmpty ||
            !(request.array("protocols") ?? []).isEmpty ||
            !(request.array("domains") ?? []).isEmpty ||
            !(request.array("filters") ?? []).isEmpty ||
            request.int("stream_id") != nil
    }

    private func packetID(from request: TCPViewerMCPRequest) throws -> PacketSummary.ID {
        if let value = request.string("packet_id"), let id = PacketSummary.ID(value) {
            return id
        }
        if let value = request.int("packet_id"), let id = PacketSummary.ID(exactly: value) {
            return id
        }
        throw TCPViewerMCPCommandRouterError.invalidParameter("packet_id must be a valid UInt64 string.")
    }

    private func boundedInteger(
        _ value: Int,
        named name: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard range.contains(value) else {
            throw TCPViewerMCPCommandRouterError.invalidParameter(
                "\(name) must be between \(range.lowerBound) and \(range.upperBound)."
            )
        }
        return value
    }

    private func optionalString(
        _ value: TCPViewerMCPValue?,
        named name: String,
        maximumByteCount: Int
    ) throws -> String? {
        guard let value else {
            return nil
        }
        guard let string = value.stringValue else {
            throw TCPViewerMCPCommandRouterError.invalidParameter("\(name) must be a string.")
        }
        guard string.utf8.count <= maximumByteCount else {
            throw TCPViewerMCPCommandRouterError.invalidParameter("\(name) is too long.")
        }
        return string
    }

    private func failure(_ error: Error) -> TCPViewerMCPResponse {
        let message = error.localizedDescription
        return .failure(redactionEnabled() ? redactor.redact(message) : message)
    }
}
