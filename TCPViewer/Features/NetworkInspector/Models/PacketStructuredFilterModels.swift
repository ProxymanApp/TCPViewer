//
//  PacketStructuredFilterModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/5/26.
//

import Foundation
import PcapPlusPlusCore

enum PacketStructuredFilterQuery: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case anyText
    case urlDomain
    case `protocol`
    case source
    case destination
    case sourcePort
    case destinationPort
    case client
    case pid
    case bundleIdentifier
    case streamID
    case direction
    case tcpFlags
    case tcpPayload
    case decodeStatus
    case interface
    case length
    case summary
    case tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyText:
            "Any Text"
        case .urlDomain:
            "URL/Domain"
        case .protocol:
            "Protocol"
        case .source:
            "Source"
        case .destination:
            "Destination"
        case .sourcePort:
            "Source Port"
        case .destinationPort:
            "Destination Port"
        case .client:
            "Client"
        case .pid:
            "PID"
        case .bundleIdentifier:
            "Bundle ID"
        case .streamID:
            "Stream ID"
        case .direction:
            "Direction"
        case .tcpFlags:
            "TCP Flags"
        case .tcpPayload:
            "TCP Payload"
        case .decodeStatus:
            "Decode Status"
        case .interface:
            "Interface"
        case .length:
            "Length"
        case .summary:
            "Summary"
        case .tags:
            "Tags"
        }
    }

    var supportsNumericComparison: Bool {
        switch self {
        case .sourcePort, .destinationPort, .pid, .streamID, .tcpPayload, .length:
            true
        default:
            false
        }
    }
}

enum PacketStructuredFilterCondition: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case contains
    case notContains
    case hasPrefix
    case notHasPrefix
    case hasSuffix
    case notHasSuffix
    case lessThan
    case greaterThanOrEqual
    case matchesRegex
    case notMatchesRegex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains:
            "Contains"
        case .notContains:
            "Not Contains"
        case .hasPrefix:
            "Has Prefix"
        case .notHasPrefix:
            "Not Has Prefix"
        case .hasSuffix:
            "Has Suffix"
        case .notHasSuffix:
            "Not Has Suffix"
        case .lessThan:
            "<"
        case .greaterThanOrEqual:
            ">="
        case .matchesRegex:
            "Match Regex"
        case .notMatchesRegex:
            "Not Match Regex"
        }
    }
}

enum PacketStructuredFilterGroupOperator: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case and
    case or

    var id: String { rawValue }

    var title: String {
        switch self {
        case .and:
            "AND all filters"
        case .or:
            "OR all filters"
        }
    }
}

struct PacketStructuredFilter: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var query: PacketStructuredFilterQuery
    var condition: PacketStructuredFilterCondition
    var text: String
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        query: PacketStructuredFilterQuery = .urlDomain,
        condition: PacketStructuredFilterCondition = .contains,
        text: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.query = query
        self.condition = condition
        self.text = text
        self.isEnabled = isEnabled
    }

    var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool {
        isEnabled && !normalizedText.isEmpty
    }

    func duplicatedForNewRow() -> PacketStructuredFilter {
        PacketStructuredFilter(
            query: query,
            condition: condition,
            text: "",
            isEnabled: isEnabled
        )
    }
}

struct PacketStructuredFilterGroup: Codable, Sendable, Hashable {
    static let maxFilterCount = 5
    static let `default` = PacketStructuredFilterGroup(filters: [PacketStructuredFilter()], operator: .and)

    var filters: [PacketStructuredFilter]
    var `operator`: PacketStructuredFilterGroupOperator

    init(
        filters: [PacketStructuredFilter] = [PacketStructuredFilter()],
        `operator`: PacketStructuredFilterGroupOperator = .and
    ) {
        let clampedFilters = Array(filters.prefix(Self.maxFilterCount))
        self.filters = clampedFilters.isEmpty ? [PacketStructuredFilter()] : clampedFilters
        self.operator = `operator`
    }

    var activeFilters: [PacketStructuredFilter] {
        filters.filter(\.isActive)
    }

    var canAddFilter: Bool {
        filters.count < Self.maxFilterCount
    }

    func replacing(_ updatedFilter: PacketStructuredFilter) -> PacketStructuredFilterGroup {
        PacketStructuredFilterGroup(
            filters: filters.map { $0.id == updatedFilter.id ? updatedFilter : $0 },
            operator: `operator`
        )
    }

    func addingCopy(of filterID: PacketStructuredFilter.ID?) -> PacketStructuredFilterGroup {
        guard canAddFilter else {
            return self
        }

        let sourceFilter = filterID.flatMap { id in filters.first { $0.id == id } } ?? PacketStructuredFilter()
        return PacketStructuredFilterGroup(
            filters: filters + [sourceFilter.duplicatedForNewRow()],
            operator: `operator`
        )
    }

    func removingOrClearing(filterID: PacketStructuredFilter.ID) -> PacketStructuredFilterGroup {
        guard filters.count > 1 else {
            return PacketStructuredFilterGroup(
                filters: [PacketStructuredFilter(id: filterID, query: filters.first?.query ?? .urlDomain, condition: filters.first?.condition ?? .contains, isEnabled: false)],
                operator: `operator`
            )
        }

        let nextFilters = filters.filter { $0.id != filterID }
        return PacketStructuredFilterGroup(filters: nextFilters, operator: `operator`)
    }

    func updatingOperator(_ nextOperator: PacketStructuredFilterGroupOperator) -> PacketStructuredFilterGroup {
        PacketStructuredFilterGroup(filters: filters, operator: nextOperator)
    }
}

struct PacketStructuredFilterStore {
    private struct StoredState: Codable {
        static let currentVersion = 1

        let version: Int
        let group: PacketStructuredFilterGroup

        init(version: Int = Self.currentVersion, group: PacketStructuredFilterGroup) {
            self.version = version
            self.group = group
        }
    }

    private static let defaultKey = "TCPViewer.packetStructuredFilters.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    // Load only current-version persisted filters so stale shapes fall back safely.
    func load() -> PacketStructuredFilterGroup {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(StoredState.self, from: data),
              state.version == StoredState.currentVersion else {
            return .default
        }

        return PacketStructuredFilterGroup(filters: state.group.filters, operator: state.group.operator)
    }

    func save(_ group: PacketStructuredFilterGroup) {
        guard let data = try? JSONEncoder().encode(StoredState(group: group)) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

final class PacketStructuredFilterService {
    struct EvaluationContext {
        fileprivate let groupOperator: PacketStructuredFilterGroupOperator
        fileprivate let filters: [PreparedFilter]

        fileprivate var isEmpty: Bool {
            filters.isEmpty
        }
    }

    fileprivate struct PreparedFilter {
        let filter: PacketStructuredFilter
        let normalizedText: String
        let regex: NSRegularExpression?
        let hasInvalidRegex: Bool
        let cost: Int

        init(filter: PacketStructuredFilter) {
            let normalizedText = filter.normalizedText
            self.filter = filter
            self.normalizedText = normalizedText
            self.cost = Self.evaluationCost(for: filter)
            switch filter.condition {
            case .matchesRegex, .notMatchesRegex:
                if let regex = try? NSRegularExpression(pattern: normalizedText, options: [.caseInsensitive]) {
                    self.regex = regex
                    self.hasInvalidRegex = false
                } else {
                    self.regex = nil
                    self.hasInvalidRegex = true
                }
            default:
                self.regex = nil
                self.hasInvalidRegex = false
            }
        }

        private static func evaluationCost(for filter: PacketStructuredFilter) -> Int {
            if filter.condition == .lessThan || filter.condition == .greaterThanOrEqual {
                return 0
            }

            switch (filter.query, filter.condition) {
            case (_, .matchesRegex), (_, .notMatchesRegex):
                return 4
            case (.anyText, _):
                return 5
            case (.sourcePort, _), (.destinationPort, _), (.pid, _), (.streamID, _), (.tcpPayload, _), (.length, _):
                return 1
            case (.direction, _), (.tcpFlags, _), (.decodeStatus, _), (.interface, _), (.tags, _):
                return 2
            default:
                return 3
            }
        }
    }

    // Prepare filters once before scanning packet rows so regex patterns are not compiled per packet.
    func evaluationContext(for group: PacketStructuredFilterGroup) -> EvaluationContext {
        let filters = group.activeFilters.map(PreparedFilter.init)
        let orderedFilters = group.operator == .and
            ? filters.sorted { $0.cost < $1.cost }
            : filters
        return EvaluationContext(
            groupOperator: group.operator,
            filters: orderedFilters
        )
    }

    // Apply the global AND/OR operator to all active filters in the group.
    func matches(_ packet: PacketSummary, group: PacketStructuredFilterGroup) -> Bool {
        matches(packet, context: evaluationContext(for: group))
    }

    // Apply a prepared global AND/OR context to one packet.
    func matches(_ packet: PacketSummary, context: EvaluationContext) -> Bool {
        guard !context.isEmpty else {
            return true
        }

        switch context.groupOperator {
        case .and:
            return context.filters.allSatisfy { matches(packet, preparedFilter: $0) }
        case .or:
            return context.filters.contains { matches(packet, preparedFilter: $0) }
        }
    }

    // Evaluate one filter against the packet values selected by its query.
    func matches(_ packet: PacketSummary, filter: PacketStructuredFilter) -> Bool {
        matches(packet, preparedFilter: PreparedFilter(filter: filter))
    }

    private func matches(_ packet: PacketSummary, preparedFilter: PreparedFilter) -> Bool {
        let filter = preparedFilter.filter
        guard filter.isActive else {
            return true
        }

        let text = preparedFilter.normalizedText
        if filter.condition == .lessThan || filter.condition == .greaterThanOrEqual {
            return matchesNumeric(packet, query: filter.query, condition: filter.condition, text: text)
        }

        let values = stringValues(for: packet, query: filter.query)
        return matches(
            values: values,
            condition: filter.condition,
            text: text,
            regex: preparedFilter.regex,
            hasInvalidRegex: preparedFilter.hasInvalidRegex
        )
    }

    // Compare numeric packet fields only for queries that expose numeric values.
    private func matchesNumeric(
        _ packet: PacketSummary,
        query: PacketStructuredFilterQuery,
        condition: PacketStructuredFilterCondition,
        text: String
    ) -> Bool {
        guard query.supportsNumericComparison,
              let expectedValue = Double(text) else {
            return false
        }

        let values = numericValues(for: packet, query: query)
        guard !values.isEmpty else {
            return false
        }

        switch condition {
        case .lessThan:
            return values.contains { $0 < expectedValue }
        case .greaterThanOrEqual:
            return values.contains { $0 >= expectedValue }
        default:
            return false
        }
    }

    private func matches(
        values: [String],
        condition: PacketStructuredFilterCondition,
        text: String,
        regex: NSRegularExpression?,
        hasInvalidRegex: Bool
    ) -> Bool {
        switch condition {
        case .contains:
            return values.contains { $0.localizedCaseInsensitiveContains(text) }
        case .notContains:
            return !values.contains { $0.localizedCaseInsensitiveContains(text) }
        case .hasPrefix:
            return values.contains { hasPrefix($0, text) }
        case .notHasPrefix:
            return !values.contains { hasPrefix($0, text) }
        case .hasSuffix:
            return values.contains { hasSuffix($0, text) }
        case .notHasSuffix:
            return !values.contains { hasSuffix($0, text) }
        case .matchesRegex:
            return matchesRegex(values: values, regex: regex, hasInvalidRegex: hasInvalidRegex, isNegated: false)
        case .notMatchesRegex:
            return matchesRegex(values: values, regex: regex, hasInvalidRegex: hasInvalidRegex, isNegated: true)
        case .lessThan, .greaterThanOrEqual:
            return false
        }
    }

    private func matchesRegex(
        values: [String],
        regex: NSRegularExpression?,
        hasInvalidRegex: Bool,
        isNegated: Bool
    ) -> Bool {
        guard !hasInvalidRegex, let regex else {
            return false
        }

        let didMatch = values.contains { value in
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, range: range) != nil
        }
        return isNegated ? !didMatch : didMatch
    }

    private func hasPrefix(_ value: String, _ prefix: String) -> Bool {
        value.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    private func hasSuffix(_ value: String, _ suffix: String) -> Bool {
        value.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) != nil
    }

    // Convert each supported query into searchable display strings.
    private func stringValues(for packet: PacketSummary, query: PacketStructuredFilterQuery) -> [String] {
        switch query {
        case .anyText:
            return [searchableText(for: packet)]
        case .urlDomain:
            return compact([
                packet.sniDomainName,
                packet.infoSummary,
                packet.layers.compactMap(\.detailSummary).joined(separator: " "),
            ])
        case .protocol:
            return compact([
                NetworkInspectorFormatters.protocolLabel(for: packet),
                packet.transportHint.rawValue,
                packet.protocolSummary,
                packet.layers.map(\.name).joined(separator: " "),
            ])
        case .source:
            return endpointValues(packet.endpoints.source)
        case .destination:
            return endpointValues(packet.endpoints.destination)
        case .sourcePort:
            return compact([packet.endpoints.source.port.map(String.init)])
        case .destinationPort:
            return compact([packet.endpoints.destination.port.map(String.init)])
        case .client:
            return compact([
                packet.client?.displayName,
                packet.client?.name,
                packet.client?.executablePath,
                packet.client?.bundlePath,
            ])
        case .pid:
            return compact([packet.client.map { String($0.pid) }])
        case .bundleIdentifier:
            return compact([packet.client?.bundleIdentifier])
        case .streamID:
            return compact([packet.streamID.map(String.init)])
        case .direction:
            return compact([packet.direction.map(NetworkInspectorFormatters.directionLabel)])
        case .tcpFlags:
            return compact([packet.tcpFlags])
        case .tcpPayload:
            return compact([packet.tcpPayloadLength.map(String.init)])
        case .decodeStatus:
            return compact([
                NetworkInspectorFormatters.decodeStatusLabel(packet.decodeStatus),
                packet.decodeStatus.reason,
            ])
        case .interface:
            return compact([packet.captureMetadata.interfaceName, packet.interfaceID])
        case .length:
            return compact([String(packet.capturedLength), NetworkInspectorFormatters.byteCount(packet.capturedLength)])
        case .summary:
            return compact([packet.infoSummary])
        case .tags:
            return NetworkInspectorFormatters.tags(for: packet).map(\.label)
        }
    }

    private func numericValues(for packet: PacketSummary, query: PacketStructuredFilterQuery) -> [Double] {
        switch query {
        case .sourcePort:
            return compact([packet.endpoints.source.port]).map { Double($0) }
        case .destinationPort:
            return compact([packet.endpoints.destination.port]).map { Double($0) }
        case .pid:
            return compact([packet.client?.pid]).map { Double($0) }
        case .streamID:
            return compact([packet.streamID]).map { Double($0) }
        case .tcpPayload:
            return compact([packet.tcpPayloadLength]).map { Double($0) }
        case .length:
            return [Double(packet.capturedLength)]
        default:
            return []
        }
    }

    private func searchableText(for packet: PacketSummary) -> String {
        compact([
            String(packet.packetNumber),
            NetworkInspectorFormatters.protocolLabel(for: packet),
            packet.transportHint.rawValue,
            endpointValues(packet.endpoints.source).joined(separator: " "),
            endpointValues(packet.endpoints.destination).joined(separator: " "),
            packet.sniDomainName,
            packet.client?.displayName,
            packet.client?.name,
            packet.client?.bundleIdentifier,
            packet.infoSummary,
            packet.layers.map(\.name).joined(separator: " "),
            packet.layers.compactMap(\.detailSummary).joined(separator: " "),
            NetworkInspectorFormatters.decodeStatusLabel(packet.decodeStatus),
            packet.decodeStatus.reason,
            packet.captureMetadata.interfaceName,
            packet.interfaceID,
        ])
        .joined(separator: " ")
    }

    private func endpointValues(_ endpoint: PacketEndpoint) -> [String] {
        compact([
            endpoint.address,
            endpoint.port.map(String.init),
            NetworkInspectorFormatters.endpointLabel(endpoint),
        ])
    }

    private func compact<T>(_ values: [T?]) -> [T] {
        values.compactMap { $0 }
    }
}
