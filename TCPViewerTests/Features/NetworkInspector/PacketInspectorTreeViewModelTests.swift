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
    @Test func inspectorFilterIsAlwaysVisibleAndCommandShiftFPreservesQuery() throws {
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
        #expect(outlineView.performKeyEquivalent(with: commandShiftFEvent()))
        #expect(!isEffectivelyHidden(searchField))

        searchField.stringValue = "source"
        #expect(outlineView.performKeyEquivalent(with: commandShiftFEvent()))

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
    @Test func inspectorContextMenuIncludesFilterCommandForRows() throws {
        let packet = makePacket()
        let controller = PacketInspectorViewController(configuration: AppConfiguration(defaults: isolatedDefaults()))
        controller.loadViewIfNeeded()
        controller.render(snapshot: makeSnapshot(
            packet: packet,
            inspectionState: loadedInspectionState(packet: packet, inspection: makeFrameInspection(for: packet))
        ))

        let outlineView = try #require(firstSubview(ofType: NSOutlineView.self, in: controller.view))
        let menu = try #require(outlineView.menu)
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        controller.menuNeedsUpdate(menu)

        #expect(menu.items.count == 3)
        let copyItem = menu.items[0]
        let separatorItem = menu.items[1]
        let filterItem = menu.items[2]

        #expect(copyItem.title == "Copy")
        #expect(copyItem.isEnabled)
        #expect(separatorItem.isSeparatorItem)
        #expect(filterItem.title == "Filter")
        #expect(filterItem.isEnabled)
        #expect(filterItem.keyEquivalent == "f")
        #expect(filterItem.keyEquivalentModifierMask.contains(.command))
        #expect(filterItem.keyEquivalentModifierMask.contains(.shift))
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

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.PacketInspectorTreeViewModelTests.\(UUID().uuidString)"
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

    private func findOutlineScrollView(in view: NSView) -> NSScrollView? {
        allSubviews(ofType: NSScrollView.self, in: view).first { $0.documentView is NSOutlineView }
    }

    private func allSubviews<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
        let current = (view as? T).map { [$0] } ?? []
        return view.subviews.reduce(current) { result, subview in
            result + allSubviews(ofType: type, in: subview)
        }
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
                    children: [
                        PacketDetailNode(
                            id: "frame.flags",
                            name: "Flags",
                            children: [
                                PacketDetailNode(id: "frame.flags.df", name: "Don't Fragment", value: "Set"),
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

private final class PacketInspectorDelegateSpy: PacketInspectorViewControllerDelegate {
    var selectedDetailNodeID: String?

    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?) {
        selectedDetailNodeID = identifier
    }
}
