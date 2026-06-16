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

    @Test func localEndpointAddressesClassifyTrafficWithoutDirectionMetadata() {
        let clock = ManualClock()
        let service = makeService(clock: clock, localAddresses: ["10.0.0.2", "fe80::1%en0"])
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(
                packetNumber: 1,
                direction: nil,
                originalLength: 2_048,
                sourceAddress: "93.184.216.34",
                destinationAddress: "10.0.0.2"
            ),
            makePacket(
                packetNumber: 2,
                direction: nil,
                originalLength: 1_024,
                sourceAddress: "[fe80::1]",
                destinationAddress: "2606:2800:220:1:248:1893:25c8:1946"
            ),
        ])

        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 512)
        #expect(snapshot.downloadBytesPerSecond == 1_024)
    }

    @Test func localEndpointClassificationDoesNotDoubleCountDirectionBackfill() {
        let clock = ManualClock()
        let service = makeService(clock: clock, localAddresses: ["10.0.0.2"])
        service.sampleNow(notifiesHandler: false)
        var ingestState = liveIngestState([
            makePacket(
                packetNumber: 1,
                direction: nil,
                originalLength: 200,
                sourceAddress: "10.0.0.2",
                destinationAddress: "93.184.216.34"
            ),
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

    @Test func disabledMonitoringDoesNotAccumulateCapturedTraffic() {
        let clock = ManualClock()
        let service = makeService(clock: clock, monitoredInterfaceID: nil)
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(!service.isMonitoring)
        #expect(snapshot.uploadBytesPerSecond == 0)
        #expect(snapshot.downloadBytesPerSecond == 0)
    }

    @Test func monitoringOnlyCountsTheSelectedInterface() {
        let clock = ManualClock()
        let service = makeService(clock: clock, monitoredInterfaceID: "en0")
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 200, interfaceID: "en1"),
            makePacket(packetNumber: 2, direction: .inbound, originalLength: 80, interfaceID: "en0"),
        ])

        service.recordPacketIngestState(ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(snapshot.uploadBytesPerSecond == 0)
        #expect(snapshot.downloadBytesPerSecond == 40)
    }

    @Test func disablingNetworkMonitoringKeepsTimerAndClearsPendingNetworkSpeed() {
        let clock = ManualClock()
        let service = makeService(clock: clock, startsTimer: true)
        service.sampleNow(notifiesHandler: false)
        let ingestState = liveIngestState([
            makePacket(packetNumber: 1, direction: .outbound, originalLength: 200),
        ])

        service.recordPacketIngestState(ingestState)
        service.updateMonitoring(interfaceID: nil, baselineIngestState: ingestState)
        clock.advance(by: 2)
        let snapshot = service.sampleNow(notifiesHandler: false)

        #expect(!service.isMonitoring)
        #expect(service.isSampling)
        #expect(snapshot.memoryBytes == 323 * 1_024 * 1_024)
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

    private func makeService(
        clock: ManualClock,
        memoryBytes: UInt64 = 323 * 1_024 * 1_024,
        monitoredInterfaceID: String? = "en0",
        localAddresses: Set<String> = [],
        startsTimer: Bool = false
    ) -> TCPViewerStatusMetricsService {
        let service = TCPViewerStatusMetricsService(
            memorySampler: { memoryBytes },
            dateProvider: clock.now,
            callbackQueue: DispatchQueue(label: "com.proxyman.tcpviewer.StatusMetricsTests.callback")
        )
        if let monitoredInterfaceID {
            service.updateMonitoring(
                interfaceID: monitoredInterfaceID,
                localAddresses: localAddresses,
                baselineIngestState: .empty,
                startsTimer: startsTimer
            )
        }
        return service
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
        originalLength: Int,
        interfaceID: String = "en0",
        sourceAddress: String = "10.0.0.1",
        destinationAddress: String = "10.0.0.2"
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .live,
            interfaceID: interfaceID,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: 1234),
                destination: PacketEndpoint(address: destinationAddress, port: 443)
            ),
            originalLength: originalLength,
            capturedLength: originalLength,
            streamID: UInt32(packetNumber),
            direction: direction,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false, interfaceName: interfaceID)
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
