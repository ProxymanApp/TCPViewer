//
//  PacketAnalyzerLinkTypeTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 3/11/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct PacketAnalyzerLinkTypeTests {
    // IPv4 + UDP from 192.168.0.1:5353 to 192.168.0.2:53.
    private let ipv4UDP: [UInt8] = [
        0x45, 0x00, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00,
        0x40, 0x11, 0x00, 0x00, 192, 168, 0, 1, 192, 168, 0, 2,
        0x14, 0xe9, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00,
    ]

    @Test(arguments: [Libpcap.dltRaw, Libpcap.linktypeRaw, Libpcap.linktypeIPv4])
    func rawIPLinkTypesDecodeAddresses(linkType: Int32) {
        let packet = analyze(ipv4UDP, linkType: linkType)

        #expect(packet.decodeStatus.kind != .unsupported)
        #expect(packet.sourceAddress == "192.168.0.1")
        #expect(packet.destinationAddress == "192.168.0.2")
    }

    @Test func linuxCookedCaptureV2DecodesTheEncapsulatedProtocol() {
        // SLL2: protocol 0x0800, reserved, interface index, ARPHRD_ETHER, packet type, address length, address.
        let header: [UInt8] = [0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x06]
            + [0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0x00, 0x00]
        let packet = analyze(header + ipv4UDP, linkType: Libpcap.linktypeLinuxSLL2)

        #expect(packet.decodeStatus.kind != .unsupported)
        #expect(packet.sourceAddress == "192.168.0.1")
        #expect(packet.detailNodes.contains { $0.fieldName == "sll" })
    }

    private func analyze(_ bytes: [UInt8], linkType: Int32) -> AnalyzedPacket {
        PacketAnalyzer(record: NativePacketRecord(
            identifier: 1,
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            rawBytes: Data(bytes),
            originalLength: bytes.count,
            linkLayerType: linkType,
            interfaceIdentifier: nil,
            interfaceName: nil,
            packetComment: nil
        )).analyze()
    }
}
