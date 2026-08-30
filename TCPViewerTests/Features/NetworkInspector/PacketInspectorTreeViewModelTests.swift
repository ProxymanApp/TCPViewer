//
//  PacketInspectorTreeViewModelTests.swift
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

struct PacketInspectorTreeViewModelTests {
    @Test func emptyStateShowsSelectionPrompt() {
        let viewModel = PacketInspectorTreeViewModel()

        #expect(viewModel.render(snapshot: makeSnapshot(inspectionState: .empty)) == .reload)

        #expect(viewModel.rootItems.count == 1)
        #expect(viewModel.rootItems[0].kind == .message)
        #expect(viewModel.rootItems[0].displayText == "Select a packet to inspect its decode tree.")
    }

    @MainActor
    @Test func emptySelectionShowsPlaceholderAndHidesInspectorViews() throws {
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(inspectionState: .empty))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let outlineScrollView = try #require(findOutlineScrollView(in: controller.view))
        let hexTextView = try #require(firstSubview(ofType: HFTextView.self, in: controller.view))
        let textValues = textFieldValues(in: controller.view)

        #expect(isEffectivelyHidden(outlineView))
        #expect(isEffectivelyHidden(outlineScrollView))
        #expect(isEffectivelyHidden(hexTextView))
        #expect(textValues.contains("No Packet Selected"))
        #expect(textValues.contains("Select a packet to inspect its decode tree and bytes."))
    }

    @MainActor
    @Test func selectedPacketRestoresInspectorViewsAfterEmptyState() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(inspectionState: .empty))
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: PacketInspectionState(
                selectedPacketID: packet.id,
                inspection: makeFrameInspection(for: packet),
                selectedDetailNodeID: nil,
                highlightedByteRange: nil,
                isLoading: false,
                statusMessage: "Inspecting packet 1."
            )
        ))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let outlineScrollView = try #require(findOutlineScrollView(in: controller.view))
        let hexTextView = try #require(firstSubview(ofType: HFTextView.self, in: controller.view))

        #expect(!isEffectivelyHidden(outlineView))
        #expect(!isEffectivelyHidden(outlineScrollView))
        #expect(!isEffectivelyHidden(hexTextView))
        #expect(!textFieldValues(in: controller.view).contains("No Packet Selected"))
    }

    @MainActor
    @Test func decryptedDirectionsShareOneStreamLoad() async throws {
        let packet = makePacket(sniDomainName: "api.example.com")
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        let delegate = PacketInspectorDelegateSpy()
        delegate.decryptedStreamResult = .success(DecryptedStreamResult(
            protocolName: .tls,
            client: PacketEndpoint(address: "10.0.0.1", port: 1234),
            server: PacketEndpoint(address: "10.0.0.2", port: 443),
            request: DecryptedStreamPayload(data: Data("GET / HTTP/1.1\r\n\r\n".utf8), observedByteCount: 18, isTruncated: false),
            response: DecryptedStreamPayload(data: Data("HTTP/1.1 200 OK\r\n\r\n".utf8), observedByteCount: 19, isTruncated: false)
        ))
        controller.delegate = delegate
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeFrameInspection(for: packet))
        ))
        let tabs = try #require(segmentedControl(labels: ["Packet", "Decrypted"], in: controller.view))
        let directions = try #require(segmentedControl(labels: ["Client → Server", "Server → Client"], in: controller.view))
        let textView = try #require(allSubviews(ofType: NSTextView.self, in: controller.view).first { $0.usesFindBar })

        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        await drainMainQueue()

        #expect(delegate.decryptedStreamLoadCount == 1)
        #expect(textView.string == "GET / HTTP/1.1\r\n\r\n")
        #expect(textFieldValues(in: controller.view).contains("api.example.com"))

        directions.selectedSegment = 1
        directions.sendAction(directions.action, to: directions.target)
        await drainMainQueue()

        #expect(delegate.decryptedStreamLoadCount == 1)
        #expect(textView.string == "HTTP/1.1 200 OK\r\n\r\n")
    }

    @MainActor
    @Test func missingKeyLogOffersChooserInsideDecryptedView() async throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        let delegate = PacketInspectorDelegateSpy()
        delegate.decryptedStreamResult = .failure(TCPViewerCoreError(
            code: .unavailableFeature,
            message: "No TLS key-log file is selected. Choose one in Decrypted or open Tools → TLS Decryption… first."
        ))
        controller.delegate = delegate
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeFrameInspection(for: packet))
        ))
        let tabs = try #require(segmentedControl(labels: ["Packet", "Decrypted"], in: controller.view))

        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        await drainMainQueue()

        let chooseButton = try #require(allSubviews(ofType: NSButton.self, in: controller.view).first {
            $0.title == "Choose TLS Key Log…"
        })
        #expect(!isEffectivelyHidden(chooseButton))

        chooseButton.sendAction(chooseButton.action, to: chooseButton.target)
        await drainMainQueue()

        #expect(delegate.tlsKeyLogSelectionCount == 1)
        #expect(!isEffectivelyHidden(chooseButton))
    }

    @MainActor
    @Test func emptyDecryptedStreamOffersDifferentKeyLog() async throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        let delegate = PacketInspectorDelegateSpy()
        delegate.decryptedStreamResult = .success(DecryptedStreamResult(
            protocolName: .tls,
            client: packet.endpoints.source,
            server: packet.endpoints.destination,
            request: DecryptedStreamPayload(data: Data(), observedByteCount: 0, isTruncated: false),
            response: DecryptedStreamPayload(data: Data(), observedByteCount: 0, isTruncated: false)
        ))
        controller.delegate = delegate
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeFrameInspection(for: packet))
        ))
        let tabs = try #require(segmentedControl(labels: ["Packet", "Decrypted"], in: controller.view))

        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        await drainMainQueue()

        let chooseButton = try #require(allSubviews(ofType: NSButton.self, in: controller.view).first {
            $0.title == "Choose Different Key Log…"
        })
        #expect(!isEffectivelyHidden(chooseButton))
        #expect(textFieldValues(in: controller.view).contains("No decrypted data found"))
    }

    @MainActor
    @Test func runningCaptureOffersStopAndRetriesDecryption() async throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        let delegate = PacketInspectorDelegateSpy()
        delegate.decryptedStreamResult = .failure(TCPViewerCoreError(
            code: .unavailableFeature,
            message: "Stop the live capture to load the complete decrypted stream."
        ))
        delegate.stopAndDecryptHandler = {
            delegate.decryptedStreamResult = .success(self.makeDecryptedResult(packet: packet, request: "GET /after-stop"))
        }
        controller.delegate = delegate
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeFrameInspection(for: packet))
        ))
        let tabs = try #require(segmentedControl(labels: ["Packet", "Decrypted"], in: controller.view))
        let textView = try #require(allSubviews(ofType: NSTextView.self, in: controller.view).first { $0.usesFindBar })

        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        await drainMainQueue()

        let stopButton = try #require(allSubviews(ofType: NSButton.self, in: controller.view).first {
            $0.title == "Stop and Decrypt"
        })
        stopButton.sendAction(stopButton.action, to: stopButton.target)
        await drainMainQueue()
        await drainMainQueue()

        #expect(delegate.stopAndDecryptCount == 1)
        #expect(delegate.decryptedStreamLoadCount == 2)
        #expect(textView.string == "GET /after-stop")
    }

    @MainActor
    @Test func packetChangeRejectsStaleDecryptedStreamCompletion() async throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        let delegate = PacketInspectorDelegateSpy()
        delegate.defersDecryptedStreamCompletions = true
        controller.delegate = delegate
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: firstPacket,
            inspectionState: loadedInspectionState(packet: firstPacket, inspection: makeFrameInspection(for: firstPacket))
        ))
        let tabs = try #require(segmentedControl(labels: ["Packet", "Decrypted"], in: controller.view))
        let textView = try #require(allSubviews(ofType: NSTextView.self, in: controller.view).first { $0.usesFindBar })
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)

        controller.render(snapshot: makeSnapshot(
            packet: secondPacket,
            inspectionState: loadedInspectionState(packet: secondPacket, inspection: makeFrameInspection(for: secondPacket))
        ))
        #expect(delegate.decryptedStreamLoadCount == 2)
        #expect(delegate.decryptedStreamCancellationChecks[0]())
        #expect(!delegate.decryptedStreamCancellationChecks[1]())

        delegate.completeDecryptedStream(at: 0, with: .success(makeDecryptedResult(packet: firstPacket, request: "STALE")))
        await drainMainQueue()
        #expect(textView.string != "STALE")

        delegate.completeDecryptedStream(at: 1, with: .success(makeDecryptedResult(packet: secondPacket, request: "CURRENT")))
        await drainMainQueue()
        #expect(textView.string == "CURRENT")
    }

    @MainActor
    @Test func inspectorFilterIsAlwaysVisibleAndCommandShiftFIsReservedForSidebarMenu() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeNestedInspection(for: packet))
        ))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let searchField = try #require(firstSubview(ofType: NSSearchField.self, in: controller.view))
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        #expect(!isEffectivelyHidden(searchField))
        #expect(!outlineView.performKeyEquivalent(with: commandFEvent()))
        #expect(!outlineView.performKeyEquivalent(with: commandShiftFEvent()))
        #expect(!isEffectivelyHidden(searchField))

        searchField.stringValue = "source"
        #expect(!outlineView.performKeyEquivalent(with: commandShiftFEvent()))

        #expect(!isEffectivelyHidden(searchField))
        #expect(searchField.stringValue == "source")
    }

    @MainActor
    @Test func inspectorContentStartsBelowWindowToolbarSafeArea() throws {
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        let stackView = try #require(firstSubview(ofType: NSStackView.self, in: controller.view))

        #expect(hasTopConstraint(from: stackView, to: controller.view.safeAreaLayoutGuide, in: controller.view))
    }

    @MainActor
    @Test func rightPlacementLaysOutOutlineAboveHexView() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 500, height: 500)

        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeFrameInspection(for: packet)),
            inspectorPlacement: .trailing
        ))
        controller.view.layoutSubtreeIfNeeded()

        let splitView = try #require(findInspectorDetailSplitView(in: controller.view))
        let outlinePane = try #require(splitView.subviews.first { firstSubview(ofType: NSOutlineView.self, in: $0) != nil })
        let hexPane = try #require(splitView.subviews.first { firstSubview(ofType: HFTextView.self, in: $0) != nil })
        let splitFrame = splitView.convert(splitView.bounds, to: controller.view)
        let outlineFrame = outlinePane.convert(outlinePane.bounds, to: splitView)
        let hexFrame = hexPane.convert(hexPane.bounds, to: splitView)
        let availableHeight = splitView.bounds.height - splitView.dividerThickness

        #expect(!splitView.isVertical)
        #expect(frame(outlineFrame, isVisuallyAbove: hexFrame, in: splitView))
        #expect(abs(splitFrame.width - controller.view.bounds.width) <= 1)
        #expect(abs(splitFrame.height - (controller.view.bounds.height - 68)) <= 1)
        #expect(abs(outlineFrame.height - availableHeight * 0.70) <= 2)
        #expect(abs(hexFrame.height - availableHeight * 0.30) <= 2)
    }

    @MainActor
    @Test func bottomPlacementLaysOutOutlineBesideHexView() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 360)

        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeFrameInspection(for: packet)),
            inspectorPlacement: .bottom
        ))
        controller.view.layoutSubtreeIfNeeded()

        let splitView = try #require(findInspectorDetailSplitView(in: controller.view))
        let outlinePane = try #require(splitView.subviews.first { firstSubview(ofType: NSOutlineView.self, in: $0) != nil })
        let hexPane = try #require(splitView.subviews.first { firstSubview(ofType: HFTextView.self, in: $0) != nil })
        let splitFrame = splitView.convert(splitView.bounds, to: controller.view)
        let outlineFrame = outlinePane.convert(outlinePane.bounds, to: splitView)
        let hexFrame = hexPane.convert(hexPane.bounds, to: splitView)
        let availableWidth = splitView.bounds.width - splitView.dividerThickness

        #expect(splitView.isVertical)
        #expect(outlinePane.frame.minX < hexPane.frame.minX)
        #expect(abs(splitFrame.width - controller.view.bounds.width) <= 1)
        #expect(abs(outlineFrame.minX - splitView.bounds.minX) <= 1)
        #expect(abs(hexFrame.maxX - splitView.bounds.maxX) <= 1)
        #expect(abs(outlineFrame.width - availableWidth * 0.70) <= 2)
        #expect(abs(hexFrame.width - availableWidth * 0.30) <= 2)
    }

    @MainActor
    @Test func inspectorContextMenuIncludesCopySubmenuExpandAndCollapseCommands() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeNestedInspection(for: packet))
        ))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let menu = try #require(outlineView.menu)
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        controller.menuNeedsUpdate(menu)

        #expect(menu.items.count == 8)
        let copyItem = menu.items[0]
        let createColumnSeparatorItem = menu.items[1]
        let createColumnItem = menu.items[2]
        let separatorItem = menu.items[3]
        let expandAllItem = menu.items[4]
        let collapseAllItem = menu.items[5]
        let secondSeparatorItem = menu.items[6]
        let filterItem = menu.items[7]
        let copySubmenu = try #require(copyItem.submenu)
        let copySubmenuTitles = copySubmenu.items.map(\.title)

        #expect(copyItem.title == "Copy")
        #expect(copyItem.isEnabled)
        #expect(copySubmenuTitles == [
            "Selected Tree Items",
            "All Tree Items",
            "",
            "Copy Bytes as Hex + ASCII Dump",
            "...as Hex Dump",
            "...as UTF-8 Text",
            "...as ASCII Text",
            "...as a Hex Stream",
            "...as a Base64 String",
            "...as MIME Data",
            "...as C String",
            "...as Go literal",
            "...as C Array",
        ])
        #expect(copySubmenu.items[0].isEnabled)
        #expect(copySubmenu.items[1].isEnabled)
        #expect(copySubmenu.items[2].isSeparatorItem)
        let byteCopyItemsEnabled = copySubmenu.items.dropFirst(3).allSatisfy { $0.isEnabled }
        #expect(byteCopyItemsEnabled)
        #expect(createColumnSeparatorItem.isSeparatorItem)
        #expect(createColumnItem.title == "Create Column")
        #expect(createColumnItem.isEnabled)
        #expect(createColumnItem.toolTip == "Create a packet table column from the selected packet detail field.")
        #expect(separatorItem.isSeparatorItem)
        #expect(expandAllItem.title == "Expand All")
        #expect(expandAllItem.isEnabled)
        #expect(collapseAllItem.title == "Collapse All")
        #expect(collapseAllItem.isEnabled)
        #expect(secondSeparatorItem.isSeparatorItem)
        #expect(filterItem.title == "Filter")
        #expect(filterItem.isEnabled)
        #expect(filterItem.keyEquivalent.isEmpty)
    }

    @MainActor
    @Test func inspectorContextMenuExpandsAndCollapsesAllRows() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeNestedInspection(for: packet))
        ))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let menu = try #require(outlineView.menu)
        controller.menuNeedsUpdate(menu)
        let expandAllItem = try #require(menu.items.first { $0.title == "Expand All" })
        let collapseAllItem = try #require(menu.items.first { $0.title == "Collapse All" })
        let expandAction = try #require(expandAllItem.action)
        let collapseAction = try #require(collapseAllItem.action)

        #expect(outlineView.numberOfRows == 2)
        #expect(NSApp.sendAction(expandAction, to: expandAllItem.target, from: expandAllItem))

        let expandedRoot = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)
        let expandedChild = try #require(outlineView.item(atRow: 1) as? PacketInspectorTreeItem)
        #expect(outlineView.numberOfRows == 3)
        #expect(outlineView.isItemExpanded(expandedRoot))
        #expect(outlineView.isItemExpanded(expandedChild))

        #expect(NSApp.sendAction(collapseAction, to: collapseAllItem.target, from: collapseAllItem))

        let collapsedRoot = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)
        #expect(outlineView.numberOfRows == 1)
        #expect(!outlineView.isItemExpanded(collapsedRoot))
    }

    @MainActor
    @Test func inspectorLongSummaryRowsAreSelectableOutlineRows() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        let delegate = PacketInspectorDelegateSpy()
        controller.delegate = delegate
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeLongLayerSummaryInspection(for: packet))
        ))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let summaryItem = try #require(outlineView.item(atRow: 1) as? PacketInspectorTreeItem)
        let summarySelectionID = try #require(summaryItem.selectionID)

        #expect(summaryItem.nodeID == nil)
        #expect(controller.outlineView(outlineView, shouldSelectItem: summaryItem))

        outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: outlineView))

        #expect(outlineView.selectedRow == 1)
        #expect(delegate.selectedDetailNodeID == summarySelectionID)
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

    @Test func filterMatchesKeysFieldNamesAndValuesCaseInsensitively() throws {
        let packet = makePacket()
        let inspection = PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(
                    id: "ipv4",
                    name: "IPv4",
                    fieldName: "ip",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "ipv4.src", name: "Source", fieldName: "ip.src", value: "10.0.0.1"),
                        PacketDetailNode(id: "ipv4.dst", name: "Destination", fieldName: "ip.dst", value: "10.0.0.2"),
                    ]
                ),
                PacketDetailNode(id: "tcp", name: "TCP", value: "443 -> 1234", kind: .layer),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
        let state = loadedInspectionState(packet: packet, inspection: inspection)
        let viewModel = PacketInspectorTreeViewModel()

        #expect(viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: state), filterText: "IP.SRC") == .reload)

        let rootItem = try #require(viewModel.rootItems.first)
        #expect(viewModel.rootItems.count == 1)
        #expect(rootItem.displayText == "IPv4")
        #expect(rootItem.children.map(\.displayText) == ["Source: 10.0.0.1"])
    }

    @Test func activeFilterAppliesWhenPacketInspectionChanges() throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let filterText = "Packet 2"
        let viewModel = PacketInspectorTreeViewModel()

        #expect(viewModel.render(
            snapshot: makeSnapshot(
                packet: firstPacket,
                inspectionState: loadedInspectionState(packet: firstPacket, inspection: makeFrameInspection(for: firstPacket))
            ),
            filterText: filterText
        ) == .reload)
        #expect(viewModel.rootItems.first?.displayText == "No inspector fields match \"Packet 2\".")

        #expect(viewModel.render(
            snapshot: makeSnapshot(
                packet: secondPacket,
                inspectionState: loadedInspectionState(packet: secondPacket, inspection: makeFrameInspection(for: secondPacket))
            ),
            filterText: filterText
        ) == .reload)
        #expect(viewModel.rootItems.first?.displayText == "Frame: Packet 2")
    }

    @MainActor
    @Test func filterRerenderUsesLatestInspectionStateAfterSnapshotReplacement() throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let searchField = try #require(firstSubview(ofType: NSSearchField.self, in: controller.view))

        controller.render(snapshot: makeSnapshot(
            packet: firstPacket,
            inspectionState: loadedInspectionState(packet: firstPacket, inspection: makeFrameInspection(for: firstPacket))
        ))
        searchField.stringValue = "Packet 1"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        let firstItem = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)
        #expect(firstItem.displayText == "Frame: Packet 1")

        controller.render(snapshot: makeSnapshot(
            packet: secondPacket,
            inspectionState: loadedInspectionState(packet: secondPacket, inspection: makeFrameInspection(for: secondPacket))
        ))
        let staleFilterItem = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)
        #expect(staleFilterItem.displayText == "No inspector fields match \"Packet 1\".")

        searchField.stringValue = "Packet 2"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        let latestItem = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)
        #expect(latestItem.displayText == "Frame: Packet 2")
    }

    @Test func longLayerSummaryBreaksIntoReadableChildRows() throws {
        let packet = makePacket()
        let inspection = makeLongLayerSummaryInspection(for: packet)
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

        let rootItem = try #require(viewModel.rootItems.first)
        #expect(rootItem.displayText == "IEEE 802.3 Ethernet")
        #expect(rootItem.children.map(\.displayText) == [
            "Source: 90:e7:36:d2:00:00",
            "Destination: 24:b2:7f:41:80:10",
            "Decode Status: Field decoding is not available yet.",
            "Bytes: 14 bytes",
        ])
        let summaryItems = Array(rootItem.children.prefix(3))
        #expect(summaryItems.allSatisfy { $0.nodeID == nil && $0.selectionID != nil })
        #expect(viewModel.item(withNodeID: "layer-0") === rootItem)

        let summarySelectionID = try #require(summaryItems.first?.selectionID)
        let selectedState = PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: summarySelectionID,
            highlightedByteRange: nil,
            isLoading: false,
            statusMessage: "Inspecting packet 1."
        )

        #expect(viewModel.render(snapshot: makeSnapshot(packet: packet, inspectionState: selectedState)) == .selection)
        #expect(viewModel.selectedNodeID == summarySelectionID)
        #expect(viewModel.item(withNodeID: summarySelectionID)?.displayText == "Source: 90:e7:36:d2:00:00")
    }

    @Test func longLayerSummaryReusesExistingDecodedChildRows() throws {
        let packet = makePacket()
        let inspection = PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(
                    id: "ipv6",
                    name: "IPv6",
                    value: "Src: 2001:0db8:85a3:0000:0000:8a2e:0370:7334, Dst: 2001:0db8:85a3:0000:0000:8a2e:0370:7335",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "ipv6.src", name: "Source", value: "2001:0db8:85a3:0000:0000:8a2e:0370:7334"),
                        PacketDetailNode(id: "ipv6.dst", name: "Destination", value: "2001:0db8:85a3:0000:0000:8a2e:0370:7335"),
                        PacketDetailNode(id: "ipv6.hopLimit", name: "Hop Limit", value: "64"),
                    ]
                ),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
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

        let rootItem = try #require(viewModel.rootItems.first)
        #expect(rootItem.displayText == "IPv6")
        #expect(rootItem.children.map(\.displayText) == [
            "Source: 2001:0db8:85a3:0000:0000:8a2e:0370:7334",
            "Destination: 2001:0db8:85a3:0000:0000:8a2e:0370:7335",
            "Hop Limit: 64",
        ])
    }

    @Test func copyFormatterPreservesMultipleRowsAndChildIndentation() {
        let text = PacketInspectorCopyFormatter.text(for: [
            PacketInspectorCopyRow(text: "Frame: Packet 1", indentationLevel: 0),
            PacketInspectorCopyRow(text: "Ethernet II", indentationLevel: 1),
            PacketInspectorCopyRow(text: "Options:\nTimestamp", indentationLevel: 2),
        ])

        let expected = [
            "Frame: Packet 1",
            "\tEthernet II",
            "\t\tOptions:",
            "\t\tTimestamp",
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    @Test func copyRowsForLeafNodeIncludesOnlyCurrentText() {
        let packet = makePacket()
        let viewModel = PacketInspectorTreeViewModel()
        viewModel.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeNestedInspection(for: packet))
        ))

        let text = PacketInspectorCopyFormatter.text(for: viewModel.copyRows(forSelectionIDs: ["frame.flags.df"]))

        #expect(text == "\t\tDon't Fragment: Set")
    }

    @Test func copyRowsForParentNodeIncludesChildNodesWithTabIndentation() {
        let packet = makePacket()
        let viewModel = PacketInspectorTreeViewModel()
        viewModel.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeNestedInspection(for: packet))
        ))

        let text = PacketInspectorCopyFormatter.text(for: viewModel.copyRows(forSelectionIDs: ["frame"]))

        let expected = [
            "Frame: Packet 1",
            "\tFlags",
            "\t\tDon't Fragment: Set",
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    @Test func copyRowsForMultipleSelectionsSkipsChildRowsAlreadyCopiedByParent() {
        let packet = makePacket()
        let viewModel = PacketInspectorTreeViewModel()
        viewModel.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeNestedInspection(for: packet))
        ))

        let text = PacketInspectorCopyFormatter.text(for: viewModel.copyRows(forSelectionIDs: ["frame", "frame.flags.df"]))

        let expected = [
            "Frame: Packet 1",
            "\tFlags",
            "\t\tDon't Fragment: Set",
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    @Test func copyAllRowsUsesFullUnfilteredTree() {
        let packet = makePacket()
        let inspection = PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(
                    id: "ipv4",
                    name: "IPv4",
                    fieldName: "ip",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "ipv4.src", name: "Source", value: "10.0.0.1"),
                        PacketDetailNode(id: "ipv4.dst", name: "Destination", value: "10.0.0.2"),
                    ]
                ),
                PacketDetailNode(id: "tcp", name: "TCP", value: "443 -> 1234", kind: .layer),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
        let viewModel = PacketInspectorTreeViewModel()

        viewModel.render(
            snapshot: makeSnapshot(packet: packet, inspectionState: loadedInspectionState(packet: packet, inspection: inspection)),
            filterText: "Source"
        )
        let text = PacketInspectorCopyFormatter.text(for: viewModel.copyRowsForAllDetails())

        #expect(viewModel.rootItems.first?.children.map(\.displayText) == ["Source: 10.0.0.1"])
        let expected = [
            "IPv4",
            "\tSource: 10.0.0.1",
            "\tDestination: 10.0.0.2",
            "TCP: 443 -> 1234",
        ].joined(separator: "\n")
        #expect(text == expected)
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

    @Test func expansionStateExpandsOnlyTopLevelItemsByDefault() {
        let child = PacketInspectorTreeItem(id: "frame.flags", name: "Flags", kind: .field, children: [
            PacketInspectorTreeItem(id: "frame.flags.df", name: "Don't Fragment", kind: .field),
        ])
        let root = PacketInspectorTreeItem(id: "frame", name: "Frame", kind: .layer, children: [child])
        let expansionState = PacketInspectorOutlineExpansionState()

        #expect(expansionState.shouldExpand(item: root, level: 0))
        #expect(!expansionState.shouldExpand(item: child, level: 1))
        #expect(!expansionState.shouldExpand(item: child.children[0], level: 2))
    }

    @Test func expansionStateUsesManualOverrides() {
        let child = PacketInspectorTreeItem(id: "frame.flags", name: "Flags", kind: .field, children: [
            PacketInspectorTreeItem(id: "frame.flags.df", name: "Don't Fragment", kind: .field),
        ])
        let root = PacketInspectorTreeItem(id: "frame", name: "Frame", kind: .layer, children: [child])
        let expansionState = PacketInspectorOutlineExpansionState()

        expansionState.recordCollapsed(item: root)
        expansionState.recordExpanded(item: child)

        #expect(!expansionState.shouldExpand(item: root, level: 0))
        #expect(expansionState.shouldExpand(item: child, level: 1))
    }

    @MainActor
    @Test func inspectorInitialRenderExpandsRootGroupsOnly() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeNestedInspection(for: packet))
        ))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let rootItem = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)
        let childItem = try #require(outlineView.item(atRow: 1) as? PacketInspectorTreeItem)

        #expect(outlineView.numberOfRows == 2)
        #expect(outlineView.isItemExpanded(rootItem))
        #expect(!outlineView.isItemExpanded(childItem))
    }

    @MainActor
    @Test func inspectorManualRootCollapsePersistsAcrossPackets() throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(
            packet: firstPacket,
            inspectionState: loadedInspectionState(packet: firstPacket, inspection: makeNestedInspection(for: firstPacket))
        ))
        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let firstRoot = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)

        outlineView.collapseItem(firstRoot)
        controller.render(snapshot: makeSnapshot(
            packet: secondPacket,
            inspectionState: loadedInspectionState(packet: secondPacket, inspection: makeNestedInspection(for: secondPacket))
        ))
        let secondRoot = try #require(outlineView.item(atRow: 0) as? PacketInspectorTreeItem)

        #expect(outlineView.numberOfRows == 1)
        #expect(!outlineView.isItemExpanded(secondRoot))
    }

    @MainActor
    @Test func inspectorManualNestedExpansionPersistsAcrossPackets() throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()

        controller.render(snapshot: makeSnapshot(
            packet: firstPacket,
            inspectionState: loadedInspectionState(packet: firstPacket, inspection: makeNestedInspection(for: firstPacket))
        ))
        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let firstChild = try #require(outlineView.item(atRow: 1) as? PacketInspectorTreeItem)

        outlineView.expandItem(firstChild)
        controller.render(snapshot: makeSnapshot(
            packet: secondPacket,
            inspectionState: loadedInspectionState(packet: secondPacket, inspection: makeNestedInspection(for: secondPacket))
        ))
        let secondChild = try #require(outlineView.item(atRow: 1) as? PacketInspectorTreeItem)

        #expect(outlineView.numberOfRows == 3)
        #expect(outlineView.isItemExpanded(secondChild))
    }

    @MainActor
    @Test func inspectorReloadPreservesOutlineScrollPosition() throws {
        let firstPacket = makePacket(packetNumber: 1)
        let secondPacket = makePacket(packetNumber: 2)
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        controller.view.layoutSubtreeIfNeeded()

        controller.render(snapshot: makeSnapshot(
            packet: firstPacket,
            inspectionState: loadedInspectionState(packet: firstPacket, inspection: makeLargeInspection(for: firstPacket))
        ))
        controller.view.layoutSubtreeIfNeeded()
        let outlineScrollView = try #require(findOutlineScrollView(in: controller.view))

        outlineScrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
        outlineScrollView.reflectScrolledClipView(outlineScrollView.contentView)
        let originalY = outlineScrollView.contentView.bounds.origin.y

        controller.render(snapshot: makeSnapshot(
            packet: secondPacket,
            inspectionState: loadedInspectionState(packet: secondPacket, inspection: makeLargeInspection(for: secondPacket))
        ))
        controller.view.layoutSubtreeIfNeeded()

        #expect(originalY > 0)
        #expect(abs(outlineScrollView.contentView.bounds.origin.y - originalY) <= 1)
    }

    private func makeSnapshot(
        packet: PacketSummary? = nil,
        inspectionState: PacketInspectionState,
        inspectorPlacement: NetworkInspectorPlacement = .trailing
    ) -> NetworkInspectorSnapshot {
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
            inspectorPlacement: inspectorPlacement,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: tableContent
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.PacketInspectorTreeViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
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

    private func findOutlineScrollView(in view: NSView) -> NSScrollView? {
        allSubviews(ofType: NSScrollView.self, in: view).first { $0.documentView is NSOutlineView }
    }

    private func findInspectorDetailSplitView(in view: NSView) -> NSSplitView? {
        allSubviews(ofType: NSSplitView.self, in: view).first { splitView in
            splitView.subviews.contains { firstSubview(ofType: NSOutlineView.self, in: $0) != nil } &&
                splitView.subviews.contains { firstSubview(ofType: HFTextView.self, in: $0) != nil }
        }
    }

    private func allSubviews<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
        let current = (view as? T).map { [$0] } ?? []
        return view.subviews.reduce(current) { result, subview in
            result + allSubviews(ofType: type, in: subview)
        }
    }

    private func segmentedControl(labels: [String], in view: NSView) -> NSSegmentedControl? {
        allSubviews(ofType: NSSegmentedControl.self, in: view).first { control in
            control.segmentCount == labels.count &&
                labels.indices.allSatisfy { control.label(forSegment: $0) == labels[$0] }
        }
    }

    private func frame(_ upperFrame: NSRect, isVisuallyAbove lowerFrame: NSRect, in view: NSView) -> Bool {
        let tolerance: CGFloat = 1
        if view.isFlipped {
            return upperFrame.maxY <= lowerFrame.minY + tolerance
        }

        return upperFrame.minY >= lowerFrame.maxY - tolerance
    }

    private func hasTopConstraint(from view: NSView, to layoutGuide: NSLayoutGuide, in container: NSView) -> Bool {
        container.constraints.contains { constraint in
            guard let firstItem = constraint.firstItem as AnyObject?,
                  let secondItem = constraint.secondItem as AnyObject? else {
                return false
            }

            return firstItem === view &&
                secondItem === layoutGuide &&
                constraint.firstAttribute == .top &&
                constraint.secondAttribute == .top
        }
    }

    private func commandFEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        )!
    }

    private func commandShiftFEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "F",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        )!
    }

    private func isEffectivelyHidden(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let view = current {
            if view.isHidden {
                return true
            }
            current = view.superview
        }

        return false
    }

    private func textFieldValues(in view: NSView) -> [String] {
        allSubviews(ofType: NSTextField.self, in: view).map(\.stringValue)
    }

    private func loadedInspectionState(packet: PacketSummary, inspection: PacketInspection) -> PacketInspectionState {
        PacketInspectionState(
            selectedPacketID: packet.id,
            inspection: inspection,
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: false,
            statusMessage: "Inspecting packet \(packet.packetNumber)."
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

    private func makeLongLayerSummaryInspection(for packet: PacketSummary) -> PacketInspection {
        let layerName = "IEEE 802.3 Ethernet, Src: 90:e7:36:d2:00:00, Dst: 24:b2:7f:41:80:10"
        return PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(
                    id: "layer-0",
                    name: layerName,
                    value: "Detailed field decoding is not available yet for \(layerName).",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "layer-0.bytes", name: "Bytes", value: "14 bytes"),
                    ]
                ),
            ],
            decodeStatus: PacketDecodeStatus(kind: .partial, reason: "Unsupported layer")
        )
    }

    private func makeNestedInspection(for packet: PacketSummary) -> PacketInspection {
        PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: [
                PacketDetailNode(
                    id: "frame",
                    name: "Frame",
                    value: "Packet \(packet.packetNumber)",
                    kind: .layer,
                    byteRange: PacketByteRange(offset: 0, length: 2),
                    children: [
                        PacketDetailNode(
                            id: "frame.flags",
                            name: "Flags",
                            byteRange: PacketByteRange(offset: 0, length: 1),
                            children: [
                                PacketDetailNode(
                                    id: "frame.flags.df",
                                    name: "Don't Fragment",
                                    value: "Set",
                                    byteRange: PacketByteRange(offset: 0, length: 1, bitOffset: 1, bitLength: 1, hasBitRange: true)
                                ),
                            ]
                        ),
                    ]
                ),
            ],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }

    private func makeLargeInspection(for packet: PacketSummary) -> PacketInspection {
        let nodes = (0..<40).map { index in
            PacketDetailNode(
                id: "layer-\(index)",
                name: "Layer \(index)",
                value: "Packet \(packet.packetNumber)",
                kind: .layer,
                children: [
                    PacketDetailNode(id: "layer-\(index).field", name: "Field \(index)", value: "\(index)"),
                ]
            )
        }

        return PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data([0x01, 0x02]),
            detailNodes: nodes,
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }

    private func makePacket(packetNumber: UInt64 = 1, sniDomainName: String? = nil) -> PacketSummary {
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
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: sniDomainName
        )
    }

    private func makeDecryptedResult(packet: PacketSummary, request: String) -> DecryptedStreamResult {
        DecryptedStreamResult(
            protocolName: .tls,
            client: PacketEndpoint(address: "10.0.0.1", port: 1234),
            server: PacketEndpoint(address: "10.0.0.2", port: 443),
            request: DecryptedStreamPayload(data: Data(request.utf8), observedByteCount: request.utf8.count, isTruncated: false),
            response: DecryptedStreamPayload(data: Data(), observedByteCount: 0, isTruncated: false)
        )
    }
}

private final class PacketInspectorDelegateSpy: PacketInspectorViewControllerDelegate {
    var selectedDetailNodeID: String?
    var customColumnRequest: PacketCustomColumnRequest?
    var decryptedStreamResult: Result<DecryptedStreamResult, Error>?
    var decryptedStreamLoadCount = 0
    var decryptedStreamCancellationChecks: [TCPFollowCancellationCheck] = []
    var defersDecryptedStreamCompletions = false
    var tlsKeyLogSelectionCount = 0
    var tlsKeyLogSelectionOutcome: TLSKeyLogSelectionOutcome = .cancelled
    var stopAndDecryptCount = 0
    var stopAndDecryptHandler: (() -> Void)?
    private var decryptedStreamCompletions: [TCPViewerCompletion<DecryptedStreamResult>] = []

    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?) {
        selectedDetailNodeID = identifier
    }

    func packetInspectorViewController(
        _ controller: PacketInspectorViewController,
        didRequestCreateCustomColumn request: PacketCustomColumnRequest
    ) {
        customColumnRequest = request
    }

    func packetInspectorViewController(
        _ controller: PacketInspectorViewController,
        didRequestChooseTLSKeyLog completion: @escaping (TLSKeyLogSelectionOutcome) -> Void
    ) {
        tlsKeyLogSelectionCount += 1
        completion(tlsKeyLogSelectionOutcome)
    }

    func packetInspectorViewControllerDidRequestStopAndDecrypt(
        _ controller: PacketInspectorViewController,
        completion: @escaping () -> Void
    ) {
        stopAndDecryptCount += 1
        stopAndDecryptHandler?()
        completion()
    }

    func packetInspectorViewController(
        _ controller: PacketInspectorViewController,
        loadDecryptedStreamFor packetID: PacketSummary.ID,
        progress: @escaping TCPFollowProgressHandler,
        shouldCancel: @escaping TCPFollowCancellationCheck,
        completion: @escaping TCPViewerCompletion<DecryptedStreamResult>
    ) {
        decryptedStreamLoadCount += 1
        decryptedStreamCancellationChecks.append(shouldCancel)
        if defersDecryptedStreamCompletions {
            decryptedStreamCompletions.append(completion)
            return
        }
        completion(decryptedStreamResult ?? .failure(TCPViewerCoreError(
            code: .unavailableFeature,
            message: "No decrypted stream result was configured."
        )))
    }

    func completeDecryptedStream(at index: Int, with result: Result<DecryptedStreamResult, Error>) {
        decryptedStreamCompletions[index](result)
    }
}
