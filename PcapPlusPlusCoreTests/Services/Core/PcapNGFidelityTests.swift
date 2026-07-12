//
//  PcapNGFidelityTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct PcapNGFidelityTests {
    @Test func pcapNGExportPreservesMultipleInterfacesAndTimestampOptions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewer-PcapNGFidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("multiple-interfaces.pcapng")

        let nanosecondTimestamp: UInt64 = 1_234_567_890
        let binaryTimestamp: UInt64 = 2_048
        let records = [
            makeRecord(
                identifier: 1,
                timestamp: Date(timeIntervalSince1970: Double(nanosecondTimestamp) / 1_000_000_000),
                linkLayerType: Libpcap.dltEthernet,
                interfaceID: 7,
                interfaceName: "en7",
                resolution: 9,
                offset: 0,
                rawTimestamp: nanosecondTimestamp
            ),
            makeRecord(
                identifier: 2,
                timestamp: Date(timeIntervalSince1970: 12),
                linkLayerType: Libpcap.dltRaw,
                interfaceID: 12,
                interfaceName: "raw0",
                resolution: 0x8a,
                offset: 10,
                rawTimestamp: binaryTimestamp
            ),
        ]

        try NativeCaptureFile.write(records: records, to: url, format: .pcapng)
        let capture = try NativeCaptureFile.load(from: url)

        #expect(capture.records.count == 2)
        #expect(capture.records.map(\.interfaceID) == [0, 1])
        #expect(capture.records.map(\.interfaceName) == ["en7", "raw0"])
        #expect(capture.records.map(\.linkLayerType) == [Libpcap.dltEthernet, Libpcap.dltRaw])
        #expect(capture.records.map(\.pcapNGTimestampResolution) == [9, 0x8a])
        #expect(capture.records.map(\.pcapNGTimestampOffsetSeconds) == [0, 10])
        #expect(capture.records.map(\.pcapNGTimestampRawValue) == [nanosecondTimestamp, binaryTimestamp])
        #expect(abs(capture.records[0].timestamp.timeIntervalSince1970 - 1.234_567_89) < 0.000_000_1)
        #expect(capture.records[1].timestamp.timeIntervalSince1970 == 12)
    }

    @Test func pcapExportRejectsMixedLinkLayerTypes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewer-PcapMixedLinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mixed.pcap")
        let records = [
            makeRecord(identifier: 1, linkLayerType: Libpcap.dltEthernet),
            makeRecord(identifier: 2, linkLayerType: Libpcap.dltRaw),
        ]

        #expect(throws: NSError.self) {
            try NativeCaptureFile.write(records: records, to: url, format: .pcap)
        }
    }

    private func makeRecord(
        identifier: UInt64,
        timestamp: Date = Date(timeIntervalSince1970: 1),
        linkLayerType: Int32,
        interfaceID: UInt32 = 0,
        interfaceName: String? = nil,
        resolution: UInt8? = nil,
        offset: Int64 = 0,
        rawTimestamp: UInt64? = nil
    ) -> NativePacketRecord {
        NativePacketRecord(
            identifier: identifier,
            packetNumber: identifier,
            timestamp: timestamp,
            rawBytes: Data([0x01, 0x02, 0x03, 0x04]),
            originalLength: 4,
            linkLayerType: linkLayerType,
            interfaceIdentifier: interfaceName,
            interfaceName: interfaceName,
            packetComment: nil,
            interfaceID: interfaceID,
            pcapNGTimestampResolution: resolution,
            pcapNGTimestampOffsetSeconds: offset,
            pcapNGTimestampRawValue: rawTimestamp
        )
    }
}
