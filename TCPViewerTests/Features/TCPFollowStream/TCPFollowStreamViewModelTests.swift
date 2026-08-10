//
//  TCPFollowStreamViewModelTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import AppKit
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPFollowStreamViewModelTests {
    @MainActor
    @Test func rendersDirectionsPacketRangesAndTextControls() throws {
        let viewModel = TCPFollowStreamViewModel()
        viewModel.setStream(makeStream())

        let content = viewModel.renderedContent()

        #expect(content.plainText.contains("Client to Server · Packet 10"))
        #expect(content.plainText.contains("Server to Client · Packet 11"))
        #expect(content.plainText.contains("hello·\n"))
        #expect(content.displayedByteCount == 11)
        #expect(content.packetRanges.map(\.packetID) == [10, 11])
        for packetRange in content.packetRanges {
            #expect(NSMaxRange(packetRange.range) <= content.attributedText.length)
        }
    }

    @MainActor
    @Test func switchesDirectionAndHexWithoutChangingRawExports() {
        let viewModel = TCPFollowStreamViewModel()
        viewModel.setStream(makeStream())
        viewModel.setDirectionFilter(.serverToClient)
        viewModel.setRepresentation(.hex)

        let content = viewModel.renderedContent()

        #expect(!content.plainText.contains("Client to Server"))
        #expect(content.plainText.contains("Server to Client"))
        #expect(content.plainText.contains("77 6f 72 6c 64"))
        #expect(content.displayedByteCount == 5)
        #expect(viewModel.rawData(for: .clientToServer) == Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00]))
        #expect(viewModel.rawData(for: .serverToClient) == Data("world".utf8))
    }

    @MainActor
    @Test func boundsDisplayedPayloadWithoutLimitingRawExport() {
        let viewModel = TCPFollowStreamViewModel(
            maximumDisplayedPayloadBytes: 4,
            maximumDisplayedRecordCount: 10
        )
        viewModel.setStream(makeStream())

        let content = viewModel.renderedContent()

        #expect(content.displayedByteCount == 4)
        #expect(content.statusText.contains("4 of 11 bytes shown"))
        #expect(content.statusText.contains("display limited for responsiveness"))
        #expect(viewModel.rawData(for: .clientToServer).count == 6)
        #expect(viewModel.rawData(for: .serverToClient).count == 5)
    }

    @MainActor
    @Test func renderedTranscriptFillsTheScrollViewport() throws {
        let controller = TCPFollowStreamViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        controller.view.layoutSubtreeIfNeeded()

        controller.show(stream: makeStream())
        controller.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstSubview(ofType: NSScrollView.self, in: controller.view))
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(!scrollView.isHidden)
        #expect(scrollView.contentSize.width > 0)
        #expect(scrollView.contentSize.height > 0)
        #expect(textView.frame.width >= scrollView.contentSize.width)
        #expect(textView.frame.height >= scrollView.contentSize.height)
        #expect(textView.string.contains("Client to Server · Packet 10"))
    }

    @MainActor
    @Test func followWindowPlacesSettingsControlsAboveTheTranscript() throws {
        let controller = TCPFollowStreamViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 760)
        controller.view.layoutSubtreeIfNeeded()
        let labels = allSubviews(ofType: NSTextField.self, in: controller.view)
        let segmentedControls = allSubviews(ofType: NSSegmentedControl.self, in: controller.view)
        let directionControl = try #require(segmentedControls.first { $0.segmentCount == 3 })
        let representationControl = try #require(segmentedControls.first { $0.segmentCount == 2 })
        let scrollView = try #require(firstSubview(ofType: NSScrollView.self, in: controller.view))

        #expect(labels.contains { $0.stringValue == "Settings:" })
        #expect(directionControl.label(forSegment: 0) == "Both")
        #expect(directionControl.label(forSegment: 1) == "Client → Server")
        #expect(directionControl.label(forSegment: 2) == "Server → Client")
        #expect(representationControl.label(forSegment: 0) == "Text")
        #expect(representationControl.label(forSegment: 1) == "Hex")
        let directionFrame = directionControl.convert(directionControl.bounds, to: controller.view)
        let representationFrame = representationControl.convert(representationControl.bounds, to: controller.view)
        #expect(directionFrame.minY > scrollView.frame.maxY)
        #expect(representationFrame.minY > scrollView.frame.maxY)

        controller.show(stream: makeStream())
        directionControl.selectedSegment = TCPFollowDirectionFilter.serverToClient.rawValue
        directionControl.sendAction(directionControl.action, to: directionControl.target)
        representationControl.selectedSegment = TCPFollowRepresentation.hex.rawValue
        representationControl.sendAction(representationControl.action, to: representationControl.target)
        #expect(!controller.renderedContent.plainText.contains("Client to Server"))
        #expect(controller.renderedContent.plainText.contains("77 6f 72 6c 64"))
    }

    @MainActor
    @Test func followWindowToolbarUsesAnExportIconMenu() throws {
        let controller = TCPFollowStreamWindowController(packetID: 10)
        let window = try #require(controller.window)
        let toolbar = try #require(controller.window?.toolbar)
        let exportItem = try #require(toolbar.items.first {
            $0.itemIdentifier.rawValue == "TCPFollowStream.save"
        })
        let exportButton = try #require(exportItem.view as? NSPopUpButton)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        window.layoutIfNeeded()
        toolbar.validateVisibleItems()

        #expect(window.minSize.width >= 1_100)
        #expect(toolbar.items.count == 2)
        #expect(exportItem.visibilityPriority == .user)
        #expect(exportItem.isVisible)
        #expect(exportButton.imagePosition == .imageOnly)
        #expect(exportButton.item(at: 0)?.image != nil)
        #expect(exportButton.toolTip == "Export TCP stream")
    }

    private func makeStream() -> TCPFollowStream {
        TCPFollowStream(
            client: PacketEndpoint(address: "192.0.2.1", port: 50_000),
            server: PacketEndpoint(address: "198.51.100.2", port: 443),
            records: [
                TCPFollowRecord(
                    direction: .clientToServer,
                    packetID: 10,
                    timestamp: Date(timeIntervalSince1970: 10),
                    sequenceNumber: 100,
                    data: Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00])
                ),
                TCPFollowRecord(
                    direction: .serverToClient,
                    packetID: 11,
                    timestamp: Date(timeIntervalSince1970: 11),
                    sequenceNumber: 200,
                    data: Data("world".utf8)
                ),
            ],
            clientByteCount: 6,
            serverByteCount: 5,
            capturedThroughPacketID: 12,
            capturedAt: Date(timeIntervalSince1970: 12),
            isTruncated: false
        )
    }

    private func firstSubview<View: NSView>(ofType type: View.Type, in root: NSView) -> View? {
        if let match = root as? View {
            return match
        }
        for subview in root.subviews {
            if let match = firstSubview(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func allSubviews<View: NSView>(ofType type: View.Type, in root: NSView) -> [View] {
        var matches = root.subviews.compactMap { $0 as? View }
        for subview in root.subviews {
            matches.append(contentsOf: allSubviews(ofType: type, in: subview))
        }
        return matches
    }
}
