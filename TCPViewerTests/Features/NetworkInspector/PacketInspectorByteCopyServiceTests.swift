//
//  PacketInspectorByteCopyServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/7/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketInspectorByteCopyServiceTests {
    private let service = PacketInspectorByteCopyService()

    @Test func hexDumpFormatsUseSelectedProtocolByteRange() {
        let bytes = Data((0x30...0x3f).map(UInt8.init))
        let inspection = makeInspection(rawBytes: bytes)
        let ipv4Item = makeItem(
            id: "ipv4",
            name: "IPv4",
            kind: .layer,
            byteRange: PacketByteRange(offset: 0, length: bytes.count)
        )

        let hexASCII = service.copyText(format: .hexASCIIDump, inspection: inspection, items: [ipv4Item])
        let hexOnly = service.copyText(format: .hexDump, inspection: inspection, items: [ipv4Item])

        #expect(hexASCII == "0000  30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f  0123456789:;<=>?")
        #expect(hexOnly == "0000  30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f")
    }

    @Test func textFormatsDecodeUTF8AndPreservePrintableASCII() {
        let bytes = Data("Hello, café\n".utf8)
        let inspection = makeInspection(rawBytes: bytes)
        let payloadItem = makeItem(
            id: "tcp.payload",
            name: "TCP Payload",
            byteRange: PacketByteRange(offset: 0, length: bytes.count)
        )

        #expect(service.copyText(format: .utf8Text, inspection: inspection, items: [payloadItem]) == "Hello, café\n")
        #expect(service.copyText(format: .asciiText, inspection: inspection, items: [payloadItem]) == "Hello, caf..\n")
    }

    @Test func multipleSelectionsStaySeparatedAndUseAlternateByteViews() {
        let inspection = makeInspection(
            rawBytes: Data([0x01, 0x02, 0x03, 0x04]),
            byteViews: [
                PacketByteView(id: "frame", label: "Frame", bytes: Data([0x01, 0x02, 0x03, 0x04])),
                PacketByteView(id: "reassembled-tcp", label: "Reassembled TCP", bytes: Data([0xaa, 0xbb, 0xcc, 0xdd])),
            ]
        )
        let frameItem = makeItem(id: "frame.bytes", name: "Frame Bytes", byteRange: PacketByteRange(offset: 0, length: 2))
        let tcpItem = makeItem(
            id: "tcp.reassembled",
            name: "Reassembled TCP",
            byteRange: PacketByteRange(offset: 1, length: 2, sourceID: "reassembled-tcp")
        )

        #expect(service.copyText(format: .hexStream, inspection: inspection, items: [frameItem, tcpItem]) == "0102\nbbcc")
        #expect(service.copyText(format: .base64String, inspection: inspection, items: [frameItem, tcpItem]) == "AQI=\nu8w=")
    }

    @Test func parentWithoutByteRangeCopiesMergedChildRanges() {
        let inspection = makeInspection(rawBytes: Data([0x00, 0x01, 0x12, 0x34, 0x56, 0x78]))
        let tcpItem = makeItem(
            id: "tcp",
            name: "TCP",
            kind: .layer,
            children: [
                makeItem(id: "tcp.srcport", name: "Source Port", byteRange: PacketByteRange(offset: 2, length: 2)),
                makeItem(id: "tcp.dstport", name: "Destination Port", byteRange: PacketByteRange(offset: 4, length: 2)),
            ]
        )

        #expect(service.copyText(format: .hexStream, inspection: inspection, items: [tcpItem]) == "12345678")
    }

    @Test func parentWithoutByteRangeMergesChildrenInByteOffsetOrder() {
        let inspection = makeInspection(rawBytes: Data([0xaa, 0xbb, 0xcc, 0xdd]))
        let optionsItem = makeItem(
            id: "tcp.options",
            name: "Options",
            kind: .field,
            children: [
                makeItem(id: "tcp.options.late", name: "Late Option", byteRange: PacketByteRange(offset: 2, length: 2)),
                makeItem(id: "tcp.options.early", name: "Early Option", byteRange: PacketByteRange(offset: 0, length: 2)),
            ]
        )

        #expect(service.copyText(format: .hexStream, inspection: inspection, items: [optionsItem]) == "aabbccdd")
    }

    @Test func invalidRangesAreIgnoredAndValidRangesAreClipped() {
        let inspection = makeInspection(rawBytes: Data([0x01, 0x02, 0x03, 0x04]))
        let clippedItem = makeItem(id: "valid", name: "Valid", byteRange: PacketByteRange(offset: 2, length: 20))
        let outOfBoundsItem = makeItem(id: "out", name: "Out", byteRange: PacketByteRange(offset: 4, length: 1))
        let missingSourceItem = makeItem(
            id: "missing",
            name: "Missing Source",
            byteRange: PacketByteRange(offset: 0, length: 1, sourceID: "missing")
        )
        let negativeItem = makeItem(id: "negative", name: "Negative", byteRange: PacketByteRange(offset: -1, length: 1))

        #expect(service.copyText(format: .hexStream, inspection: inspection, items: [clippedItem]) == "0304")
        #expect(service.copyText(format: .hexStream, inspection: inspection, items: [outOfBoundsItem, missingSourceItem, negativeItem]).isEmpty)
        #expect(!service.canCopyBytes(from: [outOfBoundsItem, missingSourceItem, negativeItem], inspection: inspection))
        #expect(!service.canCopyBytes(from: [clippedItem], inspection: nil))
    }

    @Test func languageAndMIMEFormatsEscapeBinaryBytesSafely() {
        let bytes = Data([0x48, 0x65, 0x00, 0x30, 0x0f, 0x41, 0x22, 0x5c, 0x0a])
        let inspection = makeInspection(rawBytes: bytes)
        let item = makeItem(id: "payload", name: "Payload", byteRange: PacketByteRange(offset: 0, length: bytes.count))

        #expect(service.copyText(format: .cString, inspection: inspection, items: [item]) == "\"He\\x00\" \"0\\x0f\" \"A\\\"\\\\\\n\"")
        #expect(service.copyText(format: .goLiteral, inspection: inspection, items: [item]) == "\"He\\x000\\x0fA\\\"\\\\\\n\"")
        #expect(service.copyText(format: .cArray, inspection: inspection, items: [item]) == """
        unsigned char packet_bytes[] = {
            0x48, 0x65, 0x00, 0x30, 0x0f, 0x41, 0x22, 0x5c, 0x0a
        };
        """)
        #expect(service.copyText(format: .mimeData, inspection: inspection, items: [item]) == """
        Content-Type: application/octet-stream
        Content-Transfer-Encoding: base64

        SGUAMA9BIlwK
        """)
    }

    private func makeInspection(
        rawBytes: Data,
        byteViews: [PacketByteView]? = nil
    ) -> PacketInspection {
        PacketInspection(
            packetID: 1,
            packetNumber: 1,
            rawBytes: rawBytes,
            byteViews: byteViews,
            detailNodes: [],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }

    private func makeItem(
        id: String,
        name: String,
        kind: PacketInspectorTreeItemKind = .field,
        byteRange: PacketByteRange? = nil,
        children: [PacketInspectorTreeItem] = []
    ) -> PacketInspectorTreeItem {
        PacketInspectorTreeItem(
            id: id,
            nodeID: id,
            name: name,
            kind: kind,
            byteRange: byteRange,
            children: children
        )
    }
}
