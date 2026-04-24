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

enum PacketInspectorTab: String, CaseIterable, Identifiable, Sendable, Hashable {
    case overview
    case layers
    case hex
    case stream
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .layers:
            "Layers"
        case .hex:
            "Hex"
        case .stream:
            "Stream"
        case .notes:
            "Notes"
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
    let packet: PacketSummary
    let numberText: String
    let timeText: String
    let sourceText: String
    let destinationText: String
    let domainText: String
    let clientText: String
    let protocolText: String
    let lengthText: String
    let summaryText: String
    let tags: [PacketTag]
    let severity: PacketSeverity

    init(packet: PacketSummary) {
        self.id = packet.id
        self.packet = packet
        self.numberText = "\(packet.packetNumber)"
        self.timeText = NetworkInspectorFormatters.packetTime.string(from: packet.timestamp)
        self.sourceText = NetworkInspectorFormatters.endpointLabel(packet.endpoints.source)
        self.destinationText = NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination)
        self.domainText = packet.sniDomainName ?? "-"
        self.clientText = packet.client?.displayName ?? "-"
        self.protocolText = NetworkInspectorFormatters.protocolLabel(for: packet)
        self.lengthText = NetworkInspectorFormatters.byteCount(packet.capturedLength)
        self.summaryText = packet.infoSummary
        self.tags = NetworkInspectorFormatters.tags(for: packet)
        self.severity = NetworkInspectorFormatters.severity(for: packet)
    }

    var tagText: String {
        tags.map(\.label).joined(separator: " | ")
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

struct NetworkInspectorSnapshot: Equatable {
    var base: PacketryWindowSnapshot
    var selectedSidebar: NetworkInspectorSidebarSelection
    var selectedSourceListSelection: PacketSourceListSelection
    var sourceListSnapshot: PacketSourceListSnapshot
    var sourceListFilterText: String
    var workspaceMode: NetworkInspectorWorkspaceMode
    var inspectorTab: PacketInspectorTab
    var isInspectorVisible: Bool
    var displayFilterText: String
    var displayFilter: PacketDisplayFilter
    var displayFilterChips: [PacketFilterChip]
    var packetRows: [PacketTableRow]
    var packetRowIDs: [PacketSummary.ID]
    var packetTableGeneration: UInt64
    var packetTableUpdatePlan: PacketTableUpdatePlan
    var malformedPacketCount: Int
    var selectedPacket: PacketSummary?
    var selectedPacketRowIndex: Int?

    static func make(
        base: PacketryWindowSnapshot,
        selectedSidebar: NetworkInspectorSidebarSelection,
        selectedSourceListSelection: PacketSourceListSelection,
        sourceListSnapshot: PacketSourceListSnapshot,
        sourceListFilterText: String,
        workspaceMode: NetworkInspectorWorkspaceMode,
        inspectorTab: PacketInspectorTab,
        isInspectorVisible: Bool,
        displayFilterText: String,
        packetTableContent: PacketTableContent
    ) -> NetworkInspectorSnapshot {
        return NetworkInspectorSnapshot(
            base: base,
            selectedSidebar: selectedSidebar,
            selectedSourceListSelection: selectedSourceListSelection,
            sourceListSnapshot: sourceListSnapshot,
            sourceListFilterText: sourceListFilterText,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            isInspectorVisible: isInspectorVisible,
            displayFilterText: displayFilterText,
            displayFilter: packetTableContent.displayFilter,
            displayFilterChips: packetTableContent.displayFilterChips,
            packetRows: packetTableContent.rows,
            packetRowIDs: packetTableContent.rowIDs,
            packetTableGeneration: packetTableContent.generation,
            packetTableUpdatePlan: packetTableContent.updatePlan,
            malformedPacketCount: packetTableContent.malformedPacketCount,
            selectedPacket: packetTableContent.selectedPacket(id: base.selectedPacketID),
            selectedPacketRowIndex: packetTableContent.selectedRowIndex(id: base.selectedPacketID)
        )
    }

    static func == (lhs: NetworkInspectorSnapshot, rhs: NetworkInspectorSnapshot) -> Bool {
        lhs.base == rhs.base &&
            lhs.selectedSidebar == rhs.selectedSidebar &&
            lhs.selectedSourceListSelection == rhs.selectedSourceListSelection &&
            lhs.sourceListSnapshot == rhs.sourceListSnapshot &&
            lhs.sourceListFilterText == rhs.sourceListFilterText &&
            lhs.workspaceMode == rhs.workspaceMode &&
            lhs.inspectorTab == rhs.inspectorTab &&
            lhs.isInspectorVisible == rhs.isInspectorVisible &&
            lhs.displayFilterText == rhs.displayFilterText &&
            lhs.displayFilter == rhs.displayFilter &&
            lhs.displayFilterChips == rhs.displayFilterChips &&
            lhs.packetRows.count == rhs.packetRows.count &&
            lhs.packetRows.first?.id == rhs.packetRows.first?.id &&
            lhs.packetRows.last?.id == rhs.packetRows.last?.id &&
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
        packetRows.count
    }

    var totalPacketCount: Int {
        base.packetIngestState.totalPacketCount
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

struct PacketTableContent: Sendable {
    let displayFilter: PacketDisplayFilter
    let displayFilterChips: [PacketFilterChip]
    let rows: [PacketTableRow]
    let rowIDs: [PacketSummary.ID]
    let generation: UInt64
    let updatePlan: PacketTableUpdatePlan
    let malformedPacketCount: Int
    let visiblePacketsByID: [PacketSummary.ID: PacketSummary]
    let visiblePacketRowIndexByID: [PacketSummary.ID: Int]

    static let empty = PacketTableContent(
        displayFilter: PacketDisplayFilter(""),
        displayFilterChips: [],
        rows: [],
        rowIDs: [],
        generation: 0,
        updatePlan: .none,
        malformedPacketCount: 0,
        visiblePacketsByID: [:],
        visiblePacketRowIndexByID: [:]
    )

    init(
        displayFilter: PacketDisplayFilter,
        displayFilterChips: [PacketFilterChip],
        rows: [PacketTableRow],
        rowIDs: [PacketSummary.ID],
        generation: UInt64,
        updatePlan: PacketTableUpdatePlan,
        malformedPacketCount: Int,
        visiblePacketsByID: [PacketSummary.ID: PacketSummary],
        visiblePacketRowIndexByID: [PacketSummary.ID: Int]
    ) {
        self.displayFilter = displayFilter
        self.displayFilterChips = displayFilterChips
        self.rows = rows
        self.rowIDs = rowIDs
        self.generation = generation
        self.updatePlan = updatePlan
        self.malformedPacketCount = malformedPacketCount
        self.visiblePacketsByID = visiblePacketsByID
        self.visiblePacketRowIndexByID = visiblePacketRowIndexByID
    }

    func selectedPacket(id: PacketSummary.ID?) -> PacketSummary? {
        guard let id else {
            return nil
        }

        return visiblePacketsByID[id]
    }

    func selectedRowIndex(id: PacketSummary.ID?) -> Int? {
        guard let id else {
            return nil
        }

        return visiblePacketRowIndexByID[id]
    }
}

enum NetworkInspectorFormatters {
    static let packetTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func endpointLabel(_ endpoint: PacketEndpoint) -> String {
        guard let address = endpoint.address else {
            return "-"
        }

        guard let port = endpoint.port else {
            return address
        }

        return "\(address):\(port)"
    }

    static func protocolLabel(for packet: PacketSummary) -> String {
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
