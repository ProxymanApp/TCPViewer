//
//  EndpointStatisticsUpdateDrainCoordinator.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation
import PcapPlusPlusCore

struct EndpointStatisticsUpdateDrainCoordinator {
    enum Action {
        case none
        case drain(EndpointStatisticsIngestUpdate)
        case paused
    }

    private let maximumPendingPacketCount: Int
    private var pendingUpdate: PendingEndpointStatisticsUpdate?
    private(set) var isDrainInFlight = false
    private(set) var isPaused = false

    var retainedPendingPacketCount: Int {
        pendingUpdate?.retainedPacketCount ?? 0
    }

    init(maximumPendingPacketCount: Int = 10_000) {
        precondition(maximumPendingPacketCount >= 0)
        self.maximumPendingPacketCount = maximumPendingPacketCount
    }

    // Call on the owning queue; only the returned update crosses to the processing queue.
    mutating func enqueue(_ update: EndpointStatisticsIngestUpdate) -> Action {
        guard !isPaused else {
            return .none
        }
        guard isDrainInFlight else {
            isDrainInFlight = true
            return .drain(update)
        }

        let incomingPacketCount = update.pendingPacketCountUpperBound
        if pendingUpdate == nil {
            guard incomingPacketCount <= maximumPendingPacketCount else {
                return pause()
            }
            pendingUpdate = PendingEndpointStatisticsUpdate(update: update)
        } else if let retainedPacketCount = pendingUpdate?.retainedPacketCount,
                  incomingPacketCount <= maximumPendingPacketCount - retainedPacketCount {
            guard pendingUpdate?.append(update) == true else {
                return pause()
            }
        } else {
            return pause()
        }
        guard let pendingUpdate,
              pendingUpdate.retainedPacketCount <= maximumPendingPacketCount else {
            return pause()
        }
        return .none
    }

    mutating func drainCompleted(didConsume: Bool) -> Action {
        guard isDrainInFlight else {
            return .none
        }
        if !didConsume {
            _ = pause()
        }
        if isPaused {
            pendingUpdate = nil
            isDrainInFlight = false
            return .paused
        }
        if let pendingUpdate {
            self.pendingUpdate = nil
            return .drain(pendingUpdate.makeUpdate())
        }
        isDrainInFlight = false
        return .none
    }

    // Manual Refresh supplies one latest owned replacement and explicitly resumes aggregation.
    mutating func resume(withReplacement update: EndpointStatisticsIngestUpdate) -> Action {
        guard isPaused, !isDrainInFlight, update.previousPacketRevision == nil else {
            return isPaused ? .paused : .none
        }
        pendingUpdate = nil
        isPaused = false
        isDrainInFlight = true
        return .drain(update)
    }

    mutating func cancel() {
        pendingUpdate = nil
        isPaused = false
        isDrainInFlight = false
    }

    private mutating func pause() -> Action {
        pendingUpdate = nil
        isPaused = true
        return .paused
    }
}

private extension EndpointStatisticsIngestUpdate {
    var pendingPacketCountUpperBound: Int {
        switch kind {
        case .replace(let packets), .append(let packets), .metadata(let packets):
            return packets.count
        case .appendWithMetadata(let newPackets, let updatedPackets):
            return newPackets.count + updatedPackets.count
        }
    }
}

private struct PendingEndpointStatisticsUpdate {
    private let previousPacketRevision: UInt64
    private var packetRevision: UInt64
    private let packetLineageRevision: UInt64
    private var totalPacketCount: Int
    private var newPackets: [PacketSummary]
    private var updatedPacketsByID: [PacketSummary.ID: PacketSummary]
    private var updatedPacketOrder: [PacketSummary.ID]

    var retainedPacketCount: Int {
        newPackets.count + updatedPacketsByID.count
    }

    init?(update: EndpointStatisticsIngestUpdate) {
        guard let previousPacketRevision = update.previousPacketRevision else {
            return nil
        }
        self.previousPacketRevision = previousPacketRevision
        packetRevision = update.packetRevision
        packetLineageRevision = update.packetLineageRevision
        totalPacketCount = update.totalPacketCount
        newPackets = []
        updatedPacketsByID = [:]
        updatedPacketOrder = []
        guard appendPayload(from: update.kind) else {
            return nil
        }
    }

    mutating func append(_ update: EndpointStatisticsIngestUpdate) -> Bool {
        guard update.packetLineageRevision == packetLineageRevision,
              update.previousPacketRevision == packetRevision,
              expectedTotalPacketCount(after: update.kind) == update.totalPacketCount,
              appendPayload(from: update.kind) else {
            return false
        }
        packetRevision = update.packetRevision
        totalPacketCount = update.totalPacketCount
        return true
    }

    func makeUpdate() -> EndpointStatisticsIngestUpdate {
        let updatedPackets = updatedPacketOrder.compactMap { updatedPacketsByID[$0] }
        let kind: EndpointStatisticsIngestUpdate.Kind
        if newPackets.isEmpty {
            kind = .metadata(updatedPackets)
        } else if updatedPackets.isEmpty {
            kind = .append(newPackets)
        } else {
            kind = .appendWithMetadata(newPackets: newPackets, updatedPackets: updatedPackets)
        }
        return EndpointStatisticsIngestUpdate(
            packetRevision: packetRevision,
            packetLineageRevision: packetLineageRevision,
            totalPacketCount: totalPacketCount,
            kind: kind,
            previousPacketRevision: previousPacketRevision
        )
    }

    private func expectedTotalPacketCount(after kind: EndpointStatisticsIngestUpdate.Kind) -> Int? {
        switch kind {
        case .append(let packets):
            return totalPacketCount + packets.count
        case .appendWithMetadata(let newPackets, _):
            return totalPacketCount + newPackets.count
        case .metadata:
            return totalPacketCount
        case .replace:
            return nil
        }
    }

    private mutating func appendPayload(from kind: EndpointStatisticsIngestUpdate.Kind) -> Bool {
        switch kind {
        case .append(let packets):
            newPackets.append(contentsOf: packets)
        case .appendWithMetadata(let newPackets, let updatedPackets):
            self.newPackets.append(contentsOf: newPackets)
            appendUpdatedPackets(updatedPackets)
        case .metadata(let packets):
            appendUpdatedPackets(packets)
        case .replace:
            return false
        }
        return true
    }

    private mutating func appendUpdatedPackets(_ packets: [PacketSummary]) {
        for packet in packets {
            if updatedPacketsByID.updateValue(packet, forKey: packet.id) == nil {
                updatedPacketOrder.append(packet.id)
            }
        }
    }
}
