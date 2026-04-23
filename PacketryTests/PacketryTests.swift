import Foundation
import Testing
import PcapPlusPlusCore
@testable import Packetry

struct PacketryTests {

    @Test func packetIngestStateTracksTotalsTruncationAndDecodeIssues() {
        var ingestState = PacketIngestState.empty
        let packets = [
            PacketSummary(
                packetNumber: 1,
                timestamp: .now,
                source: .offline,
                transportHint: .tcp,
                endpoints: PacketEndpoints(
                    source: PacketEndpoint(address: "10.0.0.1", port: 1111),
                    destination: PacketEndpoint(address: "10.0.0.2", port: 80)
                ),
                originalLength: 128,
                capturedLength: 64,
                infoSummary: "Truncated packet",
                layers: [PacketLayer(name: "TCP")],
                decodeStatus: PacketDecodeStatus(kind: .partial),
                captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: true)
            ),
            PacketSummary(
                packetNumber: 2,
                timestamp: .now,
                source: .offline,
                transportHint: .udp,
                endpoints: PacketEndpoints(
                    source: PacketEndpoint(address: "10.0.0.3", port: 2222),
                    destination: PacketEndpoint(address: "10.0.0.4", port: 53)
                ),
                originalLength: 96,
                capturedLength: 96,
                infoSummary: "Healthy packet",
                layers: [PacketLayer(name: "UDP")],
                decodeStatus: PacketDecodeStatus(kind: .complete),
                captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
            ),
        ]

        ingestState.replace(with: packets, source: .offline, message: "Loaded fixture packets.")

        #expect(ingestState.totalPacketCount == 2)
        #expect(ingestState.lastBatchCount == 2)
        #expect(ingestState.truncatedPacketCount == 1)
        #expect(ingestState.decodeIssueCount == 1)
        #expect(ingestState.statusMessage == "Loaded fixture packets.")
    }

    @Test func windowSnapshotVisiblePacketCountMirrorsNavigationState() {
        var snapshot = PacketryWindowSnapshot.foundation
        let packet = PacketSummary(
            packetNumber: 1,
            timestamp: .now,
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 5000),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 64,
            capturedLength: 64,
            infoSummary: "Live packet",
            layers: [PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
        snapshot.packetIngestState.append([packet], source: .live)
        snapshot.navigationState.visiblePackets = [packet]

        #expect(snapshot.visiblePacketCount == 1)
        #expect(snapshot.packetIngestState.source == .live)
    }
}
