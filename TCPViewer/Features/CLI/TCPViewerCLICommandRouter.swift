//
//  TCPViewerCLICommandRouter.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore

protocol TCPViewerCLICommandRouting: AnyObject {
    func route(_ request: TCPViewerCLIRequest, completion: @escaping (TCPViewerCLIResponse) -> Void)
}

final class TCPViewerCLICommandRouter: TCPViewerCLICommandRouting {
    private enum Limit {
        static let maximumImportedFiles = 100
        static let maximumFollowCandidates = 250_000
        static let maximumFollowBytes = 4 * 1_024 * 1_024
        static let maximumFollowRecords = 10_000
    }

    private weak var appDelegate: AppDelegate?
    private let fileManager: FileManager
    private let licenseService: TCPViewerLicenseService
    private lazy var mcpRouter = TCPViewerMCPCommandRouter(
        dataSourceProvider: { TCPViewerMCPServiceProvider.shared.activeSource() },
        isLicenseAuthorized: { [licenseService] in licenseService.isLicenseAuthorized },
        requiresAuthorizedLicense: false,
        redactionEnabled: { false }
    )

    init(
        appDelegate: AppDelegate,
        fileManager: FileManager = .default,
        licenseService: TCPViewerLicenseService = .shared
    ) {
        self.appDelegate = appDelegate
        self.fileManager = fileManager
        self.licenseService = licenseService
    }

    // Route one validated request while keeping AppKit and workspace access on the main thread.
    func route(_ request: TCPViewerCLIRequest, completion: @escaping (TCPViewerCLIResponse) -> Void) {
        precondition(Thread.isMainThread)
        switch request.command {
        case .licenseStatus:
            completion(success(request, data: licenseStatusData()))
        case .licenseActivate:
            activateLicense(request, completion: completion)
        case .licenseRevoke:
            revokeLicense(request, completion: completion)
        case .settingsList, .settingsGet, .settingsSet, .settingsReset:
            routeSettings(request, completion: completion)
        case .fileImport:
            importFiles(request, completion: completion)
        case .fileExportSession:
            exportSession(request, completion: completion)
        case .streamFollow:
            followStream(request, completion: completion)
        default:
            routeThroughMCP(request, completion: completion)
        }
    }

    private func routeThroughMCP(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard let appDelegate else {
            completion(failure(request, code: "app_unavailable", message: "TCP Viewer is unavailable."))
            return
        }
        if request.command != .appStatus {
            do {
                _ = try appDelegate.cliWorkspaceViewModel()
            } catch {
                completion(failure(request, code: "no_active_window", error: error))
                return
            }
        }
        guard let command = mcpCommand(for: request.command) else {
            completion(failure(request, code: "unsupported_command", message: "The command is not supported."))
            return
        }

        var parameters = request.params.mapValues(mcpValue)
        if request.command == .captureStart, request.string("capture_filter") != nil {
            parameters["confirm_bpf_filter"] = .bool(true)
        }
        if request.command == .fileExport {
            parameters["apply_result_pagination"] = .bool(true)
        }
        mcpRouter.route(TCPViewerMCPRequest(command: command.rawValue, params: parameters)) { response in
            guard response.success, let data = response.data else {
                completion(self.failure(
                    request,
                    code: "app_command_failed",
                    message: response.error ?? "TCP Viewer could not complete the command."
                ))
                return
            }
            if request.command == .packetsReveal {
                appDelegate.cliRevealActiveWindow()
            }
            var cliData = data.mapValuesWithKeys { key, value in self.cliValue(value, key: key) }
            if request.command == .appStatus {
                let snapshot = TCPViewerMCPServiceProvider.shared.activeSource()?.mcpWorkspaceSnapshot()
                cliData["running"] = .bool(true)
                cliData["cli_version"] = .string(TCPViewerLicenseAppVersion.current.appVersion)
                cliData["cli_build"] = .string(TCPViewerLicenseAppVersion.current.buildNumber)
                cliData["license_state"] = .string(self.licenseService.isLicenseAuthorized ? "authorized" : "not_activated")
                cliData["active_document"] = snapshot?.documentURL.map { .string($0.path) } ?? .null
            }
            completion(self.success(request, data: cliData))
        }
    }

    private func mcpCommand(for command: TCPViewerCLICommand) -> TCPViewerMCPCommand? {
        switch command {
        case .appStatus: .getAppStatus
        case .interfacesList: .listInterfaces
        case .captureStatus: .getCaptureOverview
        case .captureStart: .startCapture
        case .capturePause: .pauseCapture
        case .captureResume: .resumeCapture
        case .captureStop: .stopCapture
        case .packetsList: .queryPackets
        case .packetsSummary: .summarizeCapture
        case .packetsDetails: .getPacketDetails
        case .packetsBytes: .getPacketBytes
        case .packetsClear: .clearPackets
        case .packetsReveal: .revealPacket
        case .streamPackets: .listStreamPackets
        case .fileExport: .exportPackets
        default: nil
        }
    }

    private func importFiles(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        do {
            guard let appDelegate else {
                throw CLIError(code: "app_unavailable", message: "TCP Viewer is unavailable.")
            }
            let paths = try stringArray(request, key: "paths", maximumCount: Limit.maximumImportedFiles)
            guard !paths.isEmpty else {
                throw CLIError(code: "invalid_parameter", message: "At least one import path is required.")
            }
            let urls = try paths.map(validImportURL)
            let sessionCount = urls.filter(TCPViewerCaptureFileImportPolicy.isSessionFileURL).count
            guard sessionCount == 0 || (sessionCount == 1 && urls.count == 1) else {
                throw CLIError(code: "invalid_parameter", message: "A tcpviewsession must be imported by itself.")
            }
            appDelegate.cliImportCaptureURLs(urls) { succeeded in
                guard succeeded else {
                    completion(self.failure(request, code: "import_failed", message: "TCP Viewer could not import the selected file."))
                    return
                }
                let packetCount = (try? appDelegate.cliWorkspaceViewModel().mcpWorkspaceSnapshot().totalPacketCount) ?? 0
                completion(self.success(request, data: [
                    "imported_files": .array(urls.map { .string($0.path) }),
                    "imported_file_count": .int(urls.count),
                    "packet_count": .int(packetCount),
                ]))
            }
        } catch let error as CLIError {
            completion(failure(request, code: error.code, message: error.message))
        } catch {
            completion(failure(request, code: "invalid_parameter", error: error))
        }
    }

    private func exportSession(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        do {
            guard let appDelegate else {
                throw CLIError(code: "app_unavailable", message: "TCP Viewer is unavailable.")
            }
            let destination = try exportSessionDestination(
                path: request.string("path"),
                overwrite: request.bool("overwrite") ?? false
            )
            let viewModel = try appDelegate.cliWorkspaceViewModel()
            viewModel.exportTCPViewSession(to: destination) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        completion(self.success(request, data: ["path": .string(destination.path)]))
                    case .failure(let error):
                        completion(self.failure(request, code: "export_failed", error: error))
                    }
                }
            }
        } catch let error as CLIError {
            completion(failure(request, code: error.code, message: error.message))
        } catch {
            completion(failure(request, code: "export_failed", error: error))
        }
    }

    private func followStream(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        do {
            guard let appDelegate else {
                throw CLIError(code: "app_unavailable", message: "TCP Viewer is unavailable.")
            }
            guard let rawID = request.string("packet_id"), let packetID = PacketSummary.ID(rawID) else {
                throw CLIError(code: "invalid_parameter", message: "packet_id must be a valid UInt64 string.")
            }
            let maximumBytes = try bounded(request.int("max_bytes") ?? Limit.maximumFollowBytes, range: 1...Limit.maximumFollowBytes, name: "max_bytes")
            let maximumRecords = try bounded(request.int("max_records") ?? Limit.maximumFollowRecords, range: 1...Limit.maximumFollowRecords, name: "max_records")
            let direction = request.string("direction") ?? "both"
            guard ["both", "client-to-server", "server-to-client"].contains(direction) else {
                throw CLIError(code: "invalid_parameter", message: "direction is invalid.")
            }
            let encoding = request.string("encoding") ?? "text"
            guard ["text", "hex", "base64"].contains(encoding) else {
                throw CLIError(code: "invalid_parameter", message: "encoding is invalid.")
            }
            let viewModel = try appDelegate.cliWorkspaceViewModel()
            let limits = TCPFollowLimits(
                maximumCandidatePacketCount: Limit.maximumFollowCandidates,
                maximumPayloadBytes: maximumBytes,
                maximumRecordCount: maximumRecords
            )
            viewModel.followTCPStream(
                containing: packetID,
                limits: limits,
                progress: nil,
                shouldCancel: nil
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let stream):
                        completion(self.success(request, data: self.followData(
                            stream,
                            direction: direction,
                            encoding: encoding,
                            maximumBytes: maximumBytes,
                            maximumRecords: maximumRecords
                        )))
                    case .failure(let error):
                        completion(self.failure(request, code: "follow_failed", error: error))
                    }
                }
            }
        } catch let error as CLIError {
            completion(failure(request, code: error.code, message: error.message))
        } catch {
            completion(failure(request, code: "follow_failed", error: error))
        }
    }

    private func followData(
        _ stream: TCPFollowStream,
        direction: String,
        encoding: String,
        maximumBytes: Int,
        maximumRecords: Int
    ) -> [String: TCPViewerCLIValue] {
        var returnedBytes = 0
        var records: [TCPViewerCLIValue] = []
        var wasLimited = stream.isTruncated
        for record in stream.records where includes(record.direction, selection: direction) {
            guard records.count < maximumRecords, returnedBytes < maximumBytes else {
                wasLimited = true
                break
            }
            let data = Data(record.data.prefix(maximumBytes - returnedBytes))
            if data.count < record.data.count { wasLimited = true }
            returnedBytes += data.count
            records.append(.object([
                "direction": .string(record.direction == .clientToServer ? "client_to_server" : "server_to_client"),
                "packet_id": .string(String(record.packetID)),
                "timestamp": .string(Self.iso8601.string(from: record.timestamp)),
                "sequence_number": .string(String(record.sequenceNumber)),
                "data": .string(encoded(data, as: encoding)),
                "byte_count": .int(data.count),
            ]))
            if data.count < record.data.count { break }
        }
        return [
            "client": endpointValue(stream.client),
            "server": endpointValue(stream.server),
            "encoding": .string(encoding),
            "direction": .string(direction.replacingOccurrences(of: "-", with: "_")),
            "records": .array(records),
            "returned_record_count": .int(records.count),
            "returned_byte_count": .int(returnedBytes),
            "captured_through_packet_id": .string(String(stream.capturedThroughPacketID)),
            "captured_at": .string(Self.iso8601.string(from: stream.capturedAt)),
            "truncated": .bool(wasLimited),
        ]
    }

    private func activateLicense(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard let key = request.string("license_key"), key.hasPrefix("TCPV-"), key.utf8.count <= 4_096 else {
            completion(failure(request, code: "invalid_parameter", message: "A valid TCP Viewer license key is required."))
            return
        }
        licenseService.activate(licenseKey: key) { status in
            guard status.isAuthorized else {
                let message: String
                if case .unauthorized(let error) = status {
                    message = error.localizedDescription.replacingOccurrences(of: key, with: "<redacted>")
                } else {
                    message = "The license could not be activated."
                }
                completion(self.failure(request, code: "license_activation_failed", message: message))
                return
            }
            completion(self.success(request, data: self.licenseStatusData()))
        }
    }

    private func revokeLicense(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard request.bool("confirm") == true else {
            completion(failure(request, code: "confirmation_required", message: "License revocation requires confirmation."))
            return
        }
        licenseService.revokeCurrentDevice { result in
            switch result {
            case .success:
                completion(self.success(request, data: ["authorized": .bool(false), "revoked": .bool(true)]))
            case .failure(let error):
                completion(self.failure(request, code: "license_revoke_failed", error: error))
            }
        }
    }

    private func licenseStatusData() -> [String: TCPViewerCLIValue] {
        guard let license = licenseService.currentLicense, licenseService.isLicenseAuthorized else {
            return ["authorized": .bool(false)]
        }
        return [
            "authorized": .bool(true),
            "email": .string(license.email),
            "license_type": .string(license.licenseType.rawValue),
            "update_expiry": .string(license.expiryDate),
            "lifetime_updates": .bool(license.hasLifetimeUpdates),
        ]
    }

    private func routeSettings(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard let appDelegate else {
            completion(failure(request, code: "app_unavailable", message: "TCP Viewer is unavailable."))
            return
        }
        let configuration = appDelegate.appConfiguration
        do {
            switch request.command {
            case .settingsList:
                completion(success(request, data: ["settings": .object(settings(configuration))]))
            case .settingsGet:
                guard let key = request.string("key"), let value = settings(configuration)[key] else {
                    throw CLIError(code: "unknown_setting", message: "The setting key is not supported.")
                }
                completion(success(request, data: ["key": .string(key), "value": value]))
            case .settingsSet:
                guard let key = request.string("key"), let rawValue = request.string("value") else {
                    throw CLIError(code: "invalid_parameter", message: "A setting key and value are required.")
                }
                try setSetting(key, value: rawValue, configuration: configuration)
                appDelegate.cliRefreshSettings()
                completion(success(request, data: ["key": .string(key), "value": settings(configuration)[key] ?? .null]))
            case .settingsReset:
                if request.bool("all") == true {
                    for key in settings(configuration).keys { _ = configuration.resetCLISetting(named: key) }
                    appDelegate.cliRefreshSettings()
                    completion(success(request, data: ["settings": .object(settings(configuration))]))
                } else if let key = request.string("key"), configuration.resetCLISetting(named: key) {
                    appDelegate.cliRefreshSettings()
                    completion(success(request, data: ["key": .string(key), "value": settings(configuration)[key] ?? .null]))
                } else {
                    throw CLIError(code: "unknown_setting", message: "The setting key is not supported.")
                }
            default:
                throw CLIError(code: "unsupported_command", message: "The settings command is not supported.")
            }
        } catch let error as CLIError {
            completion(failure(request, code: error.code, message: error.message))
        } catch {
            completion(failure(request, code: "invalid_parameter", error: error))
        }
    }

    private func settings(_ configuration: AppConfiguration) -> [String: TCPViewerCLIValue] {
        [
            "theme": .string(configuration.appearanceTheme.rawValue),
            "packet_font_size": .double(Double(configuration.packetFontSize)),
            "monospaced_font": .bool(configuration.usesMonospacedPacketFont),
            "analytics": .bool(configuration.sharesAnalytics),
            "crash_reports": .bool(configuration.sharesCrashReports),
            "quit_confirmation": .bool(configuration.confirmsBeforeQuitting),
            "mcp_enabled": .bool(configuration.isMCPServerEnabled),
            "mcp_redaction": .bool(configuration.mcpRedactsSensitiveData),
        ]
    }

    private func setSetting(_ key: String, value: String, configuration: AppConfiguration) throws {
        switch key {
        case "theme":
            guard let theme = AppAppearanceTheme(rawValue: value.lowercased()) else {
                throw CLIError(code: "invalid_setting_value", message: "theme must be system, light, or dark.")
            }
            configuration.appearanceTheme = theme
        case "packet_font_size":
            guard let size = Double(value), size.isFinite,
                  Double(AppConfiguration.minimumPacketFontSize)...Double(AppConfiguration.maximumPacketFontSize) ~= size else {
                throw CLIError(code: "invalid_setting_value", message: "packet_font_size must be between 10 and 24.")
            }
            configuration.packetFontSize = CGFloat(size)
        case "monospaced_font": configuration.usesMonospacedPacketFont = try boolean(value)
        case "analytics": configuration.sharesAnalytics = try boolean(value)
        case "crash_reports": configuration.sharesCrashReports = try boolean(value)
        case "quit_confirmation": configuration.confirmsBeforeQuitting = try boolean(value)
        case "mcp_enabled": configuration.isMCPServerEnabled = try boolean(value)
        case "mcp_redaction": configuration.mcpRedactsSensitiveData = try boolean(value)
        default:
            throw CLIError(code: "unknown_setting", message: "The setting key is not supported.")
        }
    }

    private func validImportURL(_ path: String) throws -> URL {
        guard (path as NSString).isAbsolutePath, !path.contains("\0"), path.utf8.count <= 4_096 else {
            throw CLIError(code: "invalid_parameter", message: "Import paths must be absolute file paths.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL(url) else {
            throw CLIError(code: "unsupported_file", message: "Import accepts pcap, pcapng, or tcpviewsession files.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CLIError(code: "unsafe_file", message: "Import paths must point to regular files and cannot be symbolic links.")
        }
        return url
    }

    private func exportSessionDestination(path: String?, overwrite: Bool) throws -> URL {
        guard let path, (path as NSString).isAbsolutePath, !path.contains("\0"), path.utf8.count <= 4_096 else {
            throw CLIError(code: "invalid_parameter", message: "path must be an absolute file path.")
        }
        var destination = URL(fileURLWithPath: path).standardizedFileURL
        if destination.pathExtension.isEmpty {
            destination.appendPathExtension(TCPViewSessionFormat.fileExtension)
        } else if destination.pathExtension.lowercased() != TCPViewSessionFormat.fileExtension {
            throw CLIError(code: "invalid_parameter", message: "path must use the .tcpviewsession extension.")
        }
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: parent.path) else {
            throw CLIError(code: "invalid_parameter", message: "The destination directory must exist and be writable.")
        }
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isDirectory != true else {
                throw CLIError(code: "unsafe_file", message: "The existing destination must be a regular file and cannot be a symbolic link.")
            }
            guard overwrite else {
                throw CLIError(code: "file_exists", message: "The destination exists. Use --overwrite to replace it.")
            }
        }
        return destination
    }

    private func stringArray(_ request: TCPViewerCLIRequest, key: String, maximumCount: Int) throws -> [String] {
        guard let values = request.array(key), values.count <= maximumCount else {
            throw CLIError(code: "invalid_parameter", message: "\(key) must contain at most \(maximumCount) strings.")
        }
        return try values.map { value in
            guard let string = value.stringValue else {
                throw CLIError(code: "invalid_parameter", message: "\(key) must contain only strings.")
            }
            return string
        }
    }

    private func boolean(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: throw CLIError(code: "invalid_setting_value", message: "Boolean settings accept true or false.")
        }
    }

    private func bounded(_ value: Int, range: ClosedRange<Int>, name: String) throws -> Int {
        guard range.contains(value) else {
            throw CLIError(code: "invalid_parameter", message: "\(name) is outside its supported range.")
        }
        return value
    }

    private func includes(_ direction: TCPFollowDirection, selection: String) -> Bool {
        selection == "both" ||
            (selection == "client-to-server" && direction == .clientToServer) ||
            (selection == "server-to-client" && direction == .serverToClient)
    }

    private func encoded(_ data: Data, as encoding: String) -> String {
        switch encoding {
        case "base64": data.base64EncodedString()
        case "hex": data.map { String(format: "%02x", $0) }.joined()
        default: String(decoding: data, as: UTF8.self)
        }
    }

    private func endpointValue(_ endpoint: PacketEndpoint) -> TCPViewerCLIValue {
        var value: [String: TCPViewerCLIValue] = [:]
        if let address = endpoint.address { value["address"] = .string(address) }
        if let port = endpoint.port { value["port"] = .int(Int(port)) }
        return .object(value)
    }

    private func mcpValue(_ value: TCPViewerCLIValue) -> TCPViewerMCPValue {
        switch value {
        case .string(let value): .string(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .bool(let value): .bool(value)
        case .array(let value): .array(value.map(mcpValue))
        case .object(let value): .object(value.mapValues(mcpValue))
        case .null: .null
        }
    }

    private func cliValue(_ value: TCPViewerMCPValue, key: String? = nil) -> TCPViewerCLIValue {
        switch value {
        case .string(let value):
            if key == "direction" {
                return .string(value.replacingOccurrences(of: "clientToServer", with: "client_to_server")
                    .replacingOccurrences(of: "serverToClient", with: "server_to_client"))
            }
            return .string(value)
        case .int(let value): return .int(value)
        case .double(let value):
            if ["timestamp", "earliest_timestamp", "latest_timestamp"].contains(key) {
                return .string(Self.iso8601.string(from: Date(timeIntervalSince1970: value)))
            }
            return .double(value)
        case .bool(let value): return .bool(value)
        case .array(let value): return .array(value.map { cliValue($0) })
        case .object(let value): return .object(value.mapValuesWithKeys { key, value in cliValue(value, key: key) })
        case .null: return .null
        }
    }

    private func success(_ request: TCPViewerCLIRequest, data: [String: TCPViewerCLIValue]) -> TCPViewerCLIResponse {
        .success(requestID: request.requestID, command: request.command, data: data)
    }

    private func failure(_ request: TCPViewerCLIRequest, code: String, error: Error) -> TCPViewerCLIResponse {
        failure(request, code: code, message: error.localizedDescription)
    }

    private func failure(_ request: TCPViewerCLIRequest, code: String, message: String) -> TCPViewerCLIResponse {
        .failure(requestID: request.requestID, command: request.command, code: code, message: message)
    }

    private struct CLIError: Error {
        let code: String
        let message: String
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension Dictionary {
    func mapValuesWithKeys<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { key, value in (key, transform(key, value)) })
    }
}
