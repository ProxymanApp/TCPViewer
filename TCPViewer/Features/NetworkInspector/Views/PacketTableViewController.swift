//
//  PacketTableViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import PcapPlusPlusCore
import QuartzCore

protocol PacketTableViewControllerDelegate: AnyObject {
    func packetTableViewController(_ controller: PacketTableViewController, didSelectPacket identifier: PacketSummary.ID?)
    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestPinPackets identifiers: [PacketSummary.ID]
    )
    func packetTableViewController(_ controller: PacketTableViewController, didRequestSavePackets identifiers: [PacketSummary.ID])
    func packetTableViewController(_ controller: PacketTableViewController, didRequestFollowTCPStream packetID: PacketSummary.ID)
    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestSetComment comment: String,
        onPackets identifiers: [PacketSummary.ID]
    )
    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestApplyTextStyle mutation: PacketTextStyleMutation,
        toPackets identifiers: [PacketSummary.ID]
    )
    func packetTableViewController(_ controller: PacketTableViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat)
    func packetTableViewController(_ controller: PacketTableViewController, didRequestDeletePackets identifiers: [PacketSummary.ID])
    func packetTableViewController(
        _ controller: PacketTableViewController,
        inspectPacket identifier: PacketSummary.ID,
        completion: @escaping TCPViewerCompletion<PacketInspection>
    )
}

enum PacketTableSelectionSyncAction: Equatable {
    case none
    case select(Int)
    case deselect
}

enum PacketTableSelectionSyncPlanner {
    static func action(
        visualSelectedID: PacketSummary.ID?,
        selectedPacketID: PacketSummary.ID?,
        selectedRowIndex: Int?,
        rowCount: Int
    ) -> PacketTableSelectionSyncAction {
        guard let selectedPacketID,
              let selectedRowIndex,
              (0..<rowCount).contains(selectedRowIndex) else {
            return visualSelectedID == nil ? .none : .deselect
        }

        if visualSelectedID == selectedPacketID {
            return .none
        }

        return .select(selectedRowIndex)
    }
}

fileprivate protocol PacketTableKeyboardActionHandling: AnyObject {
    func packetTableViewDidRequestCopyRowsFromKeyboard(_ tableView: PacketTableView)
    func packetTableViewDidRequestDeleteFromKeyboard(_ tableView: PacketTableView)
    func packetTableViewDidRequestAddCommentFromKeyboard(_ tableView: PacketTableView)
    func packetTableView(_ tableView: PacketTableView, didRequestTextStyle mutation: PacketTextStyleMutation)
}

fileprivate final class PacketTableView: NSTableView {
    weak var keyboardActionHandler: PacketTableKeyboardActionHandling?
    var highlightColorProvider: ((Int) -> PacketHighlightColor?)?

    @objc func copy(_ sender: Any?) {
        keyboardActionHandler?.packetTableViewDidRequestCopyRowsFromKeyboard(self)
    }

    @objc func delete(_ sender: Any?) {
        keyboardActionHandler?.packetTableViewDidRequestDeleteFromKeyboard(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if PacketCommentShortcut.matches(event) {
            keyboardActionHandler?.packetTableViewDidRequestAddCommentFromKeyboard(self)
            return
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return
        }

        if flags.contains(.command), let character = event.charactersIgnoringModifiers {
            if character == "0" {
                keyboardActionHandler?.packetTableView(self, didRequestTextStyle: .reset)
                return
            }
            if character == "/" {
                keyboardActionHandler?.packetTableView(self, didRequestTextStyle: .toggleStrikethrough)
                return
            }
            if let index = Int(character), (1...9).contains(index) {
                keyboardActionHandler?.packetTableView(
                    self,
                    didRequestTextStyle: .setHighlightColor(PacketHighlightColor.allCases[index - 1])
                )
                return
            }
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            delete(nil)
            return
        }

        super.keyDown(with: event)
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        // Paint marked rows across the table bounds, including space outside column cells.
        super.drawBackground(inClipRect: clipRect)
        let visibleRows = rows(in: clipRect)
        guard visibleRows.location != NSNotFound else {
            return
        }

        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            if selectedRowIndexes.contains(row) {
                drawSelectionBackground(forRow: row, in: clipRect)
            } else {
                drawHighlight(forRow: row, in: clipRect)
            }
        }
    }

    override func highlightSelection(inClipRect clipRect: NSRect) {
        // Restore selected packet colors after AppKit paints its standard selection.
        super.highlightSelection(inClipRect: clipRect)
        let visibleRows = rows(in: clipRect)
        guard visibleRows.location != NSNotFound else {
            return
        }
        let visibleIndexes = IndexSet(
            integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)
        )
        for row in selectedRowIndexes.intersection(visibleIndexes) {
            drawSelectionBackground(forRow: row, in: clipRect)
        }
    }

    private func drawHighlight(forRow row: Int, in clipRect: NSRect) {
        // Use the full row rect because cell frames have leading and trailing gaps.
        guard let highlightColor = highlightColorProvider?(row) else {
            return
        }

        let rowRect = rect(ofRow: row)
        let fillRect = rowRect.intersection(clipRect)
        guard !fillRect.isEmpty else {
            return
        }

        PacketHighlightPalette.backgroundColor(
            for: highlightColor,
            appearance: effectiveAppearance
        ).setFill()
        fillRect.fill()
    }

    private func drawSelectionBackground(forRow row: Int, in clipRect: NSRect) {
        // Match AppKit's active or inactive selection across the complete row.
        let fillRect = rect(ofRow: row).intersection(clipRect)
        guard !fillRect.isEmpty else {
            return
        }

        let isEmphasized = window == nil || (window?.isKeyWindow == true && window?.firstResponder === self)
        let selectionColor: NSColor = isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
        selectionColor.setFill()
        fillRect.fill()
    }
}

final class PacketTableViewModel {
    // Holds the class reference, NOT a copy of the rows array. Copying the array would re-share
    // its buffer with the cache and re-introduce the per-batch CoW we're trying to avoid.
    private(set) var rowStore: PacketTableRowStore = .empty
    private(set) var contentGeneration: UInt64 = 0
    private(set) var selectedPacketID: PacketSummary.ID?
    private(set) var selectedRowIndex: Int?

    var rows: [PacketTableRow] {
        rowStore.rows
    }

    var rowCount: Int {
        rowStore.rows.count
    }

    func rowID(at index: Int) -> PacketSummary.ID? {
        guard rowStore.rows.indices.contains(index),
              rowStore.rowIDs.indices.contains(index) else {
            return nil
        }

        return rowStore.rowIDs[index]
    }

    func rowIndex(for identifier: PacketSummary.ID) -> Int? {
        rowStore.visiblePacketRowIndexByID[identifier]
    }

    // Store the latest render state so the controller can apply incremental table updates.
    func render(snapshot: NetworkInspectorSnapshot) -> PacketTableUpdatePlan {
        let previousRowStore = rowStore
        let updatePlan = PacketTableUpdatePlanner.plan(
            previousGeneration: contentGeneration,
            currentGeneration: snapshot.packetTableGeneration,
            proposedPlan: snapshot.packetTableUpdatePlan
        )
        rowStore = snapshot.packetTableRowStore
        contentGeneration = snapshot.packetTableGeneration
        selectedPacketID = snapshot.selectedPacketID
        selectedRowIndex = snapshot.selectedPacketRowIndex

        // Release old UI-facing row buffers on main with the table render that replaced them.
        _ = previousRowStore
        return updatePlan
    }
}

final class PacketTableViewController: NSViewController {
    static let columnAutosaveName: NSTableView.AutosaveName = "TCPViewer.PacketTable.Columns"

    private struct CustomColumnWorkItem {
        let generation: Int
        let column: PacketCustomColumn
        let packetID: PacketSummary.ID
    }

    weak var delegate: PacketTableViewControllerDelegate?

    private let configuration: AppConfiguration
    private let tableView = PacketTableView()
    private let scrollView = NSScrollView()
    private let viewModel = PacketTableViewModel()
    private let contextMenuController = PacketTableContextMenuController()
    private let customColumnService = PacketCustomColumnService()
    private let columnService: PacketTableColumnService
    private let columnLayoutStore: PacketTableColumnLayoutStore
    private let columnVisibilityMenuController: PacketTableColumnVisibilityMenuController
    private var isRestoringColumnLayout = false
    private var selectionCallbackSuppressionDepth = 0
    private var lastAppliedSelectedPacketID: PacketSummary.ID?
    private var pendingUserSelection: PendingUserSelection?
    private var clickedRowIndex: Int?
    private var clickedColumnIdentifier: String?
    private var commentSheetController: PacketCommentSheetViewController?
    private var customColumnWorkQueue: [CustomColumnWorkItem] = []
    private var customColumnWorkQueueHeadIndex = 0
    private var queuedCustomColumnWorkKeys = Set<String>()
    private var activeCustomColumnInspectionCount = 0
    private var customColumnResolutionGeneration = 0
    private var pendingCustomColumnReloadIndexes = IndexSet()
    private var pendingCustomColumnReloadWorkItem: DispatchWorkItem?
    private var renderedPacketLineageRevision: UInt64?

    private let maximumConcurrentCustomColumnInspections = 8

    // Wraps Optional<ID> so we can distinguish "no pending intent" from a
    // pending user-driven deselect. A pending intent means the user has just
    // changed the selection visually and we are waiting for the snapshot
    // round-trip to acknowledge it.
    private struct PendingUserSelection {
        let id: PacketSummary.ID?
    }

    private var rows: [PacketTableRow] {
        viewModel.rows
    }

    private var isSuppressingSelectionCallbacks: Bool {
        selectionCallbackSuppressionDepth > 0
    }

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        let columnService = PacketTableColumnService()
        self.columnService = columnService
        self.columnLayoutStore = PacketTableColumnLayoutStore(defaults: configuration.userDefaults)
        self.columnVisibilityMenuController = PacketTableColumnVisibilityMenuController(columnService: columnService)
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appConfigurationDidChange(_:)),
            name: AppConfiguration.didChangeNotification,
            object: configuration
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        setupTable()
        view = scrollView
    }

    // Apply packet rows, using append plans when the model says only new visible rows arrived.
    func render(snapshot: NetworkInspectorSnapshot) {
        if renderedPacketLineageRevision != snapshot.base.packetIngestState.packetLineageRevision {
            customColumnService.clearValues()
            resetCustomColumnResolutionQueue()
            renderedPacketLineageRevision = snapshot.base.packetIngestState.packetLineageRevision
        }

        let previousRowCount = rows.count
        let updatePlan = viewModel.render(snapshot: snapshot)
        applyAppearanceConfiguration(reload: false)

        suppressSelectionCallbacks {
            switch updatePlan {
            case .none:
                break
            case .append(let range):
                applyAppendPlan(range: range, previousRowCount: previousRowCount)
            case .reload:
                preserveScrollPosition {
                    tableView.reloadData()
                }
            case .reloadRows(let indexes):
                reloadRowsIfPossible(indexes)
            case .appendAndReloadRows(let range, let reloadIndexes):
                applyAppendPlan(range: range, previousRowCount: previousRowCount)
                reloadRowsIfPossible(reloadIndexes)
            }

            syncSelection()
        }

        enqueueCustomColumnResolution(after: updatePlan, previousRowCount: previousRowCount)
    }

    // Scroll the current sorted and filtered table row into view.
    @discardableResult
    func scrollPacketToVisible(_ identifier: PacketSummary.ID) -> Bool {
        guard let rowIndex = viewModel.rowIndex(for: identifier),
              (0..<tableView.numberOfRows).contains(rowIndex) else {
            return false
        }

        tableView.scrollRowToVisible(rowIndex)
        return true
    }

    private func applyAppendPlan(range: Range<Int>, previousRowCount: Int) {
        if range.lowerBound == previousRowCount, range.upperBound <= rows.count {
            tableView.noteNumberOfRowsChanged()
        } else {
            preserveScrollPosition {
                tableView.reloadData()
            }
        }
    }

    private func reloadRowsIfPossible(_ indexes: IndexSet) {
        guard !indexes.isEmpty else {
            return
        }
        let validRange = 0..<tableView.numberOfRows
        let safeIndexes = IndexSet(indexes.filter { validRange.contains($0) })
        guard !safeIndexes.isEmpty else {
            return
        }
        let columnIndexes = IndexSet(0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: safeIndexes, columnIndexes: columnIndexes)
        // Cell reloads omit the outer row margins, so invalidate only the changed full rows.
        for row in safeIndexes {
            tableView.setNeedsDisplay(tableView.rect(ofRow: row))
        }
    }

    @objc private func appConfigurationDidChange(_ notification: Notification) {
        applyAppearanceConfiguration(reload: true)
    }

    private func setupTable() {
        // Configure the packet table and persist user-controlled column layout.
        tableView.delegate = self
        tableView.dataSource = self
        tableView.keyboardActionHandler = self
        tableView.highlightColorProvider = { [weak self] row in
            guard let self, self.rows.indices.contains(row) else {
                return nil
            }
            return self.rows[row].textStyle.highlightColor
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = configuration.packetRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.focusRingType = .none
        contextMenuController.actionHandler = self
        contextMenuController.stateProvider = self
        tableView.menu = contextMenuController.makeMenu()
        columnVisibilityMenuController.actionHandler = self
        tableView.headerView?.menu = columnVisibilityMenuController.makeMenu()

        let restoredLayout = columnLayoutStore.load()
        customColumnService.restoreColumns(restoredLayout?.customColumns ?? [])
        columnService.setCustomColumns(customColumnService.columns)
        if let restoredLayout {
            columnService.applyVisibility(from: restoredLayout)
        }
        columnService.definitions.forEach(addColumn(_:))
        tableView.autosaveName = Self.columnAutosaveName
        tableView.autosaveTableColumns = false
        restoreColumnLayout(restoredLayout)
        moveCommentColumnToEnd()
        syncColumnVisibilityFromTable()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
    }

    private func applyAppearanceConfiguration(reload: Bool) {
        tableView.rowHeight = configuration.packetRowHeight
        if reload, isViewLoaded {
            tableView.reloadData()
        }
    }

    private func addColumn(_ definition: PacketTableColumnDefinition) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.identifier))
        column.title = definition.tableTitle
        column.width = CGFloat(definition.defaultWidth)
        column.minWidth = CGFloat(definition.minimumWidth)
        column.resizingMask = definition.role == .comment
            ? [.userResizingMask, .autoresizingMask]
            : .userResizingMask
        column.dataCell = cell(for: definition.cellKind)
        column.isHidden = !columnService.isColumnVisible(identifier: definition.identifier)
        tableView.addTableColumn(column)
    }

    private func addCustomColumnIfNeeded(_ column: PacketCustomColumn) {
        guard tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.identifier)) == nil,
              let definition = columnService.definition(identifier: column.identifier) else {
            return
        }

        addColumn(definition)
        moveCommentColumnToEnd()
    }

    // Keep Comment as the flexible trailing column after built-in and custom columns.
    private func moveCommentColumnToEnd() {
        guard let commentIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == PacketTableColumnRole.comment.rawValue
        }), commentIndex != tableView.tableColumns.count - 1 else {
            return
        }
        tableView.moveColumn(commentIndex, toColumn: tableView.tableColumns.count - 1)
    }

    private func cell(for kind: PacketTableColumnCellKind) -> NSCell {
        switch kind {
        case .text:
            PacketTextCell()
        case .client:
            PacketClientCell()
        case .protocol:
            PacketProtocolCell()
        }
    }

    private func applyColumnVisibility(identifier: String) {
        guard let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)) else {
            return
        }

        column.isHidden = !columnService.isColumnVisible(identifier: identifier)
    }

    private func syncColumnVisibilityFromTable() {
        tableView.tableColumns.forEach { column in
            columnService.syncColumnVisibility(
                identifier: column.identifier.rawValue,
                isVisible: !column.isHidden
            )
        }
    }

    private func restoreColumnLayout(_ layout: PacketTableColumnLayout?) {
        guard let layout else {
            return
        }

        isRestoringColumnLayout = true
        defer { isRestoringColumnLayout = false }

        layout.columns.enumerated().forEach { targetIndex, savedColumn in
            guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == savedColumn.identifier
            }) else {
                return
            }

            if currentIndex != targetIndex, targetIndex < tableView.tableColumns.count {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
        }

        layout.columns.forEach { savedColumn in
            guard let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(savedColumn.identifier)) else {
                return
            }

            column.width = max(column.minWidth, CGFloat(savedColumn.width))
            column.isHidden = !columnService.isColumnVisible(identifier: savedColumn.identifier)
        }
    }

    private func restoreDefaultColumnLayout() {
        isRestoringColumnLayout = true
        defer { isRestoringColumnLayout = false }

        removeCustomTableColumns()
        columnService.setCustomColumns(customColumnService.columns)
        columnService.definitions.enumerated().forEach { targetIndex, definition in
            guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == definition.identifier
            }) else {
                return
            }

            if currentIndex != targetIndex {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }

            if let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.identifier)) {
                column.width = CGFloat(definition.defaultWidth)
                column.isHidden = !columnService.isColumnVisible(identifier: definition.identifier)
            }
        }
    }

    private func removeCustomTableColumns() {
        let customColumnIDs = Set(customColumnService.columns.map(\.identifier))
        for column in tableView.tableColumns where customColumnIDs.contains(column.identifier.rawValue) || column.identifier.rawValue.hasPrefix("custom.field.") {
            tableView.removeTableColumn(column)
        }
    }

    private func currentColumnLayout() -> PacketTableColumnLayout {
        PacketTableColumnLayout(columns: tableView.tableColumns.map { column in
            PacketTableColumnLayout.Column(
                identifier: column.identifier.rawValue,
                isVisible: !column.isHidden,
                width: Double(column.width)
            )
        }, customColumns: customColumnService.columns)
    }

    private func saveColumnLayout() {
        guard !isRestoringColumnLayout else {
            return
        }

        syncColumnVisibilityFromTable()
        columnLayoutStore.save(currentColumnLayout())
    }

    func createCustomColumn(from request: PacketCustomColumnRequest) {
        let result = customColumnService.createColumn(from: request)
        guard let customColumn = result.column else {
            return
        }

        columnService.setCustomColumns(customColumnService.columns)
        addCustomColumnIfNeeded(customColumn)
        _ = columnService.setColumnVisibility(identifier: customColumn.identifier, isVisible: true)
        applyColumnVisibility(identifier: customColumn.identifier)
        saveColumnLayout()
        reloadColumn(identifier: customColumn.identifier)
        enqueueCustomColumnResolution(for: customColumn, visibleFirst: true)
        animateScrollToColumn(identifier: customColumn.identifier)
    }

    private func columnIdentifier(from sender: Any?) -> String? {
        if let item = sender as? NSMenuItem {
            return item.representedObject as? String
        }

        if let view = sender as? NSView {
            return view.identifier?.rawValue
        }

        return nil
    }

    private func preserveScrollPosition(_ updates: () -> Void) {
        let clipView = scrollView.contentView
        let visibleOrigin = clipView.bounds.origin
        updates()
        clipView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func animateScrollToColumn(identifier: String) {
        guard let columnIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }) else {
            return
        }

        tableView.layoutSubtreeIfNeeded()
        let columnRect = tableView.rect(ofColumn: columnIndex)
        let clipView = scrollView.contentView
        let documentWidth = max(tableView.bounds.width, columnRect.maxX)
        let targetX = min(
            max(0, columnRect.minX - 16),
            max(0, documentWidth - clipView.bounds.width)
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clipView.animator().setBoundsOrigin(NSPoint(x: targetX, y: clipView.bounds.origin.y))
        } completionHandler: { [weak self] in
            guard let self else {
                return
            }

            self.scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func suppressSelectionCallbacks(_ updates: () -> Void) {
        selectionCallbackSuppressionDepth += 1
        defer {
            selectionCallbackSuppressionDepth -= 1
        }

        updates()
    }

    private func syncSelection() {
        let visualRow = tableView.selectedRowIndexes.first ?? -1
        let visualID = viewModel.rowID(at: visualRow)

        // Detect a user click whose `tableViewSelectionDidChange` notification
        // hasn't been delivered yet. NSTableView updates the visual selection
        // synchronously on click, but if a packet-burst-driven render arrives
        // between the click and the notification, our subsequent programmatic
        // `selectRowIndexes` here would coalesce away the pending notification.
        // The user's intent would be silently dropped. Fire the delegate now
        // so the snapshot catches up to the visual instead.
        if visualID != viewModel.selectedPacketID,
           visualID != lastAppliedSelectedPacketID {
            pendingUserSelection = PendingUserSelection(id: visualID)
            lastAppliedSelectedPacketID = visualID
            delegate?.packetTableViewController(self, didSelectPacket: visualID)
            return
        }

        // Honor a pending user click until the snapshot reflects it. Without
        // this, a snapshot mutation that arrives between the click and the
        // controller-side update can yank the visual selection back to the
        // previous packet.
        if let pending = pendingUserSelection {
            if pending.id == viewModel.selectedPacketID {
                pendingUserSelection = nil
            } else {
                return
            }
        }

        let action = PacketTableSelectionSyncPlanner.action(
            visualSelectedID: visualID,
            selectedPacketID: viewModel.selectedPacketID,
            selectedRowIndex: viewModel.selectedRowIndex,
            rowCount: viewModel.rowCount
        )

        switch action {
        case .none:
            break
        case .deselect:
            tableView.deselectAll(nil)
        case .select(let rowIndex):
            tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        }

        lastAppliedSelectedPacketID = viewModel.selectedPacketID
    }

    private func text(for column: String, in row: PacketTableRow) -> String {
        if customColumnService.columns.contains(where: { $0.identifier == column }) {
            return customColumnService.value(columnIdentifier: column, packetID: row.id) ?? ""
        }

        return row.text(for: PacketTableColumnRole(columnIdentifier: column))
    }

    private func textStyle(for column: String, in row: PacketTableRow) -> PacketTextCell.Style {
        if column == "summary", row.severity != .normal {
            return .warning
        }

        if column == "number" ||
            column == "time" ||
            column == "sourcePort" ||
            column == "destinationPort" ||
            column == "streamID" ||
            column == "direction" ||
            column == "deltaTime" ||
            column == "streamDeltaTime" ||
            column == "tcpFlags" ||
            column == "tcpPayloadBytes" ||
            column == "pid" ||
            column == "bundleIdentifier" ||
            column == "decodeStatus" ||
            column == "interface" ||
            column == "length" ||
            column == "tags" {
            return .secondary
        }

        return .primary
    }

    private func updateClickedPositionFromCurrentEvent() {
        guard let event = NSApp.currentEvent else {
            clickedRowIndex = nil
            clickedColumnIdentifier = nil
            return
        }

        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        let column = tableView.column(at: point)
        clickedRowIndex = rows.indices.contains(row) ? row : nil
        clickedColumnIdentifier = tableView.tableColumns.indices.contains(column)
            ? tableView.tableColumns[column].identifier.rawValue
            : nil
    }

    private func enqueueCustomColumnResolution(after updatePlan: PacketTableUpdatePlan, previousRowCount: Int) {
        guard !customColumnService.columns.isEmpty else {
            return
        }

        switch updatePlan {
        case .none:
            return
        case .append(let range), .appendAndReloadRows(let range, _):
            let lowerBound = max(range.lowerBound, previousRowCount)
            let upperBound = min(range.upperBound, rows.count)
            guard lowerBound < upperBound else {
                return
            }
            let safeRange = lowerBound..<upperBound
            guard !safeRange.isEmpty else {
                return
            }
            let appendedPacketIDs = rows[safeRange].map(\.id)
            visibleCustomColumns().forEach { column in
                enqueueCustomColumnResolution(for: column, packetIDs: appendedPacketIDs)
            }
        case .reload:
            visibleCustomColumns().forEach { column in
                enqueueCustomColumnResolution(for: column, visibleFirst: true)
            }
        case .reloadRows:
            return
        }
    }

    private func enqueueCustomColumnResolution(for column: PacketCustomColumn, visibleFirst: Bool) {
        let preferredPacketIDs = visibleFirst ? visiblePacketIDs() : []
        enqueueCustomColumnResolution(for: column, preferredPacketIDs: preferredPacketIDs)
    }

    private func enqueueCustomColumnResolution(
        for column: PacketCustomColumn,
        packetIDs: [PacketSummary.ID]
    ) {
        let unresolvedPacketIDs = customColumnService.unresolvedPacketIDs(for: column, packetIDs: packetIDs)
        enqueueCustomColumnResolutionWork(for: column, packetIDs: unresolvedPacketIDs)
    }

    private func enqueueCustomColumnResolution(
        for column: PacketCustomColumn,
        preferredPacketIDs: [PacketSummary.ID]
    ) {
        let packetIDs = customColumnService.unresolvedPacketIDs(
            for: column,
            rows: rows,
            preferredPacketIDs: preferredPacketIDs
        )
        enqueueCustomColumnResolutionWork(for: column, packetIDs: packetIDs)
    }

    private func enqueueCustomColumnResolutionWork(
        for column: PacketCustomColumn,
        packetIDs: [PacketSummary.ID]
    ) {
        guard !packetIDs.isEmpty else {
            return
        }

        for packetID in packetIDs {
            let key = customColumnWorkKey(columnIdentifier: column.identifier, packetID: packetID)
            guard queuedCustomColumnWorkKeys.insert(key).inserted else {
                continue
            }

            customColumnWorkQueue.append(CustomColumnWorkItem(
                generation: customColumnResolutionGeneration,
                column: column,
                packetID: packetID
            ))
        }

        processCustomColumnWorkIfNeeded()
    }

    private func processCustomColumnWorkIfNeeded() {
        guard let delegate else {
            customColumnWorkQueue.removeAll()
            customColumnWorkQueueHeadIndex = 0
            queuedCustomColumnWorkKeys.removeAll()
            activeCustomColumnInspectionCount = 0
            return
        }

        while activeCustomColumnInspectionCount < maximumConcurrentCustomColumnInspections,
              customColumnWorkQueueHeadIndex < customColumnWorkQueue.count {
            let workItem = customColumnWorkQueue[customColumnWorkQueueHeadIndex]
            customColumnWorkQueueHeadIndex += 1
            activeCustomColumnInspectionCount += 1
            delegate.packetTableViewController(self, inspectPacket: workItem.packetID) { [weak self] result in
                DispatchQueue.main.async {
                    self?.completeCustomColumnWork(workItem, result: result)
                }
            }
        }

        compactCustomColumnWorkQueueIfNeeded()
    }

    private func completeCustomColumnWork(
        _ workItem: CustomColumnWorkItem,
        result: Result<PacketInspection, Error>
    ) {
        guard workItem.generation == customColumnResolutionGeneration else {
            return
        }

        activeCustomColumnInspectionCount = max(0, activeCustomColumnInspectionCount - 1)
        queuedCustomColumnWorkKeys.remove(customColumnWorkKey(
            columnIdentifier: workItem.column.identifier,
            packetID: workItem.packetID
        ))

        let value: String
        switch result {
        case .success(let inspection):
            value = PacketCustomColumnService.resolvedValue(fieldName: workItem.column.fieldName, in: inspection)
        case .failure:
            value = ""
        }

        customColumnService.storeValue(value, columnIdentifier: workItem.column.identifier, packetID: workItem.packetID)
        queueCustomColumnReload(packetID: workItem.packetID)
        processCustomColumnWorkIfNeeded()
    }

    // Compact consumed queue entries in batches so large captures avoid repeated removeFirst work.
    private func compactCustomColumnWorkQueueIfNeeded() {
        guard customColumnWorkQueueHeadIndex > 0 else {
            return
        }

        if customColumnWorkQueueHeadIndex >= customColumnWorkQueue.count {
            customColumnWorkQueue.removeAll(keepingCapacity: true)
            customColumnWorkQueueHeadIndex = 0
            return
        }

        if customColumnWorkQueueHeadIndex > 512,
           customColumnWorkQueueHeadIndex * 2 >= customColumnWorkQueue.count {
            customColumnWorkQueue.removeFirst(customColumnWorkQueueHeadIndex)
            customColumnWorkQueueHeadIndex = 0
        }
    }

    private func queueCustomColumnReload(packetID: PacketSummary.ID) {
        guard let rowIndex = viewModel.rowIndex(for: packetID),
              rowIndex >= 0,
              rowIndex < tableView.numberOfRows else {
            return
        }

        pendingCustomColumnReloadIndexes.insert(rowIndex)
        guard pendingCustomColumnReloadWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingCustomColumnReloads()
        }
        pendingCustomColumnReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func flushPendingCustomColumnReloads() {
        pendingCustomColumnReloadWorkItem = nil
        let validRange = 0..<tableView.numberOfRows
        let rowIndexes = IndexSet(pendingCustomColumnReloadIndexes.filter { validRange.contains($0) })
        pendingCustomColumnReloadIndexes = []
        guard !rowIndexes.isEmpty else {
            return
        }

        tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
    }

    private func visiblePacketIDs() -> [PacketSummary.ID] {
        let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
        guard visibleRows.location != NSNotFound else {
            return []
        }

        let rowRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
        return rowRange.compactMap { rowIndex in
            rows.indices.contains(rowIndex) ? rows[rowIndex].id : nil
        }
    }

    private func resetCustomColumnResolutionQueue() {
        customColumnResolutionGeneration += 1
        customColumnWorkQueue.removeAll()
        customColumnWorkQueueHeadIndex = 0
        queuedCustomColumnWorkKeys.removeAll()
        activeCustomColumnInspectionCount = 0
        pendingCustomColumnReloadIndexes = []
        pendingCustomColumnReloadWorkItem?.cancel()
        pendingCustomColumnReloadWorkItem = nil
    }

    private func customColumnWorkKey(columnIdentifier: String, packetID: PacketSummary.ID) -> String {
        "\(columnIdentifier)|\(packetID)"
    }

    private func visibleCustomColumns() -> [PacketCustomColumn] {
        customColumnService.columns.filter { columnService.isColumnVisible(identifier: $0.identifier) }
    }

    private func reloadColumn(identifier: String) {
        guard let columnIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }),
              tableView.numberOfRows > 0 else {
            return
        }

        tableView.reloadData(
            forRowIndexes: IndexSet(0..<tableView.numberOfRows),
            columnIndexes: IndexSet(integer: columnIndex)
        )
    }

    private func menuState() -> PacketTableMenuState {
        PacketTableMenuLogic.state(
            rows: rows,
            selectedRowIndexes: tableView.selectedRowIndexes,
            clickedRowIndex: clickedRowIndex,
            clickedColumnIdentifier: clickedColumnIdentifier
        )
    }

    private func targetRows() -> [PacketTableRow] {
        menuState().targetRows.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    private func targetPacketIDs() -> [PacketSummary.ID] {
        targetRows().map(\.id)
    }

    private func writeToPasteboard(_ value: String) {
        guard !value.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc func copyRowsFromMenu(_ sender: Any?) {
        copyTargetRows(format: .csv)
    }

    @objc func copyRowsAsPlainTextFromMenu(_ sender: Any?) {
        copyTargetRows(format: .plainText)
    }

    @objc func copyRowsAsJSONFromMenu(_ sender: Any?) {
        copyTargetRows(format: .json)
    }

    @objc func copyRowsAsMarkdownTableFromMenu(_ sender: Any?) {
        copyTargetRows(format: .markdownTable)
    }

    @objc func copyRowsAsCSVFromMenu(_ sender: Any?) {
        copyTargetRows(format: .csv)
    }

    @objc func copyRowsAsCSVWithHeaderFromMenu(_ sender: Any?) {
        copyTargetRows(format: .csvWithHeader)
    }

    @objc func copyCellFromMenu(_ sender: Any?) {
        let state = menuState()
        guard let columnIdentifier = state.clickedColumnIdentifier else {
            return
        }

        let rows = state.targetRows.compactMap { self.rows.indices.contains($0) ? self.rows[$0] : nil }
        writeToPasteboard(PacketTableCopyFormatter.csvValues(rows.map { text(for: columnIdentifier, in: $0) }))
    }

    @objc func pinRowsFromMenu(_ sender: Any?) {
        requestPin()
    }

    @objc func saveRowsFromMenu(_ sender: Any?) {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(self, didRequestSavePackets: identifiers)
    }

    @objc func followTCPStreamFromMenu(_ sender: Any?) {
        let packetIDs = targetPacketIDs()
        guard packetIDs.count == 1, let packetID = packetIDs.first else {
            return
        }
        delegate?.packetTableViewController(self, didRequestFollowTCPStream: packetID)
    }

    @objc func addPacketCommentFromMenu(_ sender: Any?) {
        let targetRows = targetRows()
        guard !targetRows.isEmpty else {
            return
        }
        let identifiers = targetRows.map(\.id)
        let initialComment = targetRows.count == 1 ? targetRows[0].comment : nil

        let sheet = PacketCommentSheetViewController(
            initialComment: initialComment,
            packetCount: targetRows.count
        ) { [weak self] comment in
            guard let self else {
                return
            }
            self.delegate?.packetTableViewController(
                self,
                didRequestSetComment: comment,
                onPackets: identifiers
            )
        }
        commentSheetController = sheet
        sheet.show(attachedTo: view.window)
    }

    @objc func setPacketHighlightColorFromMenu(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let rawValue = menuItem.representedObject as? String,
              let color = PacketHighlightColor(rawValue: rawValue) else {
            return
        }
        applyTextStyle(.setHighlightColor(color))
    }

    @objc func togglePacketStrikethroughFromMenu(_ sender: Any?) {
        applyTextStyle(.toggleStrikethrough)
    }

    @objc func resetPacketTextStyleFromMenu(_ sender: Any?) {
        applyTextStyle(.reset)
    }

    @objc func exportRowsAsPcapFromMenu(_ sender: Any?) {
        exportTargetRows(format: .pcap)
    }

    @objc func exportRowsAsPcapngFromMenu(_ sender: Any?) {
        exportTargetRows(format: .pcapng)
    }

    @objc func deleteRowsFromMenu(_ sender: Any?) {
        deleteTargetRows()
    }

    private func copyTargetRows(format: PacketTableCopyFormat) {
        writeToPasteboard(PacketTableCopyFormatter.rows(targetRows(), format: format))
    }

    private func deleteTargetRows() {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(self, didRequestDeletePackets: identifiers)
    }

    private func exportTargetRows(format: CaptureFileFormat) {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(self, didRequestExportPackets: identifiers, format: format)
    }

    private func applyTextStyle(_ mutation: PacketTextStyleMutation) {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(
            self,
            didRequestApplyTextStyle: mutation,
            toPackets: identifiers
        )
    }

    private func requestPin() {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(
            self,
            didRequestPinPackets: identifiers
        )
    }
}

extension PacketTableViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row), let column = tableColumn?.identifier.rawValue else {
            return nil
        }

        return text(for: column, in: rows[row])
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard rows.indices.contains(row), let column = tableColumn?.identifier.rawValue else {
            return
        }

        let packetRow = rows[row]
        if let cell = cell as? PacketProtocolCell {
            cell.configure(
                protocolText: packetRow.protocolText,
                severity: packetRow.severity,
                textStyle: packetRow.textStyle,
                configuration: configuration
            )
        } else if let cell = cell as? PacketClientCell {
            cell.configure(
                displayName: packetRow.clientText,
                iconFilePath: packetRow.clientIconFilePath,
                textStyle: packetRow.textStyle,
                configuration: configuration
            )
        } else if let cell = cell as? PacketTextCell {
            cell.configure(
                style: textStyle(for: column, in: packetRow),
                textStyle: packetRow.textStyle,
                configuration: configuration
            )
        }
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        saveColumnLayout()
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        guard let commentIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == PacketTableColumnRole.comment.rawValue
        }) else {
            return true
        }
        return columnIndex != commentIndex && newColumnIndex < commentIndex
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        saveColumnLayout()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRowIndexes.first ?? -1
        let selectedID = viewModel.rowID(at: selectedRow)

        // Suppress only when the change is the echo of a programmatic update
        // we just applied. A genuine user click during a render burst still
        // needs to round-trip through the delegate, otherwise the selection
        // would be silently dropped.
        if isSuppressingSelectionCallbacks, selectedID == viewModel.selectedPacketID {
            return
        }

        guard selectedID != lastAppliedSelectedPacketID else {
            return
        }

        pendingUserSelection = PendingUserSelection(id: selectedID)
        lastAppliedSelectedPacketID = selectedID
        delegate?.packetTableViewController(self, didSelectPacket: selectedID)
    }
}

extension PacketTableViewController: PacketTableKeyboardActionHandling {
    fileprivate func packetTableViewDidRequestCopyRowsFromKeyboard(_ tableView: PacketTableView) {
        clickedRowIndex = nil
        clickedColumnIdentifier = nil
        copyTargetRows(format: .csv)
    }

    fileprivate func packetTableViewDidRequestDeleteFromKeyboard(_ tableView: PacketTableView) {
        clickedRowIndex = nil
        clickedColumnIdentifier = nil
        deleteTargetRows()
    }

    fileprivate func packetTableViewDidRequestAddCommentFromKeyboard(_ tableView: PacketTableView) {
        clickedRowIndex = nil
        clickedColumnIdentifier = nil
        addPacketCommentFromMenu(nil)
    }

    fileprivate func packetTableView(_ tableView: PacketTableView, didRequestTextStyle mutation: PacketTextStyleMutation) {
        clickedRowIndex = nil
        clickedColumnIdentifier = nil
        applyTextStyle(mutation)
    }
}

extension PacketTableViewController: PacketTableContextMenuActionHandling, PacketTableContextMenuStateProviding {
    func packetTableContextMenuWillOpen() {
        updateClickedPositionFromCurrentEvent()
    }

    func packetTableContextMenuState() -> PacketTableMenuState {
        menuState()
    }
}

extension PacketTableViewController: PacketTableColumnVisibilityMenuActionHandling {
    func togglePacketTableColumnVisibilityFromMenu(_ sender: Any?) {
        guard let identifier = columnIdentifier(from: sender),
              columnService.toggleColumnVisibility(identifier: identifier) else {
            return
        }

        applyColumnVisibility(identifier: identifier)
        if columnService.isColumnVisible(identifier: identifier),
           let customColumn = customColumnService.columns.first(where: { $0.identifier == identifier }) {
            enqueueCustomColumnResolution(for: customColumn, visibleFirst: true)
        }
        saveColumnLayout()
        tableView.headerView?.menu?.cancelTracking()
    }

    func resetPacketTableColumnsFromMenu(_ sender: Any?) {
        resetCustomColumnResolutionQueue()
        customColumnService.reset()
        columnService.resetToDefaults()
        restoreDefaultColumnLayout()
        columnLayoutStore.clear()
        syncColumnVisibilityFromTable()
        tableView.headerView?.menu?.cancelTracking()
    }
}

#if DEBUG
extension PacketTableViewController {
    // Selects a random NSTableView row so debug automation uses the same selection path as clicks.
    @discardableResult
    func selectRandomPacketRowForTesting() -> Bool {
        let rowCount = viewModel.rowCount
        guard rowCount > 0 else {
            return false
        }

        let rowIndex = randomSelectableRowIndex(rowCount: rowCount, currentRow: tableView.selectedRow)
        if rowCount == 1, tableView.selectedRow == rowIndex {
            tableView.deselectAll(nil)
        }
        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(rowIndex)
        return true
    }

    // Avoids selecting the already-selected row when more than one row is available.
    private func randomSelectableRowIndex(rowCount: Int, currentRow: Int) -> Int {
        var rowIndex = Int.random(in: 0..<rowCount)
        if rowCount > 1, rowIndex == currentRow {
            rowIndex = (rowIndex + Int.random(in: 1..<rowCount)) % rowCount
        }
        return rowIndex
    }
}
#endif
