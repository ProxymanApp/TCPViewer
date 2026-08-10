//
//  TCPFollowStreamViewModelTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPFollowStreamViewModelTests {
    @MainActor
    @Test func rendersDirectionsPacketRangesAndTextControls() throws {
        let viewModel = TCPFollowStreamViewModel()
        viewModel.setStream(makeStream())

        let content = viewModel.renderedContent()

        #expect(content.plainText.contains("Client to Server · Packet 10"))
        #expect(content.plainText.contains("Server to Client · Packet 11"))
        #expect(content.plainText.contains("hello·\n"))
        #expect(content.displayedByteCount == 11)
        #expect(content.packetRanges.map(\.packetID) == [10, 11])
        for packetRange in content.packetRanges {
            #expect(NSMaxRange(packetRange.range) <= content.attributedText.length)
        }
    }

    @MainActor
    @Test func switchesDirectionAndHexWithoutChangingRawExports() {
        let viewModel = TCPFollowStreamViewModel()
        viewModel.setStream(makeStream())
        viewModel.setDirectionFilter(.serverToClient)
        viewModel.setRepresentation(.hex)

        let content = viewModel.renderedContent()

        #expect(!content.plainText.contains("Client to Server"))
        #expect(content.plainText.contains("Server to Client"))
        #expect(content.plainText.contains("77 6f 72 6c 64"))
        #expect(content.displayedByteCount == 5)
        #expect(viewModel.rawData(for: .clientToServer) == Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00]))
        #expect(viewModel.rawData(for: .serverToClient) == Data("world".utf8))
    }

    @MainActor
    @Test func boundsDisplayedPayloadWithoutLimitingRawExport() {
        let viewModel = TCPFollowStreamViewModel(
            maximumDisplayedPayloadBytes: 4,
            maximumDisplayedRecordCount: 10
        )
        viewModel.setStream(makeStream())

        let content = viewModel.renderedContent()

        #expect(content.displayedByteCount == 4)
        #expect(content.statusText.contains("4 of 11 bytes shown"))
        #expect(content.statusText.contains("display limited for responsiveness"))
        #expect(viewModel.rawData(for: .clientToServer).count == 6)
        #expect(viewModel.rawData(for: .serverToClient).count == 5)
    }

    private func makeStream() -> TCPFollowStream {
        TCPFollowStream(
            client: PacketEndpoint(address: "192.0.2.1", port: 50_000),
            server: PacketEndpoint(address: "198.51.100.2", port: 443),
            records: [
                TCPFollowRecord(
                    direction: .clientToServer,
                    packetID: 10,
                    timestamp: Date(timeIntervalSince1970: 10),
                    sequenceNumber: 100,
                    data: Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00])
                ),
                TCPFollowRecord(
                    direction: .serverToClient,
                    packetID: 11,
                    timestamp: Date(timeIntervalSince1970: 11),
                    sequenceNumber: 200,
                    data: Data("world".utf8)
                ),
            ],
            clientByteCount: 6,
            serverByteCount: 5,
            capturedThroughPacketID: 12,
            capturedAt: Date(timeIntervalSince1970: 12),
            isTruncated: false
        )
    }
}
