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
}

final class PacketTableViewModel {
    private(set) var rows: [PacketTableRow] = []
    private(set) var contentGeneration: UInt64 = 0
    private(set) var selectedPacketID: PacketSummary.ID?
    private(set) var selectedRowIndex: Int?

    // Store the latest render state so the controller can apply incremental table updates.
    func render(snapshot: NetworkInspectorSnapshot) -> PacketTableUpdatePlan {
        let updatePlan = PacketTableUpdatePlanner.plan(
            previousGeneration: contentGeneration,
            currentGeneration: snapshot.packetTableGeneration,
            proposedPlan: snapshot.packetTableUpdatePlan
        )
        rows = snapshot.packetRows
        contentGeneration = snapshot.packetTableGeneration
        selectedPacketID = snapshot.selectedPacketID
        selectedRowIndex = snapshot.selectedPacketRowIndex
        return updatePlan
    }
}

final class PacketTableViewController: NSViewController {
    weak var delegate: PacketTableViewControllerDelegate?

    private let configuration: AppConfiguration
    private let tableView = PacketTableView()
    private let scrollView = NSScrollView()
    private let viewModel = PacketTableViewModel()
    private let contextMenuController = PacketTableContextMenuController()
    private var selectionCallbackSuppressionDepth = 0
    private var lastAppliedSelectedPacketID: PacketSummary.ID?
    private var clickedRowIndex: Int?
    private var clickedColumnIdentifier: String?

    private var rows: [PacketTableRow] {
        viewModel.rows
    }

    private var isSuppressingSelectionCallbacks: Bool {
        selectionCallbackSuppressionDepth > 0
    }

    init(configuration: AppConfiguration) {
        self.configuration = configuration
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
                if range.lowerBound == previousRowCount, range.upperBound <= rows.count {
                    tableView.noteNumberOfRowsChanged()
                } else {
                    preserveScrollPosition {
                        tableView.reloadData()
                    }
                }
            case .reload:
                preserveScrollPosition {
                    tableView.reloadData()
                }
            }

            syncSelection()
        }
    }

    @objc private func appConfigurationDidChange(_ notification: Notification) {
        applyAppearanceConfiguration(reload: true)
    }

    private func setupTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.keyboardActionHandler = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = configuration.packetRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.focusRingType = .none
        contextMenuController.actionHandler = self
        contextMenuController.stateProvider = self
        tableView.menu = contextMenuController.makeMenu()
        
        addColumn("number", title: " No.", width: 68, minWidth: 52, cell: PacketTextCell())
        addColumn("time", title: " Time", width: 112, minWidth: 96, cell: PacketTextCell())
        addColumn("source", title: " Source", width: 180, minWidth: 130, cell: PacketTextCell())
        addColumn("destination", title: " Destination", width: 180, minWidth: 130, cell: PacketTextCell())
        addColumn("domain", title: " Domain", width: 180, minWidth: 120, cell: PacketTextCell())
        addColumn("client", title: " Client", width: 160, minWidth: 120, cell: PacketClientCell())
        addColumn("protocol", title: " Protocol", width: 96, minWidth: 82, cell: PacketProtocolCell())
        addColumn("length", title: " Length", width: 80, minWidth: 68, cell: PacketTextCell())
        addColumn("summary", title: " Summary", width: 320, minWidth: 180, cell: PacketTextCell())
        addColumn("tags", title: " Tags", width: 140, minWidth: 90, cell: PacketTextCell())

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

    private func addColumn(
        _ identifier: String,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        cell: NSCell
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.resizingMask = .userResizingMask
        column.dataCell = cell
        tableView.addTableColumn(column)
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

        if column == "number" || column == "time" || column == "length" || column == "tags" {
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSuppressingSelectionCallbacks else {
            return
        }

        let selectedRow = tableView.selectedRowIndexes.first ?? -1
        let selectedID = rows.indices.contains(selectedRow) ? rows[selectedRow].id : nil
        guard selectedID != lastAppliedSelectedPacketID else {
            return
        }

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
