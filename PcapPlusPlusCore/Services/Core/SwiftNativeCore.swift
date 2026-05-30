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

final class PCPPNativeOfflineDocument {
    private let lock = NSLock()
    private var file: NativeCaptureFile
    private var partiallyLoaded = false
    private let disablesWireshark: Bool
    private var dissectionSession: WiresharkEpanSession?

    private(set) var currentURL: URL
    private(set) var currentFormat: String
    private(set) var dirty = false

    var documentMetadata: PCPPNativeCaptureDocumentMetadataDescriptor {
        lock.withLock {
            file.metadata
        }
    }

    init(url: URL, error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.currentURL = url
        self.disablesWireshark = false
        do {
            let loaded = try NativeCaptureFile.load(from: url)
            self.file = loaded
            self.currentFormat = loaded.format.rawValue
        } catch let thrownError {
            self.file = NativeCaptureFile.empty(url: url)
            self.currentFormat = CaptureFileFormat.defaultExportFormat.rawValue
            errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .offlineFileOpenFailed) as NSError
        }
        configureDissectionSession(error: errorPointer)
    }

    init(url: URL, disablesWireshark: Bool, error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.currentURL = url
        self.disablesWireshark = disablesWireshark
        do {
            let loaded = try NativeCaptureFile.load(from: url)
            self.file = loaded
            self.currentFormat = loaded.format.rawValue
        } catch let thrownError {
            self.file = NativeCaptureFile.empty(url: url)
            self.currentFormat = CaptureFileFormat.defaultExportFormat.rawValue
            errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .offlineFileOpenFailed) as NSError
        }
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
        try lock.withLock {
            guard let record = file.records.first(where: { $0.identifier == identifier }) else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the backing store.")
            }
            return try autoreleasepool {
                let analyzer = PacketAnalyzer(record: record).analyze()
                let inspection = try requireDissectionSession().inspect(record)
                return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
            }
        }
    }

    func save() throws {
        let snapshot = lock.withLock { file }
        try NativeCaptureFile.write(records: snapshot.records, to: currentURL, format: snapshot.format)
        lock.withLock {
            dirty = false
        }
    }

    func save(to url: URL, format: String) throws {
        let outputFormat = CaptureFileFormat(exportRawValue: format)
        let records = lock.withLock { file.records }
        try NativeCaptureFile.write(records: records, to: url, format: outputFormat)
        lock.withLock {
            currentURL = url
            currentFormat = outputFormat.rawValue
            file.url = url
            file.format = outputFormat
            file.metadata = PCPPNativeCaptureDocumentMetadataDescriptor(format: outputFormat.rawValue, operatingSystem: nil, hardware: nil, captureApplication: nil, fileComment: nil)
            dirty = false
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
        let records = lock.withLock {
            file.records.filter { idSet.contains($0.identifier) }
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
            if reload {
                let loaded = try NativeCaptureFile.load(from: currentURL)
                try lock.withLock {
                    file = loaded
                    currentFormat = loaded.format.rawValue
                    partiallyLoaded = false
                    dissectionSession = try WiresharkEpanSession(disabled: disablesWireshark)
                }
            }

            let records = lock.withLock { file.records }
            let totalBytes = UInt64((try? FileManager.default.attributesOfItem(atPath: currentURL.path)[.size] as? NSNumber)?.uint64Value ?? 0)
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
                        message: "Loading \(currentURL.lastPathComponent) was cancelled."
                    )
                    progressHandler?(progress)
                    lock.withLock {
                        partiallyLoaded = true
                    }
                    throw NativeNSError(.operationCancelled, progress.message)
                }

                let summary = try autoreleasepool {
                    let session = try requireDissectionSession()
                    try session.observe(record)
                    let wiresharkSummary = try session.summarize(record)
                    let analyzer = PacketAnalyzer(record: record).analyze()
                    return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
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
                        message: "Loaded \(summaries.count) packets from \(currentURL.lastPathComponent)."
                    ))
                }
            }

            if !pendingBatch.isEmpty {
                batchHandler?(pendingBatch)
            }
            try requireDissectionSession().finishFirstPass()
            progressHandler?(PCPPNativePacketLoadProgressDescriptor(
                phase: "completed",
                loadedPacketCount: UInt64(summaries.count),
                processedBytes: NSNumber(value: totalBytes),
                totalBytes: NSNumber(value: totalBytes),
                partialResult: false,
                message: "Loaded \(summaries.count) packets from \(currentURL.lastPathComponent)."
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
            dissectionSession = try WiresharkEpanSession(disabled: disablesWireshark)
        } catch let thrownError {
            if errorPointer?.pointee == nil {
                errorPointer?.pointee = NativeBridgeMapper.coreError(thrownError, defaultCode: .unavailableFeature) as NSError
            }
        }
    }

    private func requireDissectionSession() throws -> WiresharkEpanSession {
        guard let dissectionSession else {
            throw NativeNSError(.unavailableFeature, "Wireshark libwireshark backend is unavailable.")
        }
        return dissectionSession
    }
}

final class PCPPNativeLiveSession {
    var packetHandler: PCPPNativePacketBatchHandler?
    var phaseHandler: PCPPNativeSessionPhaseHandler?
    var healthHandler: PCPPNativeHealthHandler?
    var errorHandler: PCPPNativeErrorHandler?

    private let interfaceIdentifier: String
    private let options: PCPPNativeCaptureOptionsDescriptor
    private let disablesWireshark: Bool
    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.PCPPNativeLiveSession.capture", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var phase: PCPPNativeLiveSessionPhase = .ready
    private var running = false
    private var paused = false
    private var packetNumber: UInt64 = 1
    private var records: [NativePacketRecord] = []
    private var recordIndexByID: [UInt64: Int] = [:]
    private var packetsReceived: UInt64 = 0
    private var packetsDropped: UInt64 = 0
    private var packetsDroppedByInterface: UInt64 = 0
    private var liveLinkLayerType = Libpcap.dltEthernet
    private var dissectionSession: WiresharkEpanSession?

    var healthSnapshot: PCPPNativeCaptureHealthDescriptor {
        lock.withLock {
            healthDescriptor(status: nil)
        }
    }

    init(interfaceIdentifier: String, options: PCPPNativeCaptureOptionsDescriptor, error: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.interfaceIdentifier = interfaceIdentifier
        self.options = options
        self.disablesWireshark = false
        self.dissectionSession = try? WiresharkEpanSession()
    }

    init(interfaceIdentifier: String, options: PCPPNativeCaptureOptionsDescriptor, disablesWireshark: Bool, error: AutoreleasingUnsafeMutablePointer<NSError?>?) {
        self.interfaceIdentifier = interfaceIdentifier
        self.options = options
        self.disablesWireshark = disablesWireshark
        self.dissectionSession = try? WiresharkEpanSession(disabled: disablesWireshark)
    }

    func start() throws {
        let shouldOpen = lock.withLock {
            if phase == .running || phase == .starting {
                return false
            }
            phase = .starting
            return true
        }
        guard shouldOpen else {
            return
        }

        phaseHandler?(.starting, "Starting capture on \(interfaceIdentifier)...")
        let nextDissectionSession = try WiresharkEpanSession(disabled: disablesWireshark)
        let openedHandle = try Libpcap.openLive(interfaceName: interfaceIdentifier, options: options)
        lock.withLock {
            handle = openedHandle
            dissectionSession = nextDissectionSession
            running = true
            paused = false
            phase = .running
            packetNumber = 1
            liveLinkLayerType = Libpcap.dataLink(for: openedHandle)
            records.removeAll(keepingCapacity: false)
            recordIndexByID.removeAll(keepingCapacity: false)
            packetsReceived = 0
            packetsDropped = 0
            packetsDroppedByInterface = 0
        }
        phaseHandler?(.running, "Capture running on \(interfaceIdentifier).")
        captureQueue.async { [weak self] in
            self?.captureLoop(handle: openedHandle)
        }
    }

    func pause() throws {
        lock.withLock {
            guard phase == .running else { return }
            paused = true
            phase = .paused
        }
        phaseHandler?(.paused, "Capture paused.")
        healthHandler?(healthSnapshot)
    }

    func resume() throws {
        lock.withLock {
            guard phase == .paused else { return }
            paused = false
            phase = .running
        }
        phaseHandler?(.running, "Capture resumed.")
    }

    func stop() throws {
        let handleToStop = lock.withLock { () -> OpaquePointer? in
            if phase == .stopped {
                phase = .stopped
                return nil
            }
            if phase == .ready {
                running = false
                phase = .stopped
                return nil
            }
            phase = .stopping
            running = false
            return handle
        }

        if let handleToStop {
            phaseHandler?(.stopping, "Stopping capture...")
            Libpcap.breakLoop(handleToStop)
            captureQueue.sync {}
        }
        try? lock.withLock {
            try dissectionSession?.finishFirstPass()
        }

        lock.withLock {
            phase = .stopped
            if let handle = self.handle {
                if let stats = Libpcap.stats(for: handle) {
                    packetsReceived = UInt64(stats.ps_recv)
                    packetsDropped = UInt64(stats.ps_drop)
                    packetsDroppedByInterface = UInt64(stats.ps_ifdrop)
                }
                Libpcap.close(handle)
                self.handle = nil
            }
        }
        healthHandler?(healthSnapshot)
        phaseHandler?(.stopped, "Capture stopped.")
    }

    func clearCapturedPackets() {
        lock.withLock {
            packetNumber = 1
            records.removeAll(keepingCapacity: false)
            recordIndexByID.removeAll(keepingCapacity: false)
            packetsReceived = 0
            packetsDropped = 0
            packetsDroppedByInterface = 0
            dissectionSession = try? WiresharkEpanSession(disabled: disablesWireshark)
        }
    }

    func inspectPacket(withIdentifier identifier: UInt64) throws -> PCPPNativePacketInspectionDescriptor {
        try lock.withLock {
            guard let recordIndex = recordIndexByID[identifier] else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the live backing store.")
            }
            let record = records[recordIndex]
            return try autoreleasepool {
                let analyzer = PacketAnalyzer(record: record).analyze()
                let inspection = try requireDissectionSession().inspect(record)
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
        try lock.withLock {
            let selectedRecords = records(for: identifiers)
            return try selectedRecords.map { record in
                try autoreleasepool {
                    let wiresharkSummary = try requireDissectionSession().summarize(record)
                    let analyzer = PacketAnalyzer(record: record).analyze()
                    return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
                }
            }
        }
    }

    private func records(for identifiers: [UInt64]?) -> [NativePacketRecord] {
        guard let identifiers else {
            return records
        }

        return identifiers.compactMap { identifier in
            guard let index = recordIndexByID[identifier] else {
                return nil
            }
            return records[index]
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
        let selected = lock.withLock {
            records.filter { idSet.contains($0.identifier) }
        }
        try Exporter.export(records: selected, to: url, format: CaptureFileFormat(exportRawValue: format), progressHandler: progressHandler, cancellationCheck: cancellationCheck)
    }

    private func captureLoop(handle: OpaquePointer) {
        while true {
            let shouldContinue = lock.withLock { running }
            guard shouldContinue else {
                break
            }
            if lock.withLock({ paused }) {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            guard let next = Libpcap.nextPacket(from: handle) else {
                continue
            }
            let packetTimestamp = Date(timeIntervalSince1970: TimeInterval(next.header.ts.tv_sec) + TimeInterval(next.header.ts.tv_usec) / 1_000_000)
            let record: NativePacketRecord = lock.withLock {
                let record = NativePacketRecord(
                    identifier: packetNumber,
                    packetNumber: packetNumber,
                    timestamp: packetTimestamp,
                    rawBytes: next.bytes,
                    originalLength: Int(next.header.len),
                    linkLayerType: liveLinkLayerType,
                    interfaceIdentifier: interfaceIdentifier,
                    interfaceName: interfaceIdentifier,
                    packetComment: nil
                )
                packetNumber += 1
                recordIndexByID[record.identifier] = records.count
                records.append(record)
                packetsReceived += 1
                return record
            }

            let summary: PCPPNativePacketSummaryDescriptor? = autoreleasepool {
                do {
                    let session = try requireDissectionSession()
                    try session.observe(record)
                    let wiresharkSummary = try session.summarize(record)
                    let analyzer = PacketAnalyzer(record: record).analyze()
                    return makePacketSummaryDescriptor(record: record, analyzed: analyzer, wireshark: wiresharkSummary)
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
        lock.withLock {
            running = false
            phase = .failed
        }
        errorHandler?(tcpviewerError)
        phaseHandler?(.failed, tcpviewerError.message)
    }

    private func healthDescriptor(status: String?) -> PCPPNativeCaptureHealthDescriptor {
        PCPPNativeCaptureHealthDescriptor(
            packetsReceived: packetsReceived,
            packetsDropped: packetsDropped,
            packetsDroppedByInterface: packetsDroppedByInterface,
            packetsObserved: packetsReceived + packetsDropped,
            lastUpdated: Date(),
            statusMessage: status
        )
    }

    private func requireDissectionSession() throws -> WiresharkEpanSession {
        guard let dissectionSession else {
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
final class PCPPNativeLivePacketStoreTestProbe {
    private let lock = NSLock()
    private var records: [NativePacketRecord] = []
    private var offsets: [UInt64: UInt64] = [:]
    private let backingFileURL: URL
    private var backingFileHandle: FileHandle?
    private var currentBackingFileSize: UInt64 = 0
    private var dissectionSession: WiresharkEpanSession?

    var packetCount: UInt {
        lock.withLock { UInt(records.count) }
    }

    var backingFileSize: UInt64 {
        lock.withLock { currentBackingFileSize }
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
        self.dissectionSession = try? WiresharkEpanSession()
    }

    func appendPacket(identifier: UInt64, rawBytes: Data, timestamp: Date, linkLayerType: Int, originalLength: Int) throws {
        try lock.withLock {
            let offset = currentBackingFileSize
            if backingFileHandle == nil {
                FileManager.default.createFile(atPath: backingFileURL.path, contents: nil)
                backingFileHandle = try FileHandle(forWritingTo: backingFileURL)
            }
            try backingFileHandle?.write(contentsOf: rawBytes)
            currentBackingFileSize += UInt64(rawBytes.count)
            offsets[identifier] = offset
            let packetNumber = UInt64(records.count + 1)
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
            records.append(record)
            try requireDissectionSession().observe(record)
        }
    }

    func inspectPacket(identifier: UInt64) throws -> PCPPNativePacketInspectionDescriptor {
        try lock.withLock {
            guard let record = records.first(where: { $0.identifier == identifier }) else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the live backing store.")
            }
            return try autoreleasepool {
                let analyzer = PacketAnalyzer(record: record).analyze()
                let inspection = try requireDissectionSession().inspect(record)
                return makePacketInspectionDescriptor(record: record, analyzed: analyzer, wireshark: inspection)
            }
        }
    }

    func reanalyzePacketSummaries(upTo identifier: UInt64) throws -> [PCPPNativePacketSummaryDescriptor] {
        try lock.withLock {
            let limit = identifier == 0 ? UInt64.max : identifier
            let selectedRecords = records.filter { $0.identifier <= limit }
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
    }

    func reanalyzePacketSummaryUpdates(upTo identifier: UInt64) throws -> [PCPPNativePacketSummaryUpdateDescriptor] {
        try reanalyzePacketSummaries(upTo: identifier).map {
            PCPPNativePacketSummaryUpdateDescriptor(packetIdentifier: $0.identifier, protocolSummary: $0.protocolSummary, infoSummary: $0.infoSummary)
        }
    }

    func offset(identifier: UInt64) throws -> NSNumber {
        try lock.withLock {
            guard let offset = offsets[identifier] else {
                throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the backing store.")
            }
            return NSNumber(value: offset)
        }
    }

    func cleanup() {
        lock.withLock {
            try? backingFileHandle?.close()
            backingFileHandle = nil
            currentBackingFileSize = 0
            records.removeAll(keepingCapacity: false)
            offsets.removeAll(keepingCapacity: false)
            dissectionSession = nil
        }
        try? FileManager.default.removeItem(at: backingFileURL)
    }

    private func requireDissectionSession() throws -> WiresharkEpanSession {
        guard let dissectionSession else {
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

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
