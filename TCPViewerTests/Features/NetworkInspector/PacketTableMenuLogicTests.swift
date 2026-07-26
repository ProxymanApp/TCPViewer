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

    @Test func selectedClickedRowTargetsMultipleRowsAndEnablesPinWhenAnyRowHasApp() {
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
        #expect(state.pinEnabled)
        #expect(state.saveEnabled)
        #expect(state.styleEnabled)
        #expect(state.commentEnabled)
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
        #expect(state.pinEnabled)
        #expect(state.commentEnabled)
        #expect(state.exportEnabled)
    }

    @Test func customClickedColumnEnablesCopyCellWithRawIdentifier() {
        let rows = [PacketTableRow(packet: makePacket(packetNumber: 1))]

        let state = PacketTableMenuLogic.state(
            rows: rows,
            selectedRowIndexes: IndexSet(),
            clickedRowIndex: 0,
            clickedColumnIdentifier: "custom.field.ip.src"
        )

        #expect(state.targetRows == [0])
        #expect(state.clickedColumn == .unknown)
        #expect(state.clickedColumnIdentifier == "custom.field.ip.src")
        #expect(state.copyCellEnabled)
    }

    @Test func copyFormatterUsesCSVRowsAndClickedColumnCells() {
        let rows = [
            PacketTableRow(packet: makePacket(packetNumber: 1, infoSummary: "Hello, world")),
            PacketTableRow(packet: makePacket(packetNumber: 2, infoSummary: "Plain")),
        ]

        let rowCopy = PacketTableCopyFormatter.rows(rows, format: .csv)
        let cellCopy = PacketTableCopyFormatter.csvCells(rows, column: .summary)
        let customCellCopy = PacketTableCopyFormatter.csvValues(["10.0.0.1", "Hello, world"])

        #expect(rowCopy.contains("\"Hello, world\""))
        #expect(rowCopy.split(separator: "\n").count == 2)
        #expect(cellCopy == """
        "Hello, world"
        Plain
        """)
        #expect(customCellCopy == """
        10.0.0.1
        "Hello, world"
        """)
    }

    @Test func commentColumnFlattensMultilineTextForOneLineRendering() {
        let row = PacketTableRow(packet: makePacket(
            packetNumber: 1,
            customComment: "First line\nSecond line"
        ))

        #expect(row.comment == "First line\nSecond line")
        #expect(row.text(for: .comment) == "First line Second line")
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
            visualSelectedID: packets[0].id,
            selectedPacketID: packets[0].id,
            selectedRowIndex: 0,
            rowCount: packets.count
        ) == .none)

        #expect(PacketTableSelectionSyncPlanner.action(
            visualSelectedID: packets[0].id,
            selectedPacketID: packets[2].id,
            selectedRowIndex: 2,
            rowCount: packets.count
        ) == .select(2))
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
    @Test func packetTableCreatesPersistsAndResetsCustomColumns() throws {
        let defaults = Self.makeUserDefaults()
        let controller = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        controller.loadViewIfNeeded()
        let tableView = try Self.tableView(in: controller)

        controller.createCustomColumn(from: PacketCustomColumnRequest(
            fieldName: "ip.src",
            title: "Source Address",
            packetID: 1,
            sampleValue: "10.0.0.1"
        ))
        controller.createCustomColumn(from: PacketCustomColumnRequest(
            fieldName: "IP.SRC",
            title: "Duplicate Source",
            packetID: 1,
            sampleValue: "10.0.0.1"
        ))

        let customColumns = tableView.tableColumns.filter { $0.identifier.rawValue == "custom.field.ip.src" }
        let customColumn = try #require(customColumns.first)

        #expect(customColumns.count == 1)
        #expect(!customColumn.isHidden)
        #expect(tableView.tableColumns.suffix(2).map { $0.identifier.rawValue } == ["custom.field.ip.src", "comment"])

        let restoredController = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        restoredController.loadViewIfNeeded()
        let restoredTableView = try Self.tableView(in: restoredController)
        let restoredCustomColumn = try #require(restoredTableView.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier("custom.field.ip.src")
        ))

        #expect(restoredTableView.tableColumns.suffix(2).map { $0.identifier.rawValue } == ["custom.field.ip.src", "comment"])
        #expect(!restoredCustomColumn.isHidden)

        restoredController.resetPacketTableColumnsFromMenu(nil)

        let resetController = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        resetController.loadViewIfNeeded()
        let resetTableView = try Self.tableView(in: resetController)

        #expect(resetTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("custom.field.ip.src")) == nil)
        #expect(Set(resetTableView.tableColumns.map { $0.identifier.rawValue }) == Set(PacketTableColumnService.defaultDefinitions.map(\.identifier)))
    }

    @MainActor
    @Test func contextMenuItemsIncludeCopyRowsAsSubmenuAndTooltips() throws {
        let controller = PacketTableContextMenuController()
        let stateProvider = MenuStateProvider(state: PacketTableMenuState(
            targetRows: [0],
            clickedColumn: .source,
            clickedColumnIdentifier: "source",
            copyRowEnabled: true,
            copyCellEnabled: true,
            pinEnabled: true,
            saveEnabled: true,
            styleEnabled: true,
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
        let highlightItem = try #require(menu.items.first { $0.title == "Highlight" })
        let commentItem = try #require(menu.items.first { $0.title == "Add Comment…" })
        let highlightSubmenu = try #require(highlightItem.submenu)
        let copyRowsAsTitles = copyRowsAsSubmenu.items.compactMap { item in
            item.isSeparatorItem ? nil : item.title
        }

        #expect(copyRowsAsTitles == ["Plain text", "JSON", "Markdown Table", "CSV", "CSV with Header"])
        #expect(copyRowsAsSubmenu.items.filter(\.isSeparatorItem).count == 2)
        #expect(highlightSubmenu.items.compactMap { $0.isSeparatorItem ? nil : $0.title } == [
            "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Indigo", "Purple", "Pink",
            "Brown", "Gray", "Strikethrough", "Reset",
        ])
        #expect(Array(highlightSubmenu.items.prefix(9)).map(\.keyEquivalent) == (1...9).map(String.init))
        #expect(highlightSubmenu.items.first { $0.title == "Brown" }?.keyEquivalent == "")
        #expect(highlightSubmenu.items.first { $0.title == "Gray" }?.keyEquivalent == "")
        #expect(highlightSubmenu.items.first { $0.title == "Strikethrough" }?.keyEquivalent == "/")
        #expect(highlightSubmenu.items.first { $0.title == "Reset" }?.keyEquivalent == "0")
        #expect(menu.items.contains { $0.title == "Pin" && $0.submenu == nil })
        #expect(commentItem.isEnabled)
        #expect(commentItem.keyEquivalent == PacketCommentShortcut.keyEquivalent)
        #expect(commentItem.keyEquivalentModifierMask == PacketCommentShortcut.modifierMask)
        let highlightIndex = try #require(menu.items.firstIndex(where: { $0.title == "Highlight" }))
        #expect(highlightIndex > 0 && menu.items[highlightIndex - 1].title == "Add Comment…")
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { item in item.toolTip?.isEmpty == false })
    }

    @Test func commentShortcutMatchesOnlyOptionCommandM() throws {
        let matchingEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "m",
            charactersIgnoringModifiers: "m",
            isARepeat: false,
            keyCode: 46
        ))
        let conflictingEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "M",
            charactersIgnoringModifiers: "m",
            isARepeat: false,
            keyCode: 46
        ))

        #expect(PacketCommentShortcut.matches(matchingEvent))
        #expect(!PacketCommentShortcut.matches(conflictingEvent))
    }

    @MainActor
    @Test func highlightedRowPaletteResolvesOpaqueColorsAcrossAppearances() throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))

        for appearance in [lightAppearance, darkAppearance] {
            let color = PacketHighlightPalette.backgroundColor(
                for: .green,
                appearance: appearance
            )
            #expect(color.alphaComponent == 1)
        }
    }

    @MainActor
    @Test func packetTableUsesOneBackgroundAcrossCellsAndFullRow() throws {
        let defaults = Self.makeUserDefaults()
        let controller = PacketTableViewController(configuration: AppConfiguration(defaults: defaults))
        controller.loadViewIfNeeded()
        let tableView = try Self.tableView(in: controller)
        let packet = makePacket(packetNumber: 1).applying(
            textStyle: PacketTextStyle(highlightColor: .red)
        )
        controller.render(snapshot: makeSnapshot(packets: [packet]))
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        for column in tableView.tableColumns {
            guard let cell = column.dataCell as? NSTextFieldCell else {
                continue
            }
            controller.tableView(tableView, willDisplayCell: cell, for: column, row: 0)
            #expect(!cell.drawsBackground)
        }

        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        let columnsMaxX = tableView.tableColumns.indices
            .map { tableView.rect(ofColumn: $0).maxX }
            .max() ?? 0
        tableView.setFrameSize(NSSize(width: columnsMaxX + 40, height: tableView.rowHeight))

        tableView.deselectAll(nil)
        let rowEdgeColors = try Self.renderedRowEdgeColors(in: tableView, row: 0)
        for edgeColor in rowEdgeColors {
            #expect(edgeColor.redComponent > edgeColor.greenComponent)
            #expect(edgeColor.redComponent > edgeColor.blueComponent)
        }

        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let selectedEdgeColors = try Self.renderedRowEdgeColors(in: tableView, row: 0)
        let selectedColor = try #require(NSColor.selectedContentBackgroundColor.usingColorSpace(.deviceRGB))
        for edgeColor in selectedEdgeColors {
            #expect(abs(edgeColor.redComponent - selectedColor.redComponent) < 0.01)
            #expect(abs(edgeColor.greenComponent - selectedColor.greenComponent) < 0.01)
            #expect(abs(edgeColor.blueComponent - selectedColor.blueComponent) < 0.01)
        }
    }

    private func makeSnapshot(packets: [PacketSummary]) -> NetworkInspectorSnapshot {
        var base = TCPViewerWindowSnapshot.foundation
        base.packetIngestState.replace(with: packets, source: .live)
        let rows = packets.map(PacketTableRow.init(packet:))
        let visibleIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        let content = PacketTableContent(
            displayFilter: PacketDisplayFilter(""),
            displayFilterChips: [],
            store: PacketTableRowStore(rows: rows, visiblePacketRowIndexByID: visibleIndex),
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
            inspectorTab: .summary,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: content
        )
    }

    private func makePacket(
        packetNumber: UInt64,
        infoSummary: String? = nil,
        sniDomainName: String? = nil,
        client: PacketClient? = nil,
        customComment: String? = nil
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
            client: client,
            customComment: customComment
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
    private static func renderedRowEdgeColors(in tableView: NSTableView, row: Int) throws -> [NSColor] {
        let rowRect = tableView.rect(ofRow: row)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(tableView.bounds.width)),
            pixelsHigh: Int(ceil(rowRect.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        tableView.drawBackground(inClipRect: rowRect)
        NSGraphicsContext.restoreGraphicsState()

        let trailingX = max(1, bitmap.pixelsWide - 2)
        return try [1, trailingX].map { x in
            try #require(bitmap.colorAt(x: x, y: 1)?.usingColorSpace(.deviceRGB))
        }
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
    func pinRowsFromMenu(_ sender: Any?) {}
    func saveRowsFromMenu(_ sender: Any?) {}
    func addPacketCommentFromMenu(_ sender: Any?) {}
    func setPacketHighlightColorFromMenu(_ sender: Any?) {}
    func togglePacketStrikethroughFromMenu(_ sender: Any?) {}
    func resetPacketTextStyleFromMenu(_ sender: Any?) {}
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
