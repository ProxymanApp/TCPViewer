//
//  TCPViewerPaneSelection.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import Foundation
import PcapPlusPlusCore

/// Keeps asynchronous packet inspection local to one pane of a shared source.
final class TCPViewerPaneSelection {
    private weak var controller: TCPViewerWorkspaceController?
    private var generation = 0
    private var backingIdentity: String?
    private var lineage: UInt64?
    private(set) var state = PacketInspectionState.empty
    var didChange: (() -> Void)?

    init(controller: TCPViewerWorkspaceController) { self.controller = controller }

    // Reject completions from old selections, closed panes, or a cleared capture.
    func select(_ id: PacketSummary.ID?) {
        generation += 1
        let requestGeneration = generation
        let detailID = state.selectedPacketID == id ? state.selectedDetailNodeID : nil
        state = .empty
        guard let controller, let id,
              controller.snapshot.packetIngestState.packet(withID: id) != nil else { didChange?(); return }
        let ingest = controller.snapshot.packetIngestState
        backingIdentity = ingest.backingIdentity
        lineage = ingest.packetLineageRevision
        state.selectedPacketID = id
        state.isLoading = true
        didChange?()
        controller.inspectPacket(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration,
                      self.isCurrentSource, self.state.selectedPacketID == id else { return }
                self.state.isLoading = false
                switch result {
                case .success(let inspection):
                    self.state.inspection = inspection
                    self.state.selectedDetailNodeID = detailID
                    self.state.highlightedByteRange = self.find(detailID, nodes: inspection.detailNodes)?.byteRange
                    self.state.statusMessage = "Inspecting packet \(inspection.packetNumber)."
                case .failure(let error): self.state.statusMessage = error.localizedDescription
                }
                self.didChange?()
            }
        }
    }

    func selectDetail(_ id: String?) {
        state.selectedDetailNodeID = id
        state.highlightedByteRange = find(id, nodes: state.inspection?.detailNodes ?? [])?.byteRange
        didChange?()
    }

    // Keep the selected ID across suspension without retaining decoded byte buffers.
    func suspend() {
        generation += 1
        state.inspection = nil
        state.isLoading = false
    }

    func refreshSource() {
        guard let id = state.selectedPacketID else { return }
        if !isCurrentSource || controller?.snapshot.packetIngestState.packet(withID: id) == nil {
            select(nil)
        }
    }

    func close() {
        generation += 1
        didChange = nil
        controller = nil
        state = .empty
    }

    private var isCurrentSource: Bool {
        guard let ingest = controller?.snapshot.packetIngestState else { return false }
        return ingest.backingIdentity == backingIdentity && ingest.packetLineageRevision == lineage
    }

    private func find(_ id: String?, nodes: [PacketDetailNode]) -> PacketDetailNode? {
        guard let id else { return nil }
        for node in nodes {
            if node.id == id { return node }
            if let match = find(id, nodes: node.children) { return match }
        }
        return nil
    }
}
