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

    @Test func packetIngestStateUpdatesAppendCountersFromNewBatchesOnly() {
        var ingestState = PacketIngestState.empty
        let healthy = PacketSummary(
            packetNumber: 1,
            timestamp: .now,
            source: .live,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1111),
                destination: PacketEndpoint(address: "10.0.0.2", port: 80)
            ),
            originalLength: 128,
            capturedLength: 128,
            infoSummary: "Healthy packet",
            layers: [PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
        let truncated = PacketSummary(
            packetNumber: 2,
            timestamp: .now,
            source: .live,
            transportHint: .udp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.3", port: 2222),
                destination: PacketEndpoint(address: "10.0.0.4", port: 53)
            ),
            originalLength: 256,
            capturedLength: 64,
            infoSummary: "Truncated packet",
            layers: [PacketLayer(name: "UDP")],
            decodeStatus: PacketDecodeStatus(kind: .partial),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: true)
        )
        let malformed = PacketSummary(
            packetNumber: 3,
            timestamp: .now,
            source: .live,
            transportHint: .payload,
            endpoints: PacketEndpoints(source: PacketEndpoint(address: nil), destination: PacketEndpoint(address: nil)),
            originalLength: 96,
            capturedLength: 96,
            infoSummary: "Malformed packet",
            layers: [PacketLayer(name: "Payload")],
            decodeStatus: PacketDecodeStatus(kind: .malformed, reason: "Bad length"),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )

        ingestState.append([healthy], source: .live)
        #expect(ingestState.totalPacketCount == 1)
        #expect(ingestState.lastMutation == .append(0..<1))
        #expect(ingestState.truncatedPacketCount == 0)
        #expect(ingestState.decodeIssueCount == 0)

        ingestState.append([truncated, malformed], source: .live)
        #expect(ingestState.totalPacketCount == 3)
        #expect(ingestState.lastMutation == .append(1..<3))
        #expect(ingestState.truncatedPacketCount == 1)
        #expect(ingestState.decodeIssueCount == 2)
    }

}
