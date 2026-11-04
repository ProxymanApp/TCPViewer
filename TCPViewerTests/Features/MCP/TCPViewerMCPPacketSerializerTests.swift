//
//  TCPViewerMCPPacketSerializerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

struct TCPViewerMCPPacketSerializerTests {
    @Test func summaryHonorsSensitiveModeOnAndOff() {
        let packet = makeMCPPacket(id: 1)
        let protected = TCPViewerMCPPacketSerializer(redactsSensitiveData: true).summary(packet).objectValue
        let unprotected = TCPViewerMCPPacketSerializer(redactsSensitiveData: false).summary(packet).objectValue

        #expect(protected?["info"]?.stringValue == "Authorization: <redacted>")
        #expect(unprotected?["info"]?.stringValue == "Authorization: Bearer secret-value")
        #expect(protected?["id"] == .string("1"))
        #expect(protected?["source_endpoint"]?.objectValue?["port"] == .int(51_234))
    }

    @Test func inspectionRedactsSensitiveFieldsAndReportsDepthAndNodeLimits() {
        let inspection = makeMCPInspection()
        let protected = TCPViewerMCPPacketSerializer(redactsSensitiveData: true).inspection(
            inspection,
            maximumDepth: 0,
            maximumNodeCount: 1
        ).objectValue
        let root = protected?["detail_nodes"]?.arrayValue?.first?.objectValue

        #expect(root?["value"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))
        #expect(root?["raw_value"] == .string(TCPViewerMCPSensitiveDataRedactor.placeholder))
        #expect(root?["label"] == .string("Authorization: \(TCPViewerMCPSensitiveDataRedactor.placeholder)"))
        #expect(root?["children_truncated"] == .bool(true))
        #expect(protected?["returned_node_count"] == .int(1))
        #expect(protected?["nodes_truncated"] == .bool(true))

        let unprotected = TCPViewerMCPPacketSerializer(redactsSensitiveData: false).inspection(
            inspection,
            maximumDepth: 4,
            maximumNodeCount: 10
        ).objectValue
        let unprotectedRoot = unprotected?["detail_nodes"]?.arrayValue?.first?.objectValue
        let child = unprotectedRoot?["children"]?.arrayValue?.first?.objectValue
        #expect(unprotectedRoot?["value"] == .string("Bearer super-secret-token"))
        #expect(unprotectedRoot?["label"] == .string("Authorization: Bearer super-secret-token"))
        #expect(child?["value"] == .string("https://example.com/path?api_key=hidden&safe=yes"))
        #expect(unprotected?["returned_node_count"] == .int(2))
    }

    @Test func headerLabelIsRedactedLikeItsValue() {
        // HTTP/2 header rows prefix the "name: value" text, so the label is not line-anchored.
        let node = PacketDetailNode(id: "http2.header", name: "Header", label: "Header: cookie: sid=abc123",
                                    fieldName: "http2.header", value: "cookie: sid=abc123")
        let inspection = PacketInspection(packetID: 1, packetNumber: 1, rawBytes: Data(), byteViews: [],
                                          detailNodes: [node], decodeStatus: PacketDecodeStatus(kind: .complete))
        let root = TCPViewerMCPPacketSerializer(redactsSensitiveData: true)
            .inspection(inspection, maximumDepth: 1, maximumNodeCount: 1)
            .objectValue?["detail_nodes"]?.arrayValue?.first?.objectValue

        #expect(root?["value"] == .string("cookie: <redacted>"))
        #expect(root?["label"] == .string("Header: cookie: <redacted>"))
    }

    @Test func bytesAreBoundedAndSupportHexAndBase64() {
        let serializer = TCPViewerMCPPacketSerializer(redactsSensitiveData: false)
        let inspection = makeMCPInspection()

        let hex = serializer.bytes(inspection, offset: 2, length: 3, encoding: "hex").objectValue
        #expect(hex?["data"] == .string("030405"))
        #expect(hex?["has_more"] == .bool(true))

        let base64 = serializer.bytes(inspection, offset: 5, length: 99, encoding: "base64").objectValue
        #expect(base64?["data"] == .string("Bg=="))
        #expect(base64?["returned_byte_count"] == .int(1))
        #expect(base64?["has_more"] == .bool(false))
    }
}
