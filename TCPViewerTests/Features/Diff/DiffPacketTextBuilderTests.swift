//
//  DiffPacketTextBuilderTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct DiffPacketTextBuilderTests {
    @Test func everyLevelAndMultilineValueHasLiteralTabIndentation() {
        let nodes = [PacketDetailNode(id: "tcp", name: "TCP", kind: .layer, children: [
            PacketDetailNode(id: "flags", name: "Flags", value: "ACK", children: [
                PacketDetailNode(id: "ack", name: "Acknowledgment", value: "1")
            ]),
            PacketDetailNode(id: "unicode", name: "Unicode", value: "hello 🌏\r\nsecond\rthird"),
            PacketDetailNode(id: "empty", name: "Empty", value: ""),
            PacketDetailNode(id: "warning", name: "Warning", value: "Synthetic warning", kind: .warning)
        ])]
        #expect(DiffPacketTextBuilder.text(nodes: nodes) == "TCP\n\tFlags: ACK\n\t\tAcknowledgment: 1\n\tUnicode: hello 🌏\n\tsecond\n\tthird\n\tEmpty\n\tWarning: Synthetic warning")
    }

    @Test func syntheticSummaryRowsMatchInspectorCopyAll() {
        let nodes = [PacketDetailNode(id: "ip", name: "IPv4", value: "Src: 192.0.2.1, Dst: 192.0.2.2, A sufficiently long protocol summary", kind: .layer, children: [
            PacketDetailNode(id: "source", name: "Source", value: "192.0.2.1"),
            PacketDetailNode(id: "destination", name: "Destination", value: "192.0.2.2")
        ])]
        var state = PacketInspectionState.empty
        state.selectedPacketID = 1
        state.inspection = PacketInspection(packetID: 1, packetNumber: 1, rawBytes: Data(), detailNodes: nodes, decodeStatus: PacketDecodeStatus(kind: .complete))
        let inspector = PacketInspectorTreeViewModel()
        inspector.render(inspectionState: state, filterText: "Source")
        let expected = PacketInspectorCopyFormatter.text(for: inspector.copyRowsForAllDetails())
        #expect(DiffPacketTextBuilder.text(nodes: nodes) == expected)
        #expect(expected.contains("\tDestination: 192.0.2.2"))
        #expect(expected.contains("\tSummary: A sufficiently long protocol summary"))
    }

    @Test func emptyDetailsContainNoInspectorPlaceholderOrTableMetadata() {
        #expect(DiffPacketTextBuilder.text(nodes: []) == "")
    }
}
