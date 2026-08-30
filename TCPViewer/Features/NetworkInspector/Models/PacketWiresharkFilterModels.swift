//
//  PacketWiresharkFilterModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation
import PcapPlusPlusCore

enum PacketFilterMode: String, Codable, Sendable, CaseIterable {
    case builder
    case wireshark

    var title: String {
        switch self {
        case .builder:
            return "Filter Builder"
        case .wireshark:
            return "Wireshark Filter..."
        }
    }
}

struct PacketWiresharkFilterState: Equatable, Sendable {
    var draftExpression = ""
    var validation = DisplayFilterValidation(
        normalizedExpression: "",
        status: .valid
    )
    var appliedExpression = ""
    var isValidating = false
    var isApplying = false
    var evaluatedPacketCount = 0
    var totalPacketCount = 0

    var diagnostic: DisplayFilterDiagnostic? {
        validation.diagnostics.first
    }

    var progressText: String? {
        guard isApplying else {
            return nil
        }
        return "Filtering \(evaluatedPacketCount.formatted()) of \(totalPacketCount.formatted()) packets..."
    }
}

struct PacketIndexBitSet: Equatable, Sendable {
    private(set) var words: [UInt64] = []

    mutating func insert(_ index: Int) {
        guard index >= 0 else {
            return
        }
        let wordIndex = index / UInt64.bitWidth
        if words.count <= wordIndex {
            words.append(contentsOf: repeatElement(0, count: wordIndex - words.count + 1))
        }
        words[wordIndex] |= UInt64(1) << UInt64(index % UInt64.bitWidth)
    }

    func contains(_ index: Int) -> Bool {
        guard index >= 0 else {
            return false
        }
        let wordIndex = index / UInt64.bitWidth
        guard words.indices.contains(wordIndex) else {
            return false
        }
        return words[wordIndex] & (UInt64(1) << UInt64(index % UInt64.bitWidth)) != 0
    }

    func setBitCount(upTo packetCount: Int) -> Int {
        guard packetCount > 0 else {
            return 0
        }
        let fullWordCount = packetCount / UInt64.bitWidth
        let remainder = packetCount % UInt64.bitWidth
        var count = words.prefix(fullWordCount).reduce(0) { $0 + $1.nonzeroBitCount }
        if remainder > 0, words.indices.contains(fullWordCount) {
            let mask = (UInt64(1) << UInt64(remainder)) - 1
            count += (words[fullWordCount] & mask).nonzeroBitCount
        }
        return count
    }

    var setBitCount: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}

struct PacketWiresharkFilterMembership: Equatable, Sendable {
    let generation: UInt64
    let expression: String
    let evaluatedPacketCount: Int
    let matchingPacketIndexes: PacketIndexBitSet

    func matches(_ packet: PacketSummary, in ingestState: PacketIngestState) -> Bool {
        guard let index = ingestState.packetIndexByID[packet.id] else {
            return false
        }
        return matchingPacketIndexes.contains(index)
    }
}

struct PacketDisplayFilterCacheKey: Hashable, Sendable {
    static let dissectionRevision = "wireshark-4.6.6-display-filter-v1"

    let backingIdentity: String
    let packetLineageRevision: UInt64
    let expression: String
    let dissectionRevision: String
}

struct PacketDisplayFilterCacheEntry: Equatable, Sendable {
    var evaluatedPacketIndexes = PacketIndexBitSet()
    var matchingPacketIndexes = PacketIndexBitSet()

    mutating func record(
        batch: DisplayFilterMatchBatch,
        packetIndexByID: [PacketSummary.ID: Int]
    ) {
        let matchingIDs = Set(batch.matchingPacketIDs)
        for packetID in batch.evaluatedPacketIDs {
            guard let index = packetIndexByID[packetID] else {
                continue
            }
            evaluatedPacketIndexes.insert(index)
            if matchingIDs.contains(packetID) {
                matchingPacketIndexes.insert(index)
            }
        }
    }

    func unknownPacketIDs(in ingestState: PacketIngestState, limit: Int? = nil) -> [PacketSummary.ID] {
        var identifiers: [PacketSummary.ID] = []
        if let limit {
            identifiers.reserveCapacity(min(limit, ingestState.packets.count))
        }
        for (index, packet) in ingestState.packets.enumerated() where !evaluatedPacketIndexes.contains(index) {
            identifiers.append(packet.id)
            if let limit, identifiers.count >= limit {
                break
            }
        }
        return identifiers
    }

    func membership(generation: UInt64, expression: String) -> PacketWiresharkFilterMembership {
        PacketWiresharkFilterMembership(
            generation: generation,
            expression: expression,
            evaluatedPacketCount: evaluatedPacketIndexes.setBitCount,
            matchingPacketIndexes: matchingPacketIndexes
        )
    }
}

struct PacketDisplayFilterResultCache {
    private struct StoredEntry {
        var entry: PacketDisplayFilterCacheEntry
        var accessOrdinal: UInt64
    }

    private let capacity = 4
    private var entries: [PacketDisplayFilterCacheKey: StoredEntry] = [:]
    private var accessOrdinal: UInt64 = 0

    mutating func entry(for key: PacketDisplayFilterCacheKey) -> PacketDisplayFilterCacheEntry? {
        guard var stored = entries[key] else {
            return nil
        }
        accessOrdinal &+= 1
        stored.accessOrdinal = accessOrdinal
        entries[key] = stored
        return stored.entry
    }

    mutating func store(_ entry: PacketDisplayFilterCacheEntry, for key: PacketDisplayFilterCacheKey) {
        accessOrdinal &+= 1
        entries[key] = StoredEntry(entry: entry, accessOrdinal: accessOrdinal)
        guard entries.count > capacity,
              let oldestKey = entries.min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal })?.key else {
            return
        }
        entries.removeValue(forKey: oldestKey)
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}
