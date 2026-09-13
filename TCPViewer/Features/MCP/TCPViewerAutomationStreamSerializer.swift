//
//  TCPViewerAutomationStreamSerializer.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 13/9/26.
//

import Foundation
import PcapPlusPlusCore

enum TCPViewerAutomationStreamSerializer {
    // Serialize the shared snapshot without inventing TCP sequence numbers for UDP datagrams.
    static func data(
        _ stream: FollowStream,
        direction: String,
        encoding: String,
        maximumBytes: Int,
        maximumRecords: Int,
        redacted: Bool = false
    ) -> [String: TCPViewerMCPValue] {
        var returnedBytes = 0
        var records: [TCPViewerMCPValue] = []
        var wasLimited = stream.isTruncated
        for record in stream.records where includes(record.direction, selection: direction) {
            guard records.count < maximumRecords, returnedBytes < maximumBytes || record.data.isEmpty else {
                wasLimited = true
                break
            }
            let data = Data(record.data.prefix(maximumBytes - returnedBytes))
            if data.count < record.data.count { wasLimited = true }
            returnedBytes += data.count
            var entry: [String: TCPViewerMCPValue] = [
                "direction": .string(record.direction == .clientToServer ? "client_to_server" : "server_to_client"),
                "packet_id": .string(String(record.packetID)),
                "timestamp": .string(Self.iso8601.string(from: record.timestamp)),
                "sequence_number": record.sequenceNumber.map { .string(String($0)) } ?? .null,
                "byte_count": .int(data.count),
            ]
            if !redacted { entry["data"] = .string(encoded(data, as: encoding)) }
            records.append(.object(entry))
            if data.count < record.data.count { break }
        }
        return [
            "protocol": .string(stream.streamProtocol.rawValue),
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
            "payload_redacted": .bool(redacted),
        ]
    }

    private static func includes(_ direction: FollowStreamDirection, selection: String) -> Bool {
        selection == "both" ||
            (selection == "client-to-server" && direction == .clientToServer) ||
            (selection == "server-to-client" && direction == .serverToClient)
    }

    private static func encoded(_ data: Data, as encoding: String) -> String {
        switch encoding {
        case "base64": data.base64EncodedString()
        case "hex": data.map { String(format: "%02x", $0) }.joined()
        default: String(decoding: data, as: UTF8.self)
        }
    }

    private static func endpointValue(_ endpoint: PacketEndpoint) -> TCPViewerMCPValue {
        var value: [String: TCPViewerMCPValue] = [:]
        if let address = endpoint.address { value["address"] = .string(address) }
        if let port = endpoint.port { value["port"] = .int(Int(port)) }
        return .object(value)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
