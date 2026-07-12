//
//  WiresharkSessionCoordinationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkSessionCoordinationTests {
    @Test func offlineSessionsTransferOwnershipWithoutReplay() throws {
        let firstSession = try WiresharkEpanSession()
        let secondSession = try WiresharkEpanSession()
        let firstRecord = makeRecord(identifier: 1)
        let secondRecord = makeRecord(identifier: 2)

        try firstSession.observe(firstRecord)
        #expect(try firstSession.summarize(firstRecord).infoSummary.isEmpty == false)

        try secondSession.observe(secondRecord)
        #expect(try secondSession.summarize(secondRecord).infoSummary.isEmpty == false)
        // An explicit operation transfers ownership and rebuilds only the requested session state.
        #expect(try firstSession.summarize(firstRecord).infoSummary.isEmpty == false)
        #expect(try secondSession.summarize(secondRecord).infoSummary.isEmpty == false)
    }

    @Test func liveSessionPreemptsOfflineSessionWithoutReplay() throws {
        let offlineSession = try WiresharkEpanSession()
        let offlineRecord = makeRecord(identifier: 1)
        try offlineSession.observe(offlineRecord)

        let liveSession = try WiresharkEpanSession(purpose: .live)
        let liveRecord = makeRecord(identifier: 2)
        try liveSession.observe(liveRecord)
        #expect(try liveSession.summarize(liveRecord).infoSummary.isEmpty == false)

        #expect(throws: NSError.self) {
            try offlineSession.summarize(offlineRecord)
        }
    }

    @Test func inspectorCapsRawHexForLargeProtocolRanges() throws {
        let session = try WiresharkEpanSession()
        var bytes = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
            0x88, 0xb5,
        ])
        bytes.append(Data(repeating: 0xab, count: 64 * 1024))
        let record = NativePacketRecord(
            identifier: 1,
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            rawBytes: bytes,
            originalLength: bytes.count,
            linkLayerType: Libpcap.dltEthernet,
            interfaceIdentifier: "test0",
            interfaceName: "test0",
            packetComment: nil
        )

        try session.observe(record)
        let inspection = try session.inspect(record)
        let rawValues = flatten(inspection.detailNodes).compactMap(\.rawValue)

        #expect(!rawValues.isEmpty)
        #expect(rawValues.allSatisfy { $0.utf8.count <= 12_320 })
    }

    private func makeRecord(identifier: UInt64) -> NativePacketRecord {
        NativePacketRecord(
            identifier: identifier,
            packetNumber: identifier,
            timestamp: Date(timeIntervalSince1970: TimeInterval(identifier)),
            rawBytes: Data([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
                0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
                0x08, 0x00,
                0x45, 0x00, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00,
                0x40, 0x11, 0x00, 0x00, 192, 168, 0, 1, 192, 168, 0, 2,
                0x14, 0xe9, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00,
            ]),
            originalLength: 42,
            linkLayerType: Libpcap.dltEthernet,
            interfaceIdentifier: "test0",
            interfaceName: "test0",
            packetComment: nil
        )
    }

    private func flatten(_ nodes: [PCPPNativePacketDetailNodeDescriptor]) -> [PCPPNativePacketDetailNodeDescriptor] {
        nodes + nodes.flatMap { flatten($0.children) }
    }
}
