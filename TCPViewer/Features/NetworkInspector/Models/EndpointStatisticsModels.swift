//
//  EndpointStatisticsModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation

enum EndpointStatisticsGroup: String, CaseIterable, Hashable, Sendable {
    case apps
    case domains
    case ipv4
    case ipv6
    case tcp
    case udp

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .domains: return "Domains"
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        case .tcp: return "TCP"
        case .udp: return "UDP"
        }
    }
}

struct EndpointStatisticsRowID: Hashable, Sendable {
    let group: EndpointStatisticsGroup
    let key: String
}

struct EndpointStatisticsTotals: Equatable, Sendable {
    var packets: UInt64
    var bytes: UInt64
    var txPackets: UInt64
    var txBytes: UInt64
    var rxPackets: UInt64
    var rxBytes: UInt64
    var unclassifiedPackets: UInt64
    var unclassifiedBytes: UInt64

    static let zero = EndpointStatisticsTotals(
        packets: 0,
        bytes: 0,
        txPackets: 0,
        txBytes: 0,
        rxPackets: 0,
        rxBytes: 0,
        unclassifiedPackets: 0,
        unclassifiedBytes: 0
    )

    var summary: String {
        let classifiedBytes = Double(txBytes) + Double(rxBytes) + Double(unclassifiedBytes)
        guard classifiedBytes > 0 else {
            return "No byte data"
        }

        var parts: [String] = []
        if txBytes > 0 {
            parts.append("Tx \(percentage(txBytes, of: classifiedBytes))%")
        }
        if rxBytes > 0 {
            parts.append("Rx \(percentage(rxBytes, of: classifiedBytes))%")
        }
        if unclassifiedBytes > 0 {
            parts.append("Unclassified \(percentage(unclassifiedBytes, of: classifiedBytes))%")
        }
        return parts.joined(separator: " · ")
    }

    private func percentage(_ value: UInt64, of total: Double) -> Int {
        Int((Double(value) / Double(total) * 100).rounded())
    }
}

struct EndpointStatisticsRow: Identifiable, Equatable, Sendable {
    static let multipleValue = "Multiple"

    let id: EndpointStatisticsRowID
    let address: String?
    let port: String?
    let protocolName: String?
    let client: String?
    let domain: String?
    let isAddressMultiple: Bool
    let isPortMultiple: Bool
    let isProtocolMultiple: Bool
    let isClientMultiple: Bool
    let isDomainMultiple: Bool
    let packets: UInt64
    let bytes: UInt64
    let txPackets: UInt64
    let txBytes: UInt64
    let rxPackets: UInt64
    let rxBytes: UInt64
    let unclassifiedPackets: UInt64
    let unclassifiedBytes: UInt64

    init(
        id: EndpointStatisticsRowID,
        address: String?,
        port: String?,
        protocolName: String?,
        client: String?,
        domain: String?,
        isAddressMultiple: Bool = false,
        isPortMultiple: Bool = false,
        isProtocolMultiple: Bool = false,
        isClientMultiple: Bool = false,
        isDomainMultiple: Bool = false,
        packets: UInt64,
        bytes: UInt64,
        txPackets: UInt64,
        txBytes: UInt64,
        rxPackets: UInt64,
        rxBytes: UInt64,
        unclassifiedPackets: UInt64,
        unclassifiedBytes: UInt64
    ) {
        self.id = id
        self.address = address
        self.port = port
        self.protocolName = protocolName
        self.client = client
        self.domain = domain
        self.isAddressMultiple = isAddressMultiple
        self.isPortMultiple = isPortMultiple
        self.isProtocolMultiple = isProtocolMultiple
        self.isClientMultiple = isClientMultiple
        self.isDomainMultiple = isDomainMultiple
        self.packets = packets
        self.bytes = bytes
        self.txPackets = txPackets
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.rxBytes = rxBytes
        self.unclassifiedPackets = unclassifiedPackets
        self.unclassifiedBytes = unclassifiedBytes
    }

    var group: EndpointStatisticsGroup {
        id.group
    }

    var totals: EndpointStatisticsTotals {
        EndpointStatisticsTotals(
            packets: packets,
            bytes: bytes,
            txPackets: txPackets,
            txBytes: txBytes,
            rxPackets: rxPackets,
            rxBytes: rxBytes,
            unclassifiedPackets: unclassifiedPackets,
            unclassifiedBytes: unclassifiedBytes
        )
    }

    var summary: String {
        totals.summary
    }
}

struct EndpointStatisticsSnapshot: Equatable, Sendable {
    let rowsByGroup: [EndpointStatisticsGroup: [EndpointStatisticsRow]]
    let endpointCounts: [EndpointStatisticsGroup: Int]
    let footerTotals: EndpointStatisticsTotals

    static let empty = EndpointStatisticsSnapshot(rowsByGroup: [:], footerTotals: .zero)

    init(
        rowsByGroup: [EndpointStatisticsGroup: [EndpointStatisticsRow]],
        footerTotals: EndpointStatisticsTotals
    ) {
        var completeRows: [EndpointStatisticsGroup: [EndpointStatisticsRow]] = [:]
        var counts: [EndpointStatisticsGroup: Int] = [:]
        for group in EndpointStatisticsGroup.allCases {
            let rows = rowsByGroup[group] ?? []
            completeRows[group] = rows
            counts[group] = rows.count
        }
        self.rowsByGroup = completeRows
        endpointCounts = counts
        self.footerTotals = footerTotals
    }

    func rows(for group: EndpointStatisticsGroup) -> [EndpointStatisticsRow] {
        rowsByGroup[group] ?? []
    }

    func endpointCount(for group: EndpointStatisticsGroup) -> Int {
        endpointCounts[group] ?? 0
    }
}

struct EndpointStatisticsGroupSnapshot: Equatable, Sendable {
    let group: EndpointStatisticsGroup
    let rows: [EndpointStatisticsRow]
    let endpointCounts: [EndpointStatisticsGroup: Int]
    let footerTotals: EndpointStatisticsTotals

    func endpointCount(for group: EndpointStatisticsGroup) -> Int {
        endpointCounts[group] ?? 0
    }
}
