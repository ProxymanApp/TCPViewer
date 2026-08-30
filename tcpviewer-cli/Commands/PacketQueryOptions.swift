//
//  PacketQueryOptions.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import ArgumentParser
import Foundation

enum TCPViewerCLIQueryMatch: String, ExpressibleByArgument {
    case and
    case or
}

enum TCPViewerCLIQueryOrder: String, ExpressibleByArgument {
    case recent
    case oldest
}

struct TCPViewerCLIPacketQueryOptions: ParsableArguments {
    @Option(name: .customLong("protocol"), help: "Protocol name. Repeat to match any protocol.")
    var protocols: [String] = []

    @Option(name: .customLong("domain"), help: "Domain fragment. Repeat to match any domain.")
    var domains: [String] = []

    @Option(name: .customLong("address"), help: "Source or destination address fragment.")
    var addresses: [String] = []

    @Option(name: .customLong("port"), help: "Source or destination port.")
    var ports: [Int] = []

    @Option(name: .customLong("client"), help: "Client application name fragment.")
    var clients: [String] = []

    @Option(name: .customLong("packet-id"), help: "Packet ID. Repeat to match any listed packet.")
    var packetIDs: [String] = []

    @Option(name: .customLong("stream-id"), help: "TCP or UDP stream ID.")
    var streamID: UInt32?

    @Option(name: .customLong("filter"), help: "Advanced field:operator:value filter. Repeat for more filters.")
    var filters: [String] = []

    @Option(name: .customLong("match"), help: "How advanced filters are combined.")
    var match: TCPViewerCLIQueryMatch = .and

    @Flag(name: .customLong("case-sensitive"), help: "Use case-sensitive advanced text filters.")
    var caseSensitive = false

    @Option(name: .customLong("order"), help: "Read recent or oldest packets first.")
    var order: TCPViewerCLIQueryOrder = .recent

    @Option(name: .customLong("limit"), help: "Maximum returned packets, from 1 through 500.")
    var limit = 50

    @Option(name: .customLong("offset"), help: "Matched packets to skip.")
    var offset = 0

    @Option(name: .customLong("scan-limit"), help: "Maximum packets to scan, up to 100000.")
    var scanLimit = 50_000

    @Option(name: .customLong("scan-offset"), help: "Packets to skip before the bounded scan.")
    var scanOffset = 0

    var hasSelector: Bool {
        !protocols.isEmpty || !domains.isEmpty || !addresses.isEmpty || !ports.isEmpty ||
            !clients.isEmpty || !packetIDs.isEmpty || streamID != nil || !filters.isEmpty
    }

    func validate() throws {
        guard (1...500).contains(limit) else {
            throw ValidationError("--limit must be between 1 and 500.")
        }
        guard (0...100_000).contains(offset) else {
            throw ValidationError("--offset must be between 0 and 100000.")
        }
        guard (1...100_000).contains(scanLimit) else {
            throw ValidationError("--scan-limit must be between 1 and 100000.")
        }
        guard scanOffset >= 0 else {
            throw ValidationError("--scan-offset cannot be negative.")
        }
        guard filters.count + addresses.count + ports.count + clients.count <= 20 else {
            throw ValidationError("At most 20 advanced, address, port, and client filters are allowed.")
        }
        guard protocols.count <= 100, protocols.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw ValidationError("--protocol accepts at most 100 nonempty values of up to 256 UTF-8 bytes.")
        }
        guard domains.count <= 100, domains.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 }) else {
            throw ValidationError("--domain accepts at most 100 nonempty values of up to 255 UTF-8 bytes.")
        }
        guard addresses.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }) else {
            throw ValidationError("--address values must contain between 1 and 4096 UTF-8 bytes.")
        }
        guard clients.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }) else {
            throw ValidationError("--client values must contain between 1 and 4096 UTF-8 bytes.")
        }
        guard packetIDs.count <= 10_000 else {
            throw ValidationError("--packet-id accepts at most 10000 values.")
        }
        for port in ports where !(0...65_535).contains(port) {
            throw ValidationError("--port must be between 0 and 65535.")
        }
        for packetID in packetIDs where UInt64(packetID) == nil {
            throw ValidationError("--packet-id must be an unsigned decimal integer.")
        }
        _ = try parsedAdvancedFilters()
    }

    func params(includesPagination: Bool = true) throws -> [String: TCPViewerCLIValue] {
        try validate()
        var result: [String: TCPViewerCLIValue] = [
            "combination": .string(match.rawValue),
            "order": .string(order.rawValue),
            "scan_limit": .int(scanLimit),
            "scan_offset": .int(scanOffset),
        ]
        if includesPagination {
            result["limit"] = .int(limit)
            result["offset"] = .int(offset)
        }
        if !protocols.isEmpty { result["protocols"] = .array(protocols.map(TCPViewerCLIValue.string)) }
        if !domains.isEmpty { result["domains"] = .array(domains.map(TCPViewerCLIValue.string)) }
        if !packetIDs.isEmpty { result["packet_ids"] = .array(packetIDs.map(TCPViewerCLIValue.string)) }
        if let streamID { result["stream_id"] = .int(Int(streamID)) }

        var parsedFilters = try parsedAdvancedFilters()
        parsedFilters += addresses.map { filter(field: "address", operation: "contains", value: .string($0)) }
        parsedFilters += ports.map { filter(field: "port", operation: "equals", value: .int($0)) }
        parsedFilters += clients.map { filter(field: "client", operation: "contains", value: .string($0)) }
        if !parsedFilters.isEmpty { result["filters"] = .array(parsedFilters) }
        return result
    }

    private func parsedAdvancedFilters() throws -> [TCPViewerCLIValue] {
        try filters.map { rawFilter in
            let components = rawFilter.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count == 3 else {
                throw ValidationError("--filter must use field:operator:value syntax.")
            }
            let field = String(components[0])
            let operation = String(components[1])
            let value = String(components[2])
            guard Self.fields.contains(field) else {
                throw ValidationError("Unsupported filter field: \(field).")
            }
            guard Self.operators.contains(operation) else {
                throw ValidationError("Unsupported filter operator: \(operation).")
            }
            guard value.utf8.count <= 4_096 else {
                throw ValidationError("A filter value cannot exceed 4096 UTF-8 bytes.")
            }
            return filter(field: field, operation: operation, value: .lexicalFilterValue(value))
        }
    }

    private func filter(field: String, operation: String, value: TCPViewerCLIValue) -> TCPViewerCLIValue {
        .object([
            "field": .string(field),
            "operator": .string(operation),
            "value": value,
            "case_sensitive": .bool(caseSensitive),
        ])
    }

    private static let fields: Set<String> = [
        "packet_id", "packet_number", "protocol", "domain", "source_address",
        "destination_address", "address", "source_port", "destination_port", "port",
        "client", "bundle_id", "direction", "decode_status", "info", "interface",
        "stream_id", "length", "tcp_flags", "truncated", "text",
    ]

    private static let operators: Set<String> = [
        "equals", "not_equals", "contains", "not_contains", "starts_with", "ends_with",
        "greater_than", "greater_than_or_equal", "less_than", "less_than_or_equal", "exists",
    ]
}
