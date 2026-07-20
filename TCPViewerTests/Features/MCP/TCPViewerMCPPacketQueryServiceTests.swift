//
//  TCPViewerMCPPacketQueryServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct TCPViewerMCPPacketQueryServiceTests {
    @Test func defaultsToBoundedNewestFirstPagination() throws {
        let packets = (1...5).map { makeMCPPacket(id: UInt64($0)) }
        let request = TCPViewerMCPRequest(command: "query_packets", params: ["limit": .int(2), "offset": .int(1)])
        let query = try TCPViewerMCPPacketQueryService.query(from: request)
        let result = TCPViewerMCPPacketQueryService.execute(query, packets: packets)

        #expect(result.packets.map(\.id) == [4, 3])
        #expect(result.matchedPacketCount == 5)
        #expect(result.nextOffset == 3)
        #expect(!result.hasMoreUnscannedPackets)
    }

    @Test func directConstraintsAreCombinedWithFilters() throws {
        let packets = [
            makeMCPPacket(id: 1, protocolName: "TLS", domain: "api.example.com", streamID: 7),
            makeMCPPacket(id: 2, protocolName: "DNS", domain: "api.example.com", streamID: 7),
            makeMCPPacket(id: 3, protocolName: "TLS", domain: "other.test", streamID: 7),
            makeMCPPacket(id: 4, protocolName: "TLS", domain: "api.example.com", streamID: 9),
        ]
        let query = try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
            command: "query_packets",
            params: [
                "protocols": .array([.string("tls")]),
                "domains": .array([.string("example.com")]),
                "stream_id": .int(7),
                "packet_ids": .array([.string("1"), .string("2")]),
                "filters": .array([filter(field: "destination_port", operation: "equals", value: .int(443))]),
            ]
        ))
        let result = TCPViewerMCPPacketQueryService.execute(query, packets: packets)
        #expect(result.packets.map(\.id) == [1])
    }

    @Test func everyFilterFieldAndOperatorMatchesExpectedPacket() throws {
        let packet = makeMCPPacket(id: 1, capturedLength: 128, isTruncated: true)
        let cases: [(String, String, TCPViewerMCPValue)] = [
            ("packet_id", "equals", .string("1")),
            ("packet_number", "greater_than", .int(100)),
            ("protocol", "contains", .string("LS")),
            ("domain", "ends_with", .string("example.com")),
            ("source_address", "starts_with", .string("10.")),
            ("destination_address", "equals", .string("93.184.216.34")),
            ("address", "contains", .string("184.216")),
            ("source_port", "greater_than_or_equal", .int(51_234)),
            ("destination_port", "less_than_or_equal", .int(443)),
            ("port", "less_than", .int(50_000)),
            ("client", "contains", .string("Example")),
            ("bundle_id", "equals", .string("com.example.client")),
            ("direction", "equals", .string("outbound")),
            ("decode_status", "contains", .string("truncated")),
            ("info", "not_contains", .string("not-present")),
            ("interface", "equals", .string("en0")),
            ("stream_id", "equals", .int(7)),
            ("length", "greater_than", .int(100)),
            ("tcp_flags", "contains", .string("SYN")),
            ("truncated", "equals", .bool(true)),
            ("text", "contains", .string("api.example.com")),
        ]

        for (field, operation, value) in cases {
            let query = try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
                command: "query_packets",
                params: ["filters": .array([filter(field: field, operation: operation, value: value)])]
            ))
            #expect(TCPViewerMCPPacketQueryService.execute(query, packets: [packet]).packets.map(\.id) == [1], "Failed \(field) \(operation)")
        }
    }

    @Test func negativeMultiValueOperatorsRequireEveryCandidateToBeNegative() throws {
        let packet = makeMCPPacket(id: 1)
        let notContains = try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
            command: "query_packets",
            params: ["filters": .array([filter(field: "address", operation: "not_contains", value: .string("10.0"))])]
        ))
        let notEquals = try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
            command: "query_packets",
            params: ["filters": .array([filter(field: "port", operation: "not_equals", value: .int(443))])]
        ))

        #expect(TCPViewerMCPPacketQueryService.execute(notContains, packets: [packet]).packets.isEmpty)
        #expect(TCPViewerMCPPacketQueryService.execute(notEquals, packets: [packet]).packets.isEmpty)
    }

    @Test func supportsAndOrCaseSensitivityAndExistsFalse() throws {
        let packet = makeMCPPacket(id: 1, domain: nil)
        let orQuery = try query(filters: [
            filter(field: "protocol", operation: "equals", value: .string("dns")),
            filter(field: "client", operation: "contains", value: .string("example")),
        ], combination: "or")
        let andQuery = try query(filters: [
            filter(field: "protocol", operation: "equals", value: .string("Tls"), caseSensitive: true),
            filter(field: "domain", operation: "exists", value: .bool(false)),
        ], combination: "and")
        let missingDomain = try query(filters: [
            filter(field: "domain", operation: "exists", value: .bool(false)),
        ], combination: "and")

        #expect(TCPViewerMCPPacketQueryService.execute(orQuery, packets: [packet]).packets.count == 1)
        #expect(TCPViewerMCPPacketQueryService.execute(andQuery, packets: [packet]).packets.isEmpty)
        #expect(TCPViewerMCPPacketQueryService.execute(missingDomain, packets: [packet]).packets.count == 1)
    }

    @Test func scanWindowAndResultBoundsAreEnforced() throws {
        let packets = (1...10).map { makeMCPPacket(id: UInt64($0)) }
        let recent = try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
            command: "query_packets",
            params: ["scan_limit": .int(3), "limit": .int(999)]
        ))
        let oldest = try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
            command: "query_packets",
            params: ["scan_limit": .int(3), "order": .string("oldest")]
        ))

        let recentResult = TCPViewerMCPPacketQueryService.execute(recent, packets: packets)
        #expect(recent.limit == 500)
        #expect(recentResult.packets.map(\.id) == [10, 9, 8])
        #expect(recentResult.hasMoreUnscannedPackets)
        #expect(TCPViewerMCPPacketQueryService.execute(oldest, packets: packets).packets.map(\.id) == [1, 2, 3])
    }

    @Test func rejectsInvalidParametersAndCapsOversizedScan() throws {
        let invalidRequests: [[String: TCPViewerMCPValue]] = [
            ["offset": .int(-1)],
            ["offset": .int(TCPViewerMCPPacketQuery.maximumOffset + 1)],
            ["limit": .int(0)],
            ["scan_limit": .int(0)],
            ["combination": .string("xor")],
            ["order": .string("random")],
            ["protocols": .string("tcp")],
            ["protocols": .array([.string("")])],
            ["protocols": .array([.string(String(repeating: "p", count: 257))])],
            ["protocols": .array(Array(repeating: .string("tcp"), count: TCPViewerMCPPacketQuery.maximumProtocolCount + 1))],
            ["domains": .array(Array(repeating: .string("example.com"), count: TCPViewerMCPPacketQuery.maximumDomainCount + 1))],
            ["packet_ids": .array(Array(repeating: .string("1"), count: TCPViewerMCPPacketQuery.maximumPacketIDCount + 1))],
            ["packet_ids": .array([.string("-1")])],
            ["stream_id": .int(-1)],
            ["filters": .array([.string("bad")])],
            ["filters": .array([.object(["field": .string("unknown"), "value": .string("x")])])],
            ["filters": .array([.object(["field": .string("info"), "operator": .string("bad"), "value": .string("x")])])],
            ["filters": .array([.object(["field": .string("info")])])],
            ["filters": .array([filter(field: "info", operation: "contains", value: .string(String(repeating: "x", count: 4_097)))])],
            ["filters": .array([.object([
                "field": .string("info"),
                "value": .string("x"),
                "case_sensitive": .string("yes"),
            ])])],
            ["filters": .array(Array(repeating: filter(field: "info", operation: "contains", value: .string("x")), count: 21))],
        ]
        for params in invalidRequests {
            #expect(throws: Error.self) {
                try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(command: "query_packets", params: params))
            }
        }

        let capped = try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
            command: "query_packets",
            params: ["scan_limit": .int(Int.max)]
        ))
        #expect(capped.scanLimit == TCPViewerMCPPacketQuery.maximumScanLimit)
    }

    private func query(
        filters: [TCPViewerMCPValue],
        combination: String
    ) throws -> TCPViewerMCPPacketQuery {
        try TCPViewerMCPPacketQueryService.query(from: TCPViewerMCPRequest(
            command: "query_packets",
            params: ["filters": .array(filters), "combination": .string(combination)]
        ))
    }

    private func filter(
        field: String,
        operation: String,
        value: TCPViewerMCPValue,
        caseSensitive: Bool = false
    ) -> TCPViewerMCPValue {
        .object([
            "field": .string(field),
            "operator": .string(operation),
            "value": value,
            "case_sensitive": .bool(caseSensitive),
        ])
    }
}
