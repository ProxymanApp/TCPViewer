//
//  DiffPoolAutomation.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import Foundation
import HexFiend
import PcapPlusPlusCore

// MCP and CLI drive the Diff window's pool directly; errors are returned instead of shown as sheets.
final class DiffPoolAutomation {
    typealias Values = [String: TCPViewerMCPValue]
    typealias Completion = (TCPViewerMCPResponse) -> Void
    private typealias Router = TCPViewerAutomationCommandRouter

    private enum Limit {
        static let defaultResultCount = 1_000
        static let maximumResultCount = 5_000
        static let maximumContextLineCount = 20
        static let maximumPreviewByteCount = 256
        // 200 polls of 50 ms wait at most 10 seconds for the pool's serial inspections.
        static let loadingPollCount = 200
    }

    private enum SideChange {
        case keep
        case clear
        case assign(DiffPacketEntry)
    }

    private static let redactor = TCPViewerMCPSensitiveDataRedactor()
    private let pool: DiffPoolModel
    private let isLicenseAuthorized: () -> Bool
    private let isWindowOpen: () -> Bool
    private let openWindow: () -> Void
    // A serial queue runs one comparison at a time, which bounds its transient memory.
    private let queue = DispatchQueue(label: "com.proxyman.tcpviewer.diff-automation", qos: .userInitiated)

    init(pool: DiffPoolModel, isLicenseAuthorized: @escaping () -> Bool,
         isWindowOpen: @escaping () -> Bool = { false }, openWindow: @escaping () -> Void = {}) {
        self.pool = pool
        self.isLicenseAuthorized = isLicenseAuthorized
        self.isWindowOpen = isWindowOpen
        self.openWindow = openWindow
    }

    // Route the app-wide pool commands; add_diff_packets resolves its capture first and calls add.
    func route(_ command: TCPViewerMCPCommand, request: TCPViewerMCPRequest,
               redactionEnabled: @escaping () -> Bool, completion: @escaping Completion) throws {
        switch command {
        case .getDiffPool:
            completion(.success(poolData()))
        case .updateDiffPool:
            completion(.success(try update(request)))
        case .removeDiffPackets:
            completion(.success(try remove(request)))
        case .openDiffView:
            openWindow()
            completion(.success(poolData()))
        case .compareDiffPackets:
            try compare(request, redactionEnabled: redactionEnabled, completion: completion)
        default:
            throw Router.invalid("Unsupported Diff command.")
        }
    }

    // Describe the whole pool; it holds at most 500 small items, so no paging is needed.
    func poolData() -> Values {
        let authorized = isLicenseAuthorized()
        return ["entries": .array(pool.entries.map { .object(entryData($0)) }),
                "entry_count": .int(pool.entries.count),
                "left_entry_id": pool.left.map { .string(Self.identifier($0)) } ?? .null,
                "right_entry_id": pool.right.map { .string(Self.identifier($0)) } ?? .null,
                "display_mode": .string(pool.displayMode.automationName),
                "content": .string(pool.contentKind.automationName),
                "capacity": .int(authorized ? DiffPoolModel.maximumEntryCount : DiffPoolModel.freeEntryLimit),
                "remaining_capacity": .int(pool.remainingCapacity(isLicenseAuthorized: authorized)),
                "window_open": .bool(isWindowOpen())]
    }

    // Validate every packet and the pool limit before snapshotting, so a rejected call changes nothing.
    func add(_ request: TCPViewerMCPRequest, workspace: TCPViewerCaptureWorkspace) throws -> Values {
        guard let items = request.array("packet_ids"), !items.isEmpty, items.count <= DiffPoolModel.maximumEntryCount else {
            throw Router.invalid("packet_ids requires 1 to \(DiffPoolModel.maximumEntryCount) packet IDs.")
        }
        let state = workspace.controller.snapshot.packetIngestState
        let packets = try items.map { value -> PacketSummary in
            let id = try Router.require(value.stringValue.flatMap(UInt64.init), "packet_ids must be unsigned decimal strings.")
            return try Router.require(state.packet(withID: id), "Packet \(id) was not found in this capture.")
        }
        let ids = packets.map { DiffPacketID(capture: workspace.diffIdentity, lineage: state.packetLineageRevision, packet: $0.id) }
        let authorized = isLicenseAuthorized()
        let addedCount = Set(ids.filter { !pool.contains($0) }).count
        guard addedCount <= pool.remainingCapacity(isLicenseAuthorized: authorized) else {
            throw Router.invalid(authorized
                ? "The Diff pool holds up to \(DiffPoolModel.maximumEntryCount) items. Remove items to add more."
                : "The Free version allows \(DiffPoolModel.freeEntryLimit) Diff items. Remove items or activate TCP Viewer PRO.")
        }
        pool.add(rows: packets.map { PacketTableRow(packet: $0) }, from: workspace, isLicenseAuthorized: authorized)
        var data = poolData()
        data["added_count"] = .int(addedCount)
        // Entry IDs follow the request order, so callers can pair each packet with its snapshot.
        data["entry_ids"] = .array(ids.map { id in pool.entry(id).map { .string(Self.identifier($0)) } ?? .null })
        return data
    }

    // Validate both sides and modes before changing what the Diff window compares.
    private func update(_ request: TCPViewerMCPRequest) throws -> Values {
        let changes: [(SideChange, DiffSide)] = [(try sideChange("left_entry_id", request), .left),
                                                 (try sideChange("right_entry_id", request), .right)]
        if case .assign(let left) = changes[0].0, case .assign(let right) = changes[1].0, left === right {
            throw Router.invalid("left_entry_id and right_entry_id must be different items.")
        }
        let mode = try request.automationString("display_mode").map {
            try Router.require(DiffDisplayMode(automationName: $0), "display_mode must be side_by_side or unified.")
        }
        let content = try contentKind(request)
        for (change, side) in changes {
            switch change {
            case .keep: break
            case .clear: if let current = side == .left ? pool.left : pool.right { pool.assign(nil, to: current.id) }
            case .assign(let entry): pool.assign(side, to: entry.id)
            }
        }
        if let mode { pool.setDisplayMode(mode) }
        if let content { pool.setContentKind(content) }
        return poolData()
    }

    // Resolve every ID before removing, so one stale ID cannot leave a partial removal behind.
    private func remove(_ request: TCPViewerMCPRequest) throws -> Values {
        let removesAll = try request.automationBool("all", default: false)
        let items = request.array("entry_ids")
        guard removesAll != (items != nil) else { throw Router.invalid("Supply either an entry_ids array or all=true.") }
        let removed: [DiffPacketEntry]
        if removesAll {
            guard try request.automationBool("confirm", default: false) else {
                throw Router.invalid("Removing every Diff item requires confirm=true.")
            }
            removed = pool.entries
        } else {
            guard let items, !items.isEmpty, items.count <= DiffPoolModel.maximumEntryCount else {
                throw Router.invalid("entry_ids requires 1 to \(DiffPoolModel.maximumEntryCount) entry IDs.")
            }
            removed = try items.map { try entry($0, key: "entry_ids") }
        }
        pool.remove(Set(removed.map(\.id)))
        var data = poolData()
        data["removed_count"] = .int(Set(removed.map(\.id)).count)
        return data
    }

    // Compare two snapshots off the main thread; omitted fields mirror what the Diff window shows.
    private func compare(_ request: TCPViewerMCPRequest, redactionEnabled: @escaping () -> Bool,
                         completion: @escaping Completion) throws {
        let left = try request.value("left_entry_id").map { try entry($0, key: "left_entry_id") }
            ?? Router.require(pool.left, "No Left item is selected. Pass left_entry_id or use update_diff_pool.")
        let right = try request.value("right_entry_id").map { try entry($0, key: "right_entry_id") }
            ?? Router.require(pool.right, "No Right item is selected. Pass right_entry_id or use update_diff_pool.")
        guard left !== right else { throw Router.invalid("Choose two different Diff items.") }
        let content = try contentKind(request) ?? pool.contentKind
        let context = try request.automationInt("context", default: 3, range: 0...Limit.maximumContextLineCount)
        let limit = try request.automationInt("limit", default: Limit.defaultResultCount, range: 1...Limit.maximumResultCount)
        // Arbitrary binary payloads cannot be scrubbed, matching the get_packet_bytes policy.
        let redacted = redactionEnabled()
        if redacted, content == .packetBytes { throw TCPViewerMCPCommandRouterError.rawBytesRequireRedactionDisabled }

        whenLoaded([left, right], remaining: Limit.loadingPollCount) { [weak self] error in
            guard let self, error == nil else { completion(.failure(error ?? "TCP Viewer is unavailable.")); return }
            let leftNodes = left.detailNodes, rightNodes = right.detailNodes
            let leftText = left.text ?? "", rightText = right.text ?? ""
            let leftBytes = left.bytes ?? Data(), rightBytes = right.bytes ?? Data()
            self.queue.async {
                let result: Values?
                if content == .packetBytes {
                    result = Self.byteComparison(left: leftBytes, right: rightBytes, limit: limit)
                } else if redacted {
                    result = Self.textComparison(left: DiffPacketTextBuilder.text(nodes: Self.redactedNodes(leftNodes)),
                                                 right: DiffPacketTextBuilder.text(nodes: Self.redactedNodes(rightNodes)),
                                                 context: context, limit: limit)
                } else {
                    result = Self.textComparison(left: leftText, right: rightText, context: context, limit: limit)
                }
                DispatchQueue.main.async {
                    // Privacy is checked again because a comparison can outlive a settings change.
                    guard redactionEnabled() == redacted else {
                        completion(.failure("The redaction setting changed during the comparison. Retry.")); return
                    }
                    guard var data = result else { completion(.failure("The packet bytes could not be compared.")); return }
                    data["content"] = .string(content.automationName)
                    data["redacted"] = .bool(redacted)
                    data["left"] = .object(self.entryData(left))
                    data["right"] = .object(self.entryData(right))
                    completion(.success(data))
                }
            }
        }
    }

    // Inspections drain serially, so poll only this bounded pair instead of observing the whole pool.
    private func whenLoaded(_ entries: [DiffPacketEntry], remaining: Int, completion: @escaping (String?) -> Void) {
        if let failed = entries.first(where: { $0.errorMessage != nil }) {
            completion("Could not load packet \(failed.id.packet): \(failed.errorMessage ?? "")"); return
        }
        guard entries.contains(where: { $0.text == nil }) else { completion(nil); return }
        // A removed entry is never inspected, so waiting for it would only run out the deadline.
        guard entries.allSatisfy({ pool.entry($0.id) === $0 }) else {
            completion("A compared item was removed from the Diff pool."); return
        }
        guard remaining > 0 else { completion("The packets are still loading. Retry shortly."); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { completion("TCP Viewer is unavailable."); return }
            self.whenLoaded(entries, remaining: remaining - 1, completion: completion)
        }
    }

    // Report the same line changes the Packet Details editor highlights, as a unified diff.
    private static func textComparison(left: String, right: String, context: Int, limit: Int) -> Values {
        let comparison = DiffTextComparison.compare(left: left, right: right, context: context, limit: limit)
        return ["identical": .bool(left == right), "diff": .string(comparison.unifiedDiff),
                "left_line_count": .int(comparison.leftLineCount), "right_line_count": .int(comparison.rightLineCount),
                "added_line_count": .int(comparison.addedLineCount), "removed_line_count": .int(comparison.removedLineCount),
                "returned_line_count": .int(comparison.returnedLineCount),
                "truncated": .bool(comparison.isOutputTruncated), "lines_truncated": .bool(comparison.isInputTruncated)]
    }

    // Report byte ranges from the same HexFiend edit script the Packet Bytes panes highlight.
    private static func byteComparison(left: Data, right: Data, limit: Int) -> Values? {
        guard let comparison = DiffBinaryComparison.compare(left: left, right: right, tracker: HFProgressTracker()) else { return nil }
        let changes = comparison.changes.prefix(limit).map { change -> TCPViewerMCPValue in
            .object(["kind": .string(change.left.isEmpty ? "added" : change.right.isEmpty ? "removed" : "changed"),
                     "left_offset": .int(change.left.lowerBound), "left_length": .int(change.left.count),
                     "right_offset": .int(change.right.lowerBound), "right_length": .int(change.right.count),
                     "left_hex": .string(hexPreview(left, change.left)), "right_hex": .string(hexPreview(right, change.right))])
        }
        return ["identical": .bool(comparison.changes.isEmpty), "changes": .array(changes),
                "change_count": .int(comparison.changes.count), "returned_change_count": .int(changes.count),
                "left_byte_count": .int(left.count), "right_byte_count": .int(right.count),
                "truncated": .bool(changes.count < comparison.changes.count)]
    }

    // Cap each preview so one large changed range cannot dominate the response.
    private static func hexPreview(_ data: Data, _ range: Range<Int>) -> String {
        data.dropFirst(range.lowerBound).prefix(min(range.count, Limit.maximumPreviewByteCount))
            .map { String(format: "%02x", $0) }.joined()
    }

    // Scrub values the way get_packet_details does, before the text is built and compared.
    private static func redactedNodes(_ nodes: [PacketDetailNode]) -> [PacketDetailNode] {
        func redact(_ node: PacketDetailNode) -> PacketDetailNode {
            let isSensitive = redactor.isSensitiveName(node.fieldName) || redactor.isSensitiveName(node.name)
            let value = node.value.map { isSensitive ? TCPViewerMCPSensitiveDataRedactor.placeholder : redactor.redact($0) }
            return PacketDetailNode(id: node.id, name: redactor.redact(node.name), fieldName: node.fieldName, value: value,
                                    kind: node.kind, severity: node.severity, children: node.children.map(redact))
        }
        return nodes.map(redact)
    }

    // Use the pool table's own row text, so automation reads what the Diff window lists.
    private func entryData(_ entry: DiffPacketEntry) -> Values {
        let row = entry.row
        var data: Values = [
            "entry_id": .string(Self.identifier(entry)), "packet_id": .string(String(entry.id.packet)),
            "side": entry.side.map { .string($0 == .left ? "left" : "right") } ?? .null,
            "status": .string(entry.errorMessage != nil ? "failed" : entry.text == nil ? "loading" : "ready"),
            "source_available": .bool(entry.currentWorkspace != nil),
            "number": .string(row.numberText), "time": .string(row.timeText),
            "source": .string(row.sourceText), "destination": .string(row.destinationText),
            "protocol": .string(row.protocolText), "length": .string(row.lengthText), "summary": .string(row.summaryText),
        ]
        if let error = entry.errorMessage { data["error"] = .string(error) }
        if let bytes = entry.bytes { data["byte_count"] = .int(bytes.count) }
        return data
    }

    // A side field is left alone when omitted, cleared by null, and assigned by an entry ID.
    private func sideChange(_ key: String, _ request: TCPViewerMCPRequest) throws -> SideChange {
        guard let value = request.value(key) else { return .keep }
        return value == .null ? .clear : .assign(try entry(value, key: key))
    }

    // An omitted content keeps the caller's default; an unknown value is rejected.
    private func contentKind(_ request: TCPViewerMCPRequest) throws -> DiffContentKind? {
        try request.automationString("content").map {
            try Router.require(DiffContentKind(automationName: $0), "content must be details or bytes.")
        }
    }

    // Resolve an entry_id against the current pool; removed items fail instead of matching a newer snapshot.
    private func entry(_ value: TCPViewerMCPValue, key: String) throws -> DiffPacketEntry {
        let id = try Router.require(value.stringValue.flatMap(UUID.init(uuidString:)), "\(key) must contain entry_id UUIDs from get_diff_pool.")
        return try Router.require(pool.entries.first { $0.snapshotIdentity == id },
                                  "Diff item \(id.uuidString.lowercased()) was not found. Use get_diff_pool.")
    }

    // Each snapshot has its own identity, which stays stable while packet IDs repeat across captures.
    private static func identifier(_ entry: DiffPacketEntry) -> String { entry.snapshotIdentity.uuidString.lowercased() }
}

extension DiffDisplayMode {
    var automationName: String { self == .sideBySide ? "side_by_side" : "unified" }
    init?(automationName: String) {
        guard let mode = Self.allCases.first(where: { $0.automationName == automationName }) else { return nil }
        self = mode
    }
}

extension DiffContentKind {
    var automationName: String { self == .packetDetails ? "details" : "bytes" }
    init?(automationName: String) {
        guard let kind = Self.allCases.first(where: { $0.automationName == automationName }) else { return nil }
        self = kind
    }
}
