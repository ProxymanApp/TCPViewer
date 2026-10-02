//
//  DiffPoolViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit
import PcapPlusPlusCore

// Proxyman's checkbox cell keeps the same inset within the Left/Right columns.
final class DiffCheckboxCell: NSButtonCell {
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        var frame = frame
        frame.origin.x += 10
        super.drawImage(image, withFrame: frame, in: controlView)
    }
}

enum DiffTableLayout {
    // Definitions come from the main table, while Diff owns its column order and sizing.
    static func resolve(main: PacketTableColumnLayout?, saved: PacketTableColumnLayout?) -> PacketTableColumnLayout {
        let custom = main?.customColumns ?? []
        let service = PacketTableColumnService()
        service.setCustomColumns(custom)
        let definitions = service.definitions
        let allowed = Set(definitions.map(\.identifier))
        var columns = (saved ?? main)?.columns.filter { allowed.contains($0.identifier) } ?? []
        let existing = Set(columns.map(\.identifier))
        columns.append(contentsOf: definitions.filter { !existing.contains($0.identifier) }.map {
            PacketTableColumnLayout.Column(identifier: $0.identifier, isVisible: $0.isDefaultVisible, width: $0.defaultWidth)
        })
        return PacketTableColumnLayout(columns: columns, customColumns: custom)
    }
}

final class DiffPoolViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSUserInterfaceValidations, PacketTableKeyboardActionHandling, PacketTableColumnVisibilityMenuActionHandling {
    @IBOutlet weak var tableView: PacketTableView!
    @IBOutlet var mainMenu: NSMenu!
    @IBOutlet weak var backgroundView: NSBox!

    private var model: DiffPoolModel!
    private var configuration: AppConfiguration!
    private var entries: [DiffPacketEntry] = []
    private var contextIDs: Set<DiffPacketID>?
    private var layoutStore: PacketTableColumnLayoutStore!
    private var columns = PacketTableColumnService()
    private var visibilityMenu: PacketTableColumnVisibilityMenuController!
    private var customColumns: [PacketCustomColumn] = []
    private var restoringLayout = false
    private var commentSheet: PacketCommentSheetViewController?
    private var sort: NSSortDescriptor?
    private static let colors: [PacketHighlightColor] = [.red, .yellow, .green, .blue, .purple, .gray]

    var selectedEntry: DiffPacketEntry? {
        let selected = selectedEntries
        return selected.count == 1 ? selected[0] : nil
    }
    private var selectedEntries: [DiffPacketEntry] {
        tableView.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }
    private var targetEntries: [DiffPacketEntry] {
        guard let contextIDs else { return selectedEntries }
        return entries.filter { contextIDs.contains($0.id) }
    }

    // Connect the copied Cocoa layout to the shared packet-table presentation and snapshot pool.
    func configure(model: DiffPoolModel, configuration: AppConfiguration, layout: PacketTableColumnLayout?) {
        self.model = model
        self.configuration = configuration
        _ = view
        backgroundView.fillColor = .controlBackgroundColor
        layoutStore = PacketTableColumnLayoutStore(defaults: configuration.userDefaults, key: "TCPViewer.diff.columnLayout.v1")
        tableView.delegate = self
        tableView.dataSource = self
        tableView.keyboardActionHandler = self
        tableView.keyboardHighlightColors = Self.colors
        tableView.highlightColorProvider = { [weak self] index in
            guard let self, self.entries.indices.contains(index) else { return nil }
            return self.entries[index].row.textStyle.highlightColor
        }
        PacketTablePresentation.configure(tableView, configuration: configuration)
        mainMenu.delegate = self
        tableView.menu = mainMenu
        for item in mainMenu.items {
            item.target = self
            item.submenu?.items.forEach { $0.target = self }
        }
        applyLayout(DiffTableLayout.resolve(main: layout, saved: layoutStore.load()))
        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged), name: AppConfiguration.didChangeNotification, object: configuration)
        NotificationCenter.default.addObserver(self, selector: #selector(mainColumnsChanged), name: PacketTableColumnLayoutStore.didChangeNotification, object: configuration.userDefaults)
    }

    // Keep selected pool IDs stable when decode callbacks append content or rows are removed.
    func render() {
        let selected = Set(selectedEntries.map(\.id))
        entries = model.entries
        if let sort, let key = sort.key {
            entries.sort {
                let result = value(key, entry: $0).localizedStandardCompare(value(key, entry: $1))
                return sort.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(entries[$0].id) }), byExtendingSelection: false)
    }

    // Restore Diff-only geometry while keeping Left/Right anchored before the shared packet columns.
    private func applyLayout(_ layout: PacketTableColumnLayout) {
        restoringLayout = true
        defer { restoringLayout = false }
        customColumns = layout.customColumns
        columns.setCustomColumns(customColumns)
        columns.applyVisibility(from: layout)
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        for side in ["diffLeft", "diffRight"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(side))
            column.title = side == "diffLeft" ? "Left" : "Right"
            column.width = 40
            column.minWidth = 40
            column.maxWidth = 100
            let cell = DiffCheckboxCell(textCell: "")
            cell.setButtonType(.switch)
            cell.font = configuration.packetFont()
            column.dataCell = cell
            tableView.addTableColumn(column)
        }
        for saved in layout.columns {
            guard let definition = columns.definition(identifier: saved.identifier) else { continue }
            let column = PacketTablePresentation.column(definition)
            column.width = max(column.minWidth, CGFloat(saved.width))
            column.isHidden = !saved.isVisible
            column.sortDescriptorPrototype = NSSortDescriptor(key: saved.identifier, ascending: true)
            tableView.addTableColumn(column)
        }
        visibilityMenu = PacketTableColumnVisibilityMenuController(columnService: columns)
        visibilityMenu.actionHandler = self
        tableView.headerView?.menu = visibilityMenu.makeMenu()
    }

    private func currentLayout() -> PacketTableColumnLayout {
        PacketTableColumnLayout(columns: tableView.tableColumns.filter { !$0.identifier.rawValue.hasPrefix("diff") }.map {
            PacketTableColumnLayout.Column(identifier: $0.identifier.rawValue, isVisible: !$0.isHidden, width: Double($0.width))
        }, customColumns: customColumns)
    }

    private func saveLayout() {
        guard !restoringLayout else { return }
        layoutStore.save(currentLayout())
    }

    @objc private func configurationChanged() {
        tableView.rowHeight = configuration.packetRowHeight
        render()
    }

    @objc private func mainColumnsChanged(_ notification: Notification) {
        guard notification.userInfo?["key"] as? String == PacketTableColumnLayoutStore.defaultKey else { return }
        let main = PacketTableColumnLayoutStore(defaults: configuration.userDefaults).load()
        guard main?.customColumns != customColumns else { return }
        applyLayout(DiffTableLayout.resolve(main: main, saved: currentLayout()))
        saveLayout()
        render()
    }

    func toggleSide(_ side: DiffSide) {
        guard let entry = selectedEntry else { return }
        model.assign(entry.side == side ? nil : side, to: entry.id)
    }

    private func toggleTargetSide(_ side: DiffSide) {
        guard targetEntries.count == 1, let entry = targetEntries.first else { return }
        model.assign(entry.side == side ? nil : side, to: entry.id)
    }

    @IBAction func diffingPoolLeftSideBtnOnClick(_ sender: Any?) { toggleTargetSide(.left) }
    @IBAction func diffingPoolRightSideBtnOnClick(_ sender: Any?) { toggleTargetSide(.right) }
    @IBAction func diffingPoolDeleteBtnOnClick(_ sender: Any?) { model.remove(Set(targetEntries.map(\.id))) }
    @IBAction func diffingPoolDeleteAllBtnOnClick(_ sender: Any?) { model.removeAll() }

    @IBAction func diffingPoolAddCommentBtnOnClick(_ sender: Any?) {
        let targets = targetEntries
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        commentSheet = PacketCommentSheetViewController(initialComment: targets.first?.row.comment, packetCount: targets.count) { [weak self] comment in
            self?.model.setComment(comment, on: ids)
            self?.commentSheet = nil
        }
        commentSheet?.show(attachedTo: view.window)
    }

    @IBAction func diffingPoolHighlighBtnOnClick(_ sender: NSMenuItem) {
        let mutation: PacketTextStyleMutation
        if let color = Self.colors.first(where: { $0.menuTitle == sender.title }) {
            mutation = .setHighlightColor(color)
        } else { mutation = sender.title == "Reset" ? .reset : .toggleStrikethrough }
        model.apply(mutation, to: Set(targetEntries.map(\.id)))
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let targets = targetEntries
        if item.action == #selector(diffingPoolLeftSideBtnOnClick(_:)) || item.action == #selector(diffingPoolRightSideBtnOnClick(_:)) {
            let side: DiffSide = item.action == #selector(diffingPoolLeftSideBtnOnClick(_:)) ? .left : .right
            (item as? NSMenuItem)?.state = targets.count == 1 && targets[0].side == side ? .on : .off
            return targets.count == 1
        }
        if item.action == #selector(diffingPoolDeleteAllBtnOnClick(_:)) { return !entries.isEmpty }
        return !targets.isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === mainMenu else { return }
        contextIDs = nil
        guard let event = NSApp.currentEvent else { return }
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        if entries.indices.contains(row), !tableView.selectedRowIndexes.contains(row) {
            contextIDs = [entries[row].id]
        }
    }
    // Cocoa can end menu tracking before dispatching its action; retain the click target for that turn.
    func menuDidClose(_ menu: NSMenu) {
        if menu === mainMenu { DispatchQueue.main.async { [weak self] in self?.contextIDs = nil } }
    }

    private func value(_ column: String, entry: DiffPacketEntry) -> String {
        if let custom = customColumns.first(where: { $0.identifier == column }) { return entry.customValue(custom) }
        return entry.row.text(for: PacketTableColumnRole(columnIdentifier: column))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard entries.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
        if key == "diffLeft" { return entries[row].side == .left }
        if key == "diffRight" { return entries[row].side == .right }
        return value(key, entry: entries[row])
    }
    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard entries.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return }
        PacketTablePresentation.configure(cell, column: key, row: entries[row].row, configuration: configuration)
    }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard entries.indices.contains(row), let key = tableColumn?.identifier.rawValue, let enabled = object as? NSNumber,
              key == "diffLeft" || key == "diffRight" else { return }
        model.assign(enabled.boolValue ? (key == "diffLeft" ? .left : .right) : nil, to: entries[row].id)
    }
    func tableView(_ tableView: NSTableView, shouldTrackCell cell: NSCell, for tableColumn: NSTableColumn?, row: Int) -> Bool {
        tableColumn?.identifier.rawValue == "diffLeft" || tableColumn?.identifier.rawValue == "diffRight"
    }
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex >= 2 && newColumnIndex >= 2
    }
    func tableViewColumnDidMove(_ notification: Notification) { saveLayout() }
    func tableViewColumnDidResize(_ notification: Notification) { saveLayout() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if oldDescriptors.first?.ascending == false { tableView.sortDescriptors = []; sort = nil }
        else { sort = tableView.sortDescriptors.first }
        render()
    }

    func togglePacketTableColumnVisibilityFromMenu(_ sender: Any?) {
        guard let key = (sender as? NSMenuItem)?.representedObject as? String,
              columns.toggleColumnVisibility(identifier: key) else { return }
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.isHidden = !columns.isColumnVisible(identifier: key)
        saveLayout()
    }
    func resetPacketTableColumnsFromMenu(_ sender: Any?) {
        let main = PacketTableColumnLayoutStore(defaults: configuration.userDefaults).load()
        applyLayout(DiffTableLayout.resolve(main: main, saved: nil))
        saveLayout()
    }

    func packetTableViewDidRequestCopyRowsFromKeyboard(_ tableView: PacketTableView) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PacketTableCopyFormatter.plainTextRows(selectedEntries.map(\.row)), forType: .string)
    }
    func packetTableViewDidRequestDeleteFromKeyboard(_ tableView: PacketTableView) { model.remove(Set(selectedEntries.map(\.id))) }
    func packetTableViewDidRequestAddCommentFromKeyboard(_ tableView: PacketTableView) { diffingPoolAddCommentBtnOnClick(nil) }
    func packetTableView(_ tableView: PacketTableView, didRequestTextStyle mutation: PacketTextStyleMutation) { model.apply(mutation, to: Set(selectedEntries.map(\.id))) }

    deinit { NotificationCenter.default.removeObserver(self) }
}
