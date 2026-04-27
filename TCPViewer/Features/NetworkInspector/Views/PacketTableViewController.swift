import AppKit
import PcapPlusPlusCore

protocol PacketTableViewControllerDelegate: AnyObject {
    func packetTableViewController(_ controller: PacketTableViewController, didSelectPacket identifier: PacketSummary.ID?)
    func packetTableViewController(
        _ controller: PacketTableViewController,
        didRequestPin kind: PacketPinCreationKind,
        packetID: PacketSummary.ID,
        clickedColumn: PacketTableColumnRole
    )
    func packetTableViewController(_ controller: PacketTableViewController, didRequestSavePackets identifiers: [PacketSummary.ID])
    func packetTableViewController(_ controller: PacketTableViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat)
    func packetTableViewController(_ controller: PacketTableViewController, didRequestDeletePackets identifiers: [PacketSummary.ID])
}

enum PacketTableSelectionSyncAction: Equatable {
    case none
    case select(Int)
    case deselect
}

enum PacketTableSelectionSyncPlanner {
    static func action(
        rows: [PacketTableRow],
        selectedPacketID: PacketSummary.ID?,
        selectedRowIndex: Int?,
        tableSelectedRowIndexes: IndexSet
    ) -> PacketTableSelectionSyncAction {
        let tableSelectedRow = tableSelectedRowIndexes.first ?? -1
        let visualSelectedID = rows.indices.contains(tableSelectedRow) ? rows[tableSelectedRow].id : nil

        guard let selectedPacketID,
              let selectedRowIndex,
              rows.indices.contains(selectedRowIndex) else {
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
}

fileprivate final class PacketTableView: NSTableView {
    weak var keyboardActionHandler: PacketTableKeyboardActionHandling?

    @objc func copy(_ sender: Any?) {
        keyboardActionHandler?.packetTableViewDidRequestCopyRowsFromKeyboard(self)
    }

    @objc func delete(_ sender: Any?) {
        keyboardActionHandler?.packetTableViewDidRequestDeleteFromKeyboard(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            delete(nil)
            return
        }

        super.keyDown(with: event)
    }

    // NSTableView's default treats an unmodified click on an already-selected
    // row inside a multi-selection as a potential drag — the selection is not
    // collapsed. Match Finder's behavior by collapsing it ourselves.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let collapsingModifiers: NSEvent.ModifierFlags = [.shift, .command, .control, .option]

        if row >= 0,
           modifierFlags.intersection(collapsingModifiers).isEmpty,
           selectedRowIndexes.count > 1,
           selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        super.mouseDown(with: event)
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

    // Store the latest render state so the controller can apply incremental table updates.
    func render(snapshot: NetworkInspectorSnapshot) -> PacketTableUpdatePlan {
        let updatePlan = PacketTableUpdatePlanner.plan(
            previousGeneration: contentGeneration,
            currentGeneration: snapshot.packetTableGeneration,
            proposedPlan: snapshot.packetTableUpdatePlan
        )
        rowStore = snapshot.packetTableRowStore
        contentGeneration = snapshot.packetTableGeneration
        selectedPacketID = snapshot.selectedPacketID
        selectedRowIndex = snapshot.selectedPacketRowIndex
        return updatePlan
    }
}

final class PacketTableViewController: NSViewController {
    static let columnAutosaveName: NSTableView.AutosaveName = "TCPViewer.PacketTable.Columns"

    weak var delegate: PacketTableViewControllerDelegate?

    private let configuration: AppConfiguration
    private let tableView = PacketTableView()
    private let scrollView = NSScrollView()
    private let viewModel = PacketTableViewModel()
    private let contextMenuController = PacketTableContextMenuController()
    private let columnService: PacketTableColumnService
    private let columnLayoutStore: PacketTableColumnLayoutStore
    private let columnVisibilityMenuController: PacketTableColumnVisibilityMenuController
    private var isRestoringColumnLayout = false
    private var selectionCallbackSuppressionDepth = 0
    private var lastAppliedSelectedPacketID: PacketSummary.ID?
    private var pendingUserSelection: PendingUserSelection?
    private var clickedRowIndex: Int?
    private var clickedColumnIdentifier: String?

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
    }

    @objc private func appConfigurationDidChange(_ notification: Notification) {
        applyAppearanceConfiguration(reload: true)
    }

    private func setupTable() {
        // Configure the packet table and persist user-controlled column layout.
        tableView.delegate = self
        tableView.dataSource = self
        tableView.keyboardActionHandler = self
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
        if let restoredLayout {
            columnService.applyVisibility(from: restoredLayout)
        }
        columnService.definitions.forEach(addColumn(_:))
        tableView.autosaveName = Self.columnAutosaveName
        tableView.autosaveTableColumns = false
        restoreColumnLayout(restoredLayout)
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
        column.resizingMask = .userResizingMask
        column.dataCell = cell(for: definition.cellKind)
        column.isHidden = !columnService.isColumnVisible(identifier: definition.identifier)
        tableView.addTableColumn(column)
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

    private func currentColumnLayout() -> PacketTableColumnLayout {
        PacketTableColumnLayout(columns: tableView.tableColumns.map { column in
            PacketTableColumnLayout.Column(
                identifier: column.identifier.rawValue,
                isVisible: !column.isHidden,
                width: Double(column.width)
            )
        })
    }

    private func saveColumnLayout() {
        guard !isRestoringColumnLayout else {
            return
        }

        syncColumnVisibilityFromTable()
        columnLayoutStore.save(currentColumnLayout())
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

    private func suppressSelectionCallbacks(_ updates: () -> Void) {
        selectionCallbackSuppressionDepth += 1
        defer {
            selectionCallbackSuppressionDepth -= 1
        }

        updates()
    }

    private func syncSelection() {
        let visualRow = tableView.selectedRowIndexes.first ?? -1
        let visualID: PacketSummary.ID? = rows.indices.contains(visualRow) ? rows[visualRow].id : nil

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
            rows: rows,
            selectedPacketID: viewModel.selectedPacketID,
            selectedRowIndex: viewModel.selectedRowIndex,
            tableSelectedRowIndexes: tableView.selectedRowIndexes
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
        row.text(for: PacketTableColumnRole(columnIdentifier: column))
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
        let rows = state.targetRows.compactMap { self.rows.indices.contains($0) ? self.rows[$0] : nil }
        writeToPasteboard(PacketTableCopyFormatter.csvCells(rows, column: state.clickedColumn))
    }

    @objc func pinDomainFromMenu(_ sender: Any?) {
        requestPin(.domain)
    }

    @objc func pinIPFromMenu(_ sender: Any?) {
        requestPin(.ip)
    }

    @objc func pinClientFromMenu(_ sender: Any?) {
        requestPin(.client)
    }

    @objc func saveRowsFromMenu(_ sender: Any?) {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(self, didRequestSavePackets: identifiers)
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

    private func requestPin(_ kind: PacketPinCreationKind) {
        let state = menuState()
        guard state.targetRows.count == 1,
              let rowIndex = state.targetRows.first,
              rows.indices.contains(rowIndex) else {
            return
        }

        delegate?.packetTableViewController(
            self,
            didRequestPin: kind,
            packetID: rows[rowIndex].id,
            clickedColumn: state.clickedColumn
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
            cell.configure(protocolText: packetRow.protocolText, severity: packetRow.severity, configuration: configuration)
        } else if let cell = cell as? PacketClientCell {
            cell.configure(client: packetRow.client, configuration: configuration)
        } else if let cell = cell as? PacketTextCell {
            cell.configure(style: textStyle(for: column, in: packetRow), configuration: configuration)
        }
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        saveColumnLayout()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        saveColumnLayout()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRowIndexes.first ?? -1
        let selectedID = rows.indices.contains(selectedRow) ? rows[selectedRow].id : nil

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
        saveColumnLayout()
        tableView.headerView?.menu?.cancelTracking()
    }

    func resetPacketTableColumnsFromMenu(_ sender: Any?) {
        columnService.resetToDefaults()
        restoreDefaultColumnLayout()
        columnLayoutStore.clear()
        syncColumnVisibilityFromTable()
        tableView.headerView?.menu?.cancelTracking()
    }
}
