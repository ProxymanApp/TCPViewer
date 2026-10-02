//
//  DiffBinaryComparisonTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit
import Foundation
import HexFiend
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@MainActor @Suite(.serialized)
struct DiffBinaryComparisonTests {
    @Test func identicalAndEmptyBytesHaveNoChanges() throws {
        for bytes in [Data(), Data([0, 0xFF, 0x80, 0xC0, 0, 1])] {
            #expect(try comparison(bytes, bytes).changes.isEmpty)
        }
    }

    @Test func insertionKeepsTheMatchingSuffixUnchanged() throws {
        let left = Data(0..<64)
        var right = left
        right.insert(contentsOf: [0xFE, 0xFF], at: 16)
        let result = try comparison(left, right)
        #expect(result.changes == [DiffByteChange(left: 16..<16, right: 16..<18)])
        #expect(result.correspondingOffset(32, from: .left) == 34)
        #expect(result.correspondingOffset(34, from: .right) == 32)
        #expect(result.correspondingOffset(17, from: .right) == 16)
        #expect(result.correspondingOffset(8, from: .left) == 8)
        #expect(apply(result, to: left, using: right) == right)
    }

    @Test func deletionReplacementAndBoundaryChangesReconstructRawBytes() throws {
        let original = Data(0..<64)
        var deletion = original
        deletion.removeSubrange(16..<19)
        var replacement = original
        replacement.replaceSubrange(20..<23, with: [0xFF, 0, 0xFE])
        let cases = [
            (original, deletion), (original, replacement),
            (Data(), Data([0, 0xFF])), (Data([0, 0xFF]), Data()),
            (original, Data([0xFF]) + original), (original, original + Data([0xFF])),
            (original, Data(original.dropFirst())), (original, Data(original.dropLast()))
        ]
        for (left, right) in cases {
            let result = try comparison(left, right)
            #expect(!result.changes.isEmpty)
            #expect(apply(result, to: left, using: right) == right)
            for change in result.changes {
                #expect(change.left.lowerBound >= 0 && change.left.upperBound <= left.count)
                #expect(change.right.lowerBound >= 0 && change.right.upperBound <= right.count)
                #expect(!change.left.isEmpty || !change.right.isEmpty)
            }
        }
        let deleted = try comparison(original, deletion)
        #expect(deleted.changes == [DiffByteChange(left: 16..<19, right: 16..<16)])
        #expect(deleted.correspondingOffset(32, from: .left) == 29)
        #expect(deleted.correspondingOffset(17, from: .left) == 16)
    }

    @Test func binarySearchAcceptsOnlyHexPairsAndWraps() {
        #expect(DiffBinarySearch.bytes(from: "00 ff\n80\tC0") == Data([0, 0xFF, 0x80, 0xC0]))
        for invalid in ["", "0", "0xFF", "GG", "ＦＦ", "0;00", "💻"] {
            #expect(DiffBinarySearch.bytes(from: invalid) == nil)
        }
        let bytes = Data([0, 0xFF, 0x80, 0, 0xFF, 0x80])
        #expect(DiffBinarySearch.next(Data([0, 0xFF]), in: bytes, after: 2) == 3..<5)
        #expect(DiffBinarySearch.next(Data([0, 0xFF]), in: bytes, after: 6) == 0..<2)
        #expect(DiffBinarySearch.next(Data([1]), in: bytes, after: 0) == nil)
        #expect(DiffBinarySearch.next(Data(), in: bytes, after: 0) == nil)
    }

    @Test func rapidSourceChangesCoalesceAndRejectObsoleteCompletion() async {
        let probe = ComparisonProbe()
        let model = DiffBinaryModel(compare: probe.compare)
        model.render(left: Data([0]), right: Data([1]), pair: pair())
        await waitFor { probe.calls.count == 1 }
        model.render(left: Data([0]), right: Data([2]), pair: pair())
        model.render(left: Data([0]), right: Data([3, 4]), pair: pair())
        probe.releaseFirst()
        await waitFor { !model.isComparing }
        #expect(probe.calls == [Data([1]), Data([3, 4])])
        #expect(model.comparison?.changes == [DiffByteChange(left: 0..<1, right: 0..<2)])
    }

    @Test func clearingWhileComparingRejectsTheResultAndNextPairCanRun() async {
        let probe = ComparisonProbe()
        let model = DiffBinaryModel(compare: probe.compare)
        model.render(left: Data([0]), right: Data([1]), pair: pair())
        await waitFor { probe.calls.count == 1 }
        model.clear()
        probe.releaseFirst()
        #expect(model.comparison == nil && !model.isComparing)
        model.render(left: Data([0]), right: Data([2, 3]), pair: pair())
        await waitFor { !model.isComparing }
        #expect(model.comparison?.changes == [DiffByteChange(left: 0..<1, right: 0..<2)])
    }

    @Test func repeatedRenderAndModeSwitchReuseTheCompletedPair() async {
        let probe = ComparisonProbe()
        probe.releaseFirst()
        let model = DiffBinaryModel(compare: probe.compare)
        let identity = pair()
        model.render(left: Data([0]), right: Data([1]), pair: identity)
        await waitFor { !model.isComparing }
        model.render(left: Data([0]), right: Data([1]), pair: identity)
        model.clear()
        model.render(left: Data([0]), right: Data([1]), pair: identity)
        #expect(!model.isComparing && model.comparison != nil)
        #expect(probe.calls.count == 1)
    }

    @Test func comparisonFailureIsExplicitAndClearingResetsIt() async {
        let model = DiffBinaryModel(compare: { _, _, _ in nil })
        model.render(left: Data([0]), right: Data([1]), pair: pair())
        await waitFor { !model.isComparing }
        #expect(model.failed && model.comparison == nil)
        model.clear()
        #expect(!model.failed && !model.isComparing && model.comparison == nil)
    }

    @Test func nativeHexPanesAreReadOnlyAndPartialPairsRemainExplicit() async {
        let controller = DiffBinaryViewController()
        let left = entry(1, bytes: Data([0, 1, 0xFF]))
        controller.render(left: left, right: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 500)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: 500))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await waitFor { controller.leftHexView.frame.width > 600 && controller.leftHexView.frame.height > 350 }
        #expect(controller.leftHexView.frame.width > 600 && controller.rightHexView.frame.width > 600)
        #expect(controller.leftHexView.frame.height > 350 && controller.rightHexView.frame.height > 350)
        #expect(!controller.leftHexView.controller.editable && !controller.rightHexView.controller.editable)
        #expect(controller.leftHexView.byteArray.length() == 3)
        #expect(controller.rightHexView.byteArray.length() == 0)
        #expect(controller.statusLabel.stringValue == "Choose a packet for Left and Right")
        #expect(!controller.nextButton.isEnabled)
        let right = entry(2, bytes: Data([0, 2, 0xFF]))
        controller.render(left: left, right: right)
        await waitFor { controller.nextButton.isEnabled }
        #expect(controller.statusLabel.stringValue == "Difference 1 of 1")
        #expect(controller.leftHexView.controller.byteRangeAttributeArray().attributes(at: 1, length: nil).contains(kHFAttributeDiffInsertion))
        controller.nextChange(nil)
        #expect(controller.leftHexView.controller.minimumSelectionLocation() == 1)
        controller.render(left: entry(3, bytes: Data()), right: entry(4, bytes: Data()))
        await waitFor { controller.statusLabel.stringValue == "Identical bytes" }
        #expect(!controller.nextButton.isEnabled)
        controller.suspend()
        #expect(controller.leftHexView.byteArray.length() == 0 && controller.rightHexView.byteArray.length() == 0)
    }

    private func comparison(_ left: Data, _ right: Data) throws -> DiffBinaryComparison {
        try #require(DiffBinaryComparison.compare(left: left, right: right, tracker: HFProgressTracker()))
    }

    private func apply(_ comparison: DiffBinaryComparison, to left: Data, using right: Data) -> Data {
        var result = left
        for change in comparison.changes.reversed() { result.replaceSubrange(change.left, with: right[change.right]) }
        return result
    }

    private func pair() -> DiffBinaryPair { DiffBinaryPair(left: UUID(), right: UUID()) }

    private func entry(_ id: UInt64, bytes: Data) -> DiffPacketEntry {
        let packet = PacketSummary(id: id, packetNumber: id, timestamp: Date(timeIntervalSince1970: 0), source: .offline,
            transportHint: .tcp, endpoints: PacketEndpoints(source: PacketEndpoint(), destination: PacketEndpoint()),
            originalLength: bytes.count, capturedLength: bytes.count,
            infoSummary: "Synthetic", layers: [], decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false))
        let entry = DiffPacketEntry(id: DiffPacketID(capture: UUID(), lineage: 1, packet: id), row: PacketTableRow(packet: packet))
        entry.finish(nodes: [], text: "", bytes: bytes)
        return entry
    }

    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(predicate())
    }
}

// A controlled worker exercises request ordering even when cancellation arrives just after work finishes.
private final class ComparisonProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var recorded: [Data] = []
    var calls: [Data] { lock.withLock { recorded } }
    func releaseFirst() { gate.signal() }
    func compare(_ left: Data, _ right: Data, _ tracker: HFProgressTracker) -> DiffBinaryComparison? {
        let first = lock.withLock {
            recorded.append(right)
            return recorded.count == 1
        }
        if first { _ = gate.wait(timeout: .now() + 3) }
        return DiffBinaryComparison(changes: [DiffByteChange(left: 0..<left.count, right: 0..<right.count)])
    }
}
