//
//  PacketTableRowNativeSummaryLifetimeTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 27/5/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore
@testable import TCPViewer

#if DEBUG
struct PacketTableRowNativeSummaryLifetimeTests {
    @Test func liveNativeSummariesProduceRowsThatSurviveNativeStoreCleanup() throws {
        let rows = try makeRowsAfterNativeStoreCleanup(packetCount: 4)

        // Force PacketTableRow value copies after the native packet store is gone.
        var copiedRows: [PacketTableRow] = []
        copiedRows.reserveCapacity(rows.count)
        for row in rows {
            copiedRows.append(row)
        }

        #expect(copiedRows.count == 4)
        #expect(copiedRows.allSatisfy { $0.sourceText.contains("192.168.0.1") })
        #expect(copiedRows.allSatisfy { $0.destinationText.contains("192.168.0.2") })
        #expect(copiedRows.allSatisfy { !$0.protocolText.isEmpty })
        #expect(copiedRows.allSatisfy { !$0.summaryText.isEmpty })

        // Raw passthrough fields hold native-layer-backed strings; they must survive the native
        // store teardown just like the formatted ones (this is the field that crashed when rows
        // kept a dangling NSString backing).
        #expect(copiedRows.allSatisfy { $0.sourceAddress == "192.168.0.1" })
        #expect(copiedRows.allSatisfy { $0.destinationAddress == "192.168.0.2" })
    }

    @Test func liveNativeSummaryRowsSurviveTableStoreAndCopyFormattingAfterNativeStoreCleanup() throws {
        let rows = try makeRowsAfterNativeStoreCleanup(packetCount: 3)
        let visibleIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, index)
        })
        let store = PacketTableRowStore(rows: rows, visiblePacketRowIndexByID: visibleIndex)

        let copiedRows = Array(store.rows)
        let rowSet = Set(copiedRows)
        let csv = PacketTableCopyFormatter.rows(copiedRows, format: .csvWithHeader)
        let json = PacketTableCopyFormatter.rows(copiedRows, format: .json)

        #expect(copiedRows.count == 3)
        #expect(rowSet.count == 3)
        #expect(store.visiblePacketRowIndexByID[1] == 0)
        #expect(csv.contains("192.168.0.1"))
        #expect(csv.contains("192.168.0.2"))
        #expect(json.contains("\"source\""))
        #expect(json.contains("192.168.0.1"))
    }

    private func makeRowsAfterNativeStoreCleanup(packetCount: Int) throws -> [PacketTableRow] {
        let harness = NativeLivePacketDiskStoreTestHarness()
        defer { harness.cleanup() }

        let packet = makeIPv4UDPPayloadPacket()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for packetNumber in 1...packetCount {
            try harness.appendPacket(
                identifier: UInt64(packetNumber),
                rawBytes: packet,
                timestamp: timestamp.addingTimeInterval(TimeInterval(packetNumber))
            )
        }

        let rows = try harness.reanalyzePacketSummaries().map(PacketTableRow.init(packet:))
        let backingFilePath = harness.snapshot.backingFilePath

        harness.cleanup()

        #expect(!FileManager.default.fileExists(atPath: backingFilePath))

        return rows
    }

    private func makeIPv4UDPPayloadPacket() -> Data {
        Data([
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x08, 0x00,
            0x45, 0x00, 0x00, 0x20, 0x12, 0x35, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00,
            0xc0, 0xa8, 0x00, 0x01,
            0xc0, 0xa8, 0x00, 0x02,
            0x0f, 0xa0, 0x13, 0x88, 0x00, 0x0c, 0x00, 0x00,
            0xca, 0xfe, 0xba, 0xbe,
        ])
    }
}
#endif
