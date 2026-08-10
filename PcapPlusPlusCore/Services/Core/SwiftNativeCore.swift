//
//  SwiftNativeCore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 28/5/26.
//

import Darwin
import Foundation

typealias PCPPNativePacketBatchHandler = ([PCPPNativePacketSummaryDescriptor]) -> Void
typealias PCPPNativeSessionPhaseHandler = (PCPPNativeLiveSessionPhase, String) -> Void
typealias PCPPNativeHealthHandler = (PCPPNativeCaptureHealthDescriptor) -> Void
typealias PCPPNativeErrorHandler = (Error) -> Void
typealias PCPPNativeLoadProgressHandler = (PCPPNativePacketLoadProgressDescriptor) -> Void
typealias PCPPNativePacketExportProgressHandler = (UInt, UInt) -> Void
typealias PCPPNativeCancellationHandler = () -> Bool

final class PCPPNativeCore {
    func discoverInterfacesAndReturnError(_ errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) -> [PCPPNativeInterfaceDescriptor] {
        do {
            return try discoverInterfaces()
        } catch let thrownError {
            errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .interfaceDiscoveryFailed) as NSError
            return []
        }
    }

    func validateCaptureFilter(_ expression: String) -> PCPPNativeFilterValidationDescriptor {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PCPPNativeFilterValidationDescriptor(
                disposition: "invalid",
                normalizedExpression: nil,
                message: "Capture filters cannot be empty."
            )
        }

        if let validationError = Libpcap.validateFilter(trimmed) {
            return PCPPNativeFilterValidationDescriptor(
                disposition: "invalid",
                normalizedExpression: trimmed,
                message: "Invalid libpcap syntax: \(validationError)"
            )
        }

        return PCPPNativeFilterValidationDescriptor(disposition: "valid", normalizedExpression: trimmed, message: nil)
    }

    func supportedOfflineFormats() -> [String] {
        CaptureFileFormat.allCases.map(\.rawValue)
    }

    private func discoverInterfaces() throws -> [PCPPNativeInterfaceDescriptor] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw NativeNSError(.interfaceDiscoveryFailed, "TCP Viewer could not enumerate network interfaces.")
        }
        defer { freeifaddrs(head) }

        var builders: [String: InterfaceBuilder] = [:]
        var cursor = head
        while let current = cursor {
            let entry = current.pointee
            guard let namePointer = entry.ifa_name else {
                cursor = entry.ifa_next
                continue
            }

            let name = String(cString: namePointer)
            var builder = builders[name] ?? InterfaceBuilder(name: name)
            builder.flags = entry.ifa_flags
            if let address = entry.ifa_addr {
                builder.addresses.append(interfaceAddress(from: address.pointee))
            }
            builders[name] = builder
            cursor = entry.ifa_next
        }

        return builders.values.map { builder in
            let isLoopback = (builder.flags & UInt32(IFF_LOOPBACK)) != 0 || builder.name.hasPrefix("lo")
            let isUp = (builder.flags & UInt32(IFF_UP)) != 0
            let linkType: PCPPNativeLinkType = isLoopback ? .loopback : .ethernet
            let availability: PCPPNativeInterfaceAvailability = isUp ? .available : .unavailable
            let reason = isUp ? nil : "The interface is currently down."
            return PCPPNativeInterfaceDescriptor(
                identifier: builder.name,
                technicalName: builder.name,
                displayName: builder.name,
                friendlyName: builder.name,
                interfaceDescription: builder.name,
                loopback: isLoopback,
                availability: availability,
                availabilityReason: reason,
                linkType: linkType,
                addresses: builder.addresses.filter { !$0.value.isEmpty },
                activityPreview: PCPPNativeActivityPreviewDescriptor(packetsPerSecond: nil, observedAt: nil),
                canCapture: true,
                supportsPromiscuousMode: !isLoopback,
                requiresBPFPermissionSetup: true,
                providesMacOSMetadata: true
            )
        }
    }

    private func interfaceAddress(from sockaddr: sockaddr) -> PCPPNativeAddressDescriptor {
        var address = sockaddr
        switch Int32(sockaddr.sa_family) {
        case AF_INET:
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4Pointer in
                    var addr = ipv4Pointer.pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let value = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) } ?? ""
                    return PCPPNativeAddressDescriptor(family: .ipv4, value: value)
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ipv6Pointer in
                    var addr = ipv6Pointer.pointee.sin6_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    let value = inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)).map { String(cString: $0) } ?? ""
                    return PCPPNativeAddressDescriptor(family: .ipv6, value: value)
                }
            }
        default:
            return PCPPNativeAddressDescriptor(family: .unknown, value: "")
        }
    }
}

private struct InterfaceBuilder {
    let name: String
    var flags: UInt32 = 0
    var addresses: [PCPPNativeAddressDescriptor] = []
}

private struct PCPPNativeOfflineDocumentState {
    var file: NativeCaptureFile
    var partiallyLoaded = false
    var dissectionSession: WiresharkEpanSession?
    var currentURL: URL
    var currentFormat: String
    var dirty = false
}

final class PCPPNativeOfflineDocument {
    private let state: Protected<PCPPNativeOfflineDocumentState>
    private let disablesWireshark: Bool

    var currentURL: URL {
        state.read(\.currentURL)
    }

    var currentFormat: String {
        state.read(\.currentFormat)
    }

    var dirty: Bool {
        state.read(\.dirty)
    }

    var documentMetadata: PCPPNativeCaptureDocumentMetadataDescriptor {
        state.read {
            $0.file.metadata
        }
    }

    init(url: URL, error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.disablesWireshark = false
        let loadedFile: NativeCaptureFile
        let loadedFormat: String
        do {
            let loaded = try NativeCaptureFile.load(from: url)
            loadedFile = loaded
            loadedFormat = loaded.format.rawValue
        } catch let thrownError {
            loadedFile = NativeCaptureFile.empty(url: url)
            loadedFormat = CaptureFileFormat.defaultExportFormat.rawValue
            errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .offlineFileOpenFailed) as NSError
        }
        self.state = Protected(PCPPNativeOfflineDocumentState(
            file: loadedFile,
            partiallyLoaded: loadedFile.isPartialResult,
            currentURL: url,
            currentFormat: loadedFormat
        ))
        configureDissectionSession(error: errorPointer)
    }

    init(url: URL, disablesWireshark: Bool, error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.disablesWireshark = disablesWireshark
        let loadedFile: NativeCaptureFile
        let loadedFormat: String
        do {
            let loaded = try NativeCaptureFile.load(from: url)
            loadedFile = loaded
            loadedFormat = loaded.format.rawValue
        } catch let thrownError {
            loadedFile = NativeCaptureFile.empty(url: url)
            loadedFormat = CaptureFileFormat.defaultExportFormat.rawValue
            errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .offlineFileOpenFailed) as NSError
        }
        self.state = Protected(PCPPNativeOfflineDocumentState(
            file: loadedFile,
            partiallyLoaded: loadedFile.isPartialResult,
            currentURL: url,
            currentFormat: loadedFormat
        ))
        configureDissectionSession(error: errorPointer)
    }

    func openAndReturnError(_ errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) -> [PCPPNativePacketSummaryDescriptor] {
        openIncrementally(withBatchSize: UInt.max, batchHandler: nil, progressHandler: nil, cancellationCheck: nil, error: errorPointer)
    }

    func reopenAndReturnError(_ errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) -> [PCPPNativePacketSummaryDescriptor] {
        reopenIncrementally(withBatchSize: UInt.max, batchHandler: nil, progressHandler: nil, cancellationCheck: nil, error: errorPointer)
    }

    func openIncrementally(
        withBatchSize batchSize: UInt,
        batchHandler: PCPPNativePacketBatchHandler?,
        progressHandler: PCPPNativeLoadProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [PCPPNativePacketSummaryDescriptor] {
        loadIncrementally(reload: false, batchSize: Int(clamping: batchSize), batchHandler: batchHandler, progressHandler: progressHandler, cancellationCheck: cancellationCheck, error: errorPointer)
    }

    func reopenIncrementally(
        withBatchSize batchSize: UInt,
        batchHandler: PCPPNativePacketBatchHandler?,
        progressHandler: PCPPNativeLoadProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [PCPPNativePacketSummaryDescriptor] {
        loadIncrementally(reload: true, batchSize: Int(clamping: batchSize), batchHandler: batchHandler, progressHandler: progressHandler, cancellationCheck: cancellationCheck, error: errorPointer)
    }

    func inspectPacket(withIdentifier identifier: UInt64) throws -> PCPPNativePacketInspectionDescriptor {
        try state.write { state in
            guard let record = state.file.records.first(where: { $0.identifier == identifier }) else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the backing store.")
            }
            return try autoreleasepool {
                try self.makePacketInspectionDescriptorSafely(record: record, state: &state)
            }
        }
    }

    // Copy the selected conversation before retapping the document's loaded Wireshark session.
    func followTCPStream(
        containing identifier: UInt64,
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkTCPFollowFields {
        let snapshot = try state.read { state -> (NativePacketRecord, [NativePacketRecord], WiresharkEpanSession, [UInt64]) in
            guard let selected = state.file.records.first(where: { $0.identifier == identifier }) else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the backing store.")
            }
            guard let session = state.dissectionSession else {
                throw NativeNSError(.unavailableFeature, "Wireshark TCP stream reassembly is unavailable for this capture.")
            }
            let candidateIdentifiers = try session.tcpFollowCandidatePacketIdentifiers(
                containing: identifier,
                maximumPacketCount: limits.maximumCandidatePacketCount
            )
            let identifierSet = Set(candidateIdentifiers)
            var records: [NativePacketRecord] = []
            records.reserveCapacity(candidateIdentifiers.count)
            for record in state.file.records {
                if shouldCancel?() == true {
                    throw NativeNSError(.operationCancelled, "TCP stream reassembly was cancelled.")
                }
                if identifierSet.contains(record.identifier) {
                    records.append(record)
                }
            }
            return (selected, records, session, candidateIdentifiers)
        }
        if snapshot.2.canFollowObservedPackets(withIdentifiers: snapshot.3) {
            return try snapshot.2.followObservedTCPStream(
                containing: snapshot.0,
                records: snapshot.1,
                limits: limits,
                progress: progress,
                shouldCancel: shouldCancel
            )
        }
        return try WiresharkEpanSession.followTCPStreamInTemporarySession(
            containing: snapshot.0,
            records: snapshot.1,
            limits: limits,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    func save() throws {
        let snapshot = state.read { ($0.file, $0.currentURL) }
        try NativeCaptureFile.write(records: snapshot.0.records, to: snapshot.1, format: snapshot.0.format)
        state.write {
            $0.dirty = false
        }
    }

    func save(to url: URL, format: String) throws {
        let outputFormat = CaptureFileFormat(exportRawValue: format)
        let records = state.read { $0.file.records }
        try NativeCaptureFile.write(records: records, to: url, format: outputFormat)
        state.write {
            $0.currentURL = url
            $0.currentFormat = outputFormat.rawValue
            $0.file.url = url
            $0.file.format = outputFormat
            $0.file.metadata = PCPPNativeCaptureDocumentMetadataDescriptor(format: outputFormat.rawValue, operatingSystem: nil, hardware: nil, captureApplication: nil, fileComment: nil)
            $0.dirty = false
        }
    }

    func exportPackets(
        withIdentifiers identifiers: [NSNumber],
        to url: URL,
        format: String,
        textStylesByPacketID: [PacketSummary.ID: PacketTextStyle] = [:],
        commentsByPacketID: [PacketSummary.ID: String] = [:],
        progressHandler: PCPPNativePacketExportProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?
    ) throws {
        let idSet = Set(identifiers.map(\.uint64Value))
        let records = state.read {
            $0.file.records.filter { idSet.contains($0.identifier) }
        }
        try Exporter.export(
            records: records,
            to: url,
            format: CaptureFileFormat(exportRawValue: format),
            textStylesByPacketID: textStylesByPacketID,
            commentsByPacketID: commentsByPacketID,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
    }

    private func loadIncrementally(
        reload: Bool,
        batchSize: Int,
        batchHandler: PCPPNativePacketBatchHandler?,
        progressHandler: PCPPNativeLoadProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> [PCPPNativePacketSummaryDescriptor] {
        do {
            let sourceURL = state.read(\.currentURL)
            if reload {
                let loaded = try NativeCaptureFile.load(from: sourceURL)
                try state.write {
                    $0.file = loaded
                    $0.currentFormat = loaded.format.rawValue
                    $0.partiallyLoaded = loaded.isPartialResult
                    $0.dissectionSession = try WiresharkEpanSession(disabled: disablesWireshark)
                }
            }

            let records = state.read { $0.file.records }
            let initialPartialResult = state.read(\.partiallyLoaded)
            let totalBytes = UInt64((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.uint64Value ?? 0)
            var summaries: [PCPPNativePacketSummaryDescriptor] = []
            var pendingBatch: [PCPPNativePacketSummaryDescriptor] = []
            var dnsTCPStreamParser = DNSTCPStreamParser()

            for (index, record) in records.enumerated() {
                if cancellationCheck?() == true {
                    let progress = PCPPNativePacketLoadProgressDescriptor(
                        phase: "cancelled",
                        loadedPacketCount: UInt64(summaries.count),
                        processedBytes: NSNumber(value: min(UInt64(index + 1), UInt64(records.count))),
                        totalBytes: NSNumber(value: UInt64(records.count)),
                        partialResult: true,
                        message: "Loading \(sourceURL.lastPathComponent) was cancelled."
                    )
                    progressHandler?(progress)
                    state.write {
                        $0.partiallyLoaded = true
                    }
                    throw NativeNSError(.operationCancelled, progress.message)
                }

                let summary = try autoreleasepool {
                    try state.write {
                        try self.makePacketSummaryDescriptorSafely(
                            record: record,
                            state: &$0,
                            dnsTCPStreamParser: &dnsTCPStreamParser
                        )
                    }
                }
                summaries.append(summary)
                pendingBatch.append(summary)

                if pendingBatch.count >= max(batchSize, 1) {
                    batchHandler?(pendingBatch)
                    pendingBatch.removeAll(keepingCapacity: true)
                    progressHandler?(PCPPNativePacketLoadProgressDescriptor(
                        phase: "loading",
                        loadedPacketCount: UInt64(summaries.count),
                        processedBytes: NSNumber(value: totalBytes == 0 ? UInt64(summaries.count) : UInt64(Double(totalBytes) * Double(summaries.count) / Double(max(records.count, 1)))),
                        totalBytes: NSNumber(value: totalBytes),
                        partialResult: initialPartialResult,
                        message: self.loadProgressMessage(prefix: "Loaded", packetCount: summaries.count)
                    ))
                }
            }

            if !pendingBatch.isEmpty {
                batchHandler?(pendingBatch)
            }
            state.write {
                try? requireDissectionSession(in: $0).finishFirstPass()
            }
            let partialResult = state.read(\.partiallyLoaded)
            progressHandler?(PCPPNativePacketLoadProgressDescriptor(
                phase: "completed",
                loadedPacketCount: UInt64(summaries.count),
                processedBytes: NSNumber(value: totalBytes),
                totalBytes: NSNumber(value: totalBytes),
                partialResult: partialResult,
                message: self.loadProgressMessage(prefix: "Loaded", packetCount: summaries.count)
            ))
            return summaries
        } catch let thrownError {
            assign(thrownError, to: errorPointer)
            return []
        }
    }

    private func assign(_ thrownError: Error, to errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .offlineFileOpenFailed) as NSError
    }

    private func configureDissectionSession(error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        do {
            let session = try WiresharkEpanSession(disabled: disablesWireshark)
            state.write {
                $0.dissectionSession = session
            }
        } catch let thrownError {
            if errorPointer?.pointee == nil {
                errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .unavailableFeature) as NSError
            }
        }
    }

    private func requireDissectionSession(in state: PCPPNativeOfflineDocumentState) throws -> WiresharkEpanSession {
        guard let dissectionSession = state.dissectionSession else {
            throw NativeNSError(.unavailableFeature, "Wireshark libwireshark backend is unavailable.")
        }
        return dissectionSession
    }

    private func makePacketSummaryDescriptorSafely(
        record: NativePacketRecord,
        state: inout PCPPNativeOfflineDocumentState,
        dnsTCPStreamParser: inout DNSTCPStreamParser
    ) throws -> PCPPNativePacketSummaryDescriptor {
        var analyzed = PacketAnalyzer(record: record).analyze()
        mergeDNSResolutions(
            dnsTCPStreamParser.resolutions(for: analyzed, at: record.timestamp),
            into: &analyzed
        )
        do {
            let session = try requireDissectionSession(in: state)
            try session.observe(record)
            let wiresharkSummary = try session.summarize(record)
            return makePacketSummaryDescriptor(record: record, analyzed: analyzed, wireshark: wiresharkSummary)
        } catch {
            if NativeErrorIsCriticalWiresharkException(error) {
                throw error
            }
            // A single packet can be malformed enough for epan to reject it; keep the file open.
            state.partiallyLoaded = true
            return SwiftPacketDissector.dissect(
                record: record,
                disablesWireshark: true,
                analyzedPacket: analyzed
            ).summary
        }
    }

    private func makePacketInspectionDescriptorSafely(
        record: NativePacketRecord,
        state: inout PCPPNativeOfflineDocumentState
    ) throws -> PCPPNativePacketInspectionDescriptor {
        do {
            let analyzer = PacketAnalyzer(record: record).analyze()
            let inspection = try requireDissectionSession(in: state).inspect(record)
            return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
        } catch {
            if NativeErrorIsCriticalWiresharkException(error) {
                throw error
            }
            return SwiftPacketDissector.dissect(record: record, disablesWireshark: true).inspection
        }
    }

    private func loadProgressMessage(prefix: String, packetCount: Int) -> String {
        state.read {
            $0.file.loadSummaryMessage(prefix: prefix).replacingOccurrences(
                of: "\(prefix) \($0.file.records.count) packets",
                with: "\(prefix) \(packetCount) packets"
            )
        }
    }
}

protocol PCPPNativeLiveCaptureBackend {
    func open(interfaceName: String, options: PCPPNativeCaptureOptionsDescriptor) throws -> OpaquePointer
    func read(from handle: OpaquePointer) -> LibpcapPacketReadResult
    func statistics(for handle: OpaquePointer) -> pcap_stat?
    func dataLink(for handle: OpaquePointer) -> Int32
    func breakLoop(_ handle: OpaquePointer)
    func close(_ handle: OpaquePointer)
}

private struct LibpcapLiveCaptureBackend: PCPPNativeLiveCaptureBackend {
    func open(interfaceName: String, options: PCPPNativeCaptureOptionsDescriptor) throws -> OpaquePointer {
        try Libpcap.openLive(interfaceName: interfaceName, options: options)
    }

    func read(from handle: OpaquePointer) -> LibpcapPacketReadResult {
        Libpcap.nextPacket(from: handle)
    }

    func statistics(for handle: OpaquePointer) -> pcap_stat? {
        Libpcap.stats(for: handle)
    }

    func dataLink(for handle: OpaquePointer) -> Int32 {
        Libpcap.dataLink(for: handle)
    }

    func breakLoop(_ handle: OpaquePointer) {
        Libpcap.breakLoop(handle)
    }

    func close(_ handle: OpaquePointer) {
        Libpcap.close(handle)
    }
}

private struct PCPPNativeLiveSessionState {
    var handle: OpaquePointer?
    var phase: PCPPNativeLiveSessionPhase = .ready
    var running = false
    var paused = false
    var packetNumber: UInt64 = 1
    var packetStore = NativeLivePacketDiskStore()
    var packetsReceived: UInt64 = 0
    var packetsDropped: UInt64 = 0
    var packetsDroppedByInterface: UInt64 = 0
    var liveLinkLayerType = Libpcap.dltEthernet
    var dissectionSession: WiresharkEpanSession?
    var dnsTCPStreamParser = DNSTCPStreamParser()
    var statusMessage: String?
}

final class PCPPNativeLiveSession {
    var packetHandler: PCPPNativePacketBatchHandler?
    var phaseHandler: PCPPNativeSessionPhaseHandler?
    var healthHandler: PCPPNativeHealthHandler?
    var errorHandler: PCPPNativeErrorHandler?

    private let interfaceIdentifier: String
    private let options: PCPPNativeCaptureOptionsDescriptor
    private let disablesWireshark: Bool
    private let captureBackend: any PCPPNativeLiveCaptureBackend
    private let dissectionSessionFactory: () throws -> WiresharkEpanSession?
    private let state: Protected<PCPPNativeLiveSessionState>
    private let captureQueue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.PCPPNativeLiveSession.capture", qos: .userInitiated)
    private let captureQueueKey = DispatchSpecificKey<UInt8>()

    var healthSnapshot: PCPPNativeCaptureHealthDescriptor {
        state.read {
            healthDescriptor(status: nil, state: $0)
        }
    }

    init(interfaceIdentifier: String, options: PCPPNativeCaptureOptionsDescriptor, error: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.interfaceIdentifier = interfaceIdentifier
        self.options = options
        self.disablesWireshark = false
        self.captureBackend = LibpcapLiveCaptureBackend()
        self.dissectionSessionFactory = { try WiresharkEpanSession(purpose: .live) }
        self.state = Protected(PCPPNativeLiveSessionState())
        self.captureQueue.setSpecific(key: captureQueueKey, value: 1)
    }

    init(interfaceIdentifier: String, options: PCPPNativeCaptureOptionsDescriptor, disablesWireshark: Bool, error: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.interfaceIdentifier = interfaceIdentifier
        self.options = options
        self.disablesWireshark = disablesWireshark
        self.captureBackend = LibpcapLiveCaptureBackend()
        self.dissectionSessionFactory = disablesWireshark ? { nil } : { try WiresharkEpanSession(purpose: .live) }
        self.state = Protected(PCPPNativeLiveSessionState())
        self.captureQueue.setSpecific(key: captureQueueKey, value: 1)
    }

    init(
        interfaceIdentifier: String,
        options: PCPPNativeCaptureOptionsDescriptor,
        captureBackend: any PCPPNativeLiveCaptureBackend,
        dissectionSessionFactory: @escaping () throws -> WiresharkEpanSession? = { nil }
    ) {
        self.interfaceIdentifier = interfaceIdentifier
        self.options = options
        self.disablesWireshark = true
        self.captureBackend = captureBackend
        self.dissectionSessionFactory = dissectionSessionFactory
        self.state = Protected(PCPPNativeLiveSessionState())
        self.captureQueue.setSpecific(key: captureQueueKey, value: 1)
    }

    func start() throws {
        let shouldOpen = state.write {
            if $0.phase == .running || $0.phase == .starting {
                return false
            }
            $0.phase = .starting
            return true
        }
        guard shouldOpen else {
            return
        }

        phaseHandler?(.starting, "Starting capture on \(interfaceIdentifier)...")
        let openedHandle: OpaquePointer
        do {
            openedHandle = try captureBackend.open(interfaceName: interfaceIdentifier, options: options)
        } catch {
            state.write {
                $0.handle = nil
                $0.running = false
                $0.paused = false
                $0.phase = .failed
                $0.dissectionSession = nil
                $0.statusMessage = nil
            }
            throw error
        }

        // Acquire process-global EPAN ownership only after libpcap can start successfully.
        let nextDissectionSession: WiresharkEpanSession?
        let dissectionStatus: String?
        do {
            nextDissectionSession = try dissectionSessionFactory()
            dissectionStatus = disablesWireshark ? "Wireshark details are disabled; capture continues with the Swift dissector." : nil
        } catch {
            nextDissectionSession = nil
            dissectionStatus = "Wireshark details are unavailable; capture continues with the Swift dissector."
        }

        state.write {
            $0.handle = openedHandle
            $0.dissectionSession = nextDissectionSession
            $0.running = true
            $0.paused = false
            $0.phase = .running
            $0.packetNumber = 1
            $0.liveLinkLayerType = captureBackend.dataLink(for: openedHandle)
            $0.packetStore.reset()
            $0.dnsTCPStreamParser.reset()
            $0.packetsReceived = 0
            $0.packetsDropped = 0
            $0.packetsDroppedByInterface = 0
            $0.statusMessage = dissectionStatus
        }
        phaseHandler?(.running, "Capture running on \(interfaceIdentifier).")
        captureQueue.async { [weak self] in
            self?.captureLoop(handle: openedHandle)
        }
    }

    func pause() throws {
        state.write {
            guard $0.phase == .running else { return }
            $0.paused = true
            $0.phase = .paused
        }
        phaseHandler?(.paused, "Capture paused.")
        healthHandler?(healthSnapshot)
    }

    func resume() throws {
        state.write {
            guard $0.phase == .paused else { return }
            $0.paused = false
            $0.phase = .running
        }
        phaseHandler?(.running, "Capture resumed.")
    }

    func stop() throws {
        let handleToStop = state.write { state -> OpaquePointer? in
            if state.phase == .stopped {
                return nil
            }
            state.running = false
            state.paused = false
            state.phase = state.handle == nil ? .stopped : .stopping
            return state.handle
        }

        if let handleToStop {
            phaseHandler?(.stopping, "Stopping capture...")
            captureBackend.breakLoop(handleToStop)
            waitForCaptureLoopIfNeeded()
        }
        state.write {
            try? $0.dissectionSession?.finishFirstPass()
            $0.dissectionSession = nil
        }
        if let handleToStop {
            closeCaptureHandleIfOwned(handleToStop)
        }
        state.write { $0.phase = .stopped }
        healthHandler?(healthSnapshot)
        phaseHandler?(.stopped, "Capture stopped.")
    }

    // Release the native handle even when the public session is discarded without stop().
    func shutdown() {
        let handle = state.write { state -> OpaquePointer? in
            state.running = false
            state.paused = false
            return state.handle
        }
        guard let handle else {
            return
        }

        captureBackend.breakLoop(handle)
        waitForCaptureLoopIfNeeded()
        closeCaptureHandleIfOwned(handle)
        state.write {
            $0.phase = .stopped
            $0.dissectionSession = nil
        }
    }

    func clearCapturedPackets() {
        let nextDissectionSession = try? dissectionSessionFactory()
        state.write {
            $0.packetNumber = 1
            $0.packetStore.reset()
            $0.packetsReceived = 0
            $0.packetsDropped = 0
            $0.packetsDroppedByInterface = 0
            $0.dissectionSession = nextDissectionSession
            $0.dnsTCPStreamParser.reset()
            if nextDissectionSession != nil {
                $0.statusMessage = nil
            }
        }
    }

    func inspectPacket(withIdentifier identifier: UInt64) throws -> PCPPNativePacketInspectionDescriptor {
        try state.write { state in
            let record = try state.packetStore.record(withIdentifier: identifier)
            return autoreleasepool {
                guard let session = state.dissectionSession else {
                    return SwiftPacketDissector.dissect(record: record, disablesWireshark: true).inspection
                }

                do {
                    let analyzer = PacketAnalyzer(record: record).analyze()
                    let inspection = try session.inspect(record)
                    return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
                } catch {
                    disableWiresharkAfterFailure(error, state: &state)
                    return SwiftPacketDissector.dissect(record: record, disablesWireshark: true).inspection
                }
            }
        }
    }

    // Follow a duplicated disk snapshot without blocking live packet storage during the retap.
    func followTCPStream(
        containing identifier: UInt64,
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> TCPFollowStream {
        let resources = try state.read { state -> (snapshot: NativeLivePacketDiskSnapshot, session: WiresharkEpanSession) in
            guard let session = state.dissectionSession else {
                throw NativeNSError(.unavailableFeature, "Wireshark TCP stream reassembly is unavailable for this capture.")
            }
            let snapshot = try state.packetStore.snapshotForTCPStream(
                containing: identifier,
                maximumPacketCount: limits.maximumCandidatePacketCount,
                shouldCancel: shouldCancel
            )
            return (snapshot, session)
        }
        let maximumInputBytes = limits.maximumPayloadBytes > 128 * 1_024 * 1_024
            ? 256 * 1_024 * 1_024
            : max(limits.maximumPayloadBytes * 2, 16 * 1_024 * 1_024)
        let records = try resources.snapshot.records(
            maximumBytes: maximumInputBytes,
            shouldCancel: shouldCancel
        )
        guard let selected = records.first(where: { $0.identifier == identifier }) else {
            throw NativeNSError(.fileReadFailed, "The selected TCP packet is no longer in the live snapshot.")
        }
        let fields = try resources.session.followObservedTCPStream(
            containing: selected,
            records: records,
            limits: limits,
            progress: progress,
            shouldCancel: shouldCancel
        )
        return TCPFollowStream(
            client: fields.client,
            server: fields.server,
            records: fields.records,
            clientByteCount: fields.clientByteCount,
            serverByteCount: fields.serverByteCount,
            capturedThroughPacketID: resources.snapshot.capturedThroughPacketID,
            capturedAt: Date(),
            isTruncated: fields.isTruncated
        )
    }

    func reanalyzePacketSummaries() throws -> [PCPPNativePacketSummaryDescriptor] {
        try reanalyzePacketSummaries(withIdentifiers: nil)
    }

    func reanalyzePacketSummaryUpdates() throws -> [PCPPNativePacketSummaryUpdateDescriptor] {
        try reanalyzePacketSummaries().map {
            PCPPNativePacketSummaryUpdateDescriptor(
                packetIdentifier: $0.identifier,
                protocolSummary: $0.protocolSummary,
                infoSummary: $0.infoSummary
            )
        }
    }

    func reanalyzePacketSummaryUpdates(withIdentifiers identifiers: [UInt64]) throws -> [PCPPNativePacketSummaryUpdateDescriptor] {
        try reanalyzePacketSummaries(withIdentifiers: identifiers).map {
            PCPPNativePacketSummaryUpdateDescriptor(
                packetIdentifier: $0.identifier,
                protocolSummary: $0.protocolSummary,
                infoSummary: $0.infoSummary
            )
        }
    }

    private func reanalyzePacketSummaries(withIdentifiers identifiers: [UInt64]?) throws -> [PCPPNativePacketSummaryDescriptor] {
        try state.write { state in
            let selectedRecords = try state.packetStore.records(withIdentifiers: identifiers)
            return selectedRecords.map { record in
                autoreleasepool {
                    guard let session = state.dissectionSession else {
                        return SwiftPacketDissector.dissect(record: record, disablesWireshark: true).summary
                    }

                    do {
                        let wiresharkSummary = try session.summarize(record)
                        let analyzer = PacketAnalyzer(record: record).analyze()
                        return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
                    } catch {
                        disableWiresharkAfterFailure(error, state: &state)
                        return SwiftPacketDissector.dissect(record: record, disablesWireshark: true).summary
                    }
                }
            }
        }
    }

    func exportPackets(
        withIdentifiers identifiers: [NSNumber],
        to url: URL,
        format: String,
        textStylesByPacketID: [PacketSummary.ID: PacketTextStyle] = [:],
        commentsByPacketID: [PacketSummary.ID: String] = [:],
        progressHandler: PCPPNativePacketExportProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?
    ) throws {
        let idSet = Set(identifiers.map(\.uint64Value))
        let selected = try state.read {
            try $0.packetStore.records(matching: idSet)
        }
        try Exporter.export(
            records: selected,
            to: url,
            format: CaptureFileFormat(exportRawValue: format),
            textStylesByPacketID: textStylesByPacketID,
            commentsByPacketID: commentsByPacketID,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
    }

    private func captureLoop(handle: OpaquePointer) {
        while true {
            let shouldContinue = state.read(\.running)
            guard shouldContinue else {
                break
            }
            if state.read(\.paused) {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            let next: (header: pcap_pkthdr, bytes: Data)
            switch captureBackend.read(from: handle) {
            case .packet(let header, let bytes):
                next = (header, bytes)
            case .timeout:
                continue
            case .stopped:
                if state.read(\.running) {
                    handleCaptureReadFailure("libpcap ended capture unexpectedly.", handle: handle)
                }
                return
            case .failure(let message):
                handleCaptureReadFailure("libpcap stopped reading packets: \(message)", handle: handle)
                return
            }
            let packetTimestamp = Date(timeIntervalSince1970: TimeInterval(next.header.ts.tv_sec) + TimeInterval(next.header.ts.tv_usec) / 1_000_000)
            let captured: (record: NativePacketRecord, analyzed: AnalyzedPacket)
            do {
                captured = try state.write {
                    let record = NativePacketRecord(
                        identifier: $0.packetNumber,
                        packetNumber: $0.packetNumber,
                        timestamp: packetTimestamp,
                        rawBytes: next.bytes,
                        originalLength: Int(next.header.len),
                        linkLayerType: $0.liveLinkLayerType,
                        interfaceIdentifier: interfaceIdentifier,
                        interfaceName: interfaceIdentifier,
                        packetComment: nil
                    )
                    let analyzed = PacketAnalyzer(record: record).analyze()
                    try $0.packetStore.append(record)
                    $0.packetNumber += 1
                    $0.packetsReceived += 1
                    return (record, analyzed)
                }
            } catch {
                handleCaptureReadFailure("Live packet storage failed: \(error.localizedDescription)", handle: handle)
                return
            }
            let record = captured.record

            let result: (summary: PCPPNativePacketSummaryDescriptor, degraded: Bool) = autoreleasepool {
                state.write {
                    var analyzed = captured.analyzed
                    mergeDNSResolutions(
                        $0.dnsTCPStreamParser.resolutions(for: analyzed, at: record.timestamp),
                        into: &analyzed
                    )
                    guard let session = $0.dissectionSession else {
                        return (SwiftPacketDissector.dissect(
                            record: record,
                            disablesWireshark: true,
                            analyzedPacket: analyzed
                        ).summary, false)
                    }

                    do {
                        let streamIndexUpdates = try session.observe(record)
                        $0.packetStore.markTCPStreamsReady(streamIndexUpdates)
                        let wiresharkSummary = try session.summarize(record)
                        return (makePacketSummaryDescriptor(record: record, analyzed: analyzed, wireshark: wiresharkSummary), false)
                    } catch {
                        disableWiresharkAfterFailure(error, state: &$0)
                        return (SwiftPacketDissector.dissect(
                            record: record,
                            disablesWireshark: true,
                            analyzedPacket: analyzed
                        ).summary, true)
                    }
                }
            }
            if result.degraded {
                healthHandler?(healthSnapshot)
            }
            packetHandler?([result.summary])
            if record.packetNumber % 128 == 0 {
                healthHandler?(healthSnapshot)
            }
        }
    }

    private func handleCaptureReadFailure(_ message: String, handle: OpaquePointer) {
        let error = NativeNSError(.captureStopFailed, message)
        state.write { state in
            state.running = false
            state.paused = false
            state.phase = .failed
            state.statusMessage = message
            state.dissectionSession = nil
        }
        closeCaptureHandleIfOwned(handle)
        errorHandler?(error)
        phaseHandler?(.failed, message)
    }

    private func closeCaptureHandleIfOwned(_ handle: OpaquePointer) {
        let statistics = captureBackend.statistics(for: handle)
        let shouldClose = state.write { state -> Bool in
            guard state.handle == handle else {
                return false
            }
            if let statistics {
                state.packetsReceived = UInt64(statistics.ps_recv)
                state.packetsDropped = UInt64(statistics.ps_drop)
                state.packetsDroppedByInterface = UInt64(statistics.ps_ifdrop)
            }
            state.handle = nil
            return true
        }
        if shouldClose {
            captureBackend.close(handle)
        }
    }

    private func waitForCaptureLoopIfNeeded() {
        // A callback may release the public session on this queue; never synchronously join it from itself.
        guard DispatchQueue.getSpecific(key: captureQueueKey) == nil else {
            return
        }
        captureQueue.sync {}
    }

    private func disableWiresharkAfterFailure(_ error: Error, state: inout PCPPNativeLiveSessionState) {
        let message = NativeBridgeMapper.coreError(error, defaultCode: .unavailableFeature).message
        state.dissectionSession = nil
        state.statusMessage = "Wireshark details are unavailable; capture continues with the Swift dissector. \(message)"
    }

    private func healthDescriptor(status: String?, state: PCPPNativeLiveSessionState) -> PCPPNativeCaptureHealthDescriptor {
        PCPPNativeCaptureHealthDescriptor(
            packetsReceived: state.packetsReceived,
            packetsDropped: state.packetsDropped,
            packetsDroppedByInterface: state.packetsDroppedByInterface,
            packetsObserved: state.packetsReceived + state.packetsDropped,
            lastUpdated: Date(),
            statusMessage: status ?? state.statusMessage
        )
    }
}

// Merge stream observations with packet-local parsing while preserving stable order.
private func mergeDNSResolutions(_ resolutions: [DNSResolutionObservation], into packet: inout AnalyzedPacket) {
    guard !resolutions.isEmpty else {
        return
    }
    var seen = Set(packet.dnsResolutions)
    packet.dnsResolutions.append(contentsOf: resolutions.filter { seen.insert($0).inserted })
}

private func makePacketSummaryDescriptor(
    record: NativePacketRecord,
    analyzed: AnalyzedPacket,
    wireshark: WiresharkPacketSummaryFields
) -> PCPPNativePacketSummaryDescriptor {
    PCPPNativePacketSummaryDescriptor(
        identifier: record.identifier,
        packetNumber: record.packetNumber,
        timestamp: record.timestamp,
        interfaceIdentifier: record.interfaceIdentifier,
        transportHint: transportHint(analyzed: analyzed, wireshark: wireshark),
        protocolSummary: wireshark.protocolSummary,
        sourceEndpoint: PCPPNativePacketEndpointDescriptor(
            address: analyzed.sourceAddress,
            port: analyzed.sourcePort.map { NSNumber(value: $0) }
        ),
        destinationEndpoint: PCPPNativePacketEndpointDescriptor(
            address: analyzed.destinationAddress,
            port: analyzed.destinationPort.map { NSNumber(value: $0) }
        ),
        originalLength: record.originalLength,
        capturedLength: record.rawBytes.count,
        streamIdentifier: analyzed.streamID.map { NSNumber(value: $0) },
        tcpFlags: analyzed.tcpFlags,
        tcpPayloadLength: analyzed.tcpPayloadLength.map { NSNumber(value: $0) },
        infoSummary: wireshark.infoSummary,
        layers: analyzed.layers.map { PCPPNativePacketLayerDescriptor(name: $0.name, detailSummary: $0.detailSummary) },
        decodeStatus: decodeStatusDescriptor(analyzed.decodeStatus),
        captureMetadata: captureMetadataDescriptor(record),
        sniDomainName: wireshark.sniDomainName,
        dnsResolutions: analyzed.dnsResolutions,
        textStyle: record.textStyle
    )
}

private func transportHint(analyzed: AnalyzedPacket, wireshark: WiresharkPacketSummaryFields) -> PCPPNativeTransportHint {
    let protocolSummary = wireshark.protocolSummary?.lowercased() ?? ""
    let infoSummary = wireshark.infoSummary.lowercased()

    // Wireshark has conversation/reassembly state that the metadata analyzer intentionally does not keep.
    // Let epan's decoded protocol win for app-level hints when it has stronger evidence.
    if wireshark.sniDomainName?.isEmpty == false
        || protocolSummary.contains("tls")
        || infoSummary.contains("client hello")
        || infoSummary.contains("server hello") {
        return .tls
    }
    if protocolSummary.contains("dns") {
        return .dns
    }
    if protocolSummary.contains("websocket") {
        return .websocket
    }
    if protocolSummary.contains("http") {
        return .http1
    }

    return analyzed.transportHint.nativeHint
}

private func makePacketInspectionDescriptor(
    record: NativePacketRecord,
    analyzed: AnalyzedPacket,
    wireshark: WiresharkPacketInspectionFields
) -> PCPPNativePacketInspectionDescriptor {
    PCPPNativePacketInspectionDescriptor(
        packetIdentifier: record.identifier,
        packetNumber: record.packetNumber,
        rawBytes: record.rawBytes,
        byteViews: wireshark.byteViews.isEmpty ? [PCPPNativePacketByteViewDescriptor(identifier: "frame", label: "Frame", bytes: record.rawBytes)] : wireshark.byteViews,
        detailNodes: wireshark.detailNodes,
        decodeStatus: decodeStatusDescriptor(analyzed.decodeStatus)
    )
}

private func decodeStatusDescriptor(_ status: PacketDecodeStatus) -> PCPPNativeDecodeStatusDescriptor {
    PCPPNativeDecodeStatusDescriptor(kind: status.kind.nativeKind, reason: status.reason)
}

private func captureMetadataDescriptor(_ record: NativePacketRecord) -> PCPPNativePacketCaptureMetadataDescriptor {
    PCPPNativePacketCaptureMetadataDescriptor(
        linkType: nativeLinkType(record.linkLayerType),
        truncated: record.rawBytes.count < record.originalLength,
        packetComment: record.packetComment,
        interfaceName: record.interfaceName
    )
}

private func nativeLinkType(_ linkLayerType: Int32) -> PCPPNativeLinkType {
    switch linkLayerType {
    case Libpcap.dltEthernet:
        return .ethernet
    case Libpcap.dltNull:
        return .loopback
    case Libpcap.dltRaw:
        return .raw
    default:
        return .unknown
    }
}

#if DEBUG
private struct PCPPNativeLivePacketStoreTestProbeState {
    var packetStore = NativeLivePacketDiskStore()
    var dissectionSession: WiresharkEpanSession?
}

final class PCPPNativeLivePacketStoreTestProbe {
    private let state: Protected<PCPPNativeLivePacketStoreTestProbeState>
    var packetCount: UInt {
        state.read { UInt($0.packetStore.count) }
    }

    var backingFileSize: UInt64 {
        state.read { $0.packetStore.backingFileSize }
    }

    var backingFileExists: Bool {
        state.read { $0.packetStore.fileExists }
    }

    var backingFilePath: String {
        state.read { $0.packetStore.filePath }
    }

    init() {
        self.state = Protected(PCPPNativeLivePacketStoreTestProbeState(dissectionSession: try? WiresharkEpanSession()))
    }

    func appendPacket(identifier: UInt64, rawBytes: Data, timestamp: Date, linkLayerType: Int, originalLength: Int) throws {
        try state.write {
            let packetNumber = UInt64($0.packetStore.count + 1)
            let record = NativePacketRecord(
                identifier: identifier,
                packetNumber: packetNumber,
                timestamp: timestamp,
                rawBytes: rawBytes,
                originalLength: originalLength,
                linkLayerType: Int32(linkLayerType),
                interfaceIdentifier: nil,
                interfaceName: nil,
                packetComment: nil
            )
            try $0.packetStore.append(record)
            try requireDissectionSession(in: $0).observe(record)
        }
    }

    func inspectPacket(identifier: UInt64) throws -> PCPPNativePacketInspectionDescriptor {
        try state.write { state in
            let record = try state.packetStore.record(withIdentifier: identifier)
            return try autoreleasepool {
                let analyzer = PacketAnalyzer(record: record).analyze()
                let inspection = try requireDissectionSession(in: state).inspect(record)
                return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
            }
        }
    }

    func reanalyzePacketSummaries(upTo identifier: UInt64) throws -> [PCPPNativePacketSummaryDescriptor] {
        try state.write { state in
            let selectedRecords = try state.packetStore.records(upTo: identifier)
            let session = try requireDissectionSession(in: state)
            return try selectedRecords.map { record in
                try autoreleasepool {
                    try session.observe(record)
                    let wiresharkSummary = try session.summarize(record)
                    let analyzer = PacketAnalyzer(record: record).analyze()
                    return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
                }
            }
        }
    }

    func reanalyzePacketSummaryUpdates(upTo identifier: UInt64) throws -> [PCPPNativePacketSummaryUpdateDescriptor] {
        try reanalyzePacketSummaries(upTo: identifier).map {
            PCPPNativePacketSummaryUpdateDescriptor(packetIdentifier: $0.identifier, protocolSummary: $0.protocolSummary, infoSummary: $0.infoSummary)
        }
    }

    func offset(identifier: UInt64) throws -> NSNumber {
        try state.read {
            NSNumber(value: try $0.packetStore.offset(for: identifier))
        }
    }

    func cleanup() {
        state.write {
            $0.packetStore.reset()
            $0.dissectionSession = nil
        }
    }

    private func requireDissectionSession(in state: PCPPNativeLivePacketStoreTestProbeState) throws -> WiresharkEpanSession {
        guard let dissectionSession = state.dissectionSession else {
            throw NativeNSError(.unavailableFeature, "Wireshark libwireshark backend is unavailable.")
        }
        return dissectionSession
    }
}
#endif

enum Exporter {
    static func export(
        records: [NativePacketRecord],
        to url: URL,
        format: CaptureFileFormat,
        textStylesByPacketID: [PacketSummary.ID: PacketTextStyle] = [:],
        commentsByPacketID: [PacketSummary.ID: String] = [:],
        progressHandler: PCPPNativePacketExportProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?
    ) throws {
        guard !records.isEmpty else {
            throw NativeNSError(.fileWriteFailed, "There are no packets to export.")
        }
        for index in records.indices {
            if cancellationCheck?() == true {
                throw NativeNSError(.operationCancelled, "Packet export was cancelled.")
            }
            progressHandler?(UInt(index), UInt(records.count))
        }
        try NativeCaptureFile.write(
            records: records,
            to: url,
            format: format,
            textStylesByPacketID: textStylesByPacketID,
            commentsByPacketID: commentsByPacketID
        )
        progressHandler?(UInt(records.count), UInt(records.count))
    }
}

private extension NativeCaptureFile {
    static func empty(url: URL) -> NativeCaptureFile {
        NativeCaptureFile(
            url: url,
            format: .pcapng,
            records: [],
            metadata: PCPPNativeCaptureDocumentMetadataDescriptor(
                format: CaptureFileFormat.pcapng.rawValue,
                operatingSystem: nil,
                hardware: nil,
                captureApplication: nil,
                fileComment: nil
            )
        )
    }
}
