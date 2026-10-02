//
//  DiffPoolModel.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import Foundation
import PcapPlusPlusCore

struct DiffPacketID: Hashable {
    let capture: UUID
    let lineage: UInt64
    let packet: PacketSummary.ID
}

enum DiffSide { case left, right }

enum DiffDisplayMode: String, CaseIterable {
    case sideBySide, unified
    var title: String { self == .sideBySide ? "Side By Side" : "Unified" }
    var editorOptions: [String: Any] {
        ["renderSideBySide": self == .sideBySide, "ignoreTrimWhitespace": false]
    }
}

final class DiffPacketEntry {
    let id: DiffPacketID
    var row: PacketTableRow
    var side: DiffSide?
    private(set) var detailNodes: [PacketDetailNode] = []
    private var customValues: [String: String] = [:]
    private(set) var text: String?
    private(set) var errorMessage: String?
    weak var workspace: TCPViewerCaptureWorkspace?

    init(id: DiffPacketID, row: PacketTableRow, workspace: TCPViewerCaptureWorkspace? = nil) {
        self.id = id
        self.row = row
        self.workspace = workspace
    }

    var currentWorkspace: TCPViewerCaptureWorkspace? {
        guard let workspace, workspace.diffIdentity == id.capture, !workspace.isClosed,
              workspace.controller.snapshot.packetIngestState.packetLineageRevision == id.lineage,
              workspace.controller.snapshot.packetIngestState.packet(withID: id.packet) != nil else { return nil }
        return workspace
    }

    // Retain owned detail rows and text, rather than raw buffers or an entire capture document.
    func finish(nodes: [PacketDetailNode], text: String) {
        detailNodes = nodes
        self.text = text
    }

    func fail(_ error: Error) { errorMessage = error.localizedDescription }

    func customValue(_ column: PacketCustomColumn) -> String {
        guard text != nil else { return "" }
        if let cached = customValues[column.fieldName] { return cached }
        let value = PacketCustomColumnService.resolvedValue(fieldName: column.fieldName, in: PacketInspection(
            packetID: id.packet, packetNumber: id.packet, rawBytes: Data(), detailNodes: detailNodes, decodeStatus: PacketDecodeStatus(kind: .complete)
        ))
        customValues[column.fieldName] = value
        return value
    }
}

protocol DiffPoolModelDelegate: AnyObject {
    func diffPoolModelDidChange(_ model: DiffPoolModel)
}

final class DiffPoolModel {
    typealias Inspect = (@escaping TCPViewerCompletion<PacketInspection>) -> Void
    private struct PendingInspection {
        let entry: DiffPacketEntry
        let inspect: Inspect
    }

    weak var delegate: DiffPoolModelDelegate?
    private(set) var entries: [DiffPacketEntry] = []
    private var entriesByID: [DiffPacketID: DiffPacketEntry] = [:]
    private var pending: [PendingInspection] = []
    private var pendingIndex = 0
    private var isInspecting = false
    private var changeWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.proxyman.tcpviewer.diff-content")
    private let defaults: UserDefaults
    private(set) var displayMode: DiffDisplayMode

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = defaults.string(forKey: "TCPViewer.diff.displayMode").flatMap(DiffDisplayMode.init(rawValue:)) ?? .sideBySide
    }

    var left: DiffPacketEntry? { entries.first { $0.side == .left } }
    var right: DiffPacketEntry? { entries.first { $0.side == .right } }

    // Preserve Proxyman's pool ordering and its empty-pool/one-item auto-selection rules.
    func add(_ additions: [(DiffPacketEntry, Inspect)]) {
        let wasEmpty = entries.isEmpty
        let hadOne = entries.count == 1
        for (entry, inspect) in additions where entriesByID[entry.id] == nil {
            entries.append(entry)
            entriesByID[entry.id] = entry
            pending.append(PendingInspection(entry: entry, inspect: inspect))
        }
        if wasEmpty {
            if let first = entries.first { assign(.left, to: first.id, notify: false) }
            if entries.count > 1 { assign(.right, to: entries[1].id, notify: false) }
        } else if hadOne, entries.count > 1, entries[1].side == nil {
            assign(.right, to: entries[1].id, notify: false)
        }
        notifyChange()
        drain()
    }

    func assign(_ side: DiffSide?, to id: DiffPacketID, notify: Bool = true) {
        guard let entry = entriesByID[id] else { return }
        if let side {
            entries.filter { $0 !== entry && $0.side == side }.forEach { $0.side = nil }
        }
        entry.side = side
        if notify { notifyChange() }
    }

    func remove(_ ids: Set<DiffPacketID>) {
        entries.removeAll { ids.contains($0.id) }
        ids.forEach {
            entriesByID[$0]?.side = nil
            entriesByID.removeValue(forKey: $0)
        }
        notifyChange()
    }

    func removeAll() { remove(Set(entriesByID.keys)) }

    func setDisplayMode(_ mode: DiffDisplayMode) {
        displayMode = mode
        defaults.set(mode.rawValue, forKey: "TCPViewer.diff.displayMode")
        notifyChange()
    }

    // Style mutations remain useful for snapshots after their original capture has closed.
    func apply(_ mutation: PacketTextStyleMutation, to ids: Set<DiffPacketID>) {
        for id in ids {
            guard let entry = entriesByID[id] else { continue }
            entry.row.textStyle = mutation.applying(to: entry.row.textStyle)
            if let workspace = entry.currentWorkspace {
                workspace.controller.applyTextStyleMutation(.replace(entry.row.textStyle), packetIDs: [id.packet])
            }
        }
        notifyChange()
    }

    func setComment(_ comment: String, on ids: Set<DiffPacketID>) {
        let comment = PacketComment.sanitized(comment)
        for id in ids {
            guard let entry = entriesByID[id] else { continue }
            entry.row.comment = comment
            entry.row.commentText = comment.components(separatedBy: .newlines).joined(separator: " ")
            entry.currentWorkspace?.controller.setCustomComment(comment, packetIDs: [id.packet])
        }
        notifyChange()
    }

    // One native inspection at a time prevents large selections from flooding the capture decoder.
    private func drain() {
        guard !isInspecting else { return }
        while pendingIndex < pending.count {
            let work = pending[pendingIndex]
            pendingIndex += 1
            guard entriesByID[work.entry.id] === work.entry else { continue }
            isInspecting = true
            work.inspect { [weak self, weak entry = work.entry] result in
                guard let self else { return }
                self.queue.async {
                    let output = result.map { inspection -> ([PacketDetailNode], String) in
                        let nodes = inspection.detailNodes.map(Self.ownedNode)
                        return (nodes, DiffPacketTextBuilder.text(nodes: nodes))
                    }
                    DispatchQueue.main.async {
                        if let entry, self.entriesByID[entry.id] === entry {
                            switch output {
                            case .success(let (nodes, text)): entry.finish(nodes: nodes, text: text)
                            case .failure(let error): entry.fail(error)
                            }
                            self.notifyChange()
                        }
                        self.isInspecting = false
                        self.drain()
                    }
                }
            }
            return
        }
        pending.removeAll()
        pendingIndex = 0
    }

    // Native decode strings must outlive the source that originally owned their backing storage.
    private static func ownedNode(_ node: PacketDetailNode) -> PacketDetailNode {
        func owned(_ string: String) -> String { String(decoding: string.utf8, as: UTF8.self) }
        return PacketDetailNode(
            id: owned(node.id), name: owned(node.name), fieldName: owned(node.fieldName),
            value: node.value.map(owned), rawValue: node.rawValue.map(owned),
            displayFilterExpression: node.displayFilterExpression.map(owned), kind: node.kind,
            severity: node.severity, byteRange: node.byteRange, jumpTargetPacketID: node.jumpTargetPacketID,
            children: node.children.map(ownedNode)
        )
    }

    private func notifyChange() {
        guard changeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changeWork = nil
            self.delegate?.diffPoolModelDidChange(self)
        }
        changeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    deinit { changeWork?.cancel() }
}

enum DiffPacketTextBuilder {
    // The inspector's Copy All path includes generated summary rows and every collapsed child.
    static func text(nodes: [PacketDetailNode]) -> String {
        let model = PacketInspectorTreeViewModel()
        var state = PacketInspectionState.empty
        state.selectedPacketID = 0
        state.inspection = PacketInspection(packetID: 0, packetNumber: 0, rawBytes: Data(), detailNodes: nodes, decodeStatus: PacketDecodeStatus(kind: .complete))
        model.render(inspectionState: state)
        return PacketInspectorCopyFormatter.text(for: model.copyRowsForAllDetails())
    }
}
