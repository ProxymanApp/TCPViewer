//
//  DiffTextComparisonTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct DiffTextComparisonTests {
    @Test func identicalAndEmptyTextsProduceNoHunks() {
        for text in ["", "TCP\n\tFlags: ACK"] {
            let result = DiffTextComparison.compare(left: text, right: text, context: 3, limit: 100)
            #expect(result.unifiedDiff.isEmpty && result.returnedLineCount == 0)
            #expect(result.addedLineCount == 0 && result.removedLineCount == 0)
            #expect(!result.isOutputTruncated && !result.isInputTruncated)
        }
        #expect(DiffTextComparison.compare(left: "", right: "", context: 3, limit: 100).leftLineCount == 0)
    }

    @Test func changedLineKeepsIndentationAndSurroundingContext() {
        let left = "TCP\n\tSource Port: 1234\n\tSequence: 1\n\tFlags: ACK\n\tWindow: 64"
        let right = "TCP\n\tSource Port: 1234\n\tSequence: 2\n\tFlags: ACK\n\tWindow: 64"
        let result = DiffTextComparison.compare(left: left, right: right, context: 1, limit: 100)
        #expect(result.unifiedDiff == "@@ -2,3 +2,3 @@\n \tSource Port: 1234\n-\tSequence: 1\n+\tSequence: 2\n \tFlags: ACK")
        #expect(result.leftLineCount == 5 && result.rightLineCount == 5)
        #expect(result.addedLineCount == 1 && result.removedLineCount == 1 && result.returnedLineCount == 5)
    }

    @Test func insertionsAndRemovalsUseUnifiedRangesForEmptySides() {
        let added = DiffTextComparison.compare(left: "A\nB", right: "A\nB\nC", context: 0, limit: 100)
        #expect(added.unifiedDiff == "@@ -2,0 +3,1 @@\n+C")
        let removed = DiffTextComparison.compare(left: "A\nB\nC", right: "B\nC", context: 0, limit: 100)
        #expect(removed.unifiedDiff == "@@ -1,1 +0,0 @@\n-A")
        let fromEmpty = DiffTextComparison.compare(left: "", right: "A", context: 3, limit: 100)
        #expect(fromEmpty.unifiedDiff == "@@ -0,0 +1,1 @@\n+A")
    }

    @Test func distantChangesSplitIntoHunksAndTouchingContextMerges() {
        let left = (1...20).map { "line \($0)" }
        var right = left
        right[1] = "changed 2"
        right[17] = "changed 18"
        let split = DiffTextComparison.compare(left: left.joined(separator: "\n"), right: right.joined(separator: "\n"), context: 2, limit: 100)
        #expect(split.unifiedDiff.components(separatedBy: "\n").filter { $0.hasPrefix("@@") } == ["@@ -1,4 +1,4 @@", "@@ -16,5 +16,5 @@"])
        let merged = DiffTextComparison.compare(left: left.joined(separator: "\n"), right: right.joined(separator: "\n"), context: 8, limit: 100)
        #expect(merged.unifiedDiff.components(separatedBy: "\n").filter { $0.hasPrefix("@@") } == ["@@ -1,20 +1,20 @@"])
    }

    @Test func outputLimitAndPerSideLineCapAreReported() {
        let left = (1...50).map { "left \($0)" }.joined(separator: "\n")
        let right = (1...50).map { "right \($0)" }.joined(separator: "\n")
        let limited = DiffTextComparison.compare(left: left, right: right, context: 0, limit: 10)
        #expect(limited.returnedLineCount == 10 && limited.isOutputTruncated)
        #expect(limited.addedLineCount == 50 && limited.removedLineCount == 50)

        let shared = (1...DiffTextComparison.maximumLineCount).map { "line \($0)" }.joined(separator: "\n")
        let capped = DiffTextComparison.compare(left: shared + "\nleft tail", right: shared + "\nright tail", context: 3, limit: 100)
        // Lines past the cap are not compared, so the caller must be told the result is partial.
        #expect(capped.isInputTruncated && capped.unifiedDiff.isEmpty)
        #expect(capped.leftLineCount == DiffTextComparison.maximumLineCount + 1)
    }
}
