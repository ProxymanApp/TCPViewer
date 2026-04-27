import Foundation
import PcapPlusPlusCore

struct PacketInspectorRenderState: Equatable {
    let inspectorTab: PacketInspectorTab
    let selectedPacket: PacketSummary?
    let selectedPacketID: PacketSummary.ID?
    let inspection: PacketInspection?
    let selectedDetailNodeID: String?
    let highlightedByteRange: PacketByteRange?
    let isLoading: Bool
    let statusMessage: String

    init(snapshot: NetworkInspectorSnapshot) {
        self.inspectorTab = snapshot.inspectorTab
        self.selectedPacket = snapshot.selectedPacket
        self.selectedPacketID = snapshot.selectedPacketID
        self.inspection = snapshot.base.inspectionState.inspection
        self.selectedDetailNodeID = snapshot.base.inspectionState.selectedDetailNodeID
        self.highlightedByteRange = snapshot.base.inspectionState.highlightedByteRange
        self.isLoading = snapshot.base.inspectionState.isLoading
        self.statusMessage = snapshot.base.inspectionState.statusMessage
    }
}

final class PacketInspectorPanelViewModel {
    private(set) var state = PacketInspectorRenderState(snapshot: .make(
        base: .foundation,
        selectedSidebar: .liveCapture,
        selectedSourceListSelection: .allPackets,
        sourceListSnapshot: .empty,
        sourceListFilterText: "",
        workspaceMode: .packets,
        inspectorTab: .overview,
        isInspectorVisible: true,
        displayFilterText: "",
        packetTableContent: .empty
    ))

    @discardableResult
    func render(snapshot: NetworkInspectorSnapshot) -> Bool {
        let nextState = PacketInspectorRenderState(snapshot: snapshot)
        guard !shouldDeferPendingInspection(nextState) else {
            return false
        }

        guard nextState != state else {
            return false
        }

        state = nextState
        return true
    }

    private func shouldDeferPendingInspection(_ state: PacketInspectorRenderState) -> Bool {
        guard let selectedPacketID = state.selectedPacketID else {
            return false
        }

        if state.isLoading {
            return true
        }

        if let inspection = state.inspection, inspection.packetID != selectedPacketID {
            return true
        }

        return false
    }
}
