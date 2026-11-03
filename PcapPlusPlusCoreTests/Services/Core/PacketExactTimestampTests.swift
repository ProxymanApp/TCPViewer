//
//  PacketExactTimestampTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 3/11/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct PacketExactTimestampTests {
    @Test func microsecondDatesRoundTripWithoutTruncation() {
        // 0.3 is stored as 0.29999995... in a Date near 1e9 seconds.
        let timestamp = PacketExactTimestamp(microsecondsFrom: Date(timeIntervalSince1970: 1_041_342_931.3))

        #expect(timestamp == PacketExactTimestamp(seconds: 1_041_342_931, nanoseconds: 300_000_000, precisionDigits: 6))
    }

    @Test func pcapNGRawValuesDecodeExactly() {
        #expect(PacketExactTimestamp(rawValue: 1_041_342_931_300_000, resolution: 6, offsetSeconds: 0)
            == PacketExactTimestamp(seconds: 1_041_342_931, nanoseconds: 300_000_000, precisionDigits: 6))
        #expect(PacketExactTimestamp(rawValue: 1_793_735_882_520_194_053, resolution: 9, offsetSeconds: 0)
            == PacketExactTimestamp(seconds: 1_793_735_882, nanoseconds: 520_194_053, precisionDigits: 9))
        // 2^-10 resolution: 2,048 units are 2 seconds, and offsets add whole seconds.
        #expect(PacketExactTimestamp(rawValue: 2_048 + 512, resolution: 0x8a, offsetSeconds: 10)
            == PacketExactTimestamp(seconds: 12, nanoseconds: 500_000_000, precisionDigits: 4))
    }

    @Test func pcapExportKeepsMicroseconds() throws {
        let url = try temporaryURL(named: "microseconds.pcap")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = makeRecord(timestamp: Date(timeIntervalSince1970: 1_041_342_931.3))

        try NativeCaptureFile.write(records: [record], to: url, format: .pcap)
        let reloaded = try NativeCaptureFile.load(from: url).records[0]

        #expect(reloaded.exactTimestamp == PacketExactTimestamp(seconds: 1_041_342_931, nanoseconds: 300_000_000, precisionDigits: 6))
    }

    @Test func nanosecondPCAPKeepsNanoseconds() throws {
        let url = try temporaryURL(named: "nanoseconds.pcap")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var file = Data()
        file += littleEndian(UInt32(0xa1b2_3c4d))
        file += littleEndian(UInt16(2))
        file += littleEndian(UInt16(4))
        file += littleEndian(UInt32(0))
        file += littleEndian(UInt32(0))
        file += littleEndian(UInt32(65_535))
        file += littleEndian(UInt32(Libpcap.dltEthernet))
        file += littleEndian(UInt32(1_793_735_882))
        file += littleEndian(UInt32(520_194_053))
        file += littleEndian(UInt32(4))
        file += littleEndian(UInt32(4))
        file.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        try file.write(to: url)

        let record = try NativeCaptureFile.load(from: url).records[0]

        #expect(record.exactTimestamp == PacketExactTimestamp(seconds: 1_793_735_882, nanoseconds: 520_194_053, precisionDigits: 9))
    }

    @Test func wiresharkShowsTheCapturePrecision() throws {
        let session = try WiresharkEpanSession()
        let record = makeRecord(timestamp: Date(timeIntervalSince1970: 1_041_342_931.3))
        try session.observe(record)
        let nodes = try session.inspect(record).detailNodes
        let epoch = try #require(nodes.first { $0.fieldName == "frame" }?.children.first { $0.fieldName == "frame.time_epoch" })

        #expect(epoch.value == "1041342931.300000000")
    }

    private func makeRecord(timestamp: Date) -> NativePacketRecord {
        NativePacketRecord(
            identifier: 1,
            packetNumber: 1,
            timestamp: timestamp,
            rawBytes: Data([0x01, 0x02, 0x03, 0x04]),
            originalLength: 4,
            linkLayerType: Libpcap.dltEthernet,
            interfaceIdentifier: nil,
            interfaceName: nil,
            packetComment: nil
        )
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func temporaryURL(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewer-Timestamps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
