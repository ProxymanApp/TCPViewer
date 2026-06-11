//
//  TCPViewerStatusMetricsServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 11/6/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

struct TCPViewerStatusMetricsServiceTests {
    @Test func capturedTrafficUsesOutboundForUploadAndInboundForDownload() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 200),
            makePacket(packetNumber: 2, direction: .inbound, originalLength: 80),
        ])

        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 100)
        #expect(snapshot.downloadBytesPerSecond == 40)
    }

    @Test func capturedTrafficDoesNotDoubleCountUnchangedPacketRevision() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 100)
        #expect(snapshot.downloadBytesPerSecond == 0)
    }

    @Test func metadataDirectionBackfillCountsPreviouslyUncountedPacket() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        var ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: nil, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        ingestState.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [1],
                sniDomainName: nil,
                client: nil,
                direction: .outbound
            ),
        ])
        service.recordPacketIngestState(ingestState)
        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 100)
        #expect(snapshot.downloadBytesPerSecond == 0)
    }

    @Test func appendWithMetadataUpdatesCountsAppendedPacketsAndDirectionBackfills() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        var ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: nil, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        ingestState.appendAndApplyMetadataUpdates(
            [makePacket(packetNumber: 2, direction: .inbound, originalLength: 80)],
            metadataUpdates: [
                PacketMetadataUpdate(
                    packetIDs: [1],
                    sniDomainName: nil,
                    client: nil,
                    direction: .outbound
                ),
            ],
            source: .live
        )
        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 100)
        #expect(snapshot.downloadBytesPerSecond == 40)
    }

    @Test func metadataUpdateDoesNotDoubleCountPacketsAlreadyCountedOnAppend() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        var ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        ingestState.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [1],
                sniDomainName: "example.com",
                client: nil,
                direction: .outbound
            ),
        ])
        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 100)
        #expect(snapshot.downloadBytesPerSecond == 0)
    }

    @Test func resetClearsPendingNetworkSpeed() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        var ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 200),
            makePacket(packetNumber: 2, direction: .inbound, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        ingestState.reset(source: .live, message: "Cleared.")
        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 0)
        #expect(snapshot.downloadBytesPerSecond == 0)
    }

    @Test func localUnknownAndMissingDirectionsDoNotAffectSpeed() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .local, originalLength: 200),
            makePacket(packetNumber: 2, direction: .unknown, originalLength: 200),
            makePacket(packetNumber: 3, direction: nil, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 0)
        #expect(snapshot.downloadBytesPerSecond == 0)
    }

    @Test func bytesPerSecondRoundsUpAcrossSampleInterval() {
        let clock = ManualClock()
        let service = makeService(clock: clock)
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 201),
            makePacket(packetNumber: 2, direction: .inbound, originalLength: 1),
        ])

        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 101)
        #expect(snapshot.downloadBytesPerSecond == 1)
    }

    @Test func formatterUsesFriendlyRoundedUnits() {
        #expect(TCPViewerStatusMetricsFormatter.speedText(bytesPerSecond: 0) == "0 KB/s")
        #expect(TCPViewerStatusMetricsFormatter.speedText(bytesPerSecond: 1) == "1 KB/s")
        #expect(TCPViewerStatusMetricsFormatter.speedText(bytesPerSecond: 1_025) == "2 KB/s")
        #expect(TCPViewerStatusMetricsFormatter.speedText(bytesPerSecond: 1_048_577) == "2 MB/s")
        #expect(TCPViewerStatusMetricsFormatter.memoryText(bytes: 323 * 1_024 * 1_024 + 1) == "324 MB")
        #expect(TCPViewerStatusMetricsFormatter.memoryText(bytes: 1_024 * 1_024 * 1_024 + 1) == "2 GB")
    }

    private func makeService(clock: ManualClock, memoryBytes: UInt64 = 323 * 1_024 * 1_024) -> TCPViewerStatusMetricsService {
        TCPViewerStatusMetricsService(
            memorySampler: { memoryBytes },
            dateProvider: clock.now,
            callbackQueue: DispatchQueue(label: "com.proxyman.tcpviewer.StatusMetricsTests.callback")
        )
    }

    private func liveIngestState(_ packets: [PacketSummary]) -> PacketIngestState {
        var state = PacketIngestState.empty
        state.reset(source: .live, message: "Starting.")
        state.append(packets, source: .live, message: "Captured.")
        return state
    }

    private func makePacket(
        packetNumber: UInt64,
        direction: PacketDirection?,
        originalLength: Int
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: originalLength,
            capturedLength: originalLength,
            streamID: UInt32(packetNumber),
            direction: direction,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false, interfaceName: "en0")
        )
    }
}

private final class ManualClock {
    private var date = Date(timeIntervalSince1970: 0)

    func now() -> Date {
        date
    }

    func advance(by seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}
