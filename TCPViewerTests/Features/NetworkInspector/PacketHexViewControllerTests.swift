//
//  PacketHexViewControllerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 29/4/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketHexViewControllerTests {
    @Test func highlightMapsByteRangeToSelection() throws {
        let highlight = try #require(PacketHexHighlight.make(from: PacketByteRange(offset: 14, length: 20), byteCount: 64))

        #expect(highlight.byteOffset == 14)
        #expect(highlight.byteLength == 20)
        #expect(highlight.tooltip == "Bytes 14-33")
    }

    @Test func highlightMapsBitRangeToContainingByteAndTooltip() throws {
        let range = PacketByteRange(offset: 20, length: 1, bitOffset: 1, bitLength: 1, hasBitRange: true)
        let highlight = try #require(PacketHexHighlight.make(from: range, byteCount: 64))

        #expect(highlight.byteOffset == 20)
        #expect(highlight.byteLength == 1)
        #expect(highlight.tooltip == "Bytes 20-20, bits 1-1")
    }

    @Test func highlightClampsLengthToCapturedBytes() throws {
        let highlight = try #require(PacketHexHighlight.make(from: PacketByteRange(offset: 3, length: 8), byteCount: 5))

        #expect(highlight.byteOffset == 3)
        #expect(highlight.byteLength == 2)
        #expect(highlight.tooltip == "Bytes 3-4")
    }

    @Test func highlightPreservesReassembledByteSource() throws {
        let range = PacketByteRange(offset: 2, length: 4, sourceID: "reassembled-tcp")
        let highlight = try #require(PacketHexHighlight.make(from: range, byteCount: 8))

        #expect(highlight.sourceRange.sourceID == "reassembled-tcp")
        #expect(highlight.byteOffset == 2)
        #expect(highlight.byteLength == 4)
    }

    @Test func highlightIgnoresOutOfBoundsRanges() {
        #expect(PacketHexHighlight.make(from: PacketByteRange(offset: 5, length: 1), byteCount: 5) == nil)
        #expect(PacketHexHighlight.make(from: PacketByteRange(offset: 0, length: 0), byteCount: 5) == nil)
        #expect(PacketHexHighlight.make(from: nil, byteCount: 5) == nil)
    }
}
