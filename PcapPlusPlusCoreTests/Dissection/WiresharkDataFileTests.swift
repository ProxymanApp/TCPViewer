//
//  WiresharkDataFileTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 3/11/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkDataFileTests {
    @Test func wellKnownAddressesResolveFromBundledDataFiles() throws {
        // ARP request to the Ethernet broadcast address; "Broadcast" comes from Wireshark's wka file.
        let bytes = Data([
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
            0x08, 0x06,
            0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 192, 168, 0, 1,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 192, 168, 0, 2,
        ])
        let record = NativePacketRecord(
            identifier: 1,
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            rawBytes: bytes,
            originalLength: bytes.count,
            linkLayerType: Libpcap.dltEthernet,
            interfaceIdentifier: "en0",
            interfaceName: "en0",
            packetComment: nil
        )
        let session = try WiresharkEpanSession()
        try session.observe(record)

        let ethernet = try #require(try session.inspect(record).detailNodes.first { $0.fieldName == "eth" })

        #expect(ethernet.children.first { $0.fieldName == "eth.dst" }?.label == "Destination: Broadcast (ff:ff:ff:ff:ff:ff)")
    }
}
