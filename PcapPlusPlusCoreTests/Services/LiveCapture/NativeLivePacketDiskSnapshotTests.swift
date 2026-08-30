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
        try store.append(makeRecord(identifier: 1, byte: 0x11), tcpStreamIdentifier: 7)
        try store.append(makeRecord(identifier: 2, byte: 0x22), tcpStreamIdentifier: 8)
        try store.append(makeRecord(identifier: 3, byte: 0x33), tcpStreamIdentifier: 7)

        let snapshot = try store.snapshotForTCPStream(containing: 1, maximumPacketCount: 2)
        store.reset()
        let records = try snapshot.records(maximumBytes: 2)

        #expect(records.map(\.identifier) == [1, 3])
        #expect(records.map(\.rawBytes) == [Data([0x11]), Data([0x33])])
        #expect(snapshot.capturedThroughPacketID == 3)
    }

    @Test func snapshotEnforcesPacketAndByteBounds() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11), tcpStreamIdentifier: 7)
        try store.append(makeRecord(identifier: 2, byte: 0x22), tcpStreamIdentifier: 7)

        #expect(throws: NSError.self) {
            try store.snapshotForTCPStream(containing: 1, maximumPacketCount: 1)
        }
        let snapshot = try store.snapshotForTCPStream(containing: 1, maximumPacketCount: 2)
        #expect(throws: NSError.self) {
            try snapshot.records(maximumBytes: 1)
        }
        #expect(throws: NSError.self) {
            try snapshot.records(maximumBytes: 2, shouldCancel: { true })
        }
        #expect(throws: NSError.self) {
            try store.snapshotForTCPStream(
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
            try store.snapshotForTCPStream(containing: 1, maximumPacketCount: 1)
        }

        store.markTCPStreamReady(identifier: 1, streamIdentifier: 7)
        let snapshot = try store.snapshotForTCPStream(containing: 1, maximumPacketCount: 1)
        #expect(try snapshot.records(maximumBytes: 1).map(\.identifier) == [1])
    }

    @Test func streamIndexUpdatesBuildTheSnapshotChainInCaptureOrder() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11))
        try store.append(makeRecord(identifier: 2, byte: 0x22))
        try store.append(makeRecord(identifier: 3, byte: 0x33))

        store.markTCPStreamsReady([
            WiresharkTCPStreamIndexEntry(packetIdentifier: 3, streamIdentifier: 7),
            WiresharkTCPStreamIndexEntry(packetIdentifier: 1, streamIdentifier: 7),
            WiresharkTCPStreamIndexEntry(packetIdentifier: 2, streamIdentifier: 7),
        ])

        let snapshot = try store.snapshotForTCPStream(containing: 2, maximumPacketCount: 3)
        #expect(try snapshot.records(maximumBytes: 3).map(\.identifier) == [1, 2, 3])
    }

    @Test func fullSnapshotReplaysFromDiskWithoutBuildingARecordArray() throws {
        let store = NativeLivePacketDiskStore()
        try store.append(makeRecord(identifier: 1, byte: 0x11))
        try store.append(makeRecord(identifier: 2, byte: 0x22))
        try store.append(makeRecord(identifier: 3, byte: 0x33))

        let snapshot = try store.snapshotAll()
        store.reset()
        var identifiers: [UInt64] = []
        try snapshot.replayRecords { record in
            identifiers.append(record.identifier)
            return identifiers.count < 2
        }

        #expect(snapshot.packetCount == 3)
        #expect(try snapshot.record(withIdentifier: 3).rawBytes == Data([0x33]))
        #expect(identifiers == [1, 2])
        #expect(throws: NSError.self) {
            try snapshot.replayRecords(shouldCancel: { true }) { _ in true }
        }
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
