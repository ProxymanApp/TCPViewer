//
//  TCPViewerCLIModelsTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct TCPViewerCLIModelsTests {
    @Test(arguments: [FollowStreamProtocol.tcp, .udp])
    func followResponsePreservesProtocolAndOptionalSequenceNumbers(streamProtocol: FollowStreamProtocol) throws {
        let stream = FollowStream(streamProtocol: streamProtocol,
            client: PacketEndpoint(address: "192.0.2.1", port: 50000),
            server: PacketEndpoint(address: "198.51.100.2", port: 8080),
            records: [
                FollowStreamRecord(direction: .clientToServer, packetID: 1, timestamp: .distantPast,
                    sequenceNumber: streamProtocol == .tcp ? 123 : nil, data: Data("abc".utf8)),
                FollowStreamRecord(direction: .clientToServer, packetID: 2, timestamp: .distantPast,
                    sequenceNumber: streamProtocol == .tcp ? 126 : nil, data: Data()),
                FollowStreamRecord(direction: .serverToClient, packetID: 3, timestamp: .distantPast,
                    sequenceNumber: streamProtocol == .tcp ? 456 : nil, data: Data("reply".utf8)),
            ], clientByteCount: 3, serverByteCount: 5, capturedThroughPacketID: 3, capturedAt: .distantPast, isTruncated: false)
        let data = TCPViewerCLICommandRouter.followData(stream, direction: "client-to-server", encoding: "hex", maximumBytes: 3, maximumRecords: 2)
        #expect(data["protocol"] == .string(streamProtocol.rawValue))
        #expect(data["returned_record_count"] == .int(2))
        #expect(data["returned_byte_count"] == .int(3))
        #expect(data["truncated"] == .bool(false))
        guard case .array(let records) = data["records"], case .object(let first) = records.first else {
            Issue.record("Missing follow records")
            return
        }
        #expect(first["sequence_number"] == (streamProtocol == .tcp ? .string("123") : .null))
        #expect(first["packet_id"] == .string("1"))
        #expect(first["data"] == .string("616263"))
    }

    @Test func encodesStableEnvelopePacketIDsAndBinaryAsStrings() throws {
        let response = TCPViewerCLIResponse.success(
            requestID: "d733d28a-2c43-4d61-917c-32388fa7c052",
            command: .packetsBytes,
            data: [
                "packet_id": .string(String(UInt64.max)),
                "encoding": .string("base64"),
                "data": .string(Data([0, 1, 2]).base64EncodedString()),
            ]
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])

        #expect(object["schema_version"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        #expect(object["command"] as? String == "packets.bytes")
        #expect(data["packet_id"] as? String == "18446744073709551615")
        #expect(data["data"] as? String == "AAEC")
    }

    @Test func failureEnvelopeDoesNotContainLicenseSecrets() throws {
        let response = TCPViewerCLIResponse.failure(
            requestID: UUID().uuidString.lowercased(),
            command: .licenseActivate,
            code: "license_activation_failed",
            message: "Invalid license key."
        )
        let json = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))

        #expect(json.contains("license_activation_failed"))
        #expect(!json.contains("license_key"))
        #expect(!json.contains("signature"))
    }

    @Test func roundTripsIPv6FilterValueWithoutChangingColons() throws {
        let request = TCPViewerCLIRequest(
            command: .packetsList,
            params: [
                "filters": .array([.object([
                    "field": .string("source_address"),
                    "operator": .string("equals"),
                    "value": .string("2001:db8::1"),
                ])]),
            ],
            expiresAt: Date().addingTimeInterval(30)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try decoder.decode(TCPViewerCLIRequest.self, from: encoder.encode(request))

        #expect(decoded.requestID == request.requestID)
        #expect(decoded.command == request.command)
        #expect(decoded.params == request.params)
        #expect(decoded.array("filters")?.first?.objectValue?["value"] == .string("2001:db8::1"))
    }

    @Test func advancedFilterValuesRemainLexical() {
        #expect(TCPViewerCLIValue.lexicalFilterValue("001") == .string("001"))
        #expect(TCPViewerCLIValue.lexicalFilterValue("1e3") == .string("1e3"))
        #expect(TCPViewerCLIValue.lexicalFilterValue("true") == .string("true"))
    }

    @Test func failedImportCanReportFilesThatOpenedBeforeTheFailure() {
        let response = TCPViewerCLIResponse.failure(
            requestID: UUID().uuidString.lowercased(),
            command: .fileImport,
            code: "import_failed",
            message: "One capture could not be imported.",
            data: [
                "imported_files": .array([.string("/tmp/opened.pcap")]),
                "imported_file_count": .int(1),
            ]
        )

        #expect(!response.ok)
        #expect(response.data?["imported_files"] == .array([.string("/tmp/opened.pcap")]))
        #expect(response.data?["imported_file_count"] == .int(1))
    }
}
