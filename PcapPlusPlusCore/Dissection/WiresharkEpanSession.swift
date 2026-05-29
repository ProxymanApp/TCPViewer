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

final class WiresharkEpanSession {
    private let handle: OpaquePointer

    init(disabled: Bool = false) throws {
        guard let createdHandle = TCPViewerWiresharkSessionCreate(disabled) else {
            throw NativeNSError(.unavailableFeature, "Wireshark libwireshark backend could not be created.")
        }

        guard TCPViewerWiresharkSessionIsAvailable(createdHandle) else {
            let reason = Self.string(TCPViewerWiresharkSessionUnavailableReason(createdHandle))
                ?? "Wireshark libwireshark backend is unavailable."
            TCPViewerWiresharkSessionDestroy(createdHandle)
            throw NativeNSError(.unavailableFeature, reason)
        }

        self.handle = createdHandle
    }

    deinit {
        TCPViewerWiresharkSessionDestroy(handle)
    }

    func observe(_ record: NativePacketRecord) throws {
        try withContext(for: record) { context in
            guard TCPViewerWiresharkSessionObservePacket(handle, context) else {
                throw unavailableError()
            }
        }
    }

    func finishFirstPass() throws {
        guard TCPViewerWiresharkSessionFinishFirstPass(handle) else {
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
                    context.interfaceID = 0
                    context.sectionNumber = 0
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
