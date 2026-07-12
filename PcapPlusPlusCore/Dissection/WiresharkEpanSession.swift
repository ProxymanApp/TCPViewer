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

enum WiresharkSessionPurpose {
    case offline
    case live
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

    func observe(_ record: NativePacketRecord) throws {
        try withContext(for: record) { context in
            guard TCPViewerWiresharkSessionObservePacket(handle, context) else {
                if let criticalError = criticalExceptionErrorIfNeeded() {
                    throw criticalError
                }
                throw unavailableError()
            }
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
