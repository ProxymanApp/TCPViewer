//
//  CaptureOverviewService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import Foundation
import PcapPlusPlusCore

struct CaptureOverviewTrafficTotals: Equatable, Sendable {
    var packets: UInt64 = 0
    var bytes: UInt64 = 0
    var sentPackets: UInt64 = 0
    var sentBytes: UInt64 = 0
    var receivedPackets: UInt64 = 0
    var receivedBytes: UInt64 = 0
    var unclassifiedPackets: UInt64 = 0
    var unclassifiedBytes: UInt64 = 0
    var issuePackets: UInt64 = 0

    var isEmpty: Bool {
        packets == 0
    }

    mutating func add(_ value: CaptureOverviewTrafficTotals) {
        packets += value.packets
        bytes += value.bytes
        sentPackets += value.sentPackets
        sentBytes += value.sentBytes
        receivedPackets += value.receivedPackets
        receivedBytes += value.receivedBytes
        unclassifiedPackets += value.unclassifiedPackets
        unclassifiedBytes += value.unclassifiedBytes
        issuePackets += value.issuePackets
    }

    mutating func remove(_ value: CaptureOverviewTrafficTotals) {
        packets -= value.packets
        bytes -= value.bytes
        sentPackets -= value.sentPackets
        sentBytes -= value.sentBytes
        receivedPackets -= value.receivedPackets
        receivedBytes -= value.receivedBytes
        unclassifiedPackets -= value.unclassifiedPackets
        unclassifiedBytes -= value.unclassifiedBytes
        issuePackets -= value.issuePackets
    }
}

struct CaptureOverviewTopRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let iconFilePath: String?
    let selection: PacketSourceListSelection
    let totals: CaptureOverviewTrafficTotals
}

struct CaptureOverviewProtocolRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let totals: CaptureOverviewTrafficTotals
}

struct CaptureOverviewTimelinePoint: Equatable, Sendable {
    let date: Date
    let totals: CaptureOverviewTrafficTotals
}

struct CaptureOverviewTCPIssueRow: Identifiable, Equatable, Sendable {
    let kind: CaptureOverviewTCPIssueKind
    let packets: UInt64

    var id: Int { kind.rawValue }
}

struct CaptureOverviewServiceRow: Identifiable, Equatable, Sendable {
    let key: CaptureOverviewServiceKey
    let totals: CaptureOverviewTrafficTotals

    var id: CaptureOverviewServiceKey { key }
}

struct CaptureOverviewConversationRow: Identifiable, Equatable, Sendable {
    let key: CaptureOverviewConversationKey
    let domainName: String?
    let appName: String?
    let appIconFilePath: String?
    let totals: CaptureOverviewTrafficTotals

    var id: CaptureOverviewConversationKey { key }
}

struct CaptureOverviewSnapshot: Equatable, Sendable {
    let totals: CaptureOverviewTrafficTotals
    let firstPacketDate: Date?
    let lastPacketDate: Date?
    let appCount: Int
    let domainCount: Int
    let malformedPacketCount: UInt64
    let tcpPacketCount: UInt64
    let topApps: [CaptureOverviewTopRow]
    let topDestinations: [CaptureOverviewTopRow]
    let protocols: [CaptureOverviewProtocolRow]
    let tcpIssues: [CaptureOverviewTCPIssueRow]
    let topServices: [CaptureOverviewServiceRow]
    let topConversations: [CaptureOverviewConversationRow]
    let packetLengthCounts: [UInt64]
    let timeline: [CaptureOverviewTimelinePoint]
    let timelineInterval: TimeInterval

    static let empty = CaptureOverviewSnapshot(
        totals: CaptureOverviewTrafficTotals(),
        firstPacketDate: nil,
        lastPacketDate: nil,
        appCount: 0,
        domainCount: 0,
        malformedPacketCount: 0,
        tcpPacketCount: 0,
        topApps: [],
        topDestinations: [],
        protocols: [],
        tcpIssues: [],
        topServices: [],
        topConversations: [],
        packetLengthCounts: Array(repeating: 0, count: CaptureOverviewClassifier.packetLengthBucketCount),
        timeline: [],
        timelineInterval: 1
    )

}

private struct CaptureOverviewContribution: Equatable {
    let packetID: PacketSummary.ID
    let timestamp: Date
    let app: PacketSourceClientIdentity?
    let domain: PacketSourceDomainIdentity?
    let ipAddresses: [PacketSourceIPAddressIdentity]
    let protocolName: String
    let totals: CaptureOverviewTrafficTotals
    let isMalformed: Bool
    let isTCP: Bool
    let tcpIssue: CaptureOverviewTCPIssueKind?
    let service: CaptureOverviewServiceKey?
    let conversation: CaptureOverviewConversationKey?
    let packetLengthBucket: Int
}

private struct CaptureOverviewConversationBucket {
    var domainName: String?
    var app: PacketSourceClientIdentity?
    var totals = CaptureOverviewTrafficTotals()
}

private struct CaptureOverviewAppBucket {
    var identity: PacketSourceClientIdentity
    var totals = CaptureOverviewTrafficTotals()
}

private struct CaptureOverviewDomainBucket {
    var identity: PacketSourceDomainIdentity
    var totals = CaptureOverviewTrafficTotals()
}

private struct CaptureOverviewIPAddressBucket {
    var identity: PacketSourceIPAddressIdentity
    var totals = CaptureOverviewTrafficTotals()
}

private struct CaptureOverviewProtocolBucket {
    let title: String
    var totals = CaptureOverviewTrafficTotals()
}

private struct CaptureOverviewSourceIdentity: Equatable {
    let backingIdentity: String?
    let packetLineageRevision: UInt64
}

struct CaptureOverviewAccumulator {
    static let maximumTimelineBucketCount = 1_024
    static let maximumRenderedTimelinePointCount = 60
    static let maximumTopRowCount = 10
    static let maximumProtocolRowCount = 5
    // Each storage width divides the next one, so compaction always merges whole buckets.
    static let timelineStorageWidths: [TimeInterval] = [
        1, 2, 10, 30, 60, 300, 600, 1_800, 3_600, 7_200, 21_600, 43_200, 86_400,
    ]
    // Round chart steps; a step is used only when it is a multiple of the storage width.
    static let timelineRenderWidths: [TimeInterval] = [
        1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400,
    ]

    private var contributionsByPacketID: [PacketSummary.ID: CaptureOverviewContribution] = [:]
    private var appBuckets: [PacketSourceClientKey: CaptureOverviewAppBucket] = [:]
    private var domainBuckets: [PacketSourceDomainKey: CaptureOverviewDomainBucket] = [:]
    private var ipAddressBuckets: [PacketSourceIPAddressKey: CaptureOverviewIPAddressBucket] = [:]
    private var protocolBuckets: [String: CaptureOverviewProtocolBucket] = [:]
    private var serviceBuckets: [CaptureOverviewServiceKey: CaptureOverviewTrafficTotals] = [:]
    private var conversationBuckets: [CaptureOverviewConversationKey: CaptureOverviewConversationBucket] = [:]
    private var tcpIssueCounts = Array(repeating: UInt64(0), count: CaptureOverviewTCPIssueKind.allCases.count)
    private var packetLengthCounts = Array(repeating: UInt64(0), count: CaptureOverviewClassifier.packetLengthBucketCount)
    private var timelineBuckets: [Int64: CaptureOverviewTrafficTotals] = [:]
    private var timelineBucketWidth: TimeInterval = 1
    private var totals = CaptureOverviewTrafficTotals()
    private var malformedPacketCount: UInt64 = 0
    private var tcpPacketCount: UInt64 = 0
    private var firstPacketDate: Date?
    private var lastPacketDate: Date?
    private var cursor: EndpointStatisticsIngestCursor?

    mutating func reset() {
        contributionsByPacketID.removeAll(keepingCapacity: false)
        appBuckets.removeAll(keepingCapacity: false)
        domainBuckets.removeAll(keepingCapacity: false)
        ipAddressBuckets.removeAll(keepingCapacity: false)
        protocolBuckets.removeAll(keepingCapacity: false)
        serviceBuckets.removeAll(keepingCapacity: false)
        conversationBuckets.removeAll(keepingCapacity: false)
        tcpIssueCounts = Array(repeating: 0, count: CaptureOverviewTCPIssueKind.allCases.count)
        packetLengthCounts = Array(repeating: 0, count: CaptureOverviewClassifier.packetLengthBucketCount)
        timelineBuckets.removeAll(keepingCapacity: false)
        timelineBucketWidth = 1
        totals = CaptureOverviewTrafficTotals()
        malformedPacketCount = 0
        tcpPacketCount = 0
        firstPacketDate = nil
        lastPacketDate = nil
        cursor = nil
    }

    mutating func appendReplacementChunk(_ packets: [PacketSummary]) {
        for packet in packets {
            replaceContribution(for: packet)
        }
    }

    mutating func finishReplacement(cursor: EndpointStatisticsIngestCursor) -> Bool {
        guard contributionsByPacketID.count == cursor.totalPacketCount else {
            return false
        }
        self.cursor = cursor
        return true
    }

    // Apply exact revisions so a dropped live mutation requests a fresh chunked replacement.
    mutating func consume(_ update: EndpointStatisticsIngestUpdate) -> Bool {
        guard let cursor,
              cursor.packetLineageRevision == update.packetLineageRevision,
              update.previousPacketRevision == cursor.packetRevision else {
            return false
        }

        switch update.kind {
        case .replace:
            return false
        case .append(let packets):
            guard contributionsByPacketID.count + packets.count == update.totalPacketCount else {
                return false
            }
            for packet in packets {
                replaceContribution(for: packet)
            }
        case .appendWithMetadata(let newPackets, let updatedPackets):
            guard contributionsByPacketID.count + newPackets.count == update.totalPacketCount else {
                return false
            }
            for packet in newPackets {
                replaceContribution(for: packet)
            }
            for packet in updatedPackets {
                replaceContribution(for: packet)
            }
        case .metadata(let packets):
            guard contributionsByPacketID.count == update.totalPacketCount else {
                return false
            }
            for packet in packets {
                replaceContribution(for: packet)
            }
        }
        self.cursor = update.cursor
        return true
    }

    mutating func applyMetadata(_ packets: [PacketSummary]) {
        for packet in packets {
            replaceContribution(for: packet)
        }
    }

    // The Overview charts use 60 slots; automation callers may ask for a finer timeline.
    func snapshot(maximumTimelinePointCount: Int = maximumRenderedTimelinePointCount) -> CaptureOverviewSnapshot {
        let timeline = timelinePoints(maximumCount: max(2, maximumTimelinePointCount))
        return CaptureOverviewSnapshot(
            totals: totals,
            firstPacketDate: firstPacketDate,
            lastPacketDate: lastPacketDate,
            appCount: appBuckets.count,
            domainCount: domainBuckets.count,
            malformedPacketCount: malformedPacketCount,
            tcpPacketCount: tcpPacketCount,
            topApps: topAppRows(),
            topDestinations: topDestinationRows(),
            protocols: protocolRows(),
            tcpIssues: tcpIssueRows(),
            topServices: topServiceRows(),
            topConversations: topConversationRows(),
            packetLengthCounts: packetLengthCounts,
            timeline: timeline.points,
            timelineInterval: timeline.interval
        )
    }

    private mutating func replaceContribution(for packet: PacketSummary) {
        if let oldContribution = contributionsByPacketID[packet.id] {
            remove(oldContribution)
        }
        let contribution = Self.contribution(for: packet)
        contributionsByPacketID[packet.id] = contribution
        add(contribution)
    }

    private mutating func add(_ contribution: CaptureOverviewContribution) {
        totals.add(contribution.totals)
        if contribution.isMalformed {
            malformedPacketCount += 1
        }
        if contribution.isTCP {
            tcpPacketCount += 1
        }
        if let tcpIssue = contribution.tcpIssue {
            tcpIssueCounts[tcpIssue.rawValue] += 1
        }
        packetLengthCounts[contribution.packetLengthBucket] += 1
        if let app = contribution.app {
            var bucket = appBuckets[app.key] ?? CaptureOverviewAppBucket(identity: app)
            bucket.identity = app
            bucket.totals.add(contribution.totals)
            appBuckets[app.key] = bucket
        }
        if let domain = contribution.domain, !domain.key.isMissingDomain {
            var bucket = domainBuckets[domain.key] ?? CaptureOverviewDomainBucket(identity: domain)
            bucket.identity = domain
            bucket.totals.add(contribution.totals)
            domainBuckets[domain.key] = bucket
        }
        for ipAddress in contribution.ipAddresses {
            var bucket = ipAddressBuckets[ipAddress.key] ?? CaptureOverviewIPAddressBucket(identity: ipAddress)
            bucket.identity = ipAddress
            bucket.totals.add(contribution.totals)
            ipAddressBuckets[ipAddress.key] = bucket
        }
        var protocolBucket = protocolBuckets[contribution.protocolName]
            ?? CaptureOverviewProtocolBucket(title: contribution.protocolName)
        protocolBucket.totals.add(contribution.totals)
        protocolBuckets[contribution.protocolName] = protocolBucket
        if let service = contribution.service {
            serviceBuckets[service, default: CaptureOverviewTrafficTotals()].add(contribution.totals)
        }
        if let conversation = contribution.conversation {
            // Keep the last known names: SNI and DNS names only arrive on some packets of a conversation.
            var bucket = conversationBuckets[conversation] ?? CaptureOverviewConversationBucket()
            if let domain = contribution.domain, !domain.key.isMissingDomain {
                bucket.domainName = domain.displayName
            }
            if let app = contribution.app {
                bucket.app = app
            }
            bucket.totals.add(contribution.totals)
            conversationBuckets[conversation] = bucket
        }

        let timelineKey = self.timelineKey(for: contribution.timestamp)
        timelineBuckets[timelineKey, default: CaptureOverviewTrafficTotals()].add(contribution.totals)
        firstPacketDate = min(firstPacketDate ?? contribution.timestamp, contribution.timestamp)
        lastPacketDate = max(lastPacketDate ?? contribution.timestamp, contribution.timestamp)
        compactTimelineIfNeeded()
    }

    private mutating func remove(_ contribution: CaptureOverviewContribution) {
        totals.remove(contribution.totals)
        if contribution.isMalformed {
            malformedPacketCount -= 1
        }
        if contribution.isTCP {
            tcpPacketCount -= 1
        }
        if let tcpIssue = contribution.tcpIssue {
            tcpIssueCounts[tcpIssue.rawValue] -= 1
        }
        packetLengthCounts[contribution.packetLengthBucket] -= 1
        if let app = contribution.app, var bucket = appBuckets[app.key] {
            bucket.totals.remove(contribution.totals)
            if bucket.totals.isEmpty {
                appBuckets.removeValue(forKey: app.key)
            } else {
                appBuckets[app.key] = bucket
            }
        }
        if let domain = contribution.domain,
           !domain.key.isMissingDomain,
           var bucket = domainBuckets[domain.key] {
            bucket.totals.remove(contribution.totals)
            if bucket.totals.isEmpty {
                domainBuckets.removeValue(forKey: domain.key)
            } else {
                domainBuckets[domain.key] = bucket
            }
        }
        for ipAddress in contribution.ipAddresses {
            guard var bucket = ipAddressBuckets[ipAddress.key] else {
                continue
            }
            bucket.totals.remove(contribution.totals)
            if bucket.totals.isEmpty {
                ipAddressBuckets.removeValue(forKey: ipAddress.key)
            } else {
                ipAddressBuckets[ipAddress.key] = bucket
            }
        }
        if var bucket = protocolBuckets[contribution.protocolName] {
            bucket.totals.remove(contribution.totals)
            if bucket.totals.isEmpty {
                protocolBuckets.removeValue(forKey: contribution.protocolName)
            } else {
                protocolBuckets[contribution.protocolName] = bucket
            }
        }
        if let service = contribution.service, var bucket = serviceBuckets[service] {
            bucket.remove(contribution.totals)
            serviceBuckets[service] = bucket.isEmpty ? nil : bucket
        }
        if let conversation = contribution.conversation, var bucket = conversationBuckets[conversation] {
            bucket.totals.remove(contribution.totals)
            conversationBuckets[conversation] = bucket.totals.isEmpty ? nil : bucket
        }

        let timelineKey = self.timelineKey(for: contribution.timestamp)
        if var bucket = timelineBuckets[timelineKey] {
            bucket.remove(contribution.totals)
            if bucket.isEmpty {
                timelineBuckets.removeValue(forKey: timelineKey)
            } else {
                timelineBuckets[timelineKey] = bucket
            }
        }
    }

    private static func contribution(for packet: PacketSummary) -> CaptureOverviewContribution {
        let isTCP = CaptureOverviewClassifier.isTCP(packet)
        let tcpIssue = CaptureOverviewClassifier.tcpIssue(for: packet, isTCP: isTCP)
        let length = max(0, packet.originalLength)
        var totals = trafficTotals(bytes: UInt64(length), direction: packet.direction)
        totals.issuePackets = tcpIssue == nil ? 0 : 1
        return CaptureOverviewContribution(
            packetID: packet.id,
            timestamp: packet.timestamp,
            app: PacketSourceListClassifier.clientIdentity(for: packet),
            domain: PacketSourceListClassifier.domainIdentity(for: packet),
            ipAddresses: PacketSourceListClassifier.ipAddressIdentities(for: packet),
            protocolName: NetworkInspectorFormatters.protocolLabel(for: packet),
            totals: totals,
            isMalformed: packet.decodeStatus.kind == .malformed,
            isTCP: isTCP,
            tcpIssue: tcpIssue,
            service: CaptureOverviewClassifier.serviceKey(for: packet, isTCP: isTCP),
            conversation: CaptureOverviewClassifier.conversationKey(for: packet, isTCP: isTCP),
            packetLengthBucket: CaptureOverviewClassifier.packetLengthBucket(for: length)
        )
    }

    private static func trafficTotals(bytes: UInt64, direction: PacketDirection?) -> CaptureOverviewTrafficTotals {
        var value = CaptureOverviewTrafficTotals(packets: 1, bytes: bytes)
        switch direction {
        case .outbound:
            value.sentPackets = 1
            value.sentBytes = bytes
        case .inbound:
            value.receivedPackets = 1
            value.receivedBytes = bytes
        case .local, .unknown, nil:
            value.unclassifiedPackets = 1
            value.unclassifiedBytes = bytes
        @unknown default:
            value.unclassifiedPackets = 1
            value.unclassifiedBytes = bytes
        }
        return value
    }

    private func topAppRows() -> [CaptureOverviewTopRow] {
        var result: [CaptureOverviewTopRow] = []
        result.reserveCapacity(Self.maximumTopRowCount)
        for bucket in appBuckets.values {
            Self.insertTopRow(CaptureOverviewTopRow(
                id: bucket.identity.key.rawValue,
                title: bucket.identity.displayName,
                iconFilePath: bucket.identity.iconFilePath,
                selection: .app(bucket.identity.key),
                totals: bucket.totals
            ), into: &result, precedes: Self.precedes)
        }
        return result
    }

    private func topDestinationRows() -> [CaptureOverviewTopRow] {
        var result: [CaptureOverviewTopRow] = []
        result.reserveCapacity(Self.maximumTopRowCount)
        for bucket in domainBuckets.values {
            Self.insertTopRow(CaptureOverviewTopRow(
                id: "domain:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                iconFilePath: nil,
                selection: .domain(bucket.identity.key),
                totals: bucket.totals
            ), into: &result, precedes: Self.precedes)
        }
        for bucket in ipAddressBuckets.values {
            Self.insertTopRow(CaptureOverviewTopRow(
                id: "ip:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                iconFilePath: nil,
                selection: .ipAddress(bucket.identity.key),
                totals: bucket.totals
            ), into: &result, precedes: Self.precedes)
        }
        return result
    }

    private func topServiceRows() -> [CaptureOverviewServiceRow] {
        var result: [CaptureOverviewServiceRow] = []
        result.reserveCapacity(Self.maximumTopRowCount)
        for (key, totals) in serviceBuckets {
            Self.insertTopRow(CaptureOverviewServiceRow(key: key, totals: totals), into: &result) { lhs, rhs in
                if lhs.totals.bytes != rhs.totals.bytes {
                    return lhs.totals.bytes > rhs.totals.bytes
                }
                if lhs.key.port != rhs.key.port {
                    return lhs.key.port < rhs.key.port
                }
                return lhs.key.transport.rawValue < rhs.key.transport.rawValue
            }
        }
        return result
    }

    private func topConversationRows() -> [CaptureOverviewConversationRow] {
        var result: [CaptureOverviewConversationRow] = []
        result.reserveCapacity(Self.maximumTopRowCount)
        for (key, bucket) in conversationBuckets {
            let row = CaptureOverviewConversationRow(
                key: key,
                domainName: bucket.domainName,
                appName: bucket.app?.displayName,
                appIconFilePath: bucket.app?.iconFilePath,
                totals: bucket.totals
            )
            Self.insertTopRow(row, into: &result) { lhs, rhs in
                if lhs.totals.bytes != rhs.totals.bytes {
                    return lhs.totals.bytes > rhs.totals.bytes
                }
                if lhs.totals.packets != rhs.totals.packets {
                    return lhs.totals.packets > rhs.totals.packets
                }
                return (lhs.key.serverAddress, lhs.key.serverPort, lhs.key.clientAddress, lhs.key.clientPort) <
                    (rhs.key.serverAddress, rhs.key.serverPort, rhs.key.clientAddress, rhs.key.clientPort)
            }
        }
        return result
    }

    private func tcpIssueRows() -> [CaptureOverviewTCPIssueRow] {
        CaptureOverviewTCPIssueKind.allCases.compactMap { kind in
            let packets = tcpIssueCounts[kind.rawValue]
            return packets > 0 ? CaptureOverviewTCPIssueRow(kind: kind, packets: packets) : nil
        }
    }

    // Keep only ten candidates while scanning so high-cardinality captures avoid a full sort.
    private static func insertTopRow<Row>(
        _ row: Row,
        into result: inout [Row],
        precedes: (Row, Row) -> Bool
    ) {
        let insertionIndex = result.firstIndex { precedes(row, $0) } ?? result.endIndex
        if insertionIndex < maximumTopRowCount {
            result.insert(row, at: insertionIndex)
            if result.count > maximumTopRowCount {
                result.removeLast()
            }
        } else if result.count < maximumTopRowCount {
            result.append(row)
        }
    }

    private static func precedes(_ lhs: CaptureOverviewTopRow, _ rhs: CaptureOverviewTopRow) -> Bool {
        if lhs.totals.bytes != rhs.totals.bytes {
            return lhs.totals.bytes > rhs.totals.bytes
        }
        if lhs.totals.packets != rhs.totals.packets {
            return lhs.totals.packets > rhs.totals.packets
        }
        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func protocolRows() -> [CaptureOverviewProtocolRow] {
        let sortedRows = protocolBuckets.values.map { bucket in
            CaptureOverviewProtocolRow(id: bucket.title, title: bucket.title, totals: bucket.totals)
        }.sorted { lhs, rhs in
            if lhs.totals.bytes != rhs.totals.bytes {
                return lhs.totals.bytes > rhs.totals.bytes
            }
            if lhs.totals.packets != rhs.totals.packets {
                return lhs.totals.packets > rhs.totals.packets
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        guard sortedRows.count > Self.maximumProtocolRowCount else {
            return sortedRows
        }
        var otherTotals = CaptureOverviewTrafficTotals()
        for row in sortedRows.dropFirst(Self.maximumProtocolRowCount) {
            otherTotals.add(row.totals)
        }
        return Array(sortedRows.prefix(Self.maximumProtocolRowCount)) + [
            CaptureOverviewProtocolRow(id: "__other__", title: "Other", totals: otherTotals),
        ]
    }

    private mutating func compactTimelineIfNeeded() {
        while timelineBuckets.count > Self.maximumTimelineBucketCount {
            let previousWidth = timelineBucketWidth
            timelineBucketWidth = Self.timelineStorageWidths.first { $0 > previousWidth } ?? previousWidth * 2
            let ratio = Int64((timelineBucketWidth / previousWidth).rounded())
            var merged: [Int64: CaptureOverviewTrafficTotals] = [:]
            merged.reserveCapacity(timelineBuckets.count / Int(ratio) + 1)
            for (key, value) in timelineBuckets {
                merged[Self.floorDivide(key, by: ratio), default: CaptureOverviewTrafficTotals()].add(value)
            }
            timelineBuckets = merged
        }
    }

    // Dense, round-width slots so bar charts keep their spacing and hover maps a pointer to one slot.
    private func timelinePoints(maximumCount: Int) -> (points: [CaptureOverviewTimelinePoint], interval: TimeInterval) {
        guard let minimumKey = timelineBuckets.keys.min(),
              let maximumKey = timelineBuckets.keys.max() else {
            return ([], 1)
        }
        let span = TimeInterval(maximumKey - minimumKey + 1) * timelineBucketWidth
        let interval = Self.renderedTimelineWidth(span: span, storageWidth: timelineBucketWidth, maximumCount: maximumCount)
        let ratio = Int64((interval / timelineBucketWidth).rounded())
        let firstKey = Self.floorDivide(minimumKey, by: ratio)
        let lastKey = Self.floorDivide(maximumKey, by: ratio)
        let count = Int(lastKey - firstKey) + 1

        var renderedTotals = Array(repeating: CaptureOverviewTrafficTotals(), count: count)
        for (key, value) in timelineBuckets {
            renderedTotals[Int(Self.floorDivide(key, by: ratio) - firstKey)].add(value)
        }
        let points = renderedTotals.enumerated().map { offset, totals in
            CaptureOverviewTimelinePoint(
                date: Date(timeIntervalSince1970: TimeInterval(firstKey + Int64(offset)) * interval),
                totals: totals
            )
        }
        return (points, interval)
    }

    static func renderedTimelineWidth(
        span: TimeInterval,
        storageWidth: TimeInterval,
        maximumCount: Int = maximumRenderedTimelinePointCount
    ) -> TimeInterval {
        // Keep one spare slot because the first slot starts at a round time before the first packet.
        let maximumSlots = TimeInterval(maximumCount - 1)
        let roundWidth = timelineRenderWidths.first { width in
            width >= storageWidth &&
                width.truncatingRemainder(dividingBy: storageWidth) == 0 &&
                span / width <= maximumSlots
        }
        return roundWidth ?? (span / maximumSlots / storageWidth).rounded(.up) * storageWidth
    }

    private static func floorDivide(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    private func timelineKey(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / timelineBucketWidth))
    }
}

private final class CaptureOverviewReplacementWork {
    static let chunkSize = 2_048
    static let maximumMetadataPacketCount = 10_000

    let identity: CaptureOverviewSourceIdentity
    var cursor: EndpointStatisticsIngestCursor
    var nextPacketIndex = 0
    var isChunkInFlight = false
    var isFinishing = false
    var updatedPacketsByID: [PacketSummary.ID: PacketSummary] = [:]

    init(ingestState: PacketIngestState) {
        identity = CaptureOverviewSourceIdentity(
            backingIdentity: ingestState.backingIdentity,
            packetLineageRevision: ingestState.packetLineageRevision
        )
        cursor = EndpointStatisticsIngestCursor(
            packetRevision: ingestState.packetRevision,
            packetLineageRevision: ingestState.packetLineageRevision,
            totalPacketCount: ingestState.packets.count
        )
    }

    var nextRange: Range<Int>? {
        guard nextPacketIndex < cursor.totalPacketCount else {
            return nil
        }
        return nextPacketIndex..<min(cursor.totalPacketCount, nextPacketIndex + Self.chunkSize)
    }

    func advance(to index: Int) {
        nextPacketIndex = index
    }

    // Extend an in-progress replacement across exact live deltas without retaining the source array.
    func update(from ingestState: PacketIngestState) -> Bool {
        guard !isFinishing,
              ingestState.backingIdentity == identity.backingIdentity,
              ingestState.packetLineageRevision == identity.packetLineageRevision,
              ingestState.packetRevision == cursor.packetRevision &+ 1 else {
            return false
        }

        switch ingestState.lastMutation {
        case .append(let range):
            guard range.lowerBound == cursor.totalPacketCount,
                  range.upperBound == ingestState.packets.count else {
                return false
            }
        case .appendWithMetadataUpdates(let range, let packetIDs):
            guard range.lowerBound == cursor.totalPacketCount,
                  range.upperBound == ingestState.packets.count,
                  recordMetadata(packetIDs, from: ingestState) else {
                return false
            }
        case .metadataUpdate(let packetIDs):
            guard ingestState.packets.count == cursor.totalPacketCount,
                  recordMetadata(packetIDs, from: ingestState) else {
                return false
            }
        case .none, .reset, .replace:
            return false
        }
        cursor = EndpointStatisticsIngestCursor(
            packetRevision: ingestState.packetRevision,
            packetLineageRevision: ingestState.packetLineageRevision,
            totalPacketCount: ingestState.packets.count
        )
        return true
    }

    private func recordMetadata(_ packetIDs: [PacketSummary.ID], from ingestState: PacketIngestState) -> Bool {
        guard packetIDs.count <= Self.maximumMetadataPacketCount - updatedPacketsByID.count else {
            return false
        }
        for packetID in packetIDs {
            guard let packet = ingestState.packet(withID: packetID) else {
                continue
            }
            updatedPacketsByID[packetID] = packet
        }
        return updatedPacketsByID.count <= Self.maximumMetadataPacketCount
    }
}

final class CaptureOverviewService {
    static let presentationInterval: TimeInterval = 0.5

    var snapshotHandler: ((CaptureOverviewSnapshot) -> Void)?

    private let latestIngestStateProvider: () -> PacketIngestState
    private let processingQueue = DispatchQueue(
        label: "com.proxyman.tcpviewer.capture-overview",
        qos: .userInitiated
    )
    private var accumulator = CaptureOverviewAccumulator()
    private var updateCoordinator = EndpointStatisticsUpdateDrainCoordinator(maximumPendingPacketCount: 10_000)
    private var latestObservedCursor: EndpointStatisticsIngestCursor?
    private var latestObservedIdentity: CaptureOverviewSourceIdentity?
    private var forwardedCursor: EndpointStatisticsIngestCursor?
    private var forwardedIdentity: CaptureOverviewSourceIdentity?
    private var replacementWork: CaptureOverviewReplacementWork?
    private var processingGeneration: UInt64 = 0
    private var presentationWorkItem: DispatchWorkItem?
    private var lastPresentationTime: TimeInterval = 0
    private var isCancelled = false

    init(latestIngestStateProvider: @escaping () -> PacketIngestState) {
        self.latestIngestStateProvider = latestIngestStateProvider
    }

    deinit {
        cancel()
    }

    // Convert live state to owned deltas on main, then aggregate them on one bounded queue.
    func consume(_ ingestState: PacketIngestState) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCancelled else {
            return
        }
        let nextCursor = EndpointStatisticsIngestCursor(
            packetRevision: ingestState.packetRevision,
            packetLineageRevision: ingestState.packetLineageRevision,
            totalPacketCount: ingestState.packets.count
        )
        let sourceIdentity = CaptureOverviewSourceIdentity(
            backingIdentity: ingestState.backingIdentity,
            packetLineageRevision: ingestState.packetLineageRevision
        )
        guard latestObservedCursor != nextCursor || latestObservedIdentity != sourceIdentity else {
            return
        }
        latestObservedCursor = nextCursor
        latestObservedIdentity = sourceIdentity

        if let replacementWork {
            if replacementWork.update(from: ingestState) {
                return
            }
            startReplacement(from: ingestState)
            return
        }

        guard let forwardedCursor,
              forwardedIdentity == sourceIdentity,
              forwardedCursor.packetLineageRevision == nextCursor.packetLineageRevision,
              ingestState.packetRevision == forwardedCursor.packetRevision &+ 1,
              ingestState.lastMutation != .reset,
              ingestState.lastMutation != .replace else {
            startReplacement(from: ingestState)
            return
        }

        let update = EndpointStatisticsIngestUpdate(
            ingestState: ingestState,
            previousCursor: forwardedCursor
        )
        guard update.previousPacketRevision != nil else {
            startReplacement(from: ingestState)
            return
        }
        self.forwardedCursor = update.cursor
        handle(updateCoordinator.enqueue(update))
    }

    func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        processingGeneration &+= 1
        presentationWorkItem?.cancel()
        presentationWorkItem = nil
        replacementWork = nil
        updateCoordinator.cancel()
        snapshotHandler = nil
    }

    private func startReplacement(from ingestState: PacketIngestState) {
        processingGeneration &+= 1
        let generation = processingGeneration
        presentationWorkItem?.cancel()
        presentationWorkItem = nil
        updateCoordinator.cancel()
        forwardedCursor = nil
        forwardedIdentity = nil
        let work = CaptureOverviewReplacementWork(ingestState: ingestState)
        replacementWork = work
        processingQueue.async { [weak self, weak work] in
            guard let self, work != nil else {
                return
            }
            self.accumulator.reset()
            DispatchQueue.main.async { [weak self, weak work] in
                guard let self, let work,
                      self.processingGeneration == generation,
                      self.replacementWork === work else {
                    return
                }
                self.continueReplacement(work, generation: generation)
            }
        }
    }

    // Copy and consume one bounded packet range before requesting the next range.
    private func continueReplacement(_ work: CaptureOverviewReplacementWork, generation: UInt64) {
        guard replacementWork === work,
              !work.isChunkInFlight,
              !work.isFinishing,
              processingGeneration == generation else {
            return
        }
        let ingestState = latestIngestStateProvider()
        let identity = CaptureOverviewSourceIdentity(
            backingIdentity: ingestState.backingIdentity,
            packetLineageRevision: ingestState.packetLineageRevision
        )
        guard identity == work.identity,
              ingestState.packetRevision == work.cursor.packetRevision,
              ingestState.packets.count == work.cursor.totalPacketCount else {
            startReplacement(from: ingestState)
            return
        }
        guard let range = work.nextRange else {
            finishReplacement(work, generation: generation)
            return
        }

        let packets = Array(ingestState.packets[range])
        work.advance(to: range.upperBound)
        work.isChunkInFlight = true
        processingQueue.async { [weak self, weak work] in
            guard let self, work != nil else {
                return
            }
            self.accumulator.appendReplacementChunk(packets)
            DispatchQueue.main.async { [weak self, weak work] in
                guard let self, let work,
                      self.processingGeneration == generation,
                      self.replacementWork === work else {
                    return
                }
                work.isChunkInFlight = false
                self.continueReplacement(work, generation: generation)
            }
        }
    }

    private func finishReplacement(_ work: CaptureOverviewReplacementWork, generation: UInt64) {
        work.isFinishing = true
        let cursor = work.cursor
        let metadata = Array(work.updatedPacketsByID.values)
        processingQueue.async { [weak self, weak work] in
            guard let self, work != nil else {
                return
            }
            self.accumulator.applyMetadata(metadata)
            let didFinish = self.accumulator.finishReplacement(cursor: cursor)
            DispatchQueue.main.async { [weak self, weak work] in
                guard let self, let work,
                      self.processingGeneration == generation,
                      self.replacementWork === work else {
                    return
                }
                let latestState = self.latestIngestStateProvider()
                let latestCursor = EndpointStatisticsIngestCursor(
                    packetRevision: latestState.packetRevision,
                    packetLineageRevision: latestState.packetLineageRevision,
                    totalPacketCount: latestState.packets.count
                )
                guard didFinish, latestCursor == cursor else {
                    self.startReplacement(from: latestState)
                    return
                }
                self.replacementWork = nil
                self.forwardedCursor = cursor
                self.forwardedIdentity = work.identity
                self.requestPresentation()
            }
        }
    }

    private func handle(_ action: EndpointStatisticsUpdateDrainCoordinator.Action) {
        switch action {
        case .none:
            return
        case .drain(let update):
            let generation = processingGeneration
            processingQueue.async { [weak self] in
                guard let self else {
                    return
                }
                let didConsume = self.accumulator.consume(update)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          !self.isCancelled,
                          self.processingGeneration == generation else {
                        return
                    }
                    let nextAction = self.updateCoordinator.drainCompleted(didConsume: didConsume)
                    if didConsume {
                        self.requestPresentation()
                    }
                    self.handle(nextAction)
                }
            }
        case .paused:
            guard !updateCoordinator.isDrainInFlight else {
                return
            }
            startReplacement(from: latestIngestStateProvider())
        }
    }

    private func requestPresentation() {
        guard presentationWorkItem == nil, replacementWork == nil else {
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastPresentationTime
        let delay = max(0, Self.presentationInterval - elapsed)
        let generation = processingGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.presentationWorkItem = nil
            self.processingQueue.async { [weak self] in
                guard let self else {
                    return
                }
                let snapshot = self.accumulator.snapshot()
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          !self.isCancelled,
                          self.processingGeneration == generation,
                          self.replacementWork == nil else {
                        return
                    }
                    self.commit(snapshot)
                }
            }
        }
        presentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func commit(_ snapshot: CaptureOverviewSnapshot) {
        lastPresentationTime = ProcessInfo.processInfo.systemUptime
        snapshotHandler?(snapshot)
    }
}
