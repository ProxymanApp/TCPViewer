//
//  PacketCommentTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/7/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct PacketCommentTests {
    @Test func sanitizesWhitespaceLineEndingsAndLength() {
        let rawValue = "  \r\nFirst line\rSecond line\n" + String(repeating: "x", count: 1_100) + "  \n"
        let comment = PacketComment.sanitized(rawValue)

        #expect(comment.hasPrefix("First line\nSecond line\n"))
        #expect(comment.count == PacketComment.maximumCharacterCount)
        #expect(!comment.hasPrefix(" "))
        #expect(!comment.hasSuffix(" "))
    }

    @Test func packetCommentOverrideIsSanitizedAndFallsBackToCaptureComment() {
        let importedPacket = Self.makePacket(customComment: nil)
        let editedPacket = importedPacket.applying(customComment: "\n Edited comment \n")

        #expect(importedPacket.resolvedComment == "Imported comment")
        #expect(editedPacket.customComment == "Edited comment")
        #expect(editedPacket.resolvedComment == "Edited comment")
    }

    private static func makePacket(customComment: String?) -> PacketSummary {
        PacketSummary(
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            source: .offline,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "127.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "127.0.0.1", port: 443)
            ),
            originalLength: 4,
            capturedLength: 4,
            infoSummary: "TCP",
            layers: [],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(
                linkType: .ethernet,
                isTruncated: false,
                packetComment: "Imported comment"
            ),
            customComment: customComment
        )
    }
}
