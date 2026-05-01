//
//  PacketQuickFilterModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/5/26.
//

import Foundation
import PcapPlusPlusCore

enum PacketQuickFilterID: String, CaseIterable, Identifiable, Sendable, Hashable {
    case all
    case tcp
    case udp
    case dns
    case http
    case tls
    case websocket
    case clientHello
    case serverHello
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .tcp:
            "TCP"
        case .udp:
            "UDP"
        case .dns:
            "DNS"
        case .http:
            "HTTP"
        case .tls:
            "TLS"
        case .websocket:
            "WebSocket"
        case .clientHello:
            "Client Hello"
        case .serverHello:
            "Server Hello"
        case .errors:
            "Errors"
        }
    }
}

struct PacketQuickFilterItem: Identifiable, Equatable, Sendable {
    let id: PacketQuickFilterID
    let title: String
    let isSelected: Bool
}

struct PacketQuickFilterSelection: Equatable, Sendable, Hashable {
    let selectedIDs: Set<PacketQuickFilterID>

    static let all = PacketQuickFilterSelection(selectedIDs: [.all])

    init(selectedIDs: Set<PacketQuickFilterID> = [.all]) {
        let activeIDs = selectedIDs.subtracting([.all])
        self.selectedIDs = activeIDs.isEmpty ? [.all] : activeIDs
    }

    var activeIDs: [PacketQuickFilterID] {
        PacketQuickFilterID.allCases.filter { $0 != .all && selectedIDs.contains($0) }
    }

    var activeLabels: [String] {
        activeIDs.map(\.title)
    }

    var isActive: Bool {
        !activeIDs.isEmpty
    }

    func contains(_ id: PacketQuickFilterID) -> Bool {
        selectedIDs.contains(id)
    }

    func toggled(_ id: PacketQuickFilterID) -> PacketQuickFilterSelection {
        guard id != .all else {
            return .all
        }

        var nextIDs = Set(activeIDs)
        if nextIDs.contains(id) {
            nextIDs.remove(id)
        } else {
            nextIDs.insert(id)
        }
        return PacketQuickFilterSelection(selectedIDs: nextIDs)
    }
}

final class PacketQuickFilterService {
    private(set) var selection: PacketQuickFilterSelection

    init(selection: PacketQuickFilterSelection = .all) {
        self.selection = selection
    }

    func items(for selection: PacketQuickFilterSelection? = nil) -> [PacketQuickFilterItem] {
        let selection = selection ?? self.selection
        return PacketQuickFilterID.allCases.map { id in
            PacketQuickFilterItem(id: id, title: id.title, isSelected: selection.contains(id))
        }
    }

    @discardableResult
    func toggle(_ id: PacketQuickFilterID) -> PacketQuickFilterSelection {
        selection = selection.toggled(id)
        return selection
    }

    @discardableResult
    func reset() -> PacketQuickFilterSelection {
        selection = .all
        return selection
    }

    func matches(_ packet: PacketSummary, selection: PacketQuickFilterSelection? = nil) -> Bool {
        let selection = selection ?? self.selection
        guard selection.isActive else {
            return true
        }

        // Quick filters are OR-ed, so a packet can match any active filter chip.
        return selection.activeIDs.contains { matches(packet, filterID: $0) }
    }

    private func matches(_ packet: PacketSummary, filterID: PacketQuickFilterID) -> Bool {
        switch filterID {
        case .all:
            return true
        case .tcp:
            return matchesTransport(packet, transportName: "TCP", transportHint: .tcp) ||
                [.http1, .tls, .websocket].contains(packet.transportHint)
        case .udp:
            return matchesTransport(packet, transportName: "UDP", transportHint: .udp)
        case .dns:
            return matchesProtocol(packet, hints: [.dns], names: ["DNS"])
        case .http:
            return matchesProtocol(packet, hints: [.http1], names: ["HTTP", "HTTP1"])
        case .tls:
            return matchesProtocol(packet, hints: [.tls], names: ["TLS", "SSL", "HTTPS"])
        case .websocket:
            return matchesProtocol(packet, hints: [.websocket], names: ["WEBSOCKET"])
        case .clientHello:
            return containsPacketSummaryText(packet, phrase: "Client Hello")
        case .serverHello:
            return containsPacketSummaryText(packet, phrase: "Server Hello")
        case .errors:
            return NetworkInspectorFormatters.severity(for: packet) != .normal
        }
    }

    private func matchesTransport(
        _ packet: PacketSummary,
        transportName: String,
        transportHint: TransportProtocolHint
    ) -> Bool {
        packet.transportHint == transportHint || packet.layers.contains { layer in
            layer.name.localizedCaseInsensitiveCompare(transportName) == .orderedSame
        }
    }

    private func matchesProtocol(
        _ packet: PacketSummary,
        hints: Set<TransportProtocolHint>,
        names: Set<String>
    ) -> Bool {
        if hints.contains(packet.transportHint) {
            return true
        }

        // Protocol filters match both normalized summary text and decoded layer names.
        return protocolSearchValues(for: packet).contains { value in
            let normalizedValue = value.uppercased()
            return names.contains { name in
                normalizedValue == name || normalizedValue.hasPrefix("\(name) ") || normalizedValue.hasPrefix("\(name)/")
            }
        }
    }

    private func containsPacketSummaryText(_ packet: PacketSummary, phrase: String) -> Bool {
        [
            packet.protocolSummary ?? "",
            packet.infoSummary,
            packet.layers.map(\.name).joined(separator: " "),
            packet.layers.compactMap(\.detailSummary).joined(separator: " "),
        ]
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(phrase)
    }

    private func protocolSearchValues(for packet: PacketSummary) -> [String] {
        [
            NetworkInspectorFormatters.protocolLabel(for: packet),
            packet.transportHint.rawValue,
            packet.protocolSummary ?? "",
        ] + packet.layers.flatMap { layer in
            [layer.name, layer.detailSummary ?? ""]
        }
    }
}
