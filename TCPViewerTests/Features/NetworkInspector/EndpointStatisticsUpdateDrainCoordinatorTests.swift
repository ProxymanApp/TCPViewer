//
//  EndpointStatisticsUpdateDrainCoordinatorTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

struct EndpointStatisticsUpdateDrainCoordinatorTests {
    @Test func sequentialDeltasCoalesceIntoOneRevisionSpanningDrain() throws {
        let service = EndpointStatisticsService()
        #expect(service.consume(Self.update(revision: 1, totalCount: 1, kind: .replace([Self.packet(id: 1)]))))
        var coordinator = EndpointStatisticsUpdateDrainCoordinator(maximumPendingPacketCount: 10)

        let firstAction = coordinator.enqueue(Self.update(
            revision: 2,
            totalCount: 2,
            kind: .append([Self.packet(id: 2)])
        ))
        let firstUpdate = try Self.drainUpdate(from: firstAction)
        #expect(service.consume(firstUpdate))

        let metadataPacket = Self.packet(id: 1, domain: "api.example")
        #expect(Self.isNone(coordinator.enqueue(Self.update(
            revision: 3,
            totalCount: 2,
            kind: .metadata([metadataPacket])
        ))))
        #expect(Self.isNone(coordinator.enqueue(Self.update(
            revision: 4,
            totalCount: 3,
            kind: .append([Self.packet(id: 3)])
        ))))

        let coalesced = try Self.drainUpdate(from: coordinator.drainCompleted(didConsume: true))
        #expect(coalesced.previousPacketRevision == 2)
        #expect(coalesced.packetRevision == 4)
        #expect(coalesced.totalPacketCount == 3)
        guard case .appendWithMetadata(let newPackets, let updatedPackets) = coalesced.kind else {
            Issue.record("Expected coalesced append and metadata payloads.")
            return
        }
        #expect(newPackets.map(\.id) == [3])
        #expect(updatedPackets.map(\.id) == [1])
        #expect(service.consume(coalesced))
        #expect(service.currentSnapshot(for: .domains).rows.first?.domain == "api.example")
        #expect(Self.isNone(coordinator.drainCompleted(didConsume: true)))
        #expect(!coordinator.isDrainInFlight)
    }

    @Test func overloadPausesWithoutRebuildLoopUntilManualReplacementResumes() throws {
        let service = EndpointStatisticsService()
        var coordinator = EndpointStatisticsUpdateDrainCoordinator(maximumPendingPacketCount: 2)
        let baseline = try Self.drainUpdate(from: coordinator.enqueue(Self.update(
            revision: 1,
            totalCount: 1,
            kind: .replace([Self.packet(id: 1)])
        )))
        #expect(service.consume(baseline))
        let oversizedPackets = (2...10_001).map { Self.packet(id: UInt64($0)) }

        #expect(Self.isPaused(coordinator.enqueue(Self.update(
            revision: 2,
            totalCount: 10_001,
            kind: .append(oversizedPackets)
        ))))
        #expect(coordinator.retainedPendingPacketCount == 0)
        #expect(coordinator.isPaused)
        #expect(Self.isPaused(coordinator.drainCompleted(didConsume: true)))

        for revision in 3...1_002 {
            #expect(Self.isNone(coordinator.enqueue(Self.update(
                revision: UInt64(revision),
                totalCount: 10_000 + revision - 1,
                kind: .append([Self.packet(id: UInt64(20_000 + revision))])
            ))))
        }
        #expect(coordinator.retainedPendingPacketCount == 0)
        #expect(service.debugSnapshot().fullRebuildCount == 1)

        let droppedPackets = (3...1_002).map { revision in
            Self.packet(id: UInt64(20_000 + revision))
        }
        let latestPackets = [Self.packet(id: 1)] + oversizedPackets + droppedPackets
        let replacement = Self.update(
            revision: 1_002,
            totalCount: latestPackets.count,
            kind: .replace(latestPackets)
        )
        let resumedUpdate = try Self.drainUpdate(from: coordinator.resume(withReplacement: replacement))
        #expect(service.consume(resumedUpdate))
        #expect(Self.isNone(coordinator.drainCompleted(didConsume: true)))
        #expect(service.debugSnapshot().fullRebuildCount == 2)
        #expect(service.currentSnapshot(for: .ipv4).footerTotals.packets == 11_001)
        #expect(!coordinator.isPaused)
        let nextAppend = try Self.drainUpdate(from: coordinator.enqueue(Self.update(
            revision: 1_003,
            totalCount: 11_002,
            kind: .append([Self.packet(id: 30_000)])
        )))
        #expect(nextAppend.totalPacketCount == 11_002)
        #expect(service.consume(nextAppend))
        #expect(Self.isNone(coordinator.drainCompleted(didConsume: true)))
        #expect(service.currentSnapshot(for: .ipv4).footerTotals.packets == 11_002)
        #expect(!coordinator.isDrainInFlight)
        #expect(coordinator.retainedPendingPacketCount == 0)
    }

    @Test func rejectedDrainDropsPendingWorkAndPauses() throws {
        var coordinator = EndpointStatisticsUpdateDrainCoordinator(maximumPendingPacketCount: 10)
        _ = try Self.drainUpdate(from: coordinator.enqueue(Self.update(
            revision: 1,
            totalCount: 1,
            kind: .replace([Self.packet(id: 1)])
        )))
        #expect(Self.isNone(coordinator.enqueue(Self.update(
            revision: 2,
            totalCount: 2,
            kind: .append([Self.packet(id: 2)])
        ))))

        #expect(Self.isPaused(coordinator.drainCompleted(didConsume: false)))
        #expect(!coordinator.isDrainInFlight)
        #expect(coordinator.isPaused)
        #expect(coordinator.retainedPendingPacketCount == 0)
    }
}

private extension EndpointStatisticsUpdateDrainCoordinatorTests {
    static func update(
        revision: UInt64,
        totalCount: Int,
        kind: EndpointStatisticsIngestUpdate.Kind
    ) -> EndpointStatisticsIngestUpdate {
        EndpointStatisticsIngestUpdate(
            packetRevision: revision,
            packetLineageRevision: 1,
            totalPacketCount: totalCount,
            kind: kind
        )
    }

    static func drainUpdate(
        from action: EndpointStatisticsUpdateDrainCoordinator.Action
    ) throws -> EndpointStatisticsIngestUpdate {
        guard case .drain(let update) = action else {
            Issue.record("Expected a drain action.")
            throw CoordinatorTestError.missingDrain
        }
        return update
    }

    static func isNone(_ action: EndpointStatisticsUpdateDrainCoordinator.Action) -> Bool {
        if case .none = action {
            return true
        }
        return false
    }

    static func isPaused(_ action: EndpointStatisticsUpdateDrainCoordinator.Action) -> Bool {
        if case .paused = action {
            return true
        }
        return false
    }

    static func packet(id: UInt64, domain: String? = nil) -> PacketSummary {
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
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: domain
        )
    }

    enum CoordinatorTestError: Error {
        case missingDrain
    }
}
