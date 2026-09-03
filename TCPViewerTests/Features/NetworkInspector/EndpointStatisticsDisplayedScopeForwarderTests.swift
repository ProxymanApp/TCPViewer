//
//  EndpointStatisticsDisplayedScopeForwarderTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

struct EndpointStatisticsDisplayedScopeForwarderTests {
    @Test func initialStateRequiresAChunkedReplacement() {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let packets = Self.packets(count: 2)

        let result = forwarder.forwardingResult(
            from: Self.source(generation: 1, packetIDs: [1, 2], updatePlan: .reload),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: Self.provider(packets)
        )
        #expect(Self.isReplacementRequired(result))
        #expect(forwarder.packetCount == 0)
    }

    @Test func consecutiveAppendCopiesOnlyNewPackets() throws {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let packets = Self.packets(count: 3)
        Self.prime(&forwarder, source: Self.source(
            generation: 1,
            packetIDs: [1, 2],
            updatePlan: .reload
        ), packets: Array(packets.prefix(2)))

        let candidate = Self.update(from: forwarder.forwardingResult(
            from: Self.source(generation: 2, packetIDs: [1, 2, 3], updatePlan: .append(2..<3)),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: Self.provider(packets)
        ))
        let update = try #require(candidate)

        guard case .append(let appendedPackets) = update.kind else {
            Issue.record("Expected an append update.")
            return
        }
        #expect(appendedPackets.map { $0.id } == [3])
        #expect(update.totalPacketCount == 3)
        #expect(forwarder.packetCount == 3)
    }

    @Test func sameGenerationDoesNotReplayAnAlreadyConsumedUpdatePlan() throws {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let packets = Self.packets(count: 3)
        Self.prime(&forwarder, source: Self.source(
            generation: 1,
            packetIDs: [1, 2],
            updatePlan: .reload
        ), packets: Array(packets.prefix(2)))

        let appended = Self.update(from: forwarder.forwardingResult(
            from: Self.source(generation: 2, packetIDs: [1, 2, 3], updatePlan: .append(2..<3)),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: Self.provider(packets)
        ))
        _ = try #require(appended)
        var providerCallCount = 0

        let replayedAppend = forwarder.forwardingResult(
            from: Self.source(generation: 2, packetIDs: [1, 2, 3], updatePlan: .append(2..<3)),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: { _ in
                providerCallCount += 1
                return []
            }
        )
        let replayedReload = forwarder.forwardingResult(
            from: Self.source(generation: 2, packetIDs: [1, 2, 3], updatePlan: .reload),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: { _ in
                providerCallCount += 1
                return []
            }
        )

        #expect(Self.isNone(replayedAppend))
        #expect(Self.isNone(replayedReload))
        #expect(providerCallCount == 0)
        #expect(forwarder.packetCount == 3)
    }

    @Test func settledFilterWithoutADeltaRequestsAPresentation() {
        #expect(EndpointStatisticsDisplayedSourcePolicy.shouldPresentAfterFiltering(
            wasWaitingForFilter: true,
            didForward: false
        ))
        #expect(!EndpointStatisticsDisplayedSourcePolicy.shouldPresentAfterFiltering(
            wasWaitingForFilter: false,
            didForward: false
        ))
        #expect(!EndpointStatisticsDisplayedSourcePolicy.shouldPresentAfterFiltering(
            wasWaitingForFilter: true,
            didForward: true
        ))
    }

    @Test func reloadRowsCopiesOnlyUpdatedPackets() throws {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let packets = Self.packets(count: 2)
        Self.prime(&forwarder, source: Self.source(
            generation: 1,
            packetIDs: [1, 2],
            updatePlan: .reload
        ), packets: packets)

        let candidate = Self.update(from: forwarder.forwardingResult(
            from: Self.source(
                generation: 2,
                packetIDs: [1, 2],
                updatePlan: .reloadRows(IndexSet(integer: 1))
            ),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: Self.provider(packets)
        ))
        let update = try #require(candidate)

        guard case .metadata(let updatedPackets) = update.kind else {
            Issue.record("Expected a metadata update.")
            return
        }
        #expect(updatedPackets.map { $0.id } == [2])
        #expect(update.totalPacketCount == 2)
    }

    @Test func skippedTableGenerationRequiresAChunkedReplacement() {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let packets = Self.packets(count: 3)
        Self.prime(&forwarder, source: Self.source(
            generation: 1,
            packetIDs: [1, 2],
            updatePlan: .reload
        ), packets: Array(packets.prefix(2)))

        let result = forwarder.forwardingResult(
            from: Self.source(generation: 3, packetIDs: [1, 2, 3], updatePlan: .append(2..<3)),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: Self.provider(packets)
        )
        #expect(Self.isReplacementRequired(result))
    }

    @Test func inFlightDisplayFilterKeepsLastConfirmedState() {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let packets = Self.packets(count: 2)
        Self.prime(&forwarder, source: Self.source(
            generation: 1,
            packetIDs: [1],
            updatePlan: .reload
        ), packets: Array(packets.prefix(1)))
        let previousCursor = forwarder.cursor

        let result = forwarder.forwardingResult(
            from: Self.source(
                generation: 2,
                packetIDs: [2],
                updatePlan: .reload,
                isFiltering: true
            ),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: Self.provider(packets)
        )

        #expect(Self.isNone(result))
        #expect(forwarder.packetCount == 1)
        #expect(forwarder.cursor == previousCursor)
    }

    @Test func sourceDefersPacketIDLoadingUntilDisplayedScopeConsumesIt() {
        var loadedSelections: [Int] = []

        _ = Self.source(
            generation: 1,
            packetIDs: Array(1...100_000).map(UInt64.init),
            updatePlan: .reload,
            didLoadSelection: { loadedSelections.append($0.count) }
        )

        #expect(loadedSelections.isEmpty)
    }

    @Test func appendLoadsOnlyTheBoundedDelta() throws {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let packets = Self.packets(count: 3)
        Self.prime(&forwarder, source: Self.source(
            generation: 1,
            packetIDs: [1, 2],
            updatePlan: .reload
        ), packets: Array(packets.prefix(2)))
        var loadedSelections: [Int] = []

        let candidate = Self.update(from: forwarder.forwardingResult(
            from: Self.source(
                generation: 2,
                packetIDs: [1, 2, 3],
                updatePlan: .append(2..<3),
                didLoadSelection: { loadedSelections.append($0.count) }
            ),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: Self.provider(packets)
        ))
        _ = try #require(candidate)

        #expect(loadedSelections == [1])
    }

    @Test func staleRenderedSourceDoesNotLoadOrResolvePacketIDsFromANewCapture() {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        var loadedSelectionCount = 0
        var providerCallCount = 0
        let staleSource = Self.source(
            generation: 1,
            packetIDs: [1],
            updatePlan: .reload,
            didLoadSelection: { loadedSelectionCount += $0.count }
        )

        let result = forwarder.forwardingResult(
            from: staleSource,
            expectedSourceIdentity: EndpointStatisticsSourceIdentity(
                backingIdentity: "capture-b",
                packetLineageRevision: 2
            ),
            forceReplacement: true,
            packetProvider: { _ in
                providerCallCount += 1
                return []
            }
        )

        #expect(Self.isNone(result))
        #expect(loadedSelectionCount == 0)
        #expect(providerCallCount == 0)
        #expect(forwarder.cursor == nil)
    }

    @Test func replacementAccumulatorKeepsEveryMainTurnBoundedAcrossAnExtendedTail() throws {
        var accumulator = EndpointStatisticsDisplayedReplacementAccumulator(
            packetCount: 1_000,
            chunkSize: 512
        )
        var observedRanges: [Range<Int>] = []
        while let range = accumulator.nextRange {
            observedRanges.append(range)
            let packets = range.map { Self.makePacket(id: UInt64($0 + 1)) }
            let didAppend = accumulator.append(packetIDs: packets.map(\.id), packets: packets)
            #expect(didAppend)
        }
        let didExtend = accumulator.extend(to: 2_000)
        #expect(didExtend)
        while let range = accumulator.nextRange {
            observedRanges.append(range)
            let packets = range.map { Self.makePacket(id: UInt64($0 + 1)) }
            let didAppend = accumulator.append(packetIDs: packets.map(\.id), packets: packets)
            #expect(didAppend)
        }

        let replacement = Self.makePacket(id: 99_999)
        accumulator.replaceLoadedPacket(at: 1_500, with: replacement)
        let flattened = accumulator.packetChunks.flatMap(\.packets)

        #expect(observedRanges.allSatisfy { $0.count <= 512 })
        #expect(flattened.count == 2_000)
        #expect(flattened[1_500].id == replacement.id)
    }

    @Test func replacementStopsForSameGenerationFilteringOrScopeChange() {
        let source = Self.source(generation: 7, packetIDs: [1], updatePlan: .reload)
        let filteringSource = Self.source(
            generation: 7,
            packetIDs: [1],
            updatePlan: .reload,
            isFiltering: true
        )

        #expect(!EndpointStatisticsDisplayedSourcePolicy.canLoadReplacement(
            source: source,
            latestSource: filteringSource,
            expectedIdentity: Self.sourceIdentity,
            usesDisplayedPackets: true
        ))
        #expect(!EndpointStatisticsDisplayedSourcePolicy.canLoadReplacement(
            source: source,
            latestSource: source,
            expectedIdentity: Self.sourceIdentity,
            usesDisplayedPackets: false
        ))
    }

    @Test func displayedReplacementSurvivesAppendWhileLoadingAndRejectsOldFlatten() throws {
        let initialPackets = Self.packets(count: 3_000)
        let initialSource = Self.source(
            generation: 1,
            packetIDs: initialPackets.map(\.id),
            updatePlan: .reload
        )
        let work = EndpointStatisticsDisplayedReplacementWork(source: initialSource, mode: .enqueue)
        let firstRange = try #require(work.accumulator.nextRange)
        let firstPackets = Array(initialPackets[firstRange])
        let didAppendFirstChunk = work.accumulator.append(
            packetIDs: firstPackets.map(\.id),
            packets: firstPackets
        )
        #expect(didAppendFirstChunk)
        let staleFlattenToken = work.cancellationToken
        let staleFlattenCount = work.accumulator.packetCount

        let appendedPackets = (3_001...4_000).map { Self.makePacket(id: UInt64($0)) }
        let allPackets = initialPackets + appendedPackets
        let appendedSource = Self.source(
            generation: 2,
            packetIDs: allPackets.map(\.id),
            updatePlan: .append(3_000..<4_000)
        )

        #expect(work.update(to: appendedSource, packetProvider: Self.provider(allPackets)) == .updated)
        #expect(work.accumulator.nextPacketIndex == firstRange.upperBound)
        #expect(work.accumulator.packetCount == 4_000)
        #expect(!work.acceptsFlattenedPackets(
            token: staleFlattenToken,
            packetCount: staleFlattenCount,
            flattenedPacketCount: staleFlattenCount
        ))

        while let range = work.accumulator.nextRange {
            let packetIDs = try #require(work.source.packetIDs(in: range))
            let packets = Self.provider(allPackets)(packetIDs)
            let didAppendChunk = work.accumulator.append(packetIDs: packetIDs, packets: packets)
            #expect(didAppendChunk)
        }
        #expect(work.acceptsFlattenedPackets(
            token: work.cancellationToken,
            packetCount: 4_000,
            flattenedPacketCount: 4_000
        ))
        #expect(work.accumulator.packetChunks.flatMap(\.packets).map(\.id) == allPackets.map(\.id))
    }

    @Test func rawReplacementRejectsAFlattenCapturedBeforeAnAppend() throws {
        let work = EndpointStatisticsRawReplacementWork(
            sourceIdentity: Self.sourceIdentity,
            packetRevision: 1,
            packetCount: 1,
            mode: .enqueue
        )
        let packet = Self.makePacket(id: 1)
        let didAppendPacket = work.accumulator.append(packetIDs: [packet.id], packets: [packet])
        #expect(didAppendPacket)
        let staleFlattenToken = work.cancellationToken

        #expect(work.prepareForMorePackets(packetRevision: 2, packetCount: 2))
        #expect(!work.acceptsFlattenedPackets(
            token: staleFlattenToken,
            packetRevision: 1,
            packetCount: 1,
            flattenedPacketCount: 1
        ))
    }

    @Test func sustainedAppendsDuringDisplayedFlattenKeepTheFrozenBoundaryValid() throws {
        var allPackets = Self.packets(count: 100)
        var source = Self.source(
            generation: 1,
            packetIDs: allPackets.map(\.id),
            updatePlan: .reload
        )
        let work = EndpointStatisticsDisplayedReplacementWork(source: source, mode: .enqueue)
        while let range = work.accumulator.nextRange {
            let packets = Array(allPackets[range])
            let didAppend = work.accumulator.append(packetIDs: packets.map(\.id), packets: packets)
            #expect(didAppend)
        }
        work.isFlattening = true
        let flattenToken = work.cancellationToken
        let flattenCount = work.accumulator.packetCount

        for generation in 2...101 {
            let oldCount = allPackets.count
            allPackets.append(Self.makePacket(id: UInt64(oldCount + 1)))
            source = Self.source(
                generation: UInt64(generation),
                packetIDs: allPackets.map(\.id),
                updatePlan: .append(oldCount..<allPackets.count)
            )
            #expect(work.update(to: source, packetProvider: Self.provider(allPackets)) == .updated)
        }

        #expect(work.cancellationToken === flattenToken)
        #expect(work.deferredUpdates.count == 100)
        #expect(work.retainedDeferredPacketCount == 100)
        #expect(work.acceptsFlattenedPackets(
            token: flattenToken,
            packetCount: flattenCount,
            flattenedPacketCount: flattenCount
        ))

        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let replacementCandidate = forwarder.replacementUpdate(
            from: Self.source(
                generation: 1,
                packetIDs: Array(allPackets.prefix(flattenCount)).map(\.id),
                updatePlan: .reload
            ),
            packets: Array(allPackets.prefix(flattenCount))
        )
        let replacement = try #require(replacementCandidate)
        var latestUpdate = replacement
        for deferredUpdate in work.deferredUpdates {
            let candidate = forwarder.deferredUpdate(deferredUpdate)
            latestUpdate = try #require(candidate)
        }
        #expect(latestUpdate.totalPacketCount == allPackets.count)
    }

    @Test func rawReplacementExtendsLargeContiguousAppendsInChunksBeforeFlattening() {
        let work = EndpointStatisticsRawReplacementWork(
            sourceIdentity: Self.sourceIdentity,
            packetRevision: 1,
            packetCount: 100,
            mode: .enqueue
        )

        #expect(work.prepareForMorePackets(packetRevision: 2, packetCount: 20_100))
        #expect(work.prepareForMorePackets(packetRevision: 3, packetCount: 40_100))
        #expect(work.accumulator.packetCount == 40_100)
        #expect(work.accumulator.nextRange?.count == EndpointStatisticsDisplayedReplacementAccumulator.defaultChunkSize)
    }

    @Test func rawFlattenBoundaryRemainsValidWhileBoundedAppendsAreDeferred() {
        let work = EndpointStatisticsRawReplacementWork(
            sourceIdentity: Self.sourceIdentity,
            packetRevision: 1,
            packetCount: 100,
            mode: .enqueue
        )
        work.isFlattening = true
        let flattenToken = work.cancellationToken

        for revision in 2...101 {
            let packet = Self.makePacket(id: UInt64(99 + revision))
            let update = EndpointStatisticsIngestUpdate(
                packetRevision: UInt64(revision),
                packetLineageRevision: Self.sourceIdentity.packetLineageRevision,
                totalPacketCount: 99 + revision,
                kind: .append([packet])
            )
            #expect(work.deferUpdate(update, maximumPacketCount: 10_000))
        }

        #expect(work.cancellationToken === flattenToken)
        #expect(work.deferredUpdates.count == 100)
        #expect(work.logicalPacketCount == 200)
        #expect(work.acceptsFlattenedPackets(
            token: flattenToken,
            packetRevision: 1,
            packetCount: 100,
            flattenedPacketCount: 100
        ))
    }

    @Test func oversizedDisplayedDeltasRequireReplacementBeforeLoadingIDs() {
        var forwarder = EndpointStatisticsDisplayedScopeForwarder()
        let firstPacket = Self.makePacket(id: 1)
        Self.prime(
            &forwarder,
            source: Self.source(generation: 1, packetIDs: [1], updatePlan: .reload),
            packets: [firstPacket]
        )
        let packetIDs = (1...10_002).map(UInt64.init)
        var loadedSelectionCount = 0
        var providerCallCount = 0

        let appendResult = forwarder.forwardingResult(
            from: Self.source(
                generation: 2,
                packetIDs: packetIDs,
                updatePlan: .append(1..<10_002),
                didLoadSelection: { loadedSelectionCount += $0.count }
            ),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: { _ in
                providerCallCount += 1
                return []
            }
        )

        #expect(Self.isReplacementRequired(appendResult))
        #expect(loadedSelectionCount == 0)
        #expect(providerCallCount == 0)

        let reloadResult = forwarder.forwardingResult(
            from: Self.source(
                generation: 2,
                packetIDs: [1],
                updatePlan: .reloadRows(IndexSet(integersIn: 0..<10_001)),
                didLoadSelection: { loadedSelectionCount += $0.count }
            ),
            expectedSourceIdentity: Self.sourceIdentity,
            forceReplacement: false,
            packetProvider: { _ in
                providerCallCount += 1
                return []
            }
        )

        #expect(Self.isReplacementRequired(reloadResult))
        #expect(loadedSelectionCount == 0)
        #expect(providerCallCount == 0)
    }

    @Test func rawDeltaPolicyCapsAppendAndMetadataBeforeMaterialization() {
        #expect(EndpointStatisticsRawDeltaPolicy.exceedsAutomaticLimit(
            .append(0..<10_001)
        ))
        #expect(EndpointStatisticsRawDeltaPolicy.exceedsAutomaticLimit(
            .appendWithMetadataUpdates(
                range: 0..<9_500,
                updatedPacketIDs: Array(1...501).map(UInt64.init)
            )
        ))
        #expect(EndpointStatisticsRawDeltaPolicy.exceedsAutomaticLimit(
            .metadataUpdate(packetIDs: Array(1...10_001).map(UInt64.init))
        ))
        #expect(!EndpointStatisticsRawDeltaPolicy.exceedsAutomaticLimit(
            .append(0..<10_000)
        ))
    }
}

private extension EndpointStatisticsDisplayedScopeForwarderTests {
    static let sourceIdentity = EndpointStatisticsSourceIdentity(
        backingIdentity: "capture-a",
        packetLineageRevision: 1
    )

    static func prime(
        _ forwarder: inout EndpointStatisticsDisplayedScopeForwarder,
        source: EndpointStatisticsRenderedSource,
        packets: [PacketSummary]
    ) {
        _ = forwarder.replacementUpdate(from: source, packets: packets)
    }

    static func update(
        from result: EndpointStatisticsDisplayedScopeForwardingResult
    ) -> EndpointStatisticsIngestUpdate? {
        guard case .update(let update) = result else {
            return nil
        }
        return update
    }

    static func isNone(_ result: EndpointStatisticsDisplayedScopeForwardingResult) -> Bool {
        if case .none = result {
            return true
        }
        return false
    }

    static func isReplacementRequired(
        _ result: EndpointStatisticsDisplayedScopeForwardingResult
    ) -> Bool {
        if case .replacementRequired = result {
            return true
        }
        return false
    }

    static func source(
        generation: UInt64,
        packetIDs: [PacketSummary.ID],
        updatePlan: PacketTableUpdatePlan,
        isFiltering: Bool = false,
        didLoadSelection: ((EndpointStatisticsPacketIDSelection) -> Void)? = nil
    ) -> EndpointStatisticsRenderedSource {
        EndpointStatisticsRenderedSource(
            identity: sourceIdentity,
            packetTableGeneration: generation,
            visiblePacketCount: packetIDs.count,
            updatePlan: updatePlan,
            isFiltering: isFiltering,
            packetIDLoader: { selection in
                didLoadSelection?(selection)
                switch selection {
                case .range(let range):
                    return Array(packetIDs[range])
                case .indexes(let indexes):
                    return indexes.map { packetIDs[$0] }
                }
            }
        )
    }

    static func provider(_ packets: [PacketSummary]) -> ([PacketSummary.ID]) -> [PacketSummary] {
        let packetsByID = Dictionary(uniqueKeysWithValues: packets.map { ($0.id, $0) })
        return { packetIDs in
            packetIDs.compactMap { packetsByID[$0] }
        }
    }

    static func packets(count: Int) -> [PacketSummary] {
        (1...count).map { makePacket(id: UInt64($0)) }
    }

    static func makePacket(id: UInt64) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.2", port: 51_000),
                destination: PacketEndpoint(address: "93.184.216.34", port: 443)
            ),
            originalLength: 128,
            capturedLength: 128,
            direction: .outbound,
            infoSummary: "Packet \(id)",
            layers: [PacketLayer(name: "IPv4"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }
}
