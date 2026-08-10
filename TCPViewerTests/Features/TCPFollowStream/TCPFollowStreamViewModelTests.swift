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

    @Test func streamNavigationSortsIDsAndStaysInsideTheImportedCapture() throws {
        var ingestState = PacketIngestState.empty
        let packets = [
            makeNavigationPacket(packetNumber: 10, streamID: 5),
            makeNavigationPacket(packetNumber: 11, streamID: 9, transportHint: .tls),
            makeNavigationPacket(packetNumber: 12, streamID: 5),
            makeNavigationPacket(packetNumber: 13, streamID: 1, transportHint: .udp, layerName: "UDP"),
            makeNavigationPacket(packetNumber: 20, streamID: 7),
            makeNavigationPacket(packetNumber: 21, streamID: 11),
        ]
        ingestState.append(packets, source: .offline)
        let firstFileID = ImportedCaptureFileID(rawValue: "first")
        let secondFileID = ImportedCaptureFileID(rawValue: "second")
        ingestState.importedPacketReferenceByID = [
            10: ImportedPacketReference(fileID: firstFileID, originalPacketID: 1),
            11: ImportedPacketReference(fileID: firstFileID, originalPacketID: 2),
            12: ImportedPacketReference(fileID: firstFileID, originalPacketID: 3),
            13: ImportedPacketReference(fileID: firstFileID, originalPacketID: 4),
            20: ImportedPacketReference(fileID: secondFileID, originalPacketID: 1),
            21: ImportedPacketReference(fileID: secondFileID, originalPacketID: 2),
        ]

        let navigation = try #require(TCPFollowStreamNavigation(
            ingestState: ingestState,
            selectedPacketID: 11
        ))
        let previous = try #require(navigation.selecting(index: 0))

        #expect(navigation.entries.map(\.streamID) == [5, 9])
        #expect(navigation.entries.map(\.packetID) == [10, 11])
        #expect(navigation.selectedEntry.streamID == 9)
        #expect(previous.selectedEntry.streamID == 5)
        #expect(navigation.selecting(index: 2) == nil)
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
        let navigation = try #require(makeStreamNavigation())
        let controller = TCPFollowStreamWindowController(navigation: navigation)
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

    @MainActor
    @Test func followWindowStepperLoadsTheSelectedStream() throws {
        let navigation = try #require(makeStreamNavigation())
        let controller = TCPFollowStreamWindowController(navigation: navigation)
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        let stepper = try #require(firstSubview(ofType: NSStepper.self, in: contentView))
        var requestedEntry: TCPFollowStreamNavigation.Entry?
        controller.streamSelectionHandler = { requestedEntry = $0 }

        controller.show(stream: makeStream())
        #expect(stepper.isEnabled)
        #expect(stepper.integerValue == 3)
        #expect(stepper.maxValue == 9)

        stepper.integerValue = 4
        stepper.sendAction(stepper.action, to: stepper.target)

        #expect(requestedEntry?.streamID == 9)
        #expect(requestedEntry?.packetID == 20)
        #expect(!stepper.isEnabled)
        #expect(window.title == "Follow TCP Stream · Stream 9")

        controller.show(stream: makeStream())
        #expect(stepper.isEnabled)
        #expect(stepper.integerValue == 9)

        requestedEntry = nil
        stepper.integerValue = 8
        stepper.sendAction(stepper.action, to: stepper.target)

        #expect(requestedEntry?.streamID == 3)
        #expect(requestedEntry?.packetID == 10)
        #expect(window.title == "Follow TCP Stream · Stream 3")
    }

    @MainActor
    @Test func followWindowSearchFocusesCountsAndWrapsMatches() async throws {
        let navigation = try #require(makeStreamNavigation())
        let windowController = TCPFollowStreamWindowController(navigation: navigation)
        let window = try #require(windowController.window)
        let contentController = try #require(window.contentViewController as? TCPFollowStreamViewController)
        let contentView = contentController.view
        let searchField = try #require(allSubviews(ofType: NSSearchField.self, in: contentView).first {
            $0.placeholderString == "Search transcript"
        })
        let matchLabel = try #require(allSubviews(ofType: NSTextField.self, in: contentView).first {
            $0.stringValue == "0 of 0"
        })
        let previousButton = try #require(allSubviews(ofType: NSButton.self, in: contentView).first {
            $0.toolTip == "Previous match"
        })
        let nextButton = try #require(allSubviews(ofType: NSButton.self, in: contentView).first {
            $0.toolTip == "Next match"
        })
        let scrollView = try #require(firstSubview(ofType: NSScrollView.self, in: contentView))
        let textView = try #require(scrollView.documentView as? NSTextView)

        contentView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 760)
        windowController.show(stream: makeStream())
        contentView.layoutSubtreeIfNeeded()
        let searchFrame = searchField.convert(searchField.bounds, to: contentView)
        #expect(searchFrame.maxY <= scrollView.frame.minY)

        #expect(window.nextResponder === windowController)
        windowController.focusStructuredFilter(nil)
        #expect(window.firstResponder === searchField.currentEditor())

        searchField.stringValue = "packet"
        contentController.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: searchField
        ))
        await waitUntil { matchLabel.stringValue == "1 of 2" }

        let firstRange = textView.selectedRange()
        #expect(matchLabel.stringValue == "1 of 2")
        #expect(previousButton.isEnabled)
        #expect(nextButton.isEnabled)

        nextButton.performClick(nil)
        #expect(matchLabel.stringValue == "2 of 2")
        #expect(textView.selectedRange() != firstRange)

        nextButton.performClick(nil)
        #expect(matchLabel.stringValue == "1 of 2")
        #expect(textView.selectedRange() == firstRange)

        previousButton.performClick(nil)
        #expect(matchLabel.stringValue == "2 of 2")

        contentController.setRepresentation(.hex)
        searchField.stringValue = "77 6f 72 6c 64"
        contentController.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: searchField
        ))
        await waitUntil { matchLabel.stringValue == "1 of 1" }
        #expect(matchLabel.stringValue == "1 of 1")
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

    private func makeStreamNavigation() -> TCPFollowStreamNavigation? {
        var ingestState = PacketIngestState.empty
        ingestState.append([
            makeNavigationPacket(packetNumber: 10, streamID: 3),
            makeNavigationPacket(packetNumber: 20, streamID: 9),
        ], source: .offline)
        return TCPFollowStreamNavigation(ingestState: ingestState, selectedPacketID: 10)
    }

    private func makeNavigationPacket(
        packetNumber: UInt64,
        streamID: UInt32,
        transportHint: TransportProtocolHint = .tcp,
        layerName: String = "TCP"
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "192.0.2.1", port: 50_000),
                destination: PacketEndpoint(address: "198.51.100.2", port: 443)
            ),
            originalLength: 64,
            capturedLength: 64,
            streamID: streamID,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: layerName)],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
