//
//  PacketHexViewControllerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 29/4/26.
//

import AppKit
import Foundation
import HexFiend
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketHexViewControllerTests {
    @Test func highlightMapsByteRangeToSelection() throws {
        let highlight = try #require(PacketHexHighlight.make(from: PacketByteRange(offset: 14, length: 20), byteCount: 64))

        #expect(highlight.byteOffset == 14)
        #expect(highlight.byteLength == 20)
        #expect(highlight.tooltip == "Bytes 14-33")
    }

    @Test func highlightMapsBitRangeToContainingByteAndTooltip() throws {
        let range = PacketByteRange(offset: 20, length: 1, bitOffset: 1, bitLength: 1, hasBitRange: true)
        let highlight = try #require(PacketHexHighlight.make(from: range, byteCount: 64))

        #expect(highlight.byteOffset == 20)
        #expect(highlight.byteLength == 1)
        #expect(highlight.tooltip == "Bytes 20-20, bits 1-1")
    }

    @Test func highlightClampsLengthToCapturedBytes() throws {
        let highlight = try #require(PacketHexHighlight.make(from: PacketByteRange(offset: 3, length: 8), byteCount: 5))

        #expect(highlight.byteOffset == 3)
        #expect(highlight.byteLength == 2)
        #expect(highlight.tooltip == "Bytes 3-4")
    }

    @Test func highlightPreservesReassembledByteSource() throws {
        let range = PacketByteRange(offset: 2, length: 4, sourceID: "reassembled-tcp")
        let highlight = try #require(PacketHexHighlight.make(from: range, byteCount: 8))

        #expect(highlight.sourceRange.sourceID == "reassembled-tcp")
        #expect(highlight.byteOffset == 2)
        #expect(highlight.byteLength == 4)
    }

    @Test func highlightIgnoresOutOfBoundsRanges() {
        #expect(PacketHexHighlight.make(from: PacketByteRange(offset: 5, length: 1), byteCount: 5) == nil)
        #expect(PacketHexHighlight.make(from: PacketByteRange(offset: 0, length: 0), byteCount: 5) == nil)
        #expect(PacketHexHighlight.make(from: nil, byteCount: 5) == nil)
    }

    @Test func followPayloadMatchPrefersReassembledSource() throws {
        let payload = Data([0xAA, 0xBB])
        let range = try #require(FollowStreamPayloadMatcher.matchingRange(
            for: payload,
            in: [
                PacketByteView(id: "frame", label: "Frame", bytes: Data([0x00, 0xAA, 0xBB, 0x01])),
                PacketByteView(id: "reassembled-tcp", label: "Reassembled TCP", bytes: Data([0x02, 0xAA, 0xBB, 0x03])),
            ]
        ))

        #expect(range == PacketByteRange(offset: 1, length: 2, sourceID: "reassembled-tcp"))
    }

    @Test func followPayloadMatchRequiresOneUnambiguousLocation() {
        let payload = Data([0xAA, 0xBB])

        #expect(FollowStreamPayloadMatcher.matchingRange(
            for: payload,
            in: [PacketByteView(
                id: "reassembled-tcp",
                label: "Reassembled TCP",
                bytes: Data([0xAA, 0xBB, 0x00, 0xAA, 0xBB])
            )]
        ) == nil)
        #expect(FollowStreamPayloadMatcher.matchingRange(
            for: payload,
            in: [
                PacketByteView(id: "reassembled-a", label: "Reassembled A", bytes: Data([0x00, 0xAA, 0xBB])),
                PacketByteView(id: "reassembled-b", label: "Reassembled B", bytes: Data([0x01, 0xAA, 0xBB])),
            ]
        ) == nil)
    }

    @MainActor
    @Test func manualByteViewSelectionSurvivesPacketChange() throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(packet: firstPacket, inspection: makeInspection(for: firstPacket)))
        let segmentedControl = try #require(firstSubview(ofType: NSSegmentedControl.self, in: controller.view))
        #expect(segmentedControl.selectedSegment == 0)

        segmentedControl.selectedSegment = 1
        let action = try #require(segmentedControl.action)
        _ = NSApp.sendAction(action, to: segmentedControl.target, from: segmentedControl)
        #expect(segmentedControl.selectedSegment == 1)

        controller.render(snapshot: makeSnapshot(packet: secondPacket, inspection: makeInspection(for: secondPacket)))

        #expect(segmentedControl.selectedSegment == 1)
        #expect(segmentedControl.label(forSegment: segmentedControl.selectedSegment) == "Reassembled TCP")
    }

    @MainActor
    @Test func followPayloadRevealSelectsSourceAndSurvivesSamePacketRender() throws {
        let packet = makePacket(packetNumber: 1)
        let inspection = makeInspection(for: packet)
        let snapshot = makeSnapshot(packet: packet, inspection: inspection)
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.render(snapshot: snapshot)

        let didReveal = controller.revealFollowStreamPayload(FollowStreamRevealTarget(
            packetID: packet.id,
            payload: Data([0xAA, 0x01])
        ))
        let segmentedControl = try #require(firstSubview(ofType: NSSegmentedControl.self, in: controller.view))

        #expect(didReveal)
        #expect(segmentedControl.label(forSegment: segmentedControl.selectedSegment) == "Reassembled TCP")

        controller.render(snapshot: snapshot)

        #expect(segmentedControl.label(forSegment: segmentedControl.selectedSegment) == "Reassembled TCP")
    }

    @MainActor
    @Test(arguments: [false, true])
    func followPayloadRevealExplainsWhenNoExactSourceExists(emptyPayload: Bool) throws {
        let packet = makePacket(packetNumber: 1)
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(packet: packet, inspection: makeInspection(for: packet)))

        let didReveal = controller.revealFollowStreamPayload(FollowStreamRevealTarget(
            packetID: packet.id,
            payload: emptyPayload ? Data() : Data([0xFE, 0xED])
        ))
        let statusLabel = try #require(allSubviews(ofType: NSTextField.self, in: controller.view).first {
            $0.stringValue == (emptyPayload ? "Empty payload" : "Reassembled from multiple packets")
        })

        #expect(!didReveal)
        #expect(!statusLabel.isHidden)
    }

    @MainActor
    @Test func failedFollowPayloadRevealClearsThePreviousHighlight() throws {
        let packet = makePacket(packetNumber: 1)
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(packet: packet, inspection: makeInspection(for: packet)))
        let hexTextView = try #require(firstSubview(ofType: HFTextView.self, in: controller.view))

        #expect(controller.revealFollowStreamPayload(FollowStreamRevealTarget(
            packetID: packet.id,
            payload: Data([0xAA, 0x01])
        )))
        #expect(!hexTextView.controller.selectedContentsRanges.isEmpty)

        #expect(!controller.revealFollowStreamPayload(FollowStreamRevealTarget(
            packetID: packet.id,
            payload: Data([0xFE, 0xED])
        )))
        let clearedRange = try #require(hexTextView.controller.selectedContentsRanges.first)
        #expect(clearedRange.hfRange().length == 0)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.PacketHexViewControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func firstSubview<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let view = view as? T {
            return view
        }

        for subview in view.subviews {
            if let match = firstSubview(ofType: type, in: subview) {
                return match
            }
        }

        return nil
    }

    private func allSubviews<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews {
            matches.append(contentsOf: allSubviews(ofType: type, in: subview))
        }
        return matches
    }

    private func makeSnapshot(packet: PacketSummary, inspection: PacketInspection) -> NetworkInspectorSnapshot {
        var base = TCPViewerWindowSnapshot.foundation
        base.packetIngestState.replace(with: [packet], source: packet.source)
        base.navigationState.visiblePacketIDs = [packet.id]
        base.inspectionState = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: false,
            statusMessage: "Inspecting packet \(packet.packetNumber)."
        )

        let rows = [PacketTableRow(packet: packet)]
        let tableContent = PacketTableContent(
            displayFilter: PacketDisplayFilter(""),
            displayFilterChips: [],
            store: PacketTableRowStore(rows: rows, visiblePacketRowIndexByID: [packet.id: 0]),
            generation: 1,
            updatePlan: .reload,
            malformedPacketCount: 0
        )

        return NetworkInspectorSnapshot.make(
            base: base,
            selectedSidebar: .liveCapture,
            selectedSourceListSelection: .allPackets,
            sourceListSnapshot: .empty,
            sourceListFilterText: "",
            workspaceMode: .packets,
            inspectorTab: .hex,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: tableContent
        )
    }

    private func makeInspection(for packet: PacketSummary) -> PacketInspection {
        let frameBytes = Data([0x01, UInt8(packet.packetNumber)])
        return PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: frameBytes,
            byteViews: [
                PacketByteView(id: "frame", label: "Frame", bytes: frameBytes),
                PacketByteView(id: "reassembled-tcp", label: "Reassembled TCP", bytes: Data([0xAA, UInt8(packet.packetNumber)])),
            ],
            detailNodes: [
                PacketDetailNode(id: "frame", name: "Frame", value: "Packet \(packet.packetNumber)", kind: .layer),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }

    private func makePacket(packetNumber: UInt64) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 12_345),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: 1,
            infoSummary: "Packet \(packetNumber)",
            layers: [
                PacketLayer(name: "Ethernet"),
                PacketLayer(name: "TCP"),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }
}
