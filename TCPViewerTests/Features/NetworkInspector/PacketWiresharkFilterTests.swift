//
//  PacketWiresharkFilterTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

struct PacketWiresharkFilterTests {
    @Test func bitSetStoresSparseIndexesAndCountsOnlyRequestedPrefix() {
        var bitSet = PacketIndexBitSet()
        for index in [0, 1, 63, 64, 99_999] {
            bitSet.insert(index)
        }

        #expect(bitSet.contains(0))
        #expect(bitSet.contains(64))
        #expect(bitSet.contains(99_999))
        #expect(!bitSet.contains(2))
        #expect(!bitSet.contains(100_000))
        #expect(bitSet.setBitCount == 5)
        #expect(bitSet.setBitCount(upTo: 64) == 3)
        #expect(bitSet.setBitCount(upTo: 100_000) == 5)
    }

    @Test func cacheRetainsFourMostRecentlyUsedExpressions() {
        var cache = PacketDisplayFilterResultCache()
        let keys = (0..<5).map { index in
            PacketDisplayFilterCacheKey(
                backingIdentity: "capture",
                packetLineageRevision: 1,
                expression: "frame.number == \(index)",
                dissectionRevision: PacketDisplayFilterCacheKey.dissectionRevision
            )
        }

        for (index, key) in keys.prefix(4).enumerated() {
            cache.store(Self.entry(matchingIndex: index), for: key)
        }
        _ = cache.entry(for: keys[0])
        cache.store(Self.entry(matchingIndex: 4), for: keys[4])

        #expect(cache.entry(for: keys[0]) != nil)
        #expect(cache.entry(for: keys[1]) == nil)
        #expect(cache.entry(for: keys[2]) != nil)
        #expect(cache.entry(for: keys[3]) != nil)
        #expect(cache.entry(for: keys[4]) != nil)
    }

    @Test func cacheEntryTracksEvaluatedAndMatchingPacketIndexesIncrementally() {
        let packets = (0..<100_000).map { Self.packet(id: UInt64($0 + 1)) }
        let ingestState = Self.ingestState(packets: packets)
        var entry = PacketDisplayFilterCacheEntry()
        let evaluatedIDs = stride(from: 1, through: 100_000, by: 2).map(UInt64.init)
        let matchingIDs = stride(from: 1, through: 100_000, by: 10_000).map(UInt64.init)

        entry.record(
            batch: DisplayFilterMatchBatch(
                generation: 7,
                evaluatedPacketIDs: evaluatedIDs,
                matchingPacketIDs: matchingIDs
            ),
            packetIndexByID: ingestState.packetIndexByID
        )

        #expect(entry.membership(generation: 7, expression: "frame.number % 2 == 1").evaluatedPacketCount == 50_000)
        #expect(entry.membership(generation: 7, expression: "frame.number % 2 == 1").matchingPacketIndexes.setBitCount == 10)
        #expect(entry.unknownPacketIDs(in: ingestState, limit: 3) == [2, 4, 6])
    }

    @Test func diagnosticRangeConvertsUTF8OffsetsToNativeTextRanges() throws {
        let expression = "ip.addr == \"café\" && tcp.port =="
        let byteOffset = try #require(expression.range(of: "tcp.port"))
        let utf8Index = try #require(byteOffset.lowerBound.samePosition(in: expression.utf8))
        let utf8Start = expression.utf8.distance(from: expression.utf8.startIndex, to: utf8Index)
        let sourceRange = DisplayFilterSourceRange(utf8StartOffset: utf8Start, utf8Length: "tcp.port".utf8.count)

        #expect(PacketWiresharkFilterTextRange.nsRange(for: sourceRange, in: expression) == NSRange(location: 21, length: 8))
        #expect(PacketWiresharkFilterTextRange.column(for: sourceRange, in: expression) == 22)
    }

    private static func entry(matchingIndex: Int) -> PacketDisplayFilterCacheEntry {
        var entry = PacketDisplayFilterCacheEntry()
        entry.evaluatedPacketIndexes.insert(matchingIndex)
        entry.matchingPacketIndexes.insert(matchingIndex)
        return entry
    }

    private static func ingestState(packets: [PacketSummary]) -> PacketIngestState {
        var state = PacketIngestState.empty
        state.backingIdentity = "capture"
        state.packets = packets
        state.packetIndexByID = Dictionary(uniqueKeysWithValues: packets.enumerated().map { ($0.element.id, $0.offset) })
        state.packetLineageRevision = 1
        return state
    }

    private static func packet(id: UInt64) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
            source: .offline,
            transportHint: .tcp,
            protocolSummary: "TCP",
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 64,
            capturedLength: 64,
            infoSummary: "Packet \(id)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "IPv4"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }
}
