//
//  WiresharkEpanSession.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 29/5/26.
//

import Foundation
@_implementationOnly import TCPViewerWiresharkEpanShim

struct WiresharkPacketSummaryFields {
    let protocolSummary: String?
    let infoSummary: String
    let sniDomainName: String?
}

struct WiresharkPacketInspectionFields {
    let byteViews: [PCPPNativePacketByteViewDescriptor]
    let detailNodes: [PCPPNativePacketDetailNodeDescriptor]
    let sniDomainName: String?
}

struct WiresharkTCPFollowFields {
    let client: PacketEndpoint
    let server: PacketEndpoint
    let records: [TCPFollowRecord]
    let clientByteCount: Int
    let serverByteCount: Int
    let isTruncated: Bool
}

struct WiresharkDecryptedFollowFields {
    let protocolName: DecryptedStreamProtocol
    let client: PacketEndpoint
    let server: PacketEndpoint
    let request: DecryptedStreamPayload
    let response: DecryptedStreamPayload
}

struct WiresharkTCPStreamIndexEntry: Sendable, Equatable {
    let packetIdentifier: UInt64
    let streamIdentifier: UInt32
}

enum WiresharkSessionPurpose {
    case offline
    case live
    case follow
}

struct WiresharkRuntimeConfiguration {
    private static let appFolderName = "TCPViewer"
    private static let settingsFolderName = "settings"
    private static let wiresharkFolderName = "Wireshark"

    private let fileManager: FileManager
    private let applicationSupportBaseURL: URL

    init(fileManager: FileManager = .default, applicationSupportBaseURL: URL? = nil) {
        self.fileManager = fileManager
        self.applicationSupportBaseURL = applicationSupportBaseURL ?? Self.defaultApplicationSupportBaseURL(fileManager: fileManager)
    }

    var personalConfigurationDirectoryURL: URL {
        applicationSupportBaseURL
            .appendingPathComponent(Self.appFolderName, isDirectory: true)
            .appendingPathComponent(Self.settingsFolderName, isDirectory: true)
            .appendingPathComponent(Self.wiresharkFolderName, isDirectory: true)
    }

    @discardableResult
    func createPersonalConfigurationDirectoryIfNeeded() throws -> URL {
        try fileManager.createDirectory(at: personalConfigurationDirectoryURL, withIntermediateDirectories: true)
        return personalConfigurationDirectoryURL
    }

    private static func defaultApplicationSupportBaseURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

final class WiresharkEpanSession {
    private let handle: OpaquePointer
    private let criticalExceptionLogger: WiresharkCriticalExceptionLogger

    init(
        disabled: Bool = false,
        purpose: WiresharkSessionPurpose = .offline,
        criticalExceptionLogger: WiresharkCriticalExceptionLogger = .shared,
        runtimeConfiguration: WiresharkRuntimeConfiguration = WiresharkRuntimeConfiguration()
    ) throws {
        self.criticalExceptionLogger = criticalExceptionLogger
        let createdHandle: OpaquePointer?
        if disabled {
            createdHandle = TCPViewerWiresharkSessionCreate(true, purpose == .live, nil)
        } else {
            let configurationDirectory = try runtimeConfiguration.createPersonalConfigurationDirectoryIfNeeded()
            createdHandle = configurationDirectory.path.withCString { path in
                TCPViewerWiresharkSessionCreate(false, purpose == .live, path)
            }
        }

        guard let createdHandle else {
            throw NativeNSError(.unavailableFeature, "Wireshark libwireshark backend could not be created.")
        }

        guard TCPViewerWiresharkSessionIsAvailable(createdHandle) else {
            if let criticalError = Self.criticalExceptionErrorIfNeeded(for: createdHandle, logger: criticalExceptionLogger) {
                TCPViewerWiresharkSessionDestroy(createdHandle)
                throw criticalError
            }
            let reason = Self.string(TCPViewerWiresharkSessionUnavailableReason(createdHandle))
                ?? "Wireshark libwireshark backend is unavailable."
            TCPViewerWiresharkSessionDestroy(createdHandle)
            throw NativeNSError(.unavailableFeature, reason)
        }
        self.handle = createdHandle
    }

    deinit {
        TCPViewerWiresharkSessionReleaseResources(handle)
        logPendingCriticalExceptions()
        TCPViewerWiresharkSessionDestroy(handle)
    }

    @discardableResult
    func observe(_ record: NativePacketRecord) throws -> [WiresharkTCPStreamIndexEntry] {
        try withContext(for: record) { context in
            let succeeded = TCPViewerWiresharkSessionObservePacket(handle, context)
            let updates = copyPendingTCPStreamIndexUpdates()
            guard succeeded else {
                if let criticalError = criticalExceptionErrorIfNeeded() {
                    throw criticalError
                }
                throw unavailableError()
            }
            return updates
        }
    }

    func finishFirstPass() throws {
        guard TCPViewerWiresharkSessionFinishFirstPass(handle) else {
            if let criticalError = criticalExceptionErrorIfNeeded() {
                throw criticalError
            }
            throw unavailableError()
        }
    }

    // Check whether this session still owns the selected packet's first-pass state.
    func canFollowObservedPacket(withIdentifier identifier: UInt64) -> Bool {
        TCPViewerWiresharkSessionCanFollowObservedPacket(handle, identifier)
    }

    // Confirm the active first pass still contains every frame needed by the retap.
    func canFollowObservedPackets(withIdentifiers identifiers: [UInt64]) -> Bool {
        identifiers.withUnsafeBufferPointer { buffer in
            TCPViewerWiresharkSessionCanFollowObservedPackets(
                handle,
                buffer.baseAddress,
                buffer.count
            )
        }
    }

    // Resolve Wireshark's connection-specific stream membership, including dependency frames.
    func tcpFollowCandidatePacketIdentifiers(
        containing identifier: UInt64,
        maximumPacketCount: Int
    ) throws -> [UInt64] {
        guard let resultPointer = TCPViewerWiresharkSessionCopyTCPFollowCandidates(
            handle,
            identifier,
            maximumPacketCount
        ) else {
            throw unavailableError("Wireshark returned no TCP stream candidate index.")
        }
        defer { TCPViewerWiresharkFollowCandidateResultDestroy(resultPointer) }
        let result = resultPointer.pointee
        guard result.succeeded else {
            throw unavailableError(Self.string(result.errorMessage))
        }
        guard let identifiers = result.packetIdentifiers, result.packetIdentifierCount > 0 else {
            return []
        }
        return Array(UnsafeBufferPointer(start: identifiers, count: result.packetIdentifierCount))
    }

    // Return Wireshark's connection-specific tcp.stream value for one observed packet.
    func tcpStreamIdentifier(for packetIdentifier: UInt64) -> UInt32? {
        var streamIdentifier: UInt32 = 0
        guard TCPViewerWiresharkSessionTCPStreamIdentifier(
            handle,
            packetIdentifier,
            &streamIdentifier
        ) else {
            return nil
        }
        return streamIdentifier
    }

    func summarize(_ record: NativePacketRecord) throws -> WiresharkPacketSummaryFields {
        try withContext(for: record) { context in
            guard let resultPointer = TCPViewerWiresharkSessionSummarizePacket(handle, context) else {
                throw unavailableError()
            }
            defer { TCPViewerWiresharkSummaryResultDestroy(resultPointer) }

            let result = resultPointer.pointee
            guard result.succeeded else {
                if let criticalError = criticalExceptionErrorIfNeeded() {
                    throw criticalError
                }
                throw unavailableError(Self.string(result.errorMessage))
            }

            return WiresharkPacketSummaryFields(
                protocolSummary: Self.string(result.protocol),
                infoSummary: Self.string(result.info) ?? "Packet",
                sniDomainName: Self.string(result.sniDomainName)
            )
        }
    }

    func inspect(_ record: NativePacketRecord) throws -> WiresharkPacketInspectionFields {
        try withContext(for: record) { context in
            guard let resultPointer = TCPViewerWiresharkSessionInspectPacket(handle, context) else {
                throw unavailableError()
            }
            defer { TCPViewerWiresharkInspectionResultDestroy(resultPointer) }

            let result = resultPointer.pointee
            guard result.succeeded else {
                if let criticalError = criticalExceptionErrorIfNeeded() {
                    throw criticalError
                }
                throw unavailableError(Self.string(result.errorMessage))
            }

            return WiresharkPacketInspectionFields(
                byteViews: byteViews(from: result),
                detailNodes: detailNodes(from: result),
                sniDomainName: Self.string(result.sniDomainName)
            )
        }
    }

    // Build a bounded temporary session when an inactive offline document needs to be followed.
    static func followTCPStreamInTemporarySession(
        containing selectedRecord: NativePacketRecord,
        records: [NativePacketRecord],
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkTCPFollowFields {
        try validateFollowRequest(selectedRecord: selectedRecord, records: records, limits: limits)
        let session = try WiresharkEpanSession(purpose: .follow)
        let totalWorkCount = records.count * 2
        for (index, record) in records.enumerated() {
            if shouldCancel?() == true {
                throw NativeNSError(.operationCancelled, "TCP stream reassembly was cancelled.")
            }
            try session.observe(record)
            reportFollowProgress(
                processedPacketCount: index + 1,
                totalPacketCount: totalWorkCount,
                handler: progress
            )
        }
        try session.finishFirstPass()
        return try session.followObservedStream(
            containing: selectedRecord,
            records: records,
            limits: limits,
            protocolName: "TCP",
            progressOffset: records.count,
            progressTotal: totalWorkCount,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    // Retap an immutable snapshot using the capture's already-loaded Wireshark session.
    func followObservedTCPStream(
        containing selectedRecord: NativePacketRecord,
        records: [NativePacketRecord],
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkTCPFollowFields {
        try followObservedStream(
            containing: selectedRecord,
            records: records,
            limits: limits,
            protocolName: "TCP",
            progressOffset: 0,
            progressTotal: records.count,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    private func followObservedStream(
        containing selectedRecord: NativePacketRecord,
        records: [NativePacketRecord],
        limits: TCPFollowLimits,
        protocolName: String,
        progressOffset: Int,
        progressTotal: Int,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkTCPFollowFields {
        try Self.validateFollowRequest(selectedRecord: selectedRecord, records: records, limits: limits)
        return try followObservedStream(
            containing: selectedRecord,
            limits: limits,
            protocolName: protocolName,
            progressOffset: progressOffset,
            progressTotal: progressTotal,
            progress: progress,
            shouldCancel: shouldCancel,
            replay: { consume in
                for record in records {
                    if try !consume(record) {
                        break
                    }
                }
            }
        )
    }

    // Consume replayed packets one at a time so stopped live captures never load all packet bytes into memory.
    private func followObservedStream(
        containing selectedRecord: NativePacketRecord,
        limits: TCPFollowLimits,
        protocolName: String,
        progressOffset: Int,
        progressTotal: Int,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?,
        replay: (_ consume: (NativePacketRecord) throws -> Bool) throws -> Void
    ) throws -> WiresharkTCPFollowFields {
        var followIsActive = false
        defer {
            if followIsActive {
                TCPViewerWiresharkSessionCancelFollowTCPStream(handle)
            }
        }
        try withContext(for: selectedRecord) { context in
            let didBegin = protocolName.withCString { name in
                TCPViewerWiresharkSessionBeginFollowStream(handle, context, name)
            }
            guard didBegin else {
                if let criticalError = criticalExceptionErrorIfNeeded() {
                    throw criticalError
                }
                throw unavailableError()
            }
        }
        followIsActive = true

        var processedPacketCount = 0
        try replay { record in
            if shouldCancel?() == true {
                throw NativeNSError(.operationCancelled, "TCP stream reassembly was cancelled.")
            }
            let status = try withContext(for: record) { context in
                TCPViewerWiresharkSessionProcessFollowPacket(
                    handle,
                    context,
                    limits.maximumPayloadBytes
                )
            }
            if status == TCPViewerWiresharkFollowPacketFailed {
                if let criticalError = criticalExceptionErrorIfNeeded() {
                    throw criticalError
                }
                throw unavailableError()
            }
            processedPacketCount += 1
            Self.reportFollowProgress(
                processedPacketCount: progressOffset + processedPacketCount,
                totalPacketCount: progressTotal,
                handler: progress
            )
            return status != TCPViewerWiresharkFollowPacketLimitReached
        }

        guard let resultPointer = TCPViewerWiresharkSessionFinishFollowTCPStream(
            handle,
            limits.maximumPayloadBytes,
            limits.maximumRecordCount
        ) else {
            throw unavailableError("Wireshark returned no TCP stream result.")
        }
        followIsActive = false
        defer { TCPViewerWiresharkFollowResultDestroy(resultPointer) }
        let result = resultPointer.pointee
        guard result.succeeded else {
            if let criticalError = criticalExceptionErrorIfNeeded() {
                throw criticalError
            }
            throw unavailableError(Self.string(result.errorMessage))
        }

        return WiresharkTCPFollowFields(
            client: PacketEndpoint(
                address: Self.string(result.clientAddress),
                port: result.clientPort
            ),
            server: PacketEndpoint(
                address: Self.string(result.serverAddress),
                port: result.serverPort
            ),
            records: followRecords(from: result),
            clientByteCount: Int(clamping: result.clientByteCount),
            serverByteCount: Int(clamping: result.serverByteCount),
            isTruncated: result.isTruncated
        )
    }

    // Build a temporary first pass, then let Wireshark choose TLS, DTLS, or QUIC follow semantics.
    static func followDecryptedStreamInTemporarySession(
        containing selectedRecord: NativePacketRecord,
        records: [NativePacketRecord],
        limits: DecryptedStreamLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkDecryptedFollowFields {
        guard records.contains(where: { $0.identifier == selectedRecord.identifier }) else {
            throw NativeNSError(.fileReadFailed, "The selected packet is not available in the stream snapshot.")
        }
        return try followDecryptedStreamInTemporarySession(
            containing: selectedRecord,
            recordCount: records.count,
            replay: { consume in
                for record in records {
                    if try !consume(record) {
                        break
                    }
                }
            },
            limits: limits,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    // Build a temporary first pass while reading each retained packet only when Wireshark needs it.
    static func followDecryptedStreamInTemporarySession(
        containing selectedRecord: NativePacketRecord,
        recordCount: Int,
        replay: (_ consume: (NativePacketRecord) throws -> Bool) throws -> Void,
        limits: DecryptedStreamLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkDecryptedFollowFields {
        guard TCPViewerWiresharkHasTLSKeyLog() else {
            throw NativeNSError(.unavailableFeature, "No TLS key-log file is selected. Choose one in Decrypted or open Tools → TLS Decryption… first.")
        }
        let session = try WiresharkEpanSession(purpose: .follow)
        let totalWorkCount = recordCount > Int.max / 2 ? Int.max : recordCount * 2
        var processedPacketCount = 0
        try replay { record in
            if shouldCancel?() == true {
                throw NativeNSError(.operationCancelled, "TLS stream decryption was cancelled.")
            }
            try session.observe(record)
            processedPacketCount += 1
            reportFollowProgress(
                processedPacketCount: processedPacketCount,
                totalPacketCount: totalWorkCount,
                handler: progress
            )
            return true
        }
        try session.finishFirstPass()
        return try session.followObservedDecryptedStream(
            containing: selectedRecord,
            replay: replay,
            limits: limits,
            progressOffset: recordCount,
            progressTotal: totalWorkCount,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    func followObservedDecryptedStream(
        containing selectedRecord: NativePacketRecord,
        records: [NativePacketRecord],
        limits: DecryptedStreamLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkDecryptedFollowFields {
        guard TCPViewerWiresharkHasTLSKeyLog() else {
            throw NativeNSError(.unavailableFeature, "No TLS key-log file is selected. Choose one in Decrypted or open Tools → TLS Decryption… first.")
        }
        guard records.contains(where: { $0.identifier == selectedRecord.identifier }) else {
            throw NativeNSError(.fileReadFailed, "The selected packet is not available in the stream snapshot.")
        }
        return try followObservedDecryptedStream(
            containing: selectedRecord,
            replay: { consume in
                for record in records {
                    if try !consume(record) {
                        break
                    }
                }
            },
            limits: limits,
            progressOffset: 0,
            progressTotal: records.count,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    private func followObservedDecryptedStream(
        containing selectedRecord: NativePacketRecord,
        replay: (_ consume: (NativePacketRecord) throws -> Bool) throws -> Void,
        limits: DecryptedStreamLimits,
        progressOffset: Int,
        progressTotal: Int,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkDecryptedFollowFields {
        let followLimits = TCPFollowLimits(
            maximumPayloadBytes: limits.maximumBytesPerDirection,
            maximumRecordCount: limits.maximumRecordCount
        )
        var lastError: Error?
        for protocolName in [DecryptedStreamProtocol.tls, .dtls, .quic] {
            do {
                let fields = try followObservedStream(
                    containing: selectedRecord,
                    limits: followLimits,
                    protocolName: protocolName.rawValue,
                    progressOffset: progressOffset,
                    progressTotal: progressTotal,
                    progress: progress,
                    shouldCancel: shouldCancel,
                    replay: replay
                )
                return decryptedFields(protocolName: protocolName, fields: fields, limit: limits.maximumBytesPerDirection)
            } catch {
                if shouldCancel?() == true {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError ?? NativeNSError(.unavailableFeature, "Select a TLS, DTLS, or QUIC packet to decrypt its stream.")
    }

    private func decryptedFields(
        protocolName: DecryptedStreamProtocol,
        fields: WiresharkTCPFollowFields,
        limit: Int
    ) -> WiresharkDecryptedFollowFields {
        var request = Data()
        var response = Data()
        for record in fields.records {
            switch record.direction {
            case .clientToServer:
                let remaining = max(limit - request.count, 0)
                request.append(record.data.prefix(remaining))
            case .serverToClient:
                let remaining = max(limit - response.count, 0)
                response.append(record.data.prefix(remaining))
            }
        }
        return WiresharkDecryptedFollowFields(
            protocolName: protocolName,
            client: fields.client,
            server: fields.server,
            request: DecryptedStreamPayload(
                data: request,
                observedByteCount: fields.clientByteCount,
                isTruncated: fields.isTruncated || fields.clientByteCount > request.count
            ),
            response: DecryptedStreamPayload(
                data: response,
                observedByteCount: fields.serverByteCount,
                isTruncated: fields.isTruncated || fields.serverByteCount > response.count
            )
        )
    }

    private static func validateFollowRequest(
        selectedRecord: NativePacketRecord,
        records: [NativePacketRecord],
        limits: TCPFollowLimits
    ) throws {
        guard records.count <= limits.maximumCandidatePacketCount,
              records.count <= Int.max / 2 else {
            throw NativeNSError(
                .unavailableFeature,
                "This TCP stream has more than \(limits.maximumCandidatePacketCount) candidate packets."
            )
        }
        guard records.contains(where: { $0.identifier == selectedRecord.identifier }) else {
            throw NativeNSError(.fileReadFailed, "The selected TCP packet is not available in the stream snapshot.")
        }
    }

    // Coalesce large retaps so progress cannot flood the main queue with one callback per packet.
    private static func reportFollowProgress(
        processedPacketCount: Int,
        totalPacketCount: Int,
        handler: TCPFollowProgressHandler?
    ) {
        guard processedPacketCount == 1
                || processedPacketCount == totalPacketCount
                || processedPacketCount.isMultiple(of: 1_024) else {
            return
        }
        handler?(TCPFollowProgress(
            processedPacketCount: processedPacketCount,
            totalPacketCount: totalPacketCount
        ))
    }

    private func withContext<T>(
        for record: NativePacketRecord,
        _ body: (UnsafePointer<TCPViewerWiresharkPacketContext>) throws -> T
    ) throws -> T {
        try record.rawBytes.withUnsafeBytes { rawBuffer in
            try withOptionalCString(record.interfaceName) { interfaceNamePointer in
                try withOptionalCString(record.packetComment) { packetCommentPointer in
                    var context = TCPViewerWiresharkPacketContext()
                    context.packetIdentifier = record.identifier
                    context.bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress
                    context.capturedLength = record.rawBytes.count
                    context.originalLength = max(record.originalLength, record.rawBytes.count)
                    context.linkLayerType = record.linkLayerType
                    let interval = record.timestamp.timeIntervalSince1970
                    let seconds = floor(interval)
                    context.timestampSeconds = Int64(seconds)
                    context.timestampNanoseconds = Int32(max(0, min(999_999_999, (interval - seconds) * 1_000_000_000)))
                    context.interfaceName = interfaceNamePointer
                    context.packetComment = packetCommentPointer
                    context.interfaceID = record.interfaceID
                    context.sectionNumber = record.sectionNumber
                    return try withUnsafePointer(to: &context, body)
                }
            }
        }
    }

    private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let value, !value.isEmpty else {
            return try body(nil)
        }
        return try value.withCString(body)
    }

    private func unavailableError(_ message: String? = nil) -> NSError {
        let reason = message
            ?? Self.string(TCPViewerWiresharkSessionUnavailableReason(handle))
            ?? "Wireshark libwireshark backend is unavailable."
        return NativeNSError(.unavailableFeature, reason)
    }

    private func criticalExceptionErrorIfNeeded() -> NSError? {
        Self.criticalExceptionErrorIfNeeded(for: handle, logger: criticalExceptionLogger)
    }

    private static func criticalExceptionErrorIfNeeded(for handle: OpaquePointer, logger: WiresharkCriticalExceptionLogger) -> NSError? {
        let reports = copyPendingCriticalExceptions(for: handle)
        guard let report = reports.first else {
            return nil
        }
        log(reports, with: logger)
        return NativeNSError(.criticalWiresharkException, report.reason)
    }

    private func logPendingCriticalExceptions() {
        Self.log(Self.copyPendingCriticalExceptions(for: handle), with: criticalExceptionLogger)
    }

    private static func log(_ reports: [WiresharkCriticalExceptionReport], with logger: WiresharkCriticalExceptionLogger) {
        for report in reports {
            _ = try? logger.log(report)
        }
    }

    private static func copyPendingCriticalExceptions(for handle: OpaquePointer) -> [WiresharkCriticalExceptionReport] {
        var reports: [WiresharkCriticalExceptionReport] = []
        while let reportPointer = TCPViewerWiresharkSessionCopyNextCriticalException(handle) {
            reports.append(WiresharkCriticalExceptionReport(reportPointer.pointee))
            TCPViewerWiresharkExceptionReportDestroy(reportPointer)
        }
        return reports
    }

    private func byteViews(from result: TCPViewerWiresharkInspectionResult) -> [PCPPNativePacketByteViewDescriptor] {
        guard let sources = result.byteSources, result.byteSourceCount > 0 else {
            return []
        }

        return UnsafeBufferPointer(start: sources, count: result.byteSourceCount).map { source in
            let bytes: Data
            if let bytePointer = source.bytes, source.byteCount > 0 {
                bytes = Data(bytes: bytePointer, count: source.byteCount)
            } else {
                bytes = Data()
            }
            return PCPPNativePacketByteViewDescriptor(
                identifier: Self.string(source.identifier) ?? "bytes",
                label: Self.string(source.label) ?? "Bytes",
                bytes: bytes
            )
        }
    }

    // Drain the small per-packet index delta before another observation can replace it.
    private func copyPendingTCPStreamIndexUpdates() -> [WiresharkTCPStreamIndexEntry] {
        guard let resultPointer = TCPViewerWiresharkSessionCopyPendingTCPStreamIndexUpdates(handle) else {
            return []
        }
        defer { TCPViewerWiresharkTCPStreamIndexResultDestroy(resultPointer) }
        let result = resultPointer.pointee
        guard let entries = result.entries, result.entryCount > 0 else {
            return []
        }
        return UnsafeBufferPointer(start: entries, count: result.entryCount).map {
            WiresharkTCPStreamIndexEntry(
                packetIdentifier: $0.packetIdentifier,
                streamIdentifier: $0.streamIdentifier
            )
        }
    }

    // Copy C-owned follow records before the shim destroys its result storage.
    private func followRecords(from result: TCPViewerWiresharkFollowResult) -> [TCPFollowRecord] {
        guard let recordPointer = result.records, result.recordCount > 0 else {
            return []
        }
        return UnsafeBufferPointer(start: recordPointer, count: result.recordCount).map { record in
            let data: Data
            if let bytes = record.bytes, record.byteCount > 0 {
                data = Data(bytes: bytes, count: record.byteCount)
            } else {
                data = Data()
            }
            return TCPFollowRecord(
                direction: record.isServer ? .serverToClient : .clientToServer,
                packetID: record.packetIdentifier,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(record.timestampSeconds)
                        + TimeInterval(record.timestampNanoseconds) / 1_000_000_000
                ),
                sequenceNumber: record.sequenceNumber,
                data: data
            )
        }
    }

    private func detailNodes(from result: TCPViewerWiresharkInspectionResult) -> [PCPPNativePacketDetailNodeDescriptor] {
        guard let nodes = result.nodes, result.nodeCount > 0 else {
            return []
        }
        return UnsafeBufferPointer(start: nodes, count: result.nodeCount).map(detailNode)
    }

    private func detailNode(_ node: TCPViewerWiresharkDetailNode) -> PCPPNativePacketDetailNodeDescriptor {
        let children: [PCPPNativePacketDetailNodeDescriptor]
        if let childPointer = node.children, node.childCount > 0 {
            children = UnsafeBufferPointer(start: childPointer, count: node.childCount).map(detailNode)
        } else {
            children = []
        }

        return PCPPNativePacketDetailNodeDescriptor(
            identifier: Self.string(node.identifier) ?? "wireshark.node",
            name: Self.string(node.name) ?? "Wireshark Field",
            fieldName: Self.string(node.fieldName) ?? "",
            value: Self.string(node.value),
            rawValue: Self.string(node.rawValue),
            kind: Self.string(node.kind) ?? PacketDetailNodeKind.field.rawValue,
            severity: Self.string(node.severity) ?? PacketDetailNodeSeverity.normal.rawValue,
            byteRange: byteRange(node.byteRange),
            jumpTargetPacketIdentifier: node.hasJumpTargetPacketIdentifier ? NSNumber(value: node.jumpTargetPacketIdentifier) : nil,
            children: children
        )
    }

    private func byteRange(_ pointer: UnsafeMutablePointer<TCPViewerWiresharkByteRange>?) -> PCPPNativePacketByteRangeDescriptor? {
        guard let pointer else {
            return nil
        }
        let range = pointer.pointee
        return PCPPNativePacketByteRangeDescriptor(
            offset: range.offset,
            length: range.length,
            bitOffset: Int(range.bitOffset),
            bitLength: Int(range.bitLength),
            hasBitRange: range.hasBitRange,
            sourceIdentifier: Self.string(range.sourceIdentifier) ?? "frame"
        )
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }
}

#if DEBUG
extension WiresharkEpanSession {
    func testInjectCriticalException() throws {
        guard TCPViewerWiresharkSessionTestInjectCriticalException(handle) else {
            if let criticalError = criticalExceptionErrorIfNeeded() {
                throw criticalError
            }
            throw unavailableError()
        }
    }
}
#endif
