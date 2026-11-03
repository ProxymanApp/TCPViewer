//
//  WiresharkDetailLabelTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 3/11/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkDetailLabelTests {
    @Test func detailNodesCarryWiresharkRowLabels() throws {
        let nodes = try inspectedNodes(of: ipv6LoopbackSYN())

        // Protocol rows keep Wireshark's own summary punctuation.
        let tcp = try #require(node("tcp", in: nodes))
        #expect(tcp.label == "Transmission Control Protocol, Src Port: 12345, Dst Port: 80, Seq: 0, Len: 0")
        let ethernet = try #require(node("eth", in: nodes))
        #expect(ethernet.label?.hasPrefix("Ethernet II, Src: ") == true)

        // Bitmask fields keep their bit pattern and generated fields keep their brackets.
        #expect(node("tcp.flags.syn", in: nodes)?.label == ".... .... ..1. = Syn: Set")
        #expect(node("ipv6.version", in: nodes)?.label == "0110 .... = Version: 6")
        #expect(node("tcp.stream", in: nodes)?.label == "[Stream index: 0]")

        // Custom-formatted rows are not prefixed with the field's registered name.
        #expect(node("tcp.options.mss", in: nodes)?.label == "TCP Option - Maximum segment size: 1460 bytes")
    }

    @Test func valuesKeepLeadingColons() throws {
        let nodes = try inspectedNodes(of: ipv6LoopbackSYN())
        let source = try #require(node("ipv6.src", in: nodes))

        #expect(source.value == "::1")
        #expect(source.label == "Source Address: ::1")
    }

    private func inspectedNodes(of bytes: Data) throws -> [PCPPNativePacketDetailNodeDescriptor] {
        let session = try WiresharkEpanSession()
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
        return try session.inspect(record).detailNodes
    }

    // Ethernet + IPv6 (::1 -> ::1) + TCP SYN with one MSS option.
    private func ipv6LoopbackSYN() -> Data {
        var bytes: [UInt8] = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
            0x86, 0xdd,
            0x60, 0x00, 0x00, 0x00, 0x00, 0x18, 0x06, 0x40,
        ]
        let loopback: [UInt8] = Array(repeating: 0, count: 15) + [1]
        bytes += loopback + loopback
        bytes += [
            0x30, 0x39, 0x00, 0x50,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x60, 0x02, 0xff, 0xff,
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x04, 0x05, 0xb4,
        ]
        return Data(bytes)
    }

    private func node(_ fieldName: String, in nodes: [PCPPNativePacketDetailNodeDescriptor]) -> PCPPNativePacketDetailNodeDescriptor? {
        for node in nodes {
            if node.fieldName == fieldName {
                return node
            }
            if let child = self.node(fieldName, in: node.children) {
                return child
            }
        }
        return nil
    }
}
