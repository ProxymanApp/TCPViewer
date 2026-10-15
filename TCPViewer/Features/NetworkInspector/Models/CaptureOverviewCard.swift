//
//  CaptureOverviewCard.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Foundation

// A chart card on the Overview grid. Users show or hide cards from the "+" cell.
enum CaptureOverviewCard: String, CaseIterable, Identifiable, Sendable {
    case packets
    case throughput
    case protocols
    case topApps
    case topDestinations
    case tcpAnalysis
    case conversations
    case services
    case packetLengths

    // The cards of a new Overview; the others wait in the "+" picker.
    static let defaults: [CaptureOverviewCard] = [
        .packets,
        .throughput,
        .protocols,
        .topApps,
        .topDestinations,
        .tcpAnalysis,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .packets: "Packets"
        case .throughput: "Throughput"
        case .protocols: "Protocols"
        case .topApps: "Top Apps"
        case .topDestinations: "Top Domains & IPs"
        case .tcpAnalysis: "TCP Analysis"
        case .conversations: "Top Conversations"
        case .services: "Services & Ports"
        case .packetLengths: "Packet Lengths"
        }
    }

    // What the card answers, shown in the "+" picker.
    var summary: String {
        switch self {
        case .packets: "Packets over time with TCP problems highlighted, like Wireshark's I/O Graph."
        case .throughput: "Bytes sent and received per second, and the peak rate."
        case .protocols: "Share of traffic by the protocol shown in the packet table."
        case .topApps: "The apps that send and receive the most data."
        case .topDestinations: "The domains and IP addresses with the most traffic."
        case .tcpAnalysis: "Retransmissions, duplicate ACKs, lost segments, zero windows and resets."
        case .conversations: "The busiest TCP and UDP conversations between two endpoints."
        case .services: "Traffic by service port: HTTPS, QUIC, DNS, SSH and more."
        case .packetLengths: "How many packets fall in each size range."
        }
    }

    var symbolName: String {
        switch self {
        case .packets: "chart.bar.fill"
        case .throughput: "speedometer"
        case .protocols: "chart.pie.fill"
        case .topApps: "square.grid.2x2.fill"
        case .topDestinations: "globe"
        case .tcpAnalysis: "stethoscope"
        case .conversations: "arrow.left.arrow.right"
        case .services: "number"
        case .packetLengths: "ruler.fill"
        }
    }
}

// Persists the visible cards by name, so every window and capture shows the same Overview.
final class CaptureOverviewCardLayoutStore {
    static let storageKey = "TCPViewer.overview.cards"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Unknown or duplicate names, e.g. from a newer version, are skipped.
    var cards: [CaptureOverviewCard] {
        guard let names = defaults.stringArray(forKey: Self.storageKey) else {
            return CaptureOverviewCard.defaults
        }
        var cards: [CaptureOverviewCard] = []
        for name in names {
            if let card = CaptureOverviewCard(rawValue: name), !cards.contains(card) {
                cards.append(card)
            }
        }
        return cards
    }

    // Hide a visible card, or append a hidden one at the end of the grid.
    @discardableResult
    func toggle(_ card: CaptureOverviewCard) -> [CaptureOverviewCard] {
        var cards = cards
        if let index = cards.firstIndex(of: card) {
            cards.remove(at: index)
        } else {
            cards.append(card)
        }
        defaults.set(cards.map(\.rawValue), forKey: Self.storageKey)
        return cards
    }

    func restoreDefaults() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
