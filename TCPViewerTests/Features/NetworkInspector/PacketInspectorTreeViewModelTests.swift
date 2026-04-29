import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketInspectorTreeViewModelTests {
    @Test func emptyStateShowsSelectionPrompt() {
        let viewModel = PacketInspectorTreeViewModel()

        #expect(viewModel.render(snapshot: makeSnapshot(inspectionState: .empty)) == .reload)

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

        #expect(viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: state)) == .reload)

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

        #expect(viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: state)) == .reload)

        #expect(viewModel.rootItems.map(\.kind) == [.layer, .warning])
        #expect(viewModel.rootItems[0].displayText == "Frame: Packet 1")
        #expect(viewModel.rootItems[0].children.first?.displayText == "Frame Number: 1")
        #expect(viewModel.rootItems[1].displayText == "Decode Warning: Partial decode")
    }

    @Test func copyFormatterPreservesMultipleRowsAndChildIndentation() {
        let text = PacketInspectorCopyFormatter.text(for: [
            PacketInspectorCopyRow(text: "Frame: Packet 1", indentationLevel: 0),
            PacketInspectorCopyRow(text: "Ethernet II", indentationLevel: 1),
            PacketInspectorCopyRow(text: "Options:\nTimestamp", indentationLevel: 2),
        ])

        #expect(text == """
        Frame: Packet 1
            Ethernet II
                Options:
                Timestamp
        """)
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

        #expect(viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: state)) == .reload)

        #expect(viewModel.selectedNodeID == "ipv4.src")
        #expect(viewModel.item(withNodeID: "ipv4.src")?.displayText == "Source: 10.0.0.1")
        #expect(viewModel.item(withNodeID: "missing") == nil)
    }

    @Test func selectionChangeDoesNotRebuildTreeItems() throws {
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
        let unselectedState = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: false,
            statusMessage: "Inspecting packet 1."
        )
        let selectedState = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: "ipv4.src",
            highlightedByteRange: selectedRange,
            isLoading: false,
            statusMessage: "Inspecting packet 1."
        )
        let viewModel = PacketInspectorTreeViewModel()

        #expect(viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: unselectedState)) == .reload)
        let originalRootItem = try #require(viewModel.rootItems.first)

        #expect(viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: selectedState)) == .selection)
        #expect(viewModel.selectedNodeID == "ipv4.src")
        #expect(viewModel.rootItems.first === originalRootItem)
    }

    @Test func loadingNewPacketKeepsPreviousTreeUntilDecodeCompletes() throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let viewModel = PacketInspectorTreeViewModel()
        let firstLoadedState = PacketInspectionState(
            selectedPacketID: firstPacket.id,
            inspection: makeFrameInspection(for: firstPacket),
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: false,
            statusMessage: "Inspecting packet 1."
        )
        let secondLoadingState = PacketInspectionState(
            selectedPacketID: secondPacket.id,
            inspection: nil,
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: true,
            statusMessage: "Inspecting packet 2..."
        )
        let secondLoadedState = PacketInspectionState(
            selectedPacketID: secondPacket.id,
            inspection: makeFrameInspection(for: secondPacket),
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: false,
            statusMessage: "Inspecting packet 2."
        )

        #expect(viewModel.render(snapshot: makeSnapshot(packet: firstPacket, inspectionState: firstLoadedState)) == .reload)
        let originalRootItem = try #require(viewModel.rootItems.first)

        #expect(viewModel.render(snapshot: makeSnapshot(packet: secondPacket, inspectionState: secondLoadingState)) == .none)
        #expect(viewModel.rootItems.first === originalRootItem)
        #expect(viewModel.rootItems.first?.displayText == "Frame: Packet 1")

        #expect(viewModel.render(snapshot: makeSnapshot(packet: secondPacket, inspectionState: secondLoadedState)) == .reload)
        #expect(viewModel.rootItems.first?.displayText == "Frame: Packet 2")
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

    private func makeFrameInspection(for packet: PacketSummary) -> PacketInspection {
        PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(id: "frame", name: "Frame", value: "Packet \(packet.packetNumber)", kind: .layer),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }

    private func makePacket(packetNumber: UInt64 = 1) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
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
