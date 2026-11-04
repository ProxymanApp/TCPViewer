//
//  WiresharkFrameMetadataTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 3/11/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkFrameMetadataTests {
    @Test func classicPCAPShowsNoInterface() throws {
        let frame = try frameNode(of: [makeRecord(identifier: 1, isClassicPCAP: true)]).last

        #expect(frame?.label == "Frame 1: Packet, 42 bytes on wire (336 bits), 42 bytes captured (336 bits)")
        #expect(frame?.children.contains { $0.fieldName == "frame.interface_id" } == false)
        #expect(frame?.children.contains { $0.fieldName == "frame.section_number" } == false)
    }

    @Test func pcapNGShowsSectionInterfaceDescriptionAndPacketFlags() throws {
        // epb_flags 0x1: inbound direction.
        let record = makeRecord(identifier: 1, interfaceDescription: "Wi-Fi", packetFlags: 0x0000_0001)
        let frame = try #require(try frameNode(of: [record]).last)
        let interface = try #require(frame.children.first { $0.fieldName == "frame.interface_id" })

        #expect(frame.children.first { $0.fieldName == "frame.section_number" }?.label == "Section number: 1")
        #expect(interface.children.map(\.label) == ["Interface name: en0", "Interface description: Wi-Fi"])
        let flags = try #require(frame.children.first { $0.fieldName == "frame.packet_flags" })
        #expect(flags.children.first { $0.fieldName == "frame.packet_flags_direction" }?.value == "Inbound (0x1)")
    }

    @Test func descriptionOnlyInterfaceIsNamedByItsDescriptionLikeWireshark() throws {
        // Wireshark's file provider names an interface by if_name, then if_description, then "unknown".
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("description-only.pcapng")
        try NativeCaptureFile.write(
            records: [makeRecord(identifier: 1, interfaceName: nil, interfaceDescription: "Wi-Fi")],
            to: url,
            format: .pcapng
        )

        let record = try NativeCaptureFile.load(from: url).records[0]
        let frame = try #require(try frameNode(of: [record]).last)
        let interface = try #require(frame.children.first { $0.fieldName == "frame.interface_id" })

        #expect(record.interfaceName == "Wi-Fi")
        #expect(record.interfaceDescription == "Wi-Fi")
        #expect(interface.label == "Interface id: 0 (Wi-Fi)")
        #expect(interface.children.map(\.label) == ["Interface name: Wi-Fi", "Interface description: Wi-Fi"])
    }

    @Test func secondPassKeepsTheDeltaFromThePreviousDisplayedFrame() throws {
        let records = (1...3).map { makeRecord(identifier: UInt64($0)) }
        let frames = try frameNode(of: records, inspecting: 1)
        let delta = frames.last?.children.first { $0.fieldName == "frame.time_delta_displayed" }

        // Inspecting packet 2 after packet 3 was observed must still measure from packet 1.
        #expect(delta?.label == "[Time delta from previous displayed frame: 1 second]")
    }

    private func frameNode(
        of records: [NativePacketRecord],
        inspecting index: Int? = nil
    ) throws -> [PCPPNativePacketDetailNodeDescriptor] {
        let session = try WiresharkEpanSession()
        for record in records {
            try session.observe(record)
        }
        let record = records[index ?? (records.count - 1)]
        return try session.inspect(record).detailNodes.filter { $0.fieldName == "frame" }
    }

    // Ethernet + IPv4 + UDP to port 53, one second apart per identifier.
    private func makeRecord(
        identifier: UInt64,
        interfaceName: String? = "en0",
        interfaceDescription: String? = nil,
        packetFlags: UInt32? = nil,
        isClassicPCAP: Bool = false
    ) -> NativePacketRecord {
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
            interfaceIdentifier: isClassicPCAP ? nil : interfaceName,
            interfaceName: isClassicPCAP ? nil : interfaceName,
            packetComment: nil,
            interfaceDescription: interfaceDescription,
            packetFlags: packetFlags,
            isClassicPCAP: isClassicPCAP
        )
    }
}
