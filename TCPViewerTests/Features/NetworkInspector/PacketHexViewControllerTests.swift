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

    @MainActor
    @Test func rawTabLeadsTheSegmentsForKeyLogDecryptedHTTP() throws {
        let packet = makePacket(packetNumber: 1)
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(packet: packet, inspection: makeDecryptedHTTPInspection(for: packet, path: "/first")))

        let segmentedControl = try #require(firstSubview(ofType: NSSegmentedControl.self, in: controller.view))
        let rawTextView = try #require(firstSubview(ofType: NSTextView.self, in: controller.view))
        #expect(segmentLabels(of: segmentedControl) == ["Raw", "Frame", "Decrypted TLS"])
        #expect(segmentedControl.selectedSegment == 0)
        #expect(rawTextView.string == "GET /first HTTP/1.1\nHost: example.com")
        #expect(rawTextView.enclosingScrollView?.isHidden == false)
    }

    // Plain HTTP was always readable in the tree and hex, so the tab is reserved for decrypted traffic.
    @MainActor
    @Test func packetsWithoutDecryptedTLSHaveNoRawTab() throws {
        let packet = makePacket(packetNumber: 1)
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(packet: packet, inspection: makeInspection(for: packet)))

        let segmentedControl = try #require(firstSubview(ofType: NSSegmentedControl.self, in: controller.view))
        let rawTextView = try #require(firstSubview(ofType: NSTextView.self, in: controller.view))
        #expect(segmentLabels(of: segmentedControl) == ["Frame", "Reassembled TCP"])
        #expect(rawTextView.enclosingScrollView?.isHidden == true)
        #expect(PacketRawMessageText.make(for: makeInspection(for: packet)) == nil)
    }

    @MainActor
    @Test func choiceBetweenRawAndBytesCarriesOverToLaterPackets() throws {
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        let packets = (1...3).map { makePacket(packetNumber: UInt64($0)) }
        controller.render(snapshot: makeSnapshot(packet: packets[0], inspection: makeDecryptedHTTPInspection(for: packets[0], path: "/1")))
        let segmentedControl = try #require(firstSubview(ofType: NSSegmentedControl.self, in: controller.view))
        let rawTextView = try #require(firstSubview(ofType: NSTextView.self, in: controller.view))
        let action = try #require(segmentedControl.action)

        segmentedControl.selectedSegment = 2
        _ = NSApp.sendAction(action, to: segmentedControl.target, from: segmentedControl)
        controller.render(snapshot: makeSnapshot(packet: packets[1], inspection: makeDecryptedHTTPInspection(for: packets[1], path: "/2")))

        #expect(segmentedControl.label(forSegment: segmentedControl.selectedSegment) == "Decrypted TLS")
        #expect(rawTextView.enclosingScrollView?.isHidden == true)

        segmentedControl.selectedSegment = 0
        _ = NSApp.sendAction(action, to: segmentedControl.target, from: segmentedControl)
        controller.render(snapshot: makeSnapshot(packet: packets[2], inspection: makeDecryptedHTTPInspection(for: packets[2], path: "/3")))

        #expect(segmentedControl.selectedSegment == 0)
        #expect(rawTextView.string == "GET /3 HTTP/1.1\nHost: example.com")
        #expect(rawTextView.enclosingScrollView?.isHidden == false)
    }

    @MainActor
    @Test func protocolTreeSelectionShowsItsBytesInsteadOfRaw() throws {
        let packet = makePacket(packetNumber: 1)
        let controller = PacketHexViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        let inspection = makeDecryptedHTTPInspection(for: packet, path: "/first")

        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspection: inspection,
            highlightedByteRange: PacketByteRange(offset: 0, length: 3, sourceID: "decrypted-tls")
        ))

        let segmentedControl = try #require(firstSubview(ofType: NSSegmentedControl.self, in: controller.view))
        let rawTextView = try #require(firstSubview(ofType: NSTextView.self, in: controller.view))
        #expect(segmentedControl.label(forSegment: segmentedControl.selectedSegment) == "Decrypted TLS")
        #expect(rawTextView.enclosingScrollView?.isHidden == true)

        // Clearing the tree selection returns to the tab the user prefers.
        controller.render(snapshot: makeSnapshot(packet: packet, inspection: inspection))
        #expect(segmentedControl.selectedSegment == 0)
    }

    @Test func rawTextSummarisesBinaryBodiesAndSeparatesMessages() throws {
        let packet = makePacket(packetNumber: 1)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let second = "HTTP/1.1 204 No Content\r\n\r\n"
        let decrypted = Data(head.utf8) + png + Data(second.utf8)
        let secondOffset = head.utf8.count + png.count
        let inspection = PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01]),
            byteViews: [
                PacketByteView(id: "frame", label: "Frame", bytes: Data([0x01])),
                PacketByteView(id: "decrypted-tls", label: "Decrypted TLS", bytes: decrypted),
            ],
            detailNodes: [
                makeHTTPNode(offset: 0, length: secondOffset, marker: "http.response.code"),
                makeHTTPNode(offset: secondOffset, length: second.utf8.count, marker: "http.response.code"),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )

        let text = try #require(PacketRawMessageText.make(for: inspection))

        #expect(text == [
            "HTTP/1.1 200 OK",
            "Content-Type: image/png",
            "",
            "[6 bytes of binary data]",
            "",
            String(repeating: "─", count: 24),
            "",
            "HTTP/1.1 204 No Content",
        ].joined(separator: "\n"))
    }

    private func segmentLabels(of control: NSSegmentedControl) -> [String?] {
        (0..<control.segmentCount).map { control.label(forSegment: $0) }
    }

    // A request the way Wireshark reports it after a key log decrypted the TLS record.
    private func makeDecryptedHTTPInspection(for packet: PacketSummary, path: String) -> PacketInspection {
        let request = "GET \(path) HTTP/1.1\r\nHost: example.com\r\n\r\n"
        return PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x16, UInt8(packet.packetNumber)]),
            byteViews: [
                PacketByteView(id: "frame", label: "Frame", bytes: Data([0x16, UInt8(packet.packetNumber)])),
                PacketByteView(id: "decrypted-tls", label: "Decrypted TLS", bytes: Data(request.utf8)),
            ],
            detailNodes: [makeHTTPNode(offset: 0, length: request.utf8.count, marker: "http.request.method")],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }

    private func makeHTTPNode(offset: Int, length: Int, marker: String) -> PacketDetailNode {
        let range = PacketByteRange(offset: offset, length: length, sourceID: "decrypted-tls")
        return PacketDetailNode(id: "http.\(offset)", name: "Hypertext Transfer Protocol", fieldName: "http", kind: .layer, byteRange: range, children: [
            PacketDetailNode(id: "\(marker).\(offset)", name: marker, fieldName: marker, byteRange: range),
        ])
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

    private func makeSnapshot(
        packet: PacketSummary,
        inspection: PacketInspection,
        highlightedByteRange: PacketByteRange? = nil
    ) -> NetworkInspectorSnapshot {
        var base = TCPViewerWindowSnapshot.foundation
        base.packetIngestState.replace(with: [packet], source: packet.source)
        base.navigationState.visiblePacketIDs = [packet.id]
        base.inspectionState = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: nil,
            highlightedByteRange: highlightedByteRange,
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
