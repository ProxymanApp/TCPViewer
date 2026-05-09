//
//  NetworkInspectorModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import Foundation
import PcapPlusPlusCore

enum NetworkInspectorWorkspaceMode: String, CaseIterable, Identifiable, Sendable, Hashable {
    case packets
    case flows
    case timeline
    case map
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .packets:
            "Packets"
        case .flows:
            "Flows"
        case .timeline:
            "Timeline"
        case .map:
            "Map"
        case .errors:
            "Errors"
        }
    }

    var systemImage: String {
        switch self {
        case .packets:
            "list.bullet.rectangle"
        case .flows:
            "arrow.left.arrow.right"
        case .timeline:
            "chart.xyaxis.line"
        case .map:
            "map"
        case .errors:
            "exclamationmark.triangle"
        }
    }

    var preparedStateMessage: String {
        switch self {
        case .packets:
            "Packet inspection is ready."
        case .flows:
            "Flow aggregation is prepared for the next analysis pass."
        case .timeline:
            "Timeline analysis is prepared for a future graph-backed view."
        case .map:
            "Network map analysis is prepared for a future topology view."
        case .errors:
            "Error triage is prepared for a future diagnostics view."
        }
    }
}

enum NetworkInspectorSidebarSelection: Hashable, Sendable {
    case liveCapture
    case recentCaptures
    case savedSessions
    case interface(String)
    case view(NetworkInspectorWorkspaceMode)
}

private extension String {
    var tcpviewerTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PacketInspectorTab: String, CaseIterable, Identifiable, Sendable, Hashable {
    case summary
    case detail
    case raw
    case hex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary:
            "Summary"
        case .detail:
            "Detail"
        case .raw:
            "Raw"
        case .hex:
            "Hex"
        }
    }
}

enum PacketSeverity: String, Sendable, Hashable {
    case normal
    case partial
    case malformed
    case unsupported
    case truncated

    var label: String {
        switch self {
        case .normal:
            "Normal"
        case .partial:
            "Partial"
        case .malformed:
            "Malformed"
        case .unsupported:
            "Unsupported"
        case .truncated:
            "Truncated"
        }
    }
}

struct PacketTag: Identifiable, Sendable, Hashable {
    let id: String
    let label: String
    let severity: PacketSeverity

    init(label: String, severity: PacketSeverity) {
        self.id = "\(severity.rawValue)-\(label)"
        self.label = label
        self.severity = severity
    }
}

struct PacketTableRow: Identifiable, Sendable, Hashable {
    let id: PacketSummary.ID
    let client: PacketClient?
    let sourceAddress: String?
    let destinationAddress: String?
    let sniDomainName: String?
    let timestamp: Date
    let streamID: UInt32?
    let numberText: String
    let timeText: String
    let sourceText: String
    let destinationText: String
    let sourcePortText: String
    let destinationPortText: String
    let domainText: String
    let clientText: String
    let protocolText: String
    let streamIDText: String
    let directionText: String
    let deltaTimeText: String
    let streamDeltaTimeText: String
    let tcpFlagsText: String
    let tcpPayloadBytesText: String
    let pidText: String
    let bundleIdentifierText: String
    let decodeStatusText: String
    let interfaceText: String
    let lengthText: String
    let summaryText: String
    let tags: [PacketTag]
    let severity: PacketSeverity

    init(packet: PacketSummary) {
        self.init(
            packet: packet,
            previousVisiblePacketTimestamp: nil,
            previousVisibleStreamPacketTimestamp: nil
        )
    }

    init(
        packet: PacketSummary,
        previousVisiblePacketTimestamp: Date?,
        previousVisibleStreamPacketTimestamp: Date?
    ) {
        self.id = packet.id
        self.client = packet.client
        self.sourceAddress = packet.endpoints.source.address
        self.destinationAddress = packet.endpoints.destination.address
        self.sniDomainName = packet.sniDomainName
        self.timestamp = packet.timestamp
        self.streamID = packet.streamID
        self.numberText = "\(packet.packetNumber)"
        self.timeText = NetworkInspectorFormatters.packetTimeString(packet.timestamp)
        self.sourceText = NetworkInspectorFormatters.endpointLabel(packet.endpoints.source)
        self.destinationText = NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination)
        self.sourcePortText = NetworkInspectorFormatters.portLabel(packet.endpoints.source.port)
        self.destinationPortText = NetworkInspectorFormatters.portLabel(packet.endpoints.destination.port)
        self.domainText = packet.sniDomainName ?? "-"
        self.clientText = packet.client?.displayName ?? "-"
        self.protocolText = NetworkInspectorFormatters.protocolLabel(for: packet)
        self.streamIDText = packet.streamID.map(String.init) ?? "-"
        self.directionText = NetworkInspectorFormatters.directionLabel(packet.direction)
        self.deltaTimeText = NetworkInspectorFormatters.intervalLabel(
            from: previousVisiblePacketTimestamp,
            to: packet.timestamp
        )
        self.streamDeltaTimeText = NetworkInspectorFormatters.intervalLabel(
            from: previousVisibleStreamPacketTimestamp,
            to: packet.timestamp
        )
        self.tcpFlagsText = packet.tcpFlags ?? "-"
        self.tcpPayloadBytesText = packet.tcpPayloadLength.map(NetworkInspectorFormatters.byteCount) ?? "-"
        self.pidText = packet.client.map { String($0.pid) } ?? "-"
        self.bundleIdentifierText = packet.client?.bundleIdentifier ?? "-"
        self.decodeStatusText = NetworkInspectorFormatters.decodeStatusLabel(packet.decodeStatus)
        self.interfaceText = packet.captureMetadata.interfaceName ?? packet.interfaceID ?? "-"
        self.lengthText = NetworkInspectorFormatters.byteCount(packet.capturedLength)
        self.summaryText = packet.infoSummary
        self.tags = NetworkInspectorFormatters.tags(for: packet)
        self.severity = NetworkInspectorFormatters.severity(for: packet)
    }

    var tagText: String {
        tags.map(\.label).joined(separator: " | ")
    }

    var canPinDomain: Bool {
        sniDomainName?.tcpviewerTrimmedNonEmpty != nil
    }

    var canPinClient: Bool {
        client != nil
    }

    func ipAddress(for clickedColumn: PacketTableColumnRole) -> String? {
        switch clickedColumn {
        case .source:
            return sourceAddress ?? destinationAddress
        case .destination:
            return destinationAddress ?? sourceAddress
        default:
            return destinationAddress ?? sourceAddress
        }
    }

    func text(for column: PacketTableColumnRole) -> String {
        switch column {
        case .number:
            numberText
        case .time:
            timeText
        case .source:
            sourceText
        case .destination:
            destinationText
        case .sourcePort:
            sourcePortText
        case .destinationPort:
            destinationPortText
        case .domain:
            domainText
        case .client:
            clientText
        case .protocol:
            protocolText
        case .streamID:
            streamIDText
        case .direction:
            directionText
        case .deltaTime:
            deltaTimeText
        case .streamDeltaTime:
            streamDeltaTimeText
        case .tcpFlags:
            tcpFlagsText
        case .tcpPayloadBytes:
            tcpPayloadBytesText
        case .pid:
            pidText
        case .bundleIdentifier:
            bundleIdentifierText
        case .decodeStatus:
            decodeStatusText
        case .interface:
            interfaceText
        case .length:
            lengthText
        case .summary:
            summaryText
        case .tags:
            tagText
        case .unknown:
            ""
        }
    }
}

struct PacketTableRowTimingState: Sendable, Hashable {
    private var previousVisiblePacketTimestamp: Date?
    private var previousVisibleStreamPacketTimestampByID: [UInt32: Date] = [:]

    // Build a row with deltas from the previous visible packet and stream packet.
    mutating func row(for packet: PacketSummary) -> PacketTableRow {
        let streamTimestamp = packet.streamID.flatMap { previousVisibleStreamPacketTimestampByID[$0] }
        let row = PacketTableRow(
            packet: packet,
            previousVisiblePacketTimestamp: previousVisiblePacketTimestamp,
            previousVisibleStreamPacketTimestamp: streamTimestamp
        )
        previousVisiblePacketTimestamp = packet.timestamp
        if let streamID = packet.streamID {
            previousVisibleStreamPacketTimestampByID[streamID] = packet.timestamp
        }
        return row
    }
}

struct PacketFilterChip: Identifiable, Sendable, Hashable {
    let id: String
    let label: String
}

struct PacketDisplayFilter: Sendable, Hashable {
    enum Token: Sendable, Hashable {
        case protocolName(String)
        case endpoint(String)
        case port(UInt16)
        case status(PacketSeverity)
        case text(String)

        var chip: PacketFilterChip? {
            switch self {
            case .protocolName(let value):
                PacketFilterChip(id: "protocol-\(value)", label: "Protocol: \(value.uppercased())")
            case .endpoint(let value):
                PacketFilterChip(id: "endpoint-\(value)", label: "Endpoint: \(value)")
            case .port(let value):
                PacketFilterChip(id: "port-\(value)", label: "Port: \(value)")
            case .status(let value):
                PacketFilterChip(id: "status-\(value.rawValue)", label: "Status: \(value.label)")
            case .text:
                nil
            }
        }
    }

    let rawText: String
    let tokens: [Token]

    init(_ rawText: String) {
        self.rawText = rawText
        self.tokens = Self.parse(rawText)
    }

    var isEmpty: Bool {
        tokens.isEmpty
    }

    var chips: [PacketFilterChip] {
        tokens.compactMap(\.chip)
    }

    func matches(_ packet: PacketSummary) -> Bool {
        tokens.allSatisfy { token in
            switch token {
            case .protocolName(let value):
                NetworkInspectorFormatters.protocolLabel(for: packet)
                    .localizedCaseInsensitiveContains(value)
            case .endpoint(let value):
                endpointText(for: packet).localizedCaseInsensitiveContains(value)
            case .port(let value):
                packet.endpoints.source.port == value || packet.endpoints.destination.port == value
            case .status(let value):
                NetworkInspectorFormatters.severity(for: packet) == value
            case .text(let value):
                searchableText(for: packet).localizedCaseInsensitiveContains(value)
            }
        }
    }

    private static func parse(_ rawText: String) -> [Token] {
        rawText
            .split(whereSeparator: \.isWhitespace)
            .compactMap { rawToken in
                let token = String(rawToken).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else {
                    return nil
                }

                let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    return .text(token)
                }

                let key = parts[0].lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    return .text(token)
                }

                switch key {
                case "protocol", "proto":
                    return .protocolName(value)
                case "ip", "addr", "endpoint", "host":
                    return .endpoint(value)
                case "port":
                    return UInt16(value).map(Token.port) ?? .text(token)
                case "error", "status", "decode":
                    return statusToken(value) ?? .text(token)
                default:
                    return .text(token)
                }
            }
    }

    private static func statusToken(_ value: String) -> Token? {
        switch value.lowercased() {
        case "partial":
            .status(.partial)
        case "malformed", "error":
            .status(.malformed)
        case "unsupported":
            .status(.unsupported)
        case "truncated":
            .status(.truncated)
        default:
            nil
        }
    }

    private func searchableText(for packet: PacketSummary) -> String {
        [
            "\(packet.packetNumber)",
            NetworkInspectorFormatters.protocolLabel(for: packet),
            endpointText(for: packet),
            packet.sniDomainName ?? "",
            clientText(for: packet),
            "\(packet.capturedLength)",
            packet.infoSummary,
            packet.layers.map(\.name).joined(separator: " "),
            packet.decodeStatus.reason ?? "",
            packet.captureMetadata.interfaceName ?? "",
        ]
        .joined(separator: " ")
    }

    private func clientText(for packet: PacketSummary) -> String {
        guard let client = packet.client else {
            return ""
        }

        return [
            client.displayName,
            client.name,
            client.bundleIdentifier ?? "",
            client.bundlePath ?? "",
            client.executablePath ?? "",
        ]
        .joined(separator: " ")
    }

    private func endpointText(for packet: PacketSummary) -> String {
        [
            NetworkInspectorFormatters.endpointLabel(packet.endpoints.source),
            NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination),
        ]
        .joined(separator: " ")
    }
}

enum PacketTableUpdatePlan: Equatable, Sendable {
    case none
    case append(Range<Int>)
    case reload
    case reloadRows(IndexSet)
    case appendAndReloadRows(append: Range<Int>, reload: IndexSet)
}

enum PacketTableUpdatePlanner {
    static func plan(
        previousGeneration: UInt64,
        currentGeneration: UInt64,
        proposedPlan: PacketTableUpdatePlan
    ) -> PacketTableUpdatePlan {
        previousGeneration == currentGeneration ? .none : proposedPlan
    }
}

enum NetworkInspectorPlacement: String, Equatable {
    case trailing
}

struct NetworkInspectorSnapshot: Equatable {
    var base: TCPViewerWindowSnapshot
    var selectedSidebar: NetworkInspectorSidebarSelection
    var selectedSourceListSelection: PacketSourceListSelection
    var sourceListSnapshot: PacketSourceListSnapshot
    var sourceListFilterText: String
    var quickFilterItems: [PacketQuickFilterItem]
    var quickFilterSelection: PacketQuickFilterSelection
    var workspaceMode: NetworkInspectorWorkspaceMode
    var inspectorTab: PacketInspectorTab
    var inspectorPlacement: NetworkInspectorPlacement
    var isInspectorVisible: Bool
    var isStructuredFilterVisible: Bool
    var displayFilterText: String
    var displayFilter: PacketDisplayFilter
    var displayFilterChips: [PacketFilterChip]
    var structuredFilterGroup: PacketStructuredFilterGroup
    var isPacketTableFiltering: Bool
    var packetTableRowStore: PacketTableRowStore
    var packetTableGeneration: UInt64
    var packetTableUpdatePlan: PacketTableUpdatePlan
    var malformedPacketCount: Int
    var selectedPacket: PacketSummary?
    var selectedPacketRowIndex: Int?

    var packetRows: [PacketTableRow] { packetTableRowStore.rows }

    static func make(
        base: TCPViewerWindowSnapshot,
        selectedSidebar: NetworkInspectorSidebarSelection,
        selectedSourceListSelection: PacketSourceListSelection,
        sourceListSnapshot: PacketSourceListSnapshot,
        sourceListFilterText: String,
        quickFilterItems: [PacketQuickFilterItem] = PacketQuickFilterService().items(),
        quickFilterSelection: PacketQuickFilterSelection = .all,
        workspaceMode: NetworkInspectorWorkspaceMode,
        inspectorTab: PacketInspectorTab,
        inspectorPlacement: NetworkInspectorPlacement = .trailing,
        isInspectorVisible: Bool,
        isStructuredFilterVisible: Bool = false,
        displayFilterText: String,
        structuredFilterGroup: PacketStructuredFilterGroup = .default,
        isPacketTableFiltering: Bool = false,
        packetTableContent: PacketTableContent
    ) -> NetworkInspectorSnapshot {
        return NetworkInspectorSnapshot(
            base: base,
            selectedSidebar: selectedSidebar,
            selectedSourceListSelection: selectedSourceListSelection,
            sourceListSnapshot: sourceListSnapshot,
            sourceListFilterText: sourceListFilterText,
            quickFilterItems: quickFilterItems,
            quickFilterSelection: quickFilterSelection,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            inspectorPlacement: inspectorPlacement,
            isInspectorVisible: isInspectorVisible,
            isStructuredFilterVisible: isStructuredFilterVisible,
            displayFilterText: displayFilterText,
            displayFilter: packetTableContent.displayFilter,
            displayFilterChips: packetTableContent.displayFilterChips,
            structuredFilterGroup: structuredFilterGroup,
            isPacketTableFiltering: isPacketTableFiltering,
            packetTableRowStore: packetTableContent.store,
            packetTableGeneration: packetTableContent.generation,
            packetTableUpdatePlan: packetTableContent.updatePlan,
            malformedPacketCount: packetTableContent.malformedPacketCount,
            selectedPacket: packetTableContent.selectedRowIndex(id: base.selectedPacketID) == nil
                ? nil
                : base.packetIngestState.packet(withID: base.selectedPacketID),
            selectedPacketRowIndex: packetTableContent.selectedRowIndex(id: base.selectedPacketID)
        )
    }

    // Equatable uses generation as the proxy for content equality (it bumps on every visible row
    // change), avoiding an O(N) row-array walk. Identity comparison on the store would also work,
    // but generation is monotonic and survives in-place row mutations within the same store.
    static func == (lhs: NetworkInspectorSnapshot, rhs: NetworkInspectorSnapshot) -> Bool {
        lhs.base == rhs.base &&
            lhs.selectedSidebar == rhs.selectedSidebar &&
            lhs.selectedSourceListSelection == rhs.selectedSourceListSelection &&
            lhs.sourceListSnapshot == rhs.sourceListSnapshot &&
            lhs.sourceListFilterText == rhs.sourceListFilterText &&
            lhs.quickFilterItems == rhs.quickFilterItems &&
            lhs.quickFilterSelection == rhs.quickFilterSelection &&
            lhs.workspaceMode == rhs.workspaceMode &&
            lhs.inspectorTab == rhs.inspectorTab &&
            lhs.inspectorPlacement == rhs.inspectorPlacement &&
            lhs.isInspectorVisible == rhs.isInspectorVisible &&
            lhs.isStructuredFilterVisible == rhs.isStructuredFilterVisible &&
            lhs.displayFilterText == rhs.displayFilterText &&
            lhs.displayFilter == rhs.displayFilter &&
            lhs.displayFilterChips == rhs.displayFilterChips &&
            lhs.structuredFilterGroup == rhs.structuredFilterGroup &&
            lhs.isPacketTableFiltering == rhs.isPacketTableFiltering &&
            lhs.packetTableGeneration == rhs.packetTableGeneration &&
            lhs.packetTableUpdatePlan == rhs.packetTableUpdatePlan &&
            lhs.malformedPacketCount == rhs.malformedPacketCount &&
            lhs.selectedPacket?.id == rhs.selectedPacket?.id &&
            lhs.selectedPacketRowIndex == rhs.selectedPacketRowIndex
    }

    var selectedPacketID: PacketSummary.ID? {
        base.selectedPacketID
    }

    var visiblePacketCount: Int {
        packetTableRowStore.rows.count
    }

    var totalPacketCount: Int {
        base.packetIngestState.totalPacketCount
    }

    var isQuickFilterActive: Bool {
        quickFilterSelection.isActive
    }

    var isQuickFilterResetVisible: Bool {
        quickFilterSelection.isActive
    }

    var quickFilterAppliedDescription: String? {
        guard quickFilterSelection.isActive else {
            return nil
        }

        return "Filtered by \(quickFilterSelection.activeLabels.joined(separator: ", "))"
    }

    var droppedPacketCount: UInt64 {
        base.sessionState.health.packetsDropped + base.sessionState.health.packetsDroppedByInterface
    }

    var isCaptureLocked: Bool {
        base.sessionState.canPause ||
            base.sessionState.canResume ||
            base.sessionState.canStop
    }
}

// Class-backed storage for the table's row buffer so the content cache can append rows in place.
// A struct-only design forces an Array CoW on every batch (~5.9 % of CPU at 50k rows in profiling
// before this change) because the published snapshot keeps the rows array's buffer alive. Sharing
// a class reference end-to-end keeps the buffer uniquely-owned by this store and lets the cache
// mutate it without copying. Mutations only happen on the main thread, in the same runloop pass
// that issues the corresponding NSTableView update, so AppKit never observes a torn read.
final class PacketTableRowStore: @unchecked Sendable {
    var rows: [PacketTableRow] = []
    var visiblePacketRowIndexByID: [PacketSummary.ID: Int] = [:]

    static let empty = PacketTableRowStore()

    init(rows: [PacketTableRow] = [], visiblePacketRowIndexByID: [PacketSummary.ID: Int] = [:]) {
        self.rows = rows
        self.visiblePacketRowIndexByID = visiblePacketRowIndexByID
    }
}

struct PacketTableContent: Sendable {
    let displayFilter: PacketDisplayFilter
    let displayFilterChips: [PacketFilterChip]
    let store: PacketTableRowStore
    let generation: UInt64
    let updatePlan: PacketTableUpdatePlan
    let malformedPacketCount: Int

    var rows: [PacketTableRow] { store.rows }
    var visiblePacketRowIndexByID: [PacketSummary.ID: Int] { store.visiblePacketRowIndexByID }

    static let empty = PacketTableContent(
        displayFilter: PacketDisplayFilter(""),
        displayFilterChips: [],
        store: PacketTableRowStore.empty,
        generation: 0,
        updatePlan: .none,
        malformedPacketCount: 0
    )

    init(
        displayFilter: PacketDisplayFilter,
        displayFilterChips: [PacketFilterChip],
        store: PacketTableRowStore,
        generation: UInt64,
        updatePlan: PacketTableUpdatePlan,
        malformedPacketCount: Int
    ) {
        self.displayFilter = displayFilter
        self.displayFilterChips = displayFilterChips
        self.store = store
        self.generation = generation
        self.updatePlan = updatePlan
        self.malformedPacketCount = malformedPacketCount
    }

    func selectedRowIndex(id: PacketSummary.ID?) -> Int? {
        guard let id else {
            return nil
        }

        return store.visiblePacketRowIndexByID[id]
    }
}

enum NetworkInspectorFormatters {
    private static let packetTimeFormatterKey = "TCPViewer.NetworkInspectorFormatters.packetTimeFormatter"

    static func packetTimeString(_ date: Date) -> String {
        let threadDictionary = Thread.current.threadDictionary
        if let formatter = threadDictionary[packetTimeFormatterKey] as? DateFormatter {
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        threadDictionary[packetTimeFormatterKey] = formatter
        return formatter.string(from: date)
    }

    static func endpointLabel(_ endpoint: PacketEndpoint) -> String {
        guard let address = endpoint.address else {
            return "-"
        }

        guard let port = endpoint.port else {
            return address
        }

        return "\(address):\(port)"
    }

    static func portLabel(_ port: UInt16?) -> String {
        port.map(String.init) ?? "-"
    }

    static func directionLabel(_ direction: PacketDirection?) -> String {
        guard let direction else {
            return "-"
        }

        switch direction {
        case .inbound:
            return "Inbound"
        case .outbound:
            return "Outbound"
        case .local:
            return "Local"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }

    static func intervalLabel(from startDate: Date?, to endDate: Date) -> String {
        guard let startDate else {
            return "-"
        }

        let interval = endDate.timeIntervalSince(startDate)
        guard interval >= 0 else {
            return "-"
        }

        if interval < 1 {
            return "\(Int((interval * 1_000).rounded())) ms"
        }

        return String(format: "%.3f s", interval)
    }

    static func protocolLabel(for packet: PacketSummary) -> String {
        if let protocolSummary = packet.protocolSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !protocolSummary.isEmpty {
            return protocolSummary
        }

        if packet.transportHint == .tls {
            return packet.layers.reversed()
                .map(\.name)
                .first { name in
                    let uppercasedName = name.uppercased()
                    return uppercasedName.hasPrefix("TLS") || uppercasedName.hasPrefix("SSL")
                } ?? "TLS"
        }

        if packet.transportHint != .unknown {
            return packet.transportHint.rawValue.uppercased()
        }

        if let lastLayer = packet.layers.last?.name, !lastLayer.isEmpty {
            return lastLayer.uppercased()
        }

        return "UNKNOWN"
    }

    static func byteCount(_ bytes: Int) -> String {
        "\(bytes) B"
    }

    static func decodeStatusLabel(_ status: PacketDecodeStatus) -> String {
        switch status.kind {
        case .complete:
            return "Complete"
        case .partial:
            return "Partial"
        case .malformed:
            return "Malformed"
        case .unsupported:
            return "Unsupported"
        @unknown default:
            return "Unsupported"
        }
    }

    static func severity(for packet: PacketSummary) -> PacketSeverity {
        if packet.captureMetadata.isTruncated {
            return .truncated
        }

        switch packet.decodeStatus.kind {
        case .complete:
            return .normal
        case .partial:
            return .partial
        case .malformed:
            return .malformed
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    static func tags(for packet: PacketSummary) -> [PacketTag] {
        var tags: [PacketTag] = []

        if packet.captureMetadata.isTruncated {
            tags.append(PacketTag(label: "Truncated", severity: .truncated))
        }

        switch packet.decodeStatus.kind {
        case .complete:
            break
        case .partial:
            tags.append(PacketTag(label: "Partial", severity: .partial))
        case .malformed:
            tags.append(PacketTag(label: "Malformed", severity: .malformed))
        case .unsupported:
            tags.append(PacketTag(label: "Unsupported", severity: .unsupported))
        @unknown default:
            tags.append(PacketTag(label: "Unsupported", severity: .unsupported))
        }

        return tags
    }
}
