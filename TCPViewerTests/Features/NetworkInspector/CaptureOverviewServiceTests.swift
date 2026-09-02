//
//  CaptureOverviewServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct CaptureOverviewServiceTests {
    @Test func duplicateAppsAndDomainsUseLocalDirectionAndOriginalLength() throws {
        let client = makeClient(name: "Browser", bundleIdentifier: "com.example.browser")
        let packets = [
            makePacket(id: 1, length: 200, direction: .outbound, domain: "Example.COM.", client: client),
            makePacket(id: 2, length: 100, direction: .inbound, domain: "example.com", client: client),
            makePacket(
                id: 3,
                length: 50,
                direction: .unknown,
                domain: " EXAMPLE.COM ",
                client: client,
                decodeStatus: PacketDecodeStatus(kind: .malformed)
            ),
        ]

        let snapshot = replacementSnapshot(packets)
        let app = try #require(snapshot.topApps.first)
        let domain = try #require(snapshot.topDomains.first)

        #expect(snapshot.totals.packets == 3)
        #expect(snapshot.totals.bytes == 350)
        #expect(snapshot.totals.sentBytes == 200)
        #expect(snapshot.totals.receivedBytes == 100)
        #expect(snapshot.totals.unclassifiedBytes == 50)
        #expect(snapshot.malformedPacketCount == 1)
        #expect(snapshot.appCount == 1)
        #expect(snapshot.domainCount == 1)
        #expect(app.selection == .app(PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.browser")))
        #expect(domain.selection == .domain(PacketSourceDomainKey(rawValue: "example.com", isMissingDomain: false)))
        #expect(app.totals == snapshot.totals)
        #expect(domain.totals == snapshot.totals)
    }

    @Test func metadataReclassificationRemovesThePreviousContribution() throws {
        let oldClient = makeClient(name: "Old App", bundleIdentifier: "com.example.old")
        let newClient = makeClient(name: "New App", bundleIdentifier: "com.example.new")
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk([
            makePacket(id: 1, length: 128, direction: .outbound, domain: "old.example", client: oldClient),
        ])
        let didFinishInitialReplacement = accumulator.finishReplacement(cursor: cursor(revision: 1, count: 1))
        #expect(didFinishInitialReplacement)

        let updatedPacket = makePacket(
            id: 1,
            length: 128,
            direction: .inbound,
            domain: "new.example",
            client: newClient
        )
        let didConsumeMetadata = accumulator.consume(EndpointStatisticsIngestUpdate(
            packetRevision: 2,
            packetLineageRevision: 1,
            totalPacketCount: 1,
            kind: .metadata([updatedPacket]),
            previousPacketRevision: 1
        ))
        #expect(didConsumeMetadata)

        let snapshot = accumulator.snapshot()
        #expect(snapshot.appCount == 1)
        #expect(snapshot.domainCount == 1)
        #expect(snapshot.topApps.map(\.title) == ["New App"])
        #expect(snapshot.topDomains.map(\.title) == ["new.example"])
        #expect(snapshot.totals.sentBytes == 0)
        #expect(snapshot.totals.receivedBytes == 128)
        #expect(snapshot.totals.bytes == 128)
    }

    @Test func resetDropsThePreviousCaptureLineage() {
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk([makePacket(id: 1, domain: "old.example")])
        let didFinishOldReplacement = accumulator.finishReplacement(cursor: cursor(revision: 1, count: 1))
        #expect(didFinishOldReplacement)

        accumulator.reset()
        accumulator.appendReplacementChunk([makePacket(id: 2, length: 512, domain: "new.example")])
        let didFinishNewReplacement = accumulator.finishReplacement(cursor: cursor(revision: 1, lineage: 2, count: 1))
        #expect(didFinishNewReplacement)

        let snapshot = accumulator.snapshot()
        #expect(snapshot.totals.packets == 1)
        #expect(snapshot.totals.bytes == 512)
        #expect(snapshot.topDomains.map(\.title) == ["new.example"])
    }

    @Test func topRowsAreBoundedAndUseStableTieOrdering() {
        let tiedPackets = [
            makePacket(id: 1, length: 50, domain: "gamma.example"),
            makePacket(id: 2, length: 50, domain: "gamma.example"),
            makePacket(id: 3, length: 100, domain: "beta.example"),
            makePacket(id: 4, length: 100, domain: "alpha.example"),
        ]
        let extraPackets = (0..<8).map { index in
            makePacket(id: UInt64(index + 10), length: 10 - index, domain: "extra-\(index).example")
        }

        let snapshot = replacementSnapshot(tiedPackets + extraPackets)

        #expect(snapshot.topDomains.count == CaptureOverviewAccumulator.maximumTopRowCount)
        #expect(snapshot.topDomains.prefix(3).map(\.title) == [
            "gamma.example",
            "alpha.example",
            "beta.example",
        ])
    }

    @Test func protocolTotalsAndRenderedTimelineStayBounded() {
        let hints: [TransportProtocolHint] = [.tcp, .udp, .dns, .tls, .http1, .arp, .icmp]
        var packets = hints.enumerated().map { index, hint in
            makePacket(id: UInt64(index + 1), length: (index + 1) * 10, transportHint: hint)
        }
        packets += (0..<2_000).map { index in
            makePacket(
                id: UInt64(index + 100),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                transportHint: .tcp
            )
        }

        let snapshot = replacementSnapshot(packets)
        let protocolBytes = snapshot.protocols.reduce(UInt64(0)) { $0 + $1.totals.bytes }

        #expect(snapshot.protocols.count == CaptureOverviewAccumulator.maximumProtocolRowCount + 1)
        #expect(snapshot.protocols.last?.title == "Other")
        #expect(protocolBytes == snapshot.totals.bytes)
        #expect(snapshot.timeline.count <= CaptureOverviewAccumulator.maximumRenderedTimelinePointCount)
    }

    @MainActor
    @Test func livePublishingIsThrottledToOneSnapshotPerInterval() async throws {
        var state = PacketIngestState.empty
        state.append([makePacket(id: 1)], source: .live)
        let service = CaptureOverviewService(latestIngestStateProvider: { state })
        var snapshots: [CaptureOverviewSnapshot] = []
        service.snapshotHandler = { snapshots.append($0) }
        service.consume(state)
        try await waitUntil { snapshots.count == 1 }

        for id in 2...24 {
            state.append([makePacket(id: UInt64(id))], source: .live)
            service.consume(state)
        }
        try await waitUntil(timeout: 2) { snapshots.last?.totals.packets == 24 }

        #expect(snapshots.count == 2)
        service.cancel()
    }

    @MainActor
    @Test func backingIdentityChangeRebuildsEvenWhenTheCursorValuesMatch() async throws {
        var state = PacketIngestState.empty
        state.backingIdentity = "capture-a"
        state.append([makePacket(id: 1, domain: "old.example")], source: .live)
        let service = CaptureOverviewService(latestIngestStateProvider: { state })
        var latestSnapshot = CaptureOverviewSnapshot.empty
        service.snapshotHandler = { latestSnapshot = $0 }
        service.consume(state)
        try await waitUntil { latestSnapshot.topDomains.first?.title == "old.example" }

        var replacement = PacketIngestState.empty
        replacement.backingIdentity = "capture-b"
        replacement.append([makePacket(id: 2, domain: "new.example")], source: .live)
        #expect(replacement.packetRevision == state.packetRevision)
        #expect(replacement.packetLineageRevision == state.packetLineageRevision)
        state = replacement
        service.consume(state)
        try await waitUntil(timeout: 2) { latestSnapshot.topDomains.first?.title == "new.example" }

        #expect(latestSnapshot.totals.packets == 1)
        service.cancel()
    }

    private func replacementSnapshot(_ packets: [PacketSummary]) -> CaptureOverviewSnapshot {
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk(packets)
        let didFinish = accumulator.finishReplacement(cursor: cursor(revision: 1, count: packets.count))
        #expect(didFinish)
        return accumulator.snapshot()
    }

    private func cursor(revision: UInt64, lineage: UInt64 = 1, count: Int) -> EndpointStatisticsIngestCursor {
        EndpointStatisticsIngestCursor(
            packetRevision: revision,
            packetLineageRevision: lineage,
            totalPacketCount: count
        )
    }

    private func makePacket(
        id: UInt64,
        length: Int = 128,
        timestamp: Date? = nil,
        direction: PacketDirection? = .outbound,
        domain: String? = nil,
        client: PacketClient? = nil,
        transportHint: TransportProtocolHint = .tcp,
        decodeStatus: PacketDecodeStatus = PacketDecodeStatus(kind: .complete)
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: id,
            timestamp: timestamp ?? Date(timeIntervalSince1970: TimeInterval(id)),
            source: .live,
            interfaceID: "en0",
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.2", port: 51_000),
                destination: PacketEndpoint(address: "93.184.216.34", port: 443)
            ),
            originalLength: length,
            capturedLength: min(length, 64),
            direction: direction,
            infoSummary: "Packet \(id)",
            layers: [PacketLayer(name: transportHint.rawValue.uppercased())],
            decodeStatus: decodeStatus,
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: domain,
            client: client
        )
    }

    private func makeClient(name: String, bundleIdentifier: String) -> PacketClient {
        PacketClient(
            pid: 123,
            name: name,
            displayName: name,
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            bundleIdentifier: bundleIdentifier,
            bundlePath: "/Applications/\(name).app"
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}
