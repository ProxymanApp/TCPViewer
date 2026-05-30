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
        self.state = Protected(PCPPNativeOfflineDocumentState(file: loadedFile, currentURL: url, currentFormat: loadedFormat))
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
        self.state = Protected(PCPPNativeOfflineDocumentState(file: loadedFile, currentURL: url, currentFormat: loadedFormat))
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
                let analyzer = PacketAnalyzer(record: record).analyze()
                let inspection = try requireDissectionSession(in: state).inspect(record)
                return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
            }
        }
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
        progressHandler: PCPPNativePacketExportProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?
    ) throws {
        let idSet = Set(identifiers.map(\.uint64Value))
        let records = state.read {
            $0.file.records.filter { idSet.contains($0.identifier) }
        }
        try Exporter.export(records: records, to: url, format: CaptureFileFormat(exportRawValue: format), progressHandler: progressHandler, cancellationCheck: cancellationCheck)
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
                    $0.partiallyLoaded = false
                    $0.dissectionSession = try WiresharkEpanSession(disabled: disablesWireshark)
                }
            }

            let records = state.read { $0.file.records }
            let totalBytes = UInt64((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.uint64Value ?? 0)
            var summaries: [PCPPNativePacketSummaryDescriptor] = []
            var pendingBatch: [PCPPNativePacketSummaryDescriptor] = []

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
                        let session = try requireDissectionSession(in: $0)
                        try session.observe(record)
                        let wiresharkSummary = try session.summarize(record)
                        let analyzer = PacketAnalyzer(record: record).analyze()
                        return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
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
                        partialResult: false,
                        message: "Loaded \(summaries.count) packets from \(sourceURL.lastPathComponent)."
                    ))
                }
            }

            if !pendingBatch.isEmpty {
                batchHandler?(pendingBatch)
            }
            try state.write {
                try requireDissectionSession(in: $0).finishFirstPass()
            }
            progressHandler?(PCPPNativePacketLoadProgressDescriptor(
                phase: "completed",
                loadedPacketCount: UInt64(summaries.count),
                processedBytes: NSNumber(value: totalBytes),
                totalBytes: NSNumber(value: totalBytes),
                partialResult: false,
                message: "Loaded \(summaries.count) packets from \(sourceURL.lastPathComponent)."
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
}

private struct PCPPNativeLiveSessionState {
    var handle: OpaquePointer?
    var phase: PCPPNativeLiveSessionPhase = .ready
    var running = false
    var paused = false
    var packetNumber: UInt64 = 1
    var records: [NativePacketRecord] = []
    var recordIndexByID: [UInt64: Int] = [:]
    var packetsReceived: UInt64 = 0
    var packetsDropped: UInt64 = 0
    var packetsDroppedByInterface: UInt64 = 0
    var liveLinkLayerType = Libpcap.dltEthernet
    var dissectionSession: WiresharkEpanSession?
}

final class PCPPNativeLiveSession {
    var packetHandler: PCPPNativePacketBatchHandler?
    var phaseHandler: PCPPNativeSessionPhaseHandler?
    var healthHandler: PCPPNativeHealthHandler?
    var errorHandler: PCPPNativeErrorHandler?

    private let interfaceIdentifier: String
    private let options: PCPPNativeCaptureOptionsDescriptor
    private let disablesWireshark: Bool
    private let state: Protected<PCPPNativeLiveSessionState>
    private let captureQueue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.PCPPNativeLiveSession.capture", qos: .userInitiated)

    var healthSnapshot: PCPPNativeCaptureHealthDescriptor {
        state.read {
            healthDescriptor(status: nil, state: $0)
        }
    }

    init(interfaceIdentifier: String, options: PCPPNativeCaptureOptionsDescriptor, error: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.interfaceIdentifier = interfaceIdentifier
        self.options = options
        self.disablesWireshark = false
        self.state = Protected(PCPPNativeLiveSessionState(dissectionSession: try? WiresharkEpanSession()))
    }

    init(interfaceIdentifier: String, options: PCPPNativeCaptureOptionsDescriptor, disablesWireshark: Bool, error: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.interfaceIdentifier = interfaceIdentifier
        self.options = options
        self.disablesWireshark = disablesWireshark
        self.state = Protected(PCPPNativeLiveSessionState(dissectionSession: try? WiresharkEpanSession(disabled: disablesWireshark)))
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
        let nextDissectionSession = try WiresharkEpanSession(disabled: disablesWireshark)
        let openedHandle = try Libpcap.openLive(interfaceName: interfaceIdentifier, options: options)
        state.write {
            $0.handle = openedHandle
            $0.dissectionSession = nextDissectionSession
            $0.running = true
            $0.paused = false
            $0.phase = .running
            $0.packetNumber = 1
            $0.liveLinkLayerType = Libpcap.dataLink(for: openedHandle)
            $0.records.removeAll(keepingCapacity: false)
            $0.recordIndexByID.removeAll(keepingCapacity: false)
            $0.packetsReceived = 0
            $0.packetsDropped = 0
            $0.packetsDroppedByInterface = 0
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
                state.phase = .stopped
                return nil
            }
            if state.phase == .ready {
                state.running = false
                state.phase = .stopped
                return nil
            }
            state.phase = .stopping
            state.running = false
            return state.handle
        }

        if let handleToStop {
            phaseHandler?(.stopping, "Stopping capture...")
            Libpcap.breakLoop(handleToStop)
            captureQueue.sync {}
        }
        try? state.write {
            try $0.dissectionSession?.finishFirstPass()
        }

        state.write {
            $0.phase = .stopped
            if let handle = $0.handle {
                if let stats = Libpcap.stats(for: handle) {
                    $0.packetsReceived = UInt64(stats.ps_recv)
                    $0.packetsDropped = UInt64(stats.ps_drop)
                    $0.packetsDroppedByInterface = UInt64(stats.ps_ifdrop)
                }
                Libpcap.close(handle)
                $0.handle = nil
            }
        }
        healthHandler?(healthSnapshot)
        phaseHandler?(.stopped, "Capture stopped.")
    }

    func clearCapturedPackets() {
        state.write {
            $0.packetNumber = 1
            $0.records.removeAll(keepingCapacity: false)
            $0.recordIndexByID.removeAll(keepingCapacity: false)
            $0.packetsReceived = 0
            $0.packetsDropped = 0
            $0.packetsDroppedByInterface = 0
            $0.dissectionSession = try? WiresharkEpanSession(disabled: disablesWireshark)
        }
    }

    func inspectPacket(withIdentifier identifier: UInt64) throws -> PCPPNativePacketInspectionDescriptor {
        try state.write { state in
            guard let recordIndex = state.recordIndexByID[identifier] else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the live backing store.")
            }
            let record = state.records[recordIndex]
            return try autoreleasepool {
                let analyzer = PacketAnalyzer(record: record).analyze()
                let inspection = try requireDissectionSession(in: state).inspect(record)
                return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
            }
        }
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
            let selectedRecords = records(for: identifiers, in: state)
            return try selectedRecords.map { record in
                try autoreleasepool {
                    let wiresharkSummary = try requireDissectionSession(in: state).summarize(record)
                    let analyzer = PacketAnalyzer(record: record).analyze()
                    return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
                }
            }
        }
    }

    private func records(for identifiers: [UInt64]?, in state: PCPPNativeLiveSessionState) -> [NativePacketRecord] {
        guard let identifiers else {
            return state.records
        }

        return identifiers.compactMap { identifier in
            guard let index = state.recordIndexByID[identifier] else {
                return nil
            }
            return state.records[index]
        }
    }

    func exportPackets(
        withIdentifiers identifiers: [NSNumber],
        to url: URL,
        format: String,
        progressHandler: PCPPNativePacketExportProgressHandler?,
        cancellationCheck: PCPPNativeCancellationHandler?
    ) throws {
        let idSet = Set(identifiers.map(\.uint64Value))
        let selected = state.read {
            $0.records.filter { idSet.contains($0.identifier) }
        }
        try Exporter.export(records: selected, to: url, format: CaptureFileFormat(exportRawValue: format), progressHandler: progressHandler, cancellationCheck: cancellationCheck)
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

            guard let next = Libpcap.nextPacket(from: handle) else {
                continue
            }
            let packetTimestamp = Date(timeIntervalSince1970: TimeInterval(next.header.ts.tv_sec) + TimeInterval(next.header.ts.tv_usec) / 1_000_000)
            let record: NativePacketRecord = state.write {
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
                $0.packetNumber += 1
                $0.recordIndexByID[record.identifier] = $0.records.count
                $0.records.append(record)
                $0.packetsReceived += 1
                return record
            }

            let summary: PCPPNativePacketSummaryDescriptor? = autoreleasepool {
                do {
                    return try state.write {
                        let session = try requireDissectionSession(in: $0)
                        try session.observe(record)
                        let wiresharkSummary = try session.summarize(record)
                        let analyzer = PacketAnalyzer(record: record).analyze()
                        return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
                    }
                } catch {
                    handleCaptureDissectionFailure(error)
                    return nil
                }
            }
            guard let summary else {
                break
            }
            packetHandler?([summary])
            if record.packetNumber % 128 == 0 {
                healthHandler?(healthSnapshot)
            }
        }
    }

    private func handleCaptureDissectionFailure(_ error: Error) {
        let tcpviewerError = NativeBridgeMapper.coreError(error, defaultCode: .unavailableFeature)
        state.write {
            $0.running = false
            $0.phase = .failed
        }
        errorHandler?(tcpviewerError)
        phaseHandler?(.failed, tcpviewerError.message)
    }

    private func healthDescriptor(status: String?, state: PCPPNativeLiveSessionState) -> PCPPNativeCaptureHealthDescriptor {
        PCPPNativeCaptureHealthDescriptor(
            packetsReceived: state.packetsReceived,
            packetsDropped: state.packetsDropped,
            packetsDroppedByInterface: state.packetsDroppedByInterface,
            packetsObserved: state.packetsReceived + state.packetsDropped,
            lastUpdated: Date(),
            statusMessage: status
        )
    }

    private func requireDissectionSession(in state: PCPPNativeLiveSessionState) throws -> WiresharkEpanSession {
        guard let dissectionSession = state.dissectionSession else {
            throw NativeNSError(.unavailableFeature, "Wireshark libwireshark backend is unavailable.")
        }
        return dissectionSession
    }
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
        sniDomainName: wireshark.sniDomainName
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
    var records: [NativePacketRecord] = []
    var offsets: [UInt64: UInt64] = [:]
    var backingFileHandle: FileHandle?
    var currentBackingFileSize: UInt64 = 0
    var dissectionSession: WiresharkEpanSession?
}

final class PCPPNativeLivePacketStoreTestProbe {
    private let state: Protected<PCPPNativeLivePacketStoreTestProbeState>
    private let backingFileURL: URL

    var packetCount: UInt {
        state.read { UInt($0.records.count) }
    }

    var backingFileSize: UInt64 {
        state.read(\.currentBackingFileSize)
    }

    var backingFileExists: Bool {
        FileManager.default.fileExists(atPath: backingFileURL.path)
    }

    var backingFilePath: String {
        backingFileURL.path
    }

    init() {
        self.backingFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewerLivePacketStore-\(UUID().uuidString).bin")
        self.state = Protected(PCPPNativeLivePacketStoreTestProbeState(dissectionSession: try? WiresharkEpanSession()))
    }

    func appendPacket(identifier: UInt64, rawBytes: Data, timestamp: Date, linkLayerType: Int, originalLength: Int) throws {
        try state.write {
            let offset = $0.currentBackingFileSize
            if $0.backingFileHandle == nil {
                FileManager.default.createFile(atPath: backingFileURL.path, contents: nil)
                $0.backingFileHandle = try FileHandle(forWritingTo: backingFileURL)
            }
            try $0.backingFileHandle?.write(contentsOf: rawBytes)
            $0.currentBackingFileSize += UInt64(rawBytes.count)
            $0.offsets[identifier] = offset
            let packetNumber = UInt64($0.records.count + 1)
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
            $0.records.append(record)
            try requireDissectionSession(in: $0).observe(record)
        }
    }

    func inspectPacket(identifier: UInt64) throws -> PCPPNativePacketInspectionDescriptor {
        try state.write { state in
            guard let record = state.records.first(where: { $0.identifier == identifier }) else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the live backing store.")
            }
            return try autoreleasepool {
                let analyzer = PacketAnalyzer(record: record).analyze()
                let inspection = try requireDissectionSession(in: state).inspect(record)
                return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
            }
        }
    }

    func reanalyzePacketSummaries(upTo identifier: UInt64) throws -> [PCPPNativePacketSummaryDescriptor] {
        let selectedRecords = state.read {
            let limit = identifier == 0 ? UInt64.max : identifier
            return $0.records.filter { $0.identifier <= limit }
        }
        let session = try WiresharkEpanSession()
        for record in selectedRecords {
            try session.observe(record)
        }
        return try selectedRecords.map { record in
            try autoreleasepool {
                let wiresharkSummary = try session.summarize(record)
                let analyzer = PacketAnalyzer(record: record).analyze()
                return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
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
            guard let offset = $0.offsets[identifier] else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the backing store.")
            }
            return NSNumber(value: offset)
        }
    }

    func cleanup() {
        state.write {
            try? $0.backingFileHandle?.close()
            $0.backingFileHandle = nil
            $0.currentBackingFileSize = 0
            $0.records.removeAll(keepingCapacity: false)
            $0.offsets.removeAll(keepingCapacity: false)
            $0.dissectionSession = nil
        }
        try? FileManager.default.removeItem(at: backingFileURL)
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
        try NativeCaptureFile.write(records: records, to: url, format: format)
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
