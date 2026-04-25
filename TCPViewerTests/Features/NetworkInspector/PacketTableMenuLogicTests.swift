import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
struct PacketTableMenuLogicTests {

    @Test func selectedClickedRowTargetsMultipleRowsAndDisablesPin() {
        let rows = [
            PacketTableRow(packet: makePacket(packetNumber: 1, sniDomainName: "one.example.com", client: makeClient())),
            PacketTableRow(packet: makePacket(packetNumber: 2)),
            PacketTableRow(packet: makePacket(packetNumber: 3, sniDomainName: "three.example.com", client: makeClient())),
        ]

        let state = PacketTableMenuLogic.state(
            rows: rows,
            selectedRowIndexes: IndexSet([0, 2]),
            clickedRowIndex: 2,
            clickedColumnIdentifier: "domain"
        )

        #expect(state.targetRows == [0, 2])
        #expect(state.copyRowEnabled)
        #expect(state.copyCellEnabled)
        #expect(!state.pinDomainEnabled)
        #expect(!state.pinIPEnabled)
        #expect(!state.pinClientEnabled)
        #expect(state.saveEnabled)
        #expect(state.deleteEnabled)
    }

    @Test func unselectedClickedRowTargetsSingleRowAndEnablesValidPins() {
        let rows = [
            PacketTableRow(packet: makePacket(packetNumber: 1)),
            PacketTableRow(packet: makePacket(packetNumber: 2, sniDomainName: "api.example.com", client: makeClient())),
        ]

        let state = PacketTableMenuLogic.state(
            rows: rows,
            selectedRowIndexes: IndexSet(integer: 0),
            clickedRowIndex: 1,
            clickedColumnIdentifier: "source"
        )

        #expect(state.targetRows == [1])
        #expect(state.clickedColumn == .source)
        #expect(state.pinDomainEnabled)
        #expect(state.pinIPEnabled)
        #expect(state.pinClientEnabled)
    }

    @Test func copyFormatterUsesCSVRowsAndClickedColumnCells() {
        let rows = [
            PacketTableRow(packet: makePacket(packetNumber: 1, infoSummary: "Hello, world")),
            PacketTableRow(packet: makePacket(packetNumber: 2, infoSummary: "Plain")),
        ]

        let rowCopy = PacketTableCopyFormatter.csvRows(rows)
        let cellCopy = PacketTableCopyFormatter.csvCells(rows, column: .summary)

        #expect(rowCopy.contains("\"Hello, world\""))
        #expect(rowCopy.split(separator: "\n").count == 2)
        #expect(cellCopy == """
        "Hello, world"
        Plain
        """)
    }

    @Test func selectionSyncUsesFirstSelectedRowForInspector() {
        let packets = [
            makePacket(packetNumber: 1),
            makePacket(packetNumber: 2),
            makePacket(packetNumber: 3),
        ]
        let rows = packets.map(PacketTableRow.init)

        #expect(PacketTableSelectionSyncPlanner.action(
            rows: rows,
            selectedPacketID: packets[0].id,
            selectedRowIndex: 0,
            tableSelectedRowIndexes: IndexSet([0, 2])
        ) == .none)

        #expect(PacketTableSelectionSyncPlanner.action(
            rows: rows,
            selectedPacketID: packets[2].id,
            selectedRowIndex: 2,
            tableSelectedRowIndexes: IndexSet([0, 2])
        ) == .select(2))
    }

    private func makePacket(
        packetNumber: UInt64,
        infoSummary: String? = nil,
        sniDomainName: String? = nil,
        client: PacketClient? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: nil,
            infoSummary: infoSummary ?? "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: sniDomainName,
            client: client
        )
    }

    private func makeClient() -> PacketClient {
        PacketClient(
            pid: 123,
            name: "Example",
            displayName: "Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            bundleIdentifier: "com.example.app",
            bundlePath: "/Applications/Example.app"
        )
    }
}
