//
//  NativeLivePacketDiskSnapshotTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct NativeLivePacketDiskSnapshotTests {
    @Test func snapshotKeepsOnlyTheIndexedStreamAndSurvivesStoreReset() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11), streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7))
        try store.append(makeRecord(identifier: 2, byte: 0x22), streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 8))
        try store.append(makeRecord(identifier: 3, byte: 0x33), streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7))

        let snapshot = try store.snapshotForStream(containing: 1, maximumPacketCount: 2)
        store.reset()
        let records = try snapshot.records(maximumBytes: 2)

        #expect(records.map(\.identifier) == [1, 3])
        #expect(records.map(\.rawBytes) == [Data([0x11]), Data([0x33])])
        #expect(snapshot.capturedThroughPacketID == 3)
    }

    @Test func snapshotEnforcesPacketAndByteBounds() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11), streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7))
        try store.append(makeRecord(identifier: 2, byte: 0x22), streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7))

        #expect(throws: NSError.self) {
            try store.snapshotForStream(containing: 1, maximumPacketCount: 1)
        }
        let snapshot = try store.snapshotForStream(containing: 1, maximumPacketCount: 2)
        #expect(throws: NSError.self) {
            try snapshot.records(maximumBytes: 1)
        }
        #expect(throws: NSError.self) {
            try snapshot.records(maximumBytes: 2, shouldCancel: { true })
        }
        #expect(throws: NSError.self) {
            try store.snapshotForStream(
                containing: 1,
                maximumPacketCount: 2,
                shouldCancel: { true }
            )
        }
    }

    @Test func snapshotExcludesPacketsUntilTheirStreamIsReady() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11))

        #expect(throws: NSError.self) {
            try store.snapshotForStream(containing: 1, maximumPacketCount: 1)
        }

        store.markStreamReady(identifier: 1, streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7))
        let snapshot = try store.snapshotForStream(containing: 1, maximumPacketCount: 1)
        #expect(try snapshot.records(maximumBytes: 1).map(\.identifier) == [1])
    }

    @Test func streamIndexUpdatesBuildTheSnapshotChainInCaptureOrder() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11))
        try store.append(makeRecord(identifier: 2, byte: 0x22))
        try store.append(makeRecord(identifier: 3, byte: 0x33))

        store.markStreamsReady([
            WiresharkStreamIndexEntry(packetIdentifier: 3, streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7)),
            WiresharkStreamIndexEntry(packetIdentifier: 1, streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7)),
            WiresharkStreamIndexEntry(packetIdentifier: 2, streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 7)),
        ])

        let snapshot = try store.snapshotForStream(containing: 2, maximumPacketCount: 3)
        #expect(try snapshot.records(maximumBytes: 3).map(\.identifier) == [1, 2, 3])
    }

    @Test func recordReplayVisitsDiskPayloadsOneAtATimeInCaptureOrder() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11))
        try store.append(makeRecord(identifier: 2, byte: 0x22))
        try store.append(makeRecord(identifier: 3, byte: 0x33))
        var visited: [(UInt64, Data)] = []

        try store.forEachRecord { record in
            visited.append((record.identifier, record.rawBytes))
        }

        #expect(visited.map(\.0) == [1, 2, 3])
        #expect(visited.map(\.1) == [Data([0x11]), Data([0x22]), Data([0x33])])
    }

    @Test func snapshotsSeparateTCPAndUDPWithTheSameStreamNumber() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 1), streamIdentifier: FollowStreamID(streamProtocol: .tcp, streamID: 0))
        try store.append(makeRecord(identifier: 2, byte: 2), streamIdentifier: FollowStreamID(streamProtocol: .udp, streamID: 0))
        try store.append(makeRecord(identifier: 3, byte: 3), streamIdentifier: FollowStreamID(streamProtocol: .udp, streamID: 0))
        let snapshot = try store.snapshotForStream(containing: 2, maximumPacketCount: 10)
        #expect(try snapshot.records(maximumBytes: 100).map(\.identifier) == [2, 3])
    }

    private func makeRecord(identifier: UInt64, byte: UInt8) -> NativePacketRecord {
        NativePacketRecord(
            identifier: identifier,
            packetNumber: identifier,
            timestamp: Date(timeIntervalSince1970: TimeInterval(identifier)),
            rawBytes: Data([byte]),
            originalLength: 1,
            linkLayerType: Libpcap.dltEthernet,
            interfaceIdentifier: "test0",
            interfaceName: "test0",
            packetComment: nil
        )
    }
}
