//
//  DiffTextComparison.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import Foundation

// The Diff window renders text changes in Monaco; automation needs the same result as plain text.
struct DiffTextComparison: Equatable {
    // Myers keeps O(D²) state, so capping each side also bounds memory when two packets share nothing.
    static let maximumLineCount = 2_000

    let unifiedDiff: String
    let leftLineCount: Int
    let rightLineCount: Int
    let addedLineCount: Int
    let removedLineCount: Int
    let returnedLineCount: Int
    let isOutputTruncated: Bool
    let isInputTruncated: Bool

    // Compare line by line and emit `diff -U` style hunks, stopping at the caller's output limit.
    static func compare(left: String, right: String, context: Int, limit: Int) -> DiffTextComparison {
        let leftLines = lines(left), rightLines = lines(right)
        let old = Array(leftLines.prefix(maximumLineCount)), new = Array(rightLines.prefix(maximumLineCount))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Walk both sides once so every line becomes a removal, an insertion, or shared context.
        var edits: [(marker: Character, left: Int, right: Int)] = []
        var leftIndex = 0, rightIndex = 0
        while leftIndex < old.count || rightIndex < new.count {
            if leftIndex < old.count, removed.contains(leftIndex) {
                edits.append(("-", leftIndex, rightIndex))
                leftIndex += 1
            } else if rightIndex < new.count, inserted.contains(rightIndex) {
                edits.append(("+", leftIndex, rightIndex))
                rightIndex += 1
            } else {
                edits.append((" ", leftIndex, rightIndex))
                leftIndex += 1
                rightIndex += 1
            }
        }

        // Changes whose context lines touch share one hunk.
        var hunks: [ClosedRange<Int>] = []
        for index in edits.indices where edits[index].marker != " " {
            let lower = max(0, index - context), upper = min(edits.count - 1, index + context)
            if let last = hunks.last, lower <= last.upperBound + 1 {
                hunks[hunks.count - 1] = last.lowerBound...upper
            } else {
                hunks.append(lower...upper)
            }
        }

        var output: [String] = []
        var isOutputTruncated = false
        emit: for hunk in hunks {
            let hunkEdits = edits[hunk]
            let leftCount = hunkEdits.filter { $0.marker != "+" }.count
            let rightCount = hunkEdits.filter { $0.marker != "-" }.count
            // An empty side reports the line before the change, matching the unified diff format.
            let leftStart = hunkEdits[hunk.lowerBound].left + (leftCount == 0 ? 0 : 1)
            let rightStart = hunkEdits[hunk.lowerBound].right + (rightCount == 0 ? 0 : 1)
            guard output.count < limit else { isOutputTruncated = true; break }
            output.append("@@ -\(leftStart),\(leftCount) +\(rightStart),\(rightCount) @@")
            for edit in hunkEdits {
                guard output.count < limit else { isOutputTruncated = true; break emit }
                output.append("\(edit.marker)\(edit.marker == "+" ? new[edit.right] : old[edit.left])")
            }
        }

        return DiffTextComparison(
            unifiedDiff: output.joined(separator: "\n"),
            leftLineCount: leftLines.count, rightLineCount: rightLines.count,
            addedLineCount: inserted.count, removedLineCount: removed.count,
            returnedLineCount: output.count, isOutputTruncated: isOutputTruncated,
            isInputTruncated: leftLines.count > maximumLineCount || rightLines.count > maximumLineCount
        )
    }

    private static func lines(_ text: String) -> [Substring] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
