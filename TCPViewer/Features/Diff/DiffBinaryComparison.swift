//
//  DiffBinaryComparison.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import Foundation
import HexFiend

struct DiffByteChange: Equatable {
    let left: Range<Int>
    let right: Range<Int>

    var description: String {
        if left.isEmpty { return "Added \(right.count) bytes at Right 0x\(String(right.lowerBound, radix: 16).uppercased())" }
        if right.isEmpty { return "Removed \(left.count) bytes at Left 0x\(String(left.lowerBound, radix: 16).uppercased())" }
        return "Changed \(left.count) → \(right.count) bytes · Left 0x\(String(left.lowerBound, radix: 16).uppercased()) · Right 0x\(String(right.lowerBound, radix: 16).uppercased())"
    }
}

struct DiffBinaryComparison {
    let changes: [DiffByteChange]

    // Compare bytes directly so an insertion does not mark every subsequent hex row as changed.
    static func compare(left: Data, right: Data, tracker: HFProgressTracker) -> DiffBinaryComparison? {
        if left == right { return DiffBinaryComparison(changes: []) }
        let source = HFBTreeByteArray(byteSlice: HFFullMemoryByteSlice(data: left))
        let destination = HFBTreeByteArray(byteSlice: HFFullMemoryByteSlice(data: right))
        guard let script = HFByteArrayEditScript(differenceFromSource: source, toDestination: destination,
            onlyReplace: false, skipOneByteMatches: false, trackingProgress: tracker) else { return nil }
        let changes = (0..<script.numberOfInstructions()).compactMap { index -> DiffByteChange? in
            let instruction = script.instruction(at: index)
            guard instruction.src.length > 0 || instruction.dst.length > 0 else { return nil }
            let leftStart = Int(instruction.src.location), rightStart = Int(instruction.dst.location)
            return DiffByteChange(left: leftStart..<(leftStart + Int(instruction.src.length)),
                                  right: rightStart..<(rightStart + Int(instruction.dst.length)))
        }
        return DiffBinaryComparison(changes: changes)
    }

    // Map matching bytes across insertions/deletions to keep both scrolling panes near the same content.
    func correspondingOffset(_ offset: Int, from side: DiffSide) -> Int {
        var delta = 0
        for change in changes {
            let source = side == .left ? change.left : change.right
            let destination = side == .left ? change.right : change.left
            if offset < source.lowerBound { break }
            if offset < source.upperBound {
                return destination.lowerBound + min(offset - source.lowerBound, destination.count)
            }
            delta = destination.upperBound - source.upperBound
        }
        return max(0, offset + delta)
    }
}

struct DiffBinaryPair: Equatable {
    let left: UUID
    let right: UUID
}

protocol DiffBinaryModelDelegate: AnyObject {
    func diffBinaryModelDidChange(_ model: DiffBinaryModel)
}

final class DiffBinaryModel {
    typealias Compare = (Data, Data, HFProgressTracker) -> DiffBinaryComparison?
    private struct Request {
        let id = UUID()
        let pair: DiffBinaryPair
        let left: Data
        let right: Data
    }

    weak var delegate: DiffBinaryModelDelegate?
    private(set) var comparison: DiffBinaryComparison?
    private(set) var isComparing = false
    private(set) var failed = false
    private let queue = DispatchQueue(label: "com.proxyman.tcpviewer.binary-diff", qos: .userInitiated)
    private let compare: Compare
    private var requested: Request?
    private var pending: Request?
    private var tracker: HFProgressTracker?
    private var cached: (DiffBinaryPair, DiffBinaryComparison)?

    init(compare: @escaping Compare = { DiffBinaryComparison.compare(left: $0, right: $1, tracker: $2) }) {
        self.compare = compare
    }

    // Keep at most one comparison running and one pending pair when users quickly switch sources.
    func render(left: Data, right: Data, pair: DiffBinaryPair) {
        guard requested?.pair != pair else { return }
        tracker?.requestCancel(self)
        let request = Request(pair: pair, left: left, right: right)
        requested = request
        failed = false
        if let cached, cached.0 == pair {
            comparison = cached.1
            pending = nil
            isComparing = false
        } else {
            comparison = nil
            pending = request
            isComparing = true
            drain()
        }
        delegate?.diffBinaryModelDidChange(self)
    }

    func clear() {
        tracker?.requestCancel(self)
        requested = nil
        pending = nil
        comparison = nil
        isComparing = false
        failed = false
    }

    private func drain() {
        guard tracker == nil, let request = pending else { return }
        pending = nil
        let tracker = HFProgressTracker()
        self.tracker = tracker
        let compare = self.compare
        queue.async { [weak self] in
            let result = autoreleasepool { compare(request.left, request.right, tracker) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tracker = nil
                if self.requested?.id == request.id {
                    self.comparison = result
                    self.isComparing = false
                    self.failed = result == nil
                    if let result { self.cached = (request.pair, result) }
                    self.delegate?.diffBinaryModelDidChange(self)
                }
                self.drain()
            }
        }
    }

    deinit { tracker?.requestCancel(self) }
}
