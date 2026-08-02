//
//  TCPViewerMCPPacketSerializer.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import PcapPlusPlusCore

struct TCPViewerMCPPacketSerializer {
    private let redactor: TCPViewerMCPSensitiveDataRedactor
    private let redactsSensitiveData: Bool

    init(
        redactor: TCPViewerMCPSensitiveDataRedactor = TCPViewerMCPSensitiveDataRedactor(),
        redactsSensitiveData: Bool
    ) {
        self.redactor = redactor
        self.redactsSensitiveData = redactsSensitiveData
    }

    // Keep summaries compact enough for large result pages while preserving useful filter fields.
    func summary(_ packet: PacketSummary) -> TCPViewerMCPValue {
        var object: [String: TCPViewerMCPValue] = [
            "id": .string(String(packet.id)),
            "packet_number": .string(String(packet.packetNumber)),
            "timestamp": .double(packet.timestamp.timeIntervalSince1970),
            "source": .string(packet.source.rawValue),
            "protocol": .string(packet.protocolSummary ?? packet.transportHint.rawValue),
            "transport_hint": .string(packet.transportHint.rawValue),
            "original_length": .int(packet.originalLength),
            "captured_length": .int(packet.capturedLength),
            "info": protectedText(packet.infoSummary),
            "decode_status": .string(packet.decodeStatus.kind.rawValue),
            "truncated": .bool(packet.captureMetadata.isTruncated),
        ]

        object["source_endpoint"] = endpoint(packet.endpoints.source)
        object["destination_endpoint"] = endpoint(packet.endpoints.destination)
        if let interfaceID = packet.interfaceID {
            object["interface_id"] = protectedText(interfaceID)
        }
        if let domain = packet.domainName {
            object["domain"] = protectedText(domain)
        }
        if let domainSource = packet.domainSource {
            object["domain_source"] = .string(domainSource.rawValue)
        }
        if let streamID = packet.streamID {
            object["stream_id"] = .int(Int(streamID))
        }
        if let direction = packet.direction {
            object["direction"] = .string(direction.rawValue)
        }
        if let tcpFlags = packet.tcpFlags {
            object["tcp_flags"] = protectedText(tcpFlags)
        }
        if let tcpPayloadLength = packet.tcpPayloadLength {
            object["tcp_payload_length"] = .int(tcpPayloadLength)
        }
        if let reason = packet.decodeStatus.reason {
            object["decode_reason"] = protectedText(reason)
        }
        if let client = packet.client {
            object["client"] = clientValue(client)
        }
        return .object(object)
    }

    func inspection(
        _ inspection: PacketInspection,
        maximumDepth: Int,
        maximumNodeCount: Int
    ) -> TCPViewerMCPValue {
        var remainingNodes = maximumNodeCount
        let nodes = inspection.detailNodes.compactMap { node in
            detailNode(node, depth: 0, maximumDepth: maximumDepth, remainingNodes: &remainingNodes)
        }
        let views = inspection.byteViews.map { view in
            TCPViewerMCPValue.object([
                "id": protectedText(view.id),
                "label": protectedText(view.label),
                "byte_count": .int(view.bytes.count),
            ])
        }

        return .object([
            "packet_id": .string(String(inspection.packetID)),
            "packet_number": .string(String(inspection.packetNumber)),
            "decode_status": .string(inspection.decodeStatus.kind.rawValue),
            "raw_byte_count": .int(inspection.rawBytes.count),
            "byte_views": .array(views),
            "detail_nodes": .array(nodes),
            "returned_node_count": .int(maximumNodeCount - remainingNodes),
            "nodes_truncated": .bool(remainingNodes == 0),
        ])
    }

    func bytes(
        _ inspection: PacketInspection,
        offset: Int,
        length: Int,
        encoding: String
    ) -> TCPViewerMCPValue {
        let start = min(max(offset, 0), inspection.rawBytes.count)
        let end = min(start + max(length, 0), inspection.rawBytes.count)
        let data = inspection.rawBytes[start..<end]
        let encoded: String
        switch encoding {
        case "base64":
            encoded = Data(data).base64EncodedString()
        default:
            encoded = data.map { String(format: "%02x", $0) }.joined()
        }

        return .object([
            "packet_id": .string(String(inspection.packetID)),
            "encoding": .string(encoding),
            "offset": .int(start),
            "returned_byte_count": .int(data.count),
            "total_byte_count": .int(inspection.rawBytes.count),
            "has_more": .bool(end < inspection.rawBytes.count),
            "data": .string(encoded),
        ])
    }

    private func endpoint(_ endpoint: PacketEndpoint) -> TCPViewerMCPValue {
        var object: [String: TCPViewerMCPValue] = [:]
        if let address = endpoint.address {
            object["address"] = protectedText(address)
        }
        if let port = endpoint.port {
            object["port"] = .int(Int(port))
        }
        return .object(object)
    }

    private func clientValue(_ client: PacketClient) -> TCPViewerMCPValue {
        var object: [String: TCPViewerMCPValue] = [
            "pid": .int(Int(client.pid)),
            "name": protectedText(client.name),
            "display_name": protectedText(client.displayName),
        ]
        if let bundleIdentifier = client.bundleIdentifier {
            object["bundle_id"] = protectedText(bundleIdentifier)
        }
        if let executablePath = client.executablePath {
            object["executable_path"] = protectedText(executablePath)
        }
        if let bundlePath = client.bundlePath {
            object["bundle_path"] = protectedText(bundlePath)
        }
        return .object(object)
    }

    private func detailNode(
        _ node: PacketDetailNode,
        depth: Int,
        maximumDepth: Int,
        remainingNodes: inout Int
    ) -> TCPViewerMCPValue? {
        guard remainingNodes > 0 else {
            return nil
        }
        remainingNodes -= 1

        let isSensitiveField = redactsSensitiveData && (
            redactor.isSensitiveName(node.fieldName) || redactor.isSensitiveName(node.name)
        )
        var object: [String: TCPViewerMCPValue] = [
            "id": protectedText(node.id),
            "name": protectedText(node.name),
            "field_name": protectedText(node.fieldName),
            "kind": .string(node.kind.rawValue),
            "severity": .string(node.severity.rawValue),
        ]
        if let value = node.value {
            object["value"] = isSensitiveField ? .string(TCPViewerMCPSensitiveDataRedactor.placeholder) : protectedText(value)
        }
        if let rawValue = node.rawValue {
            object["raw_value"] = isSensitiveField ? .string(TCPViewerMCPSensitiveDataRedactor.placeholder) : protectedText(rawValue)
        }
        if let range = node.byteRange {
            object["byte_range"] = .object([
                "offset": .int(range.offset),
                "length": .int(range.length),
                "bit_offset": .int(range.bitOffset),
                "bit_length": .int(range.bitLength),
                "source_id": protectedText(range.sourceID),
            ])
        }
        if let packetID = node.jumpTargetPacketID {
            object["jump_target_packet_id"] = .string(String(packetID))
        }

        if depth < maximumDepth && !node.children.isEmpty && remainingNodes > 0 {
            let children = node.children.compactMap { child in
                detailNode(
                    child,
                    depth: depth + 1,
                    maximumDepth: maximumDepth,
                    remainingNodes: &remainingNodes
                )
            }
            object["children"] = .array(children)
            object["children_truncated"] = .bool(children.count < node.children.count)
        } else if !node.children.isEmpty {
            object["children"] = .array([])
            object["children_truncated"] = .bool(true)
        }

        return .object(object)
    }

    private func protectedText(_ text: String) -> TCPViewerMCPValue {
        .string(redactsSensitiveData ? redactor.redact(text) : text)
    }
}
