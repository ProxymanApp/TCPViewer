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

    @Test func pcapNGExportRoundTripsPacketCommentAndTextStyle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewer-PcapNGStyle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("styled.pcapng")
        let style = PacketTextStyle(highlightColor: .indigo, isStrikethrough: true)
        let record = makeRecord(
            identifier: 7,
            linkLayerType: Libpcap.dltEthernet,
            packetComment: "Keep this comment\n"
        )

        try NativeCaptureFile.write(
            records: [record],
            to: url,
            format: .pcapng,
            textStylesByPacketID: [record.identifier: style]
        )
        let capture = try NativeCaptureFile.load(from: url)
        let exportedBytes = try Data(contentsOf: url)

        #expect(capture.records.count == 1)
        #expect(capture.records[0].rawBytes == record.rawBytes)
        #expect(capture.records[0].packetComment == "Keep this comment\n")
        #expect(capture.records[0].textStyle == style)
        #expect(exportedBytes.range(of: Data("[TCPViewer:text-style:v1:indigo:1]".utf8)) != nil)
    }

    @Test func pcapExportKeepsCanonicalBytesAndRoundTripsStyleInFileMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewer-PcapStyle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plainURL = directory.appendingPathComponent("plain.pcap")
        let styledURL = directory.appendingPathComponent("styled.pcap")
        let record = makeRecord(identifier: 1, linkLayerType: Libpcap.dltEthernet)
        let style = PacketTextStyle(highlightColor: .pink, isStrikethrough: true)

        try NativeCaptureFile.write(records: [record], to: plainURL, format: .pcap)
        try NativeCaptureFile.write(
            records: [record],
            to: styledURL,
            format: .pcap,
            textStylesByPacketID: [record.identifier: style]
        )
        let capture = try NativeCaptureFile.load(from: styledURL)

        #expect(try Data(contentsOf: plainURL) == Data(contentsOf: styledURL))
        #expect(capture.records.map(\.textStyle) == [style])
        #expect(capture.records[0].rawBytes == record.rawBytes)
    }

    @Test func explicitPlainExportMetadataResetsAnImportedStyle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewer-PcapNGStyleReset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reset.pcapng")
        let record = makeRecord(
            identifier: 3,
            linkLayerType: Libpcap.dltEthernet,
            textStyle: PacketTextStyle(highlightColor: .red)
        )

        try NativeCaptureFile.write(
            records: [record],
            to: url,
            format: .pcapng,
            textStylesByPacketID: [record.identifier: .plain]
        )
        let capture = try NativeCaptureFile.load(from: url)

        #expect(capture.records.map(\.textStyle) == [.plain])
    }

    @Test func replacingAnExistingPcapReplacesItsStyleMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewer-PcapStyleReplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replaced.pcap")
        let record = makeRecord(identifier: 1, linkLayerType: Libpcap.dltEthernet)

        try NativeCaptureFile.write(
            records: [record],
            to: url,
            format: .pcap,
            textStylesByPacketID: [record.identifier: PacketTextStyle(highlightColor: .green)]
        )
        try NativeCaptureFile.write(
            records: [record],
            to: url,
            format: .pcap,
            textStylesByPacketID: [record.identifier: .plain]
        )

        #expect(try NativeCaptureFile.load(from: url).records.map(\.textStyle) == [.plain])
    }

    private func makeRecord(
        identifier: UInt64,
        timestamp: Date = Date(timeIntervalSince1970: 1),
        linkLayerType: Int32,
        interfaceID: UInt32 = 0,
        interfaceName: String? = nil,
        resolution: UInt8? = nil,
        offset: Int64 = 0,
        rawTimestamp: UInt64? = nil,
        packetComment: String? = nil,
        textStyle: PacketTextStyle = .plain
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
            packetComment: packetComment,
            interfaceID: interfaceID,
            pcapNGTimestampResolution: resolution,
            pcapNGTimestampOffsetSeconds: offset,
            pcapNGTimestampRawValue: rawTimestamp,
            textStyle: textStyle
        )
    }
}
