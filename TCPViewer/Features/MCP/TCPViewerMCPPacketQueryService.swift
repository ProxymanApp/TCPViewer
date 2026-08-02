//
//  TCPViewerMCPPacketQueryService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import PcapPlusPlusCore

enum TCPViewerMCPPacketFilterField: String, CaseIterable {
    case packetID = "packet_id"
    case packetNumber = "packet_number"
    case protocolName = "protocol"
    case domain
    case sourceAddress = "source_address"
    case destinationAddress = "destination_address"
    case address
    case sourcePort = "source_port"
    case destinationPort = "destination_port"
    case port
    case client
    case bundleIdentifier = "bundle_id"
    case direction
    case decodeStatus = "decode_status"
    case info
    case interface
    case streamID = "stream_id"
    case length
    case tcpFlags = "tcp_flags"
    case truncated
    case text
}

enum TCPViewerMCPPacketFilterOperator: String, CaseIterable {
    case equals
    case notEquals = "not_equals"
    case contains
    case notContains = "not_contains"
    case startsWith = "starts_with"
    case endsWith = "ends_with"
    case greaterThan = "greater_than"
    case greaterThanOrEqual = "greater_than_or_equal"
    case lessThan = "less_than"
    case lessThanOrEqual = "less_than_or_equal"
    case exists
}

enum TCPViewerMCPFilterCombination: String {
    case and
    case or
}

enum TCPViewerMCPPacketOrder: String {
    case recent
    case oldest
}

struct TCPViewerMCPPacketFilter {
    let field: TCPViewerMCPPacketFilterField
    let operation: TCPViewerMCPPacketFilterOperator
    let value: String?
    let caseSensitive: Bool
}

struct TCPViewerMCPPacketQuery {
    static let defaultLimit = 50
    static let maximumLimit = 500
    static let defaultScanLimit = 50_000
    static let maximumScanLimit = 100_000
    static let maximumFilterCount = 20
    static let maximumOffset = TCPViewerMCPQueryLimit.maximumOffset
    static let maximumProtocolCount = TCPViewerMCPQueryLimit.maximumProtocolCount
    static let maximumDomainCount = TCPViewerMCPQueryLimit.maximumDomainCount
    static let maximumPacketIDCount = TCPViewerMCPQueryLimit.maximumPacketIDCount
    static let maximumFilterValueByteCount = 4_096

    let filters: [TCPViewerMCPPacketFilter]
    let combination: TCPViewerMCPFilterCombination
    let protocols: Set<String>
    let domains: [String]
    let packetIDs: Set<PacketSummary.ID>
    let streamID: UInt32?
    let scanOffset: Int
    let offset: Int
    let limit: Int
    let scanLimit: Int
    let order: TCPViewerMCPPacketOrder
}

struct TCPViewerMCPPacketQueryResult {
    let packets: [PacketSummary]
    let totalPacketCount: Int
    let scannedPacketCount: Int
    let matchedPacketCount: Int
    let offset: Int
    let nextOffset: Int?
    let scanOffset: Int
    let nextScanOffset: Int?
    let hasMoreUnscannedPackets: Bool
}

enum TCPViewerMCPPacketQueryError: Error, LocalizedError {
    case invalidParameter(String)

    var errorDescription: String? {
        switch self {
        case .invalidParameter(let message):
            return message
        }
    }
}

enum TCPViewerMCPPacketQueryService {
    // Parse and validate every query bound before any packet scan begins.
    static func query(from request: TCPViewerMCPRequest) throws -> TCPViewerMCPPacketQuery {
        let combination = try enumValue(
            TCPViewerMCPFilterCombination.self,
            rawValue: request.string("combination") ?? TCPViewerMCPFilterCombination.and.rawValue,
            parameter: "combination"
        )
        let order = try enumValue(
            TCPViewerMCPPacketOrder.self,
            rawValue: request.string("order") ?? TCPViewerMCPPacketOrder.recent.rawValue,
            parameter: "order"
        )

        let offset = request.int("offset") ?? 0
        guard (0...TCPViewerMCPPacketQuery.maximumOffset).contains(offset) else {
            throw TCPViewerMCPPacketQueryError.invalidParameter(
                "offset must be between 0 and \(TCPViewerMCPPacketQuery.maximumOffset)."
            )
        }
        let requestedLimit = request.int("limit") ?? TCPViewerMCPPacketQuery.defaultLimit
        guard requestedLimit > 0 else {
            throw TCPViewerMCPPacketQueryError.invalidParameter("limit must be greater than zero.")
        }
        let requestedScanLimit = request.int("scan_limit") ?? TCPViewerMCPPacketQuery.defaultScanLimit
        guard requestedScanLimit > 0 else {
            throw TCPViewerMCPPacketQueryError.invalidParameter("scan_limit must be greater than zero.")
        }

        let filterValues: [TCPViewerMCPValue]
        if let rawFilters = request.value("filters") {
            guard let values = rawFilters.arrayValue else {
                throw TCPViewerMCPPacketQueryError.invalidParameter("filters must be an array of objects.")
            }
            filterValues = values
        } else {
            filterValues = []
        }
        let filters = try parseFilters(filterValues)
        let protocols = try stringArray(
            request.value("protocols"),
            parameter: "protocols",
            maximumCount: TCPViewerMCPPacketQuery.maximumProtocolCount,
            maximumStringByteCount: 256
        )
            .map { $0.lowercased() }
        let domains = try stringArray(
            request.value("domains"),
            parameter: "domains",
            maximumCount: TCPViewerMCPPacketQuery.maximumDomainCount,
            maximumStringByteCount: 255
        )
            .map { $0.lowercased() }
        let packetIDs = try stringArray(
            request.value("packet_ids"),
            parameter: "packet_ids",
            maximumCount: TCPViewerMCPPacketQuery.maximumPacketIDCount,
            maximumStringByteCount: 20
        )
            .map { value -> PacketSummary.ID in
                guard let id = PacketSummary.ID(value) else {
                    throw TCPViewerMCPPacketQueryError.invalidParameter("packet_ids contains an invalid UInt64 value: \(value)")
                }
                return id
            }
        let streamID: UInt32?
        if let rawStreamID = request.int("stream_id") {
            guard let value = UInt32(exactly: rawStreamID) else {
                throw TCPViewerMCPPacketQueryError.invalidParameter("stream_id must be between 0 and \(UInt32.max).")
            }
            streamID = value
        } else {
            streamID = nil
        }
        let scanOffset: Int
        if let rawScanOffset = request.value("scan_offset") {
            guard let value = rawScanOffset.intValue else {
                throw TCPViewerMCPPacketQueryError.invalidParameter("scan_offset must be an integer.")
            }
            scanOffset = value
        } else {
            scanOffset = 0
        }
        guard scanOffset >= 0 else {
            throw TCPViewerMCPPacketQueryError.invalidParameter("scan_offset must be zero or greater.")
        }

        return TCPViewerMCPPacketQuery(
            filters: filters,
            combination: combination,
            protocols: Set(protocols),
            domains: domains,
            packetIDs: Set(packetIDs),
            streamID: streamID,
            scanOffset: scanOffset,
            offset: offset,
            limit: min(requestedLimit, TCPViewerMCPPacketQuery.maximumLimit),
            scanLimit: min(requestedScanLimit, TCPViewerMCPPacketQuery.maximumScanLimit),
            order: order
        )
    }

    // Scan at most the configured suffix/prefix and collect only the requested result page.
    static func execute(
        _ query: TCPViewerMCPPacketQuery,
        packets: [PacketSummary],
        totalPacketCount: Int? = nil
    ) -> TCPViewerMCPPacketQueryResult {
        let resolvedTotalPacketCount = max(totalPacketCount ?? packets.count, packets.count)
        let scannedCount = min(packets.count, query.scanLimit)
        let scannedPackets: ArraySlice<PacketSummary>
        switch query.order {
        case .recent:
            scannedPackets = packets.suffix(scannedCount)
        case .oldest:
            scannedPackets = packets.prefix(scannedCount)
        }

        var results: [PacketSummary] = []
        results.reserveCapacity(query.limit)
        var matchedCount = 0
        let sequence: AnySequence<PacketSummary>
        switch query.order {
        case .recent:
            sequence = AnySequence(scannedPackets.reversed())
        case .oldest:
            sequence = AnySequence(scannedPackets)
        }

        for packet in sequence where matches(packet, query: query) {
            if matchedCount >= query.offset && results.count < query.limit {
                results.append(packet)
            }
            matchedCount += 1
        }

        let consumedCount = query.offset + results.count
        let remainingAfterOffset = max(
            0,
            resolvedTotalPacketCount - min(query.scanOffset, resolvedTotalPacketCount)
        )
        let hasMoreUnscannedPackets = scannedCount < remainingAfterOffset
        let nextScanOffset = hasMoreUnscannedPackets ? query.scanOffset + scannedCount : nil
        return TCPViewerMCPPacketQueryResult(
            packets: results,
            totalPacketCount: resolvedTotalPacketCount,
            scannedPacketCount: scannedCount,
            matchedPacketCount: matchedCount,
            offset: query.offset,
            nextOffset: consumedCount < matchedCount ? consumedCount : nil,
            scanOffset: query.scanOffset,
            nextScanOffset: nextScanOffset,
            hasMoreUnscannedPackets: hasMoreUnscannedPackets
        )
    }

    private static func parseFilters(_ values: [TCPViewerMCPValue]) throws -> [TCPViewerMCPPacketFilter] {
        guard values.count <= TCPViewerMCPPacketQuery.maximumFilterCount else {
            throw TCPViewerMCPPacketQueryError.invalidParameter(
                "filters supports at most \(TCPViewerMCPPacketQuery.maximumFilterCount) entries."
            )
        }

        return try values.enumerated().map { index, value in
            guard let object = value.objectValue else {
                throw TCPViewerMCPPacketQueryError.invalidParameter("filters[\(index)] must be an object.")
            }
            guard let fieldName = object["field"]?.stringValue,
                  let field = TCPViewerMCPPacketFilterField(rawValue: fieldName) else {
                throw TCPViewerMCPPacketQueryError.invalidParameter("filters[\(index)].field is unsupported.")
            }
            let operationName = object["operator"]?.stringValue ?? TCPViewerMCPPacketFilterOperator.contains.rawValue
            guard let operation = TCPViewerMCPPacketFilterOperator(rawValue: operationName) else {
                throw TCPViewerMCPPacketQueryError.invalidParameter("filters[\(index)].operator is unsupported.")
            }
            let filterValue = scalarString(object["value"])
            if operation != .exists && filterValue == nil {
                throw TCPViewerMCPPacketQueryError.invalidParameter("filters[\(index)].value is required.")
            }
            if let filterValue,
               filterValue.utf8.count > TCPViewerMCPPacketQuery.maximumFilterValueByteCount {
                throw TCPViewerMCPPacketQueryError.invalidParameter(
                    "filters[\(index)].value is too long."
                )
            }
            if let caseSensitive = object["case_sensitive"], caseSensitive.boolValue == nil {
                throw TCPViewerMCPPacketQueryError.invalidParameter(
                    "filters[\(index)].case_sensitive must be a boolean."
                )
            }
            return TCPViewerMCPPacketFilter(
                field: field,
                operation: operation,
                value: filterValue,
                caseSensitive: object["case_sensitive"]?.boolValue ?? false
            )
        }
    }

    static func matches(_ packet: PacketSummary, query: TCPViewerMCPPacketQuery) -> Bool {
        if !query.protocols.isEmpty {
            let values = protocolValues(packet).map { $0.lowercased() }
            guard query.protocols.contains(where: { protocolName in
                values.contains(where: { $0 == protocolName || $0.contains(protocolName) })
            }) else {
                return false
            }
        }
        if !query.domains.isEmpty {
            guard let domain = packet.domainName?.lowercased(),
                  query.domains.contains(where: { domain.contains($0) }) else {
                return false
            }
        }
        if !query.packetIDs.isEmpty && !query.packetIDs.contains(packet.id) {
            return false
        }
        if let streamID = query.streamID, packet.streamID != streamID {
            return false
        }
        guard !query.filters.isEmpty else {
            return true
        }

        switch query.combination {
        case .and:
            return query.filters.allSatisfy { matches(packet, filter: $0) }
        case .or:
            return query.filters.contains { matches(packet, filter: $0) }
        }
    }

    private static func matches(_ packet: PacketSummary, filter: TCPViewerMCPPacketFilter) -> Bool {
        let stringValues = values(for: filter.field, packet: packet)
        if filter.operation == .exists {
            let expected = filter.value?.lowercased() != "false"
            return expected == stringValues.contains(where: { !$0.isEmpty })
        }

        guard let expectedValue = filter.value else {
            return false
        }
        switch filter.operation {
        case .notEquals, .notContains:
            return !stringValues.isEmpty && stringValues.allSatisfy { actualValue in
                compare(actualValue, to: expectedValue, filter: filter)
            }
        default:
            return stringValues.contains { actualValue in
                compare(actualValue, to: expectedValue, filter: filter)
            }
        }
    }

    private static func values(for field: TCPViewerMCPPacketFilterField, packet: PacketSummary) -> [String] {
        switch field {
        case .packetID:
            return [String(packet.id)]
        case .packetNumber:
            return [String(packet.packetNumber)]
        case .protocolName:
            return protocolValues(packet)
        case .domain:
            return packet.domainName.map { [$0] } ?? []
        case .sourceAddress:
            return packet.endpoints.source.address.map { [$0] } ?? []
        case .destinationAddress:
            return packet.endpoints.destination.address.map { [$0] } ?? []
        case .address:
            return [packet.endpoints.source.address, packet.endpoints.destination.address].compactMap { $0 }
        case .sourcePort:
            return packet.endpoints.source.port.map { [String($0)] } ?? []
        case .destinationPort:
            return packet.endpoints.destination.port.map { [String($0)] } ?? []
        case .port:
            return [packet.endpoints.source.port, packet.endpoints.destination.port].compactMap { $0.map(String.init) }
        case .client:
            return [packet.client?.name, packet.client?.displayName].compactMap { $0 }
        case .bundleIdentifier:
            return packet.client?.bundleIdentifier.map { [$0] } ?? []
        case .direction:
            return packet.direction.map { [$0.rawValue] } ?? []
        case .decodeStatus:
            return [packet.decodeStatus.kind.rawValue, packet.decodeStatus.reason].compactMap { $0 }
        case .info:
            return [packet.infoSummary]
        case .interface:
            return [packet.interfaceID, packet.captureMetadata.interfaceName].compactMap { $0 }
        case .streamID:
            return packet.streamID.map { [String($0)] } ?? []
        case .length:
            return [String(packet.originalLength), String(packet.capturedLength)]
        case .tcpFlags:
            return packet.tcpFlags.map { [$0] } ?? []
        case .truncated:
            return [String(packet.captureMetadata.isTruncated)]
        case .text:
            return protocolValues(packet) + [
                packet.domainName,
                packet.endpoints.source.address,
                packet.endpoints.destination.address,
                packet.client?.displayName,
                packet.client?.bundleIdentifier,
                packet.infoSummary,
                packet.tcpFlags,
            ].compactMap { $0 }
        }
    }

    private static func protocolValues(_ packet: PacketSummary) -> [String] {
        [packet.protocolSummary, packet.transportHint.rawValue].compactMap { $0 }
    }

    private static func compare(
        _ actualValue: String,
        to expectedValue: String,
        filter: TCPViewerMCPPacketFilter
    ) -> Bool {
        let actual = filter.caseSensitive ? actualValue : actualValue.lowercased()
        let expected = filter.caseSensitive ? expectedValue : expectedValue.lowercased()

        switch filter.operation {
        case .equals:
            return actual == expected
        case .notEquals:
            return actual != expected
        case .contains:
            return actual.contains(expected)
        case .notContains:
            return !actual.contains(expected)
        case .startsWith:
            return actual.hasPrefix(expected)
        case .endsWith:
            return actual.hasSuffix(expected)
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            guard let actualNumber = Double(actual), let expectedNumber = Double(expected),
                  actualNumber.isFinite, expectedNumber.isFinite else {
                return false
            }
            switch filter.operation {
            case .greaterThan:
                return actualNumber > expectedNumber
            case .greaterThanOrEqual:
                return actualNumber >= expectedNumber
            case .lessThan:
                return actualNumber < expectedNumber
            case .lessThanOrEqual:
                return actualNumber <= expectedNumber
            default:
                return false
            }
        case .exists:
            return false
        }
    }

    private static func scalarString(_ value: TCPViewerMCPValue?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .array, .object, .null:
            return nil
        }
    }

    private static func stringArray(
        _ value: TCPViewerMCPValue?,
        parameter: String,
        maximumCount: Int,
        maximumStringByteCount: Int
    ) throws -> [String] {
        guard let value else {
            return []
        }
        guard let array = value.arrayValue else {
            throw TCPViewerMCPPacketQueryError.invalidParameter("\(parameter) must be an array of strings.")
        }
        guard array.count <= maximumCount else {
            throw TCPViewerMCPPacketQueryError.invalidParameter(
                "\(parameter) supports at most \(maximumCount) entries."
            )
        }
        return try array.enumerated().map { index, value in
            guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else {
                throw TCPViewerMCPPacketQueryError.invalidParameter("\(parameter)[\(index)] must be a non-empty string.")
            }
            guard string.utf8.count <= maximumStringByteCount else {
                throw TCPViewerMCPPacketQueryError.invalidParameter(
                    "\(parameter)[\(index)] is too long."
                )
            }
            return string
        }
    }

    private static func enumValue<Value: RawRepresentable>(
        _ type: Value.Type,
        rawValue: String,
        parameter: String
    ) throws -> Value where Value.RawValue == String {
        guard let value = Value(rawValue: rawValue) else {
            throw TCPViewerMCPPacketQueryError.invalidParameter("\(parameter) has an unsupported value: \(rawValue)")
        }
        return value
    }
}
