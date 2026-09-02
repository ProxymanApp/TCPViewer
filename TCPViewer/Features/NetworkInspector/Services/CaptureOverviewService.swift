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

struct CaptureOverviewSnapshot: Equatable, Sendable {
    let totals: CaptureOverviewTrafficTotals
    let firstPacketDate: Date?
    let lastPacketDate: Date?
    let appCount: Int
    let domainCount: Int
    let malformedPacketCount: UInt64
    let topApps: [CaptureOverviewTopRow]
    let topDestinations: [CaptureOverviewTopRow]
    let protocols: [CaptureOverviewProtocolRow]
    let timeline: [CaptureOverviewTimelinePoint]

    static let empty = CaptureOverviewSnapshot(
        totals: CaptureOverviewTrafficTotals(),
        firstPacketDate: nil,
        lastPacketDate: nil,
        appCount: 0,
        domainCount: 0,
        malformedPacketCount: 0,
        topApps: [],
        topDestinations: [],
        protocols: [],
        timeline: []
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
    static let maximumRenderedTimelinePointCount = 240
    static let maximumTopRowCount = 10
    static let maximumProtocolRowCount = 5

    private var contributionsByPacketID: [PacketSummary.ID: CaptureOverviewContribution] = [:]
    private var appBuckets: [PacketSourceClientKey: CaptureOverviewAppBucket] = [:]
    private var domainBuckets: [PacketSourceDomainKey: CaptureOverviewDomainBucket] = [:]
    private var ipAddressBuckets: [PacketSourceIPAddressKey: CaptureOverviewIPAddressBucket] = [:]
    private var protocolBuckets: [String: CaptureOverviewProtocolBucket] = [:]
    private var timelineBuckets: [Int64: CaptureOverviewTrafficTotals] = [:]
    private var timelineBucketWidth: TimeInterval = 1
    private var totals = CaptureOverviewTrafficTotals()
    private var malformedPacketCount: UInt64 = 0
    private var firstPacketDate: Date?
    private var lastPacketDate: Date?
    private var cursor: EndpointStatisticsIngestCursor?

    mutating func reset() {
        contributionsByPacketID.removeAll(keepingCapacity: false)
        appBuckets.removeAll(keepingCapacity: false)
        domainBuckets.removeAll(keepingCapacity: false)
        ipAddressBuckets.removeAll(keepingCapacity: false)
        protocolBuckets.removeAll(keepingCapacity: false)
        timelineBuckets.removeAll(keepingCapacity: false)
        timelineBucketWidth = 1
        totals = CaptureOverviewTrafficTotals()
        malformedPacketCount = 0
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

    func snapshot() -> CaptureOverviewSnapshot {
        CaptureOverviewSnapshot(
            totals: totals,
            firstPacketDate: firstPacketDate,
            lastPacketDate: lastPacketDate,
            appCount: appBuckets.count,
            domainCount: domainBuckets.count,
            malformedPacketCount: malformedPacketCount,
            topApps: topAppRows(),
            topDestinations: topDestinationRows(),
            protocols: protocolRows(),
            timeline: timelinePoints()
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
        CaptureOverviewContribution(
            packetID: packet.id,
            timestamp: packet.timestamp,
            app: PacketSourceListClassifier.clientIdentity(for: packet),
            domain: PacketSourceListClassifier.domainIdentity(for: packet),
            ipAddresses: PacketSourceListClassifier.ipAddressIdentities(for: packet),
            protocolName: EndpointStatisticsClassifier.protocolName(for: packet),
            totals: trafficTotals(bytes: UInt64(max(0, packet.originalLength)), direction: packet.direction),
            isMalformed: packet.decodeStatus.kind == .malformed
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
        topRows(appBuckets.values.lazy.map { bucket in
            CaptureOverviewTopRow(
                id: bucket.identity.key.rawValue,
                title: bucket.identity.displayName,
                iconFilePath: bucket.identity.iconFilePath,
                selection: .app(bucket.identity.key),
                totals: bucket.totals
            )
        })
    }

    private func topDestinationRows() -> [CaptureOverviewTopRow] {
        var result: [CaptureOverviewTopRow] = []
        result.reserveCapacity(Self.maximumTopRowCount)
        for bucket in domainBuckets.values {
            insertTopRow(CaptureOverviewTopRow(
                id: "domain:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                iconFilePath: nil,
                selection: .domain(bucket.identity.key),
                totals: bucket.totals
            ), into: &result)
        }
        for bucket in ipAddressBuckets.values {
            insertTopRow(CaptureOverviewTopRow(
                id: "ip:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                iconFilePath: nil,
                selection: .ipAddress(bucket.identity.key),
                totals: bucket.totals
            ), into: &result)
        }
        return result
    }

    // Keep only ten candidates while scanning so high-cardinality captures avoid a full sort.
    private func topRows<Rows: Sequence>(_ rows: Rows) -> [CaptureOverviewTopRow]
        where Rows.Element == CaptureOverviewTopRow {
        var result: [CaptureOverviewTopRow] = []
        result.reserveCapacity(Self.maximumTopRowCount)
        for row in rows {
            insertTopRow(row, into: &result)
        }
        return result
    }

    private func insertTopRow(_ row: CaptureOverviewTopRow, into result: inout [CaptureOverviewTopRow]) {
        let insertionIndex = result.firstIndex { Self.precedes(row, $0) } ?? result.endIndex
        if insertionIndex < Self.maximumTopRowCount {
            result.insert(row, at: insertionIndex)
            if result.count > Self.maximumTopRowCount {
                result.removeLast()
            }
        } else if result.count < Self.maximumTopRowCount {
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
            timelineBucketWidth *= 2
            var merged: [Int64: CaptureOverviewTrafficTotals] = [:]
            merged.reserveCapacity((timelineBuckets.count + 1) / 2)
            for (key, value) in timelineBuckets {
                let timestamp = TimeInterval(key) * previousWidth
                let mergedKey = Int64(floor(timestamp / timelineBucketWidth))
                merged[mergedKey, default: CaptureOverviewTrafficTotals()].add(value)
            }
            timelineBuckets = merged
        }
    }

    private func timelinePoints() -> [CaptureOverviewTimelinePoint] {
        guard let minimumKey = timelineBuckets.keys.min(),
              let maximumKey = timelineBuckets.keys.max() else {
            return []
        }
        let span = TimeInterval(maximumKey - minimumKey + 1) * timelineBucketWidth
        var renderedWidth = timelineBucketWidth
        while span / renderedWidth > Double(Self.maximumRenderedTimelinePointCount) {
            renderedWidth *= 2
        }

        var renderedBuckets: [Int64: CaptureOverviewTrafficTotals] = [:]
        renderedBuckets.reserveCapacity(min(Self.maximumRenderedTimelinePointCount, timelineBuckets.count))
        for (key, value) in timelineBuckets {
            let timestamp = TimeInterval(key) * timelineBucketWidth
            let renderedKey = Int64(floor(timestamp / renderedWidth))
            renderedBuckets[renderedKey, default: CaptureOverviewTrafficTotals()].add(value)
        }
        return renderedBuckets.keys.sorted().map { key in
            CaptureOverviewTimelinePoint(
                date: Date(timeIntervalSince1970: TimeInterval(key) * renderedWidth),
                totals: renderedBuckets[key] ?? CaptureOverviewTrafficTotals()
            )
        }
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
