//
//  PacketTableMenuLogicTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import AppKit
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
        #expect(state.exportEnabled)
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
        #expect(state.exportEnabled)
    }

    @Test func copyFormatterUsesCSVRowsAndClickedColumnCells() {
        let rows = [
            PacketTableRow(packet: makePacket(packetNumber: 1, infoSummary: "Hello, world")),
            PacketTableRow(packet: makePacket(packetNumber: 2, infoSummary: "Plain")),
        ]

        let rowCopy = PacketTableCopyFormatter.rows(rows, format: .csv)
        let cellCopy = PacketTableCopyFormatter.csvCells(rows, column: .summary)

        #expect(rowCopy.contains("\"Hello, world\""))
        #expect(rowCopy.split(separator: "\n").count == 2)
        #expect(cellCopy == """
        "Hello, world"
        Plain
        """)
    }

    @Test func copyFormatterSupportsRowsAsFormatsForMultipleSelections() throws {
        let rows = [
            PacketTableRow(packet: makePacket(packetNumber: 1, infoSummary: "Hello, world | alpha")),
            PacketTableRow(packet: makePacket(packetNumber: 3, infoSummary: "Line\nBreak")),
        ]

        let plainText = PacketTableCopyFormatter.rows(rows, format: .plainText)
        #expect(plainText.split(separator: "\n").count == 2)
        #expect(plainText.contains("\t"))
        #expect(plainText.contains("Line Break"))

        let jsonData = try #require(PacketTableCopyFormatter.rows(rows, format: .json).data(using: .utf8))
        let jsonRows = try #require(JSONSerialization.jsonObject(with: jsonData) as? [[String: String]])
        #expect(jsonRows.count == 2)
        #expect(jsonRows[0]["summary"] == "Hello, world | alpha")
        #expect(jsonRows[1]["summary"] == "Line\nBreak")

        let markdown = PacketTableCopyFormatter.rows(rows, format: .markdownTable)
        #expect(markdown.contains("| # | Time | Source | Destination | Domain | Client | Protocol | Length | Summary | Tags |"))
        #expect(markdown.contains("Hello, world \\| alpha"))
        #expect(markdown.contains("Line Break"))

        let csvWithHeader = PacketTableCopyFormatter.rows(rows, format: .csvWithHeader)
        #expect(csvWithHeader.hasPrefix("#,Time,Source,Destination,Domain,Client,Protocol,Length,Summary,Tags\n"))
        #expect(csvWithHeader.contains("\"Hello, world | alpha\""))
        #expect(csvWithHeader.contains("\"Line\nBreak\""))
    }

    @Test func selectionSyncUsesFirstSelectedRowForInspector() {
        let packets = [
            makePacket(packetNumber: 1),
            makePacket(packetNumber: 2),
            makePacket(packetNumber: 3),
        ]

        #expect(PacketTableSelectionSyncPlanner.action(
            rowCount: packets.count,
            visualSelectedPacketID: packets[0].id,
            selectedPacketID: packets[0].id,
            selectedRowIndex: 0
        ) == .none)

        #expect(PacketTableSelectionSyncPlanner.action(
            rowCount: packets.count,
            visualSelectedPacketID: packets[0].id,
            selectedPacketID: packets[2].id,
            selectedRowIndex: 2
        ) == .select(2))
    }

    @Test func selectionSyncIgnoresStaleVisualSelection() {
        let packets = [
            makePacket(packetNumber: 1),
            makePacket(packetNumber: 2),
        ]

        #expect(PacketTableSelectionSyncPlanner.action(
            rowCount: packets.count,
            visualSelectedPacketID: nil,
            selectedPacketID: packets[1].id,
            selectedRowIndex: 2
        ) == .none)

        #expect(PacketTableSelectionSyncPlanner.action(
            rowCount: packets.count,
            visualSelectedPacketID: packets[0].id,
            selectedPacketID: nil,
            selectedRowIndex: nil
        ) == .deselect)
    }

    @Test func clickSelectionCollapsePreparesOnlyForPlainSingleClickInsideMultiSelection() {
        let selectedRows = IndexSet([1, 3])

        #expect(PacketTableClickSelectionCollapsePlanner.shouldPrepareCollapse(
            clickedRow: 3,
            selectedRowIndexes: selectedRows,
            modifierFlags: [],
            clickCount: 1
        ))
        #expect(!PacketTableClickSelectionCollapsePlanner.shouldPrepareCollapse(
            clickedRow: 3,
            selectedRowIndexes: selectedRows,
            modifierFlags: .command,
            clickCount: 1
        ))
        #expect(!PacketTableClickSelectionCollapsePlanner.shouldPrepareCollapse(
            clickedRow: 3,
            selectedRowIndexes: selectedRows,
            modifierFlags: [],
            clickCount: 2
        ))
        #expect(!PacketTableClickSelectionCollapsePlanner.shouldPrepareCollapse(
            clickedRow: 2,
            selectedRowIndexes: selectedRows,
            modifierFlags: [],
            clickCount: 1
        ))
    }

    @Test func clickSelectionCollapseAppliesOnlyAfterNonDragTrackingWithValidRow() {
        let selectedRows = IndexSet([1, 3])

        #expect(PacketTableClickSelectionCollapsePlanner.shouldApplyCollapse(
            clickedRow: 3,
            rowCount: 4,
            selectedRowIndexes: selectedRows,
            didDrag: false
        ))
        #expect(!PacketTableClickSelectionCollapsePlanner.shouldApplyCollapse(
            clickedRow: 3,
            rowCount: 4,
            selectedRowIndexes: selectedRows,
            didDrag: true
        ))
        #expect(!PacketTableClickSelectionCollapsePlanner.shouldApplyCollapse(
            clickedRow: 4,
            rowCount: 4,
            selectedRowIndexes: selectedRows,
            didDrag: false
        ))
        #expect(!PacketTableClickSelectionCollapsePlanner.shouldApplyCollapse(
            clickedRow: 3,
            rowCount: 4,
            selectedRowIndexes: IndexSet(integer: 3),
            didDrag: false
        ))
    }

    @Test func menuStateProviderIgnoresStaleSelectedIndexes() {
        let packets = [
            makePacket(packetNumber: 1),
            makePacket(packetNumber: 2),
        ]
        let rows = packets.map(PacketTableRow.init(packet:))

        let state = PacketTableMenuLogic.state(
            rowCount: rows.count,
            rowProvider: { rows.indices.contains($0) ? rows[$0] : nil },
            selectedRowIndexes: IndexSet([1, 2]),
            clickedRowIndex: nil,
            clickedColumnIdentifier: "summary"
        )

        #expect(state.targetRows == [1])
        #expect(state.copyRowEnabled)
        #expect(state.copyCellEnabled)
    }

    @Test func rowStoreSerializesConcurrentReadsAndWrites() {
        let rows = (1...300).map { packetNumber in
            PacketTableRow(packet: makePacket(packetNumber: UInt64(packetNumber)))
        }
        let store = PacketTableRowStore()
        let queue = DispatchQueue(label: "PacketTableRowStoreTests.concurrent", attributes: .concurrent)
        let appendGroup = DispatchGroup()

        for (index, row) in rows.enumerated() {
            appendGroup.enter()
            queue.async {
                store.append(row)
                appendGroup.leave()
            }

            appendGroup.enter()
            queue.async {
                _ = store.row(at: index)
                _ = store.rows(at: [index - 1, index, index + 1])
                _ = store.visibleRowIndex(for: row.id)
                appendGroup.leave()
            }
        }

        #expect(appendGroup.wait(timeout: .now() + 5) == .success)
        #expect(store.rowCount == rows.count)
        #expect(store.visiblePacketIndexCount == rows.count)

        let updateGroup = DispatchGroup()
        for row in rows {
            guard let rowIndex = store.visibleRowIndex(for: row.id) else {
                Issue.record("Missing visible index for row \(row.id)")
                continue
            }

            updateGroup.enter()
            queue.async {
                _ = store.updateRow(at: rowIndex, with: row)
                updateGroup.leave()
            }

            updateGroup.enter()
            queue.async {
                _ = store.row(at: rowIndex)
                _ = store.rowIDs()
                updateGroup.leave()
            }
        }

        #expect(updateGroup.wait(timeout: .now() + 5) == .success)
        #expect(store.rowCount == rows.count)
        for row in rows {
            #expect(store.visibleRowIndex(for: row.id) != nil)
        }
    }

    @MainActor
    @Test func packetTableDataSourceIgnoresStaleRowsAfterReload() throws {
        let defaults = Self.makeUserDefaults()
        let controller = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        controller.loadViewIfNeeded()
        let tableView = try Self.tableView(in: controller)
        let summaryColumn = try #require(tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("summary")))
        let firstPacket = makePacket(packetNumber: 1, infoSummary: "first")
        let secondPacket = makePacket(packetNumber: 2, infoSummary: "second")

        controller.render(snapshot: makeSnapshot(
            packets: [firstPacket, secondPacket],
            generation: 1,
            updatePlan: .reload
        ))
        #expect(controller.tableView(tableView, objectValueFor: summaryColumn, row: 1) as? String == "second")

        controller.render(snapshot: makeSnapshot(
            packets: [firstPacket],
            generation: 2,
            updatePlan: .reload
        ))

        #expect(controller.numberOfRows(in: tableView) == 1)
        #expect(controller.tableView(tableView, objectValueFor: summaryColumn, row: 1) == nil)
        controller.tableView(tableView, willDisplayCell: PacketTextCell(), for: summaryColumn, row: 1)
    }

    @MainActor
    @Test func packetTablePersistsUserColumnLayout() throws {
        let defaults = Self.makeUserDefaults()
        let controller = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        controller.loadViewIfNeeded()

        let tableView = try Self.tableView(in: controller)
        let columnIdentifiers = Set(tableView.tableColumns.map { $0.identifier.rawValue })
        let hiddenColumnIdentifiers = Set(tableView.tableColumns.filter { $0.isHidden }.map { $0.identifier.rawValue })
        let defaultHiddenColumnIdentifiers = Set(PacketTableColumnService.defaultDefinitions
            .filter { !$0.isDefaultVisible }
            .map(\.identifier))

        #expect(tableView.autosaveName == PacketTableViewController.columnAutosaveName)
        #expect(!tableView.autosaveTableColumns)
        #expect(tableView.allowsColumnReordering)
        #expect(tableView.allowsColumnResizing)
        #expect(columnIdentifiers == Set(PacketTableColumnService.defaultDefinitions.map(\.identifier)))
        #expect(hiddenColumnIdentifiers == defaultHiddenColumnIdentifiers)

        controller.togglePacketTableColumnVisibilityFromMenu(Self.columnSender("sourcePort"))
        controller.togglePacketTableColumnVisibilityFromMenu(Self.columnSender("tags"))

        let sourcePortColumn = try #require(tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("sourcePort")))
        sourcePortColumn.width = 144
        controller.tableViewColumnDidResize(Notification(name: Notification.Name("PacketTableColumnResizeTest"), object: tableView))

        let sourcePortIndex = try #require(tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == "sourcePort"
        }))
        tableView.moveColumn(sourcePortIndex, toColumn: 1)
        controller.tableViewColumnDidMove(Notification(name: Notification.Name("PacketTableColumnMoveTest"), object: tableView))

        let restoredController = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        restoredController.loadViewIfNeeded()
        let restoredTableView = try Self.tableView(in: restoredController)
        let restoredSourcePortColumn = try #require(restoredTableView.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier("sourcePort")
        ))
        let restoredTagsColumn = try #require(restoredTableView.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier("tags")
        ))

        #expect(restoredTableView.tableColumns[1].identifier.rawValue == "sourcePort")
        #expect(!restoredSourcePortColumn.isHidden)
        #expect(restoredTagsColumn.isHidden)
        #expect(abs(restoredSourcePortColumn.width - 144) < 0.5)

        restoredController.resetPacketTableColumnsFromMenu(nil)

        let resetController = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        resetController.loadViewIfNeeded()
        let resetTableView = try Self.tableView(in: resetController)
        let resetSourcePortColumn = try #require(resetTableView.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier("sourcePort")
        ))
        let resetTagsColumn = try #require(resetTableView.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier("tags")
        ))
        let defaultSourcePortIndex = try #require(PacketTableColumnService.defaultDefinitions.firstIndex {
            $0.identifier == "sourcePort"
        })

        #expect(resetTableView.tableColumns[defaultSourcePortIndex].identifier.rawValue == "sourcePort")
        #expect(resetSourcePortColumn.isHidden)
        #expect(!resetTagsColumn.isHidden)
        #expect(abs(resetSourcePortColumn.width - 92) < 0.5)
    }

    @MainActor
    @Test func contextMenuItemsIncludeCopyRowsAsSubmenuAndTooltips() throws {
        let controller = PacketTableContextMenuController()
        let stateProvider = MenuStateProvider(state: PacketTableMenuState(
            targetRows: [0],
            clickedColumn: .source,
            copyRowEnabled: true,
            copyCellEnabled: true,
            pinDomainEnabled: true,
            pinIPEnabled: true,
            pinClientEnabled: true,
            saveEnabled: true,
            exportEnabled: true,
            deleteEnabled: true
        ))
        let actionHandler = MenuActionHandler()
        controller.stateProvider = stateProvider
        controller.actionHandler = actionHandler

        let menu = controller.makeMenu()
        controller.menuNeedsUpdate(menu)
        let items = menu.nonSeparatorItemsIncludingSubmenus()
        let copyRowsAsItem = try #require(menu.items.first { $0.title == "Copy Rows As" })
        let copyRowsAsSubmenu = try #require(copyRowsAsItem.submenu)
        let copyRowsAsTitles = copyRowsAsSubmenu.items.compactMap { item in
            item.isSeparatorItem ? nil : item.title
        }

        #expect(copyRowsAsTitles == ["Plain text", "JSON", "Markdown Table", "CSV", "CSV with Header"])
        #expect(copyRowsAsSubmenu.items.filter(\.isSeparatorItem).count == 2)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { item in item.toolTip?.isEmpty == false })
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

    private func makeSnapshot(
        packets: [PacketSummary],
        generation: UInt64,
        updatePlan: PacketTableUpdatePlan
    ) -> NetworkInspectorSnapshot {
        var base = TCPViewerWindowSnapshot.foundation
        base.packetIngestState.replace(with: packets, source: .live)
        base.navigationState.visiblePacketIDs = packets.map(\.id)

        let rows = packets.map(PacketTableRow.init(packet:))
        let visibleIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, index)
        })
        let tableContent = PacketTableContent(
            displayFilter: PacketDisplayFilter(""),
            displayFilterChips: [],
            store: PacketTableRowStore(rows: rows, visiblePacketRowIndexByID: visibleIndex),
            generation: generation,
            updatePlan: updatePlan,
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

    private static func makeUserDefaults() -> UserDefaults {
        let suiteName = "PacketTableMenuLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    private static func tableView(in controller: PacketTableViewController) throws -> NSTableView {
        let scrollView = try #require(controller.view as? NSScrollView)
        return try #require(scrollView.documentView as? NSTableView)
    }

    @MainActor
    private static func columnSender(_ identifier: String) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }
}

private final class MenuStateProvider: PacketTableContextMenuStateProviding {
    private let state: PacketTableMenuState

    init(state: PacketTableMenuState) {
        self.state = state
    }

    func packetTableContextMenuWillOpen() {}

    func packetTableContextMenuState() -> PacketTableMenuState {
        state
    }
}

private final class MenuActionHandler: NSObject, PacketTableContextMenuActionHandling {
    func copyRowsFromMenu(_ sender: Any?) {}
    func copyRowsAsPlainTextFromMenu(_ sender: Any?) {}
    func copyRowsAsJSONFromMenu(_ sender: Any?) {}
    func copyRowsAsMarkdownTableFromMenu(_ sender: Any?) {}
    func copyRowsAsCSVFromMenu(_ sender: Any?) {}
    func copyRowsAsCSVWithHeaderFromMenu(_ sender: Any?) {}
    func copyCellFromMenu(_ sender: Any?) {}
    func pinDomainFromMenu(_ sender: Any?) {}
    func pinIPFromMenu(_ sender: Any?) {}
    func pinClientFromMenu(_ sender: Any?) {}
    func saveRowsFromMenu(_ sender: Any?) {}
    func exportRowsAsPcapFromMenu(_ sender: Any?) {}
    func exportRowsAsPcapngFromMenu(_ sender: Any?) {}
    func deleteRowsFromMenu(_ sender: Any?) {}
}

private extension NSMenu {
    func nonSeparatorItemsIncludingSubmenus() -> [NSMenuItem] {
        items.flatMap { item -> [NSMenuItem] in
            guard !item.isSeparatorItem else {
                return []
            }

            return [item] + (item.submenu?.nonSeparatorItemsIncludingSubmenus() ?? [])
        }
    }
}
