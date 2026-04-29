import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketInspectorTreeViewModelTests {
    @Test func emptyStateShowsSelectionPrompt() {
        let viewModel = PacketInspectorTreeViewModel()

        viewModel.render(snapshot: makeSnapshot(inspectionState: .empty))

        #expect(viewModel.rootItems.count == 1)
        #expect(viewModel.rootItems[0].kind == .message)
        #expect(viewModel.rootItems[0].displayText == "Select a packet to inspect its decode tree.")
    }

    @Test func loadingStateShowsStatusMessage() {
        let packet = makePacket()
        let state = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: nil,
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: true,
            statusMessage: "Inspecting packet 1..."
        )
        let viewModel = PacketInspectorTreeViewModel()

        viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: state))

        #expect(viewModel.rootItems.count == 1)
        #expect(viewModel.rootItems[0].kind == .message)
        #expect(viewModel.rootItems[0].displayText == "Inspecting packet 1...")
    }

    @Test func loadedTreeMapsNodeKindsAndDisplayText() {
        let packet = makePacket()
        let inspection = PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(
                    id: "frame",
                    name: "Frame",
                    value: "Packet 1",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "frame.number", name: "Frame Number", value: "1"),
                    ]
                ),
                PacketDetailNode(id: "warning.decode", name: "Decode Warning", value: "Partial decode", kind: .warning),
            ],
            decodeStatus: PacketDecodeStatus(kind: .partial, reason: "Partial decode")
        )
        let state = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: false,
            statusMessage: "Inspecting packet 1."
        )
        let viewModel = PacketInspectorTreeViewModel()

        viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: state))

        #expect(viewModel.rootItems.map(\.kind) == [.layer, .warning])
        #expect(viewModel.rootItems[0].displayText == "Frame: Packet 1")
        #expect(viewModel.rootItems[0].children.first?.displayText == "Frame Number: 1")
        #expect(viewModel.rootItems[1].displayText == "Decode Warning: Partial decode")
    }

    @Test func selectedDetailNodeIsPreservedWhenPresent() {
        let packet = makePacket()
        let selectedRange = PacketByteRange(offset: 26, length: 4)
        let inspection = PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(
                    id: "ipv4",
                    name: "IPv4",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "ipv4.src", name: "Source", value: "10.0.0.1", byteRange: selectedRange),
                    ]
                ),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
        let state = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: "ipv4.src",
            highlightedByteRange: selectedRange,
            isLoading: false,
            statusMessage: "Inspecting packet 1."
        )
        let viewModel = PacketInspectorTreeViewModel()

        viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: state))

        #expect(viewModel.selectedNodeID == "ipv4.src")
        #expect(viewModel.item(withNodeID: "ipv4.src")?.displayText == "Source: 10.0.0.1")
        #expect(viewModel.item(withNodeID: "missing") == nil)
    }

    private func makeSnapshot(packet: PacketSummary? = nil, inspectionState: PacketInspectionState) -> NetworkInspectorSnapshot {
        var base = TCPViewerWindowSnapshot.foundation
        if let packet {
            base.packetIngestState.replace(with: [packet], source: packet.source)
            base.navigationState.visiblePacketIDs = [packet.id]
        }
        base.inspectionState = inspectionState

        let rows = packet.map { [PacketTableRow(packet: $0)] } ?? []
        let visibleIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, index)
        })
        let tableContent = PacketTableContent(
            displayFilter: PacketDisplayFilter(""),
            displayFilterChips: [],
            store: PacketTableRowStore(rows: rows, visiblePacketRowIndexByID: visibleIndex),
            generation: 1,
            updatePlan: rows.isEmpty ? .none : .reload,
            malformedPacketCount: 0
        )

        return NetworkInspectorSnapshot.make(
            base: base,
            selectedSidebar: .liveCapture,
            selectedSourceListSelection: .allPackets,
            sourceListSnapshot: .empty,
            sourceListFilterText: "",
            workspaceMode: .packets,
            inspectorTab: .summary,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: tableContent
        )
    }

    private func makePacket() -> PacketSummary {
        PacketSummary(
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            source: .offline,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 64,
            capturedLength: 64,
            infoSummary: "TCP packet",
            layers: [PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }
}
