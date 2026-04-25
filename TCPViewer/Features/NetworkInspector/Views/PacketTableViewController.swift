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
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        
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

    @objc private func copyRowsFromMenu(_ sender: Any?) {
        copyTargetRows()
    }

    @objc private func copyCellFromMenu(_ sender: Any?) {
        let state = menuState()
        let rows = state.targetRows.compactMap { self.rows.indices.contains($0) ? self.rows[$0] : nil }
        writeToPasteboard(PacketTableCopyFormatter.csvCells(rows, column: state.clickedColumn))
    }

    @objc private func pinDomainFromMenu(_ sender: Any?) {
        requestPin(.domain)
    }

    @objc private func pinIPFromMenu(_ sender: Any?) {
        requestPin(.ip)
    }

    @objc private func pinClientFromMenu(_ sender: Any?) {
        requestPin(.client)
    }

    @objc private func saveRowsFromMenu(_ sender: Any?) {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(self, didRequestSavePackets: identifiers)
    }

    @objc private func deleteRowsFromMenu(_ sender: Any?) {
        deleteTargetRows()
    }

    private func copyTargetRows() {
        writeToPasteboard(PacketTableCopyFormatter.csvRows(targetRows()))
    }

    private func deleteTargetRows() {
        let identifiers = targetPacketIDs()
        guard !identifiers.isEmpty else {
            return
        }

        delegate?.packetTableViewController(self, didRequestDeletePackets: identifiers)
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

extension PacketTableViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateClickedPositionFromCurrentEvent()
        let state = menuState()

        menu.removeAllItems()
        let copyRowItem = NSMenuItem(title: "Copy Row", action: #selector(copyRowsFromMenu(_:)), keyEquivalent: "c")
        copyRowItem.target = self
        copyRowItem.isEnabled = state.copyRowEnabled
        menu.addItem(copyRowItem)

        let copyCellItem = NSMenuItem(title: "Copy Cell", action: #selector(copyCellFromMenu(_:)), keyEquivalent: "")
        copyCellItem.target = self
        copyCellItem.isEnabled = state.copyCellEnabled
        menu.addItem(copyCellItem)

        menu.addItem(.separator())

        let pinItem = NSMenuItem(title: "Pin", action: nil, keyEquivalent: "")
        let pinSubmenu = NSMenu(title: "Pin")
        let pinDomainItem = NSMenuItem(title: "Domain", action: #selector(pinDomainFromMenu(_:)), keyEquivalent: "")
        pinDomainItem.target = self
        pinDomainItem.isEnabled = state.pinDomainEnabled
        pinSubmenu.addItem(pinDomainItem)

        let pinIPItem = NSMenuItem(title: "IP", action: #selector(pinIPFromMenu(_:)), keyEquivalent: "")
        pinIPItem.target = self
        pinIPItem.isEnabled = state.pinIPEnabled
        pinSubmenu.addItem(pinIPItem)

        let pinClientItem = NSMenuItem(title: "Client", action: #selector(pinClientFromMenu(_:)), keyEquivalent: "")
        pinClientItem.target = self
        pinClientItem.isEnabled = state.pinClientEnabled
        pinSubmenu.addItem(pinClientItem)

        pinItem.submenu = pinSubmenu
        pinItem.isEnabled = state.pinDomainEnabled || state.pinIPEnabled || state.pinClientEnabled
        menu.addItem(pinItem)

        let saveItem = NSMenuItem(title: "Save", action: #selector(saveRowsFromMenu(_:)), keyEquivalent: "")
        saveItem.target = self
        saveItem.isEnabled = state.saveEnabled
        menu.addItem(saveItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteRowsFromMenu(_:)), keyEquivalent: "\u{8}")
        deleteItem.target = self
        deleteItem.isEnabled = state.deleteEnabled
        menu.addItem(deleteItem)
    }
}

extension PacketTableViewController: PacketTableKeyboardActionHandling {
    fileprivate func packetTableViewDidRequestCopyRowsFromKeyboard(_ tableView: PacketTableView) {
        clickedRowIndex = nil
        clickedColumnIdentifier = nil
        copyTargetRows()
    }

    fileprivate func packetTableViewDidRequestDeleteFromKeyboard(_ tableView: PacketTableView) {
        clickedRowIndex = nil
        clickedColumnIdentifier = nil
        deleteTargetRows()
    }
}

final class PacketTextCell: NSTextFieldCell {
    enum Style {
        case primary
        case secondary
        case warning
    }

    override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
    }

    convenience init() {
        self.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(style: Style, configuration: AppConfiguration) {
        font = configuration.packetFont(weight: .regular)

        switch style {
        case .primary:
            textColor = .labelColor
        case .secondary:
            textColor = .secondaryLabelColor
        case .warning:
            textColor = .systemOrange
        }
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    private func verticallyCenteredRect(forBounds rect: NSRect) -> NSRect {
        // Center text in compact rows so AppKit's default baseline does not sit high.
        var drawingRect = super.drawingRect(forBounds: rect).insetBy(dx: 6, dy: 0)
        let textHeight = cellSize(forBounds: drawingRect).height
        drawingRect.origin.y += floor((drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }
}

final class PacketProtocolCell: NSTextFieldCell {
    private var protocolText = ""
    private var severity: PacketSeverity = .normal

    override init(textCell string: String) {
        super.init(textCell: string)
        alignment = .center
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
    }

    convenience init() {
        self.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(protocolText: String, severity: PacketSeverity, configuration: AppConfiguration) {
        self.protocolText = protocolText
        self.severity = severity
        stringValue = protocolText
        font = configuration.packetFont(weight: .semibold)
        textColor = textColor(for: protocolText, severity: severity)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Draw protocol values as compact colored pills instead of plain table text.
        let label = protocolText.isEmpty ? stringValue : protocolText
        guard !label.isEmpty else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .monospacedSystemFont(ofSize: AppConfiguration.defaultPacketFontSize, weight: .semibold),
            .foregroundColor: textColor ?? .labelColor,
        ]
        let textSize = label.size(withAttributes: attributes)
        let pillWidth = min(max(textSize.width + 16, 42), cellFrame.width - 12)
        let pillHeight = min(cellFrame.height - 4, max(18, ceil(textSize.height + 6)))
        let pillRect = NSRect(
            x: cellFrame.midX - pillWidth / 2,
            y: cellFrame.midY - pillHeight / 2,
            width: pillWidth,
            height: pillHeight
        )

        backgroundColor(for: label, severity: severity).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()

        let textRect = NSRect(
            x: pillRect.midX - textSize.width / 2,
            y: pillRect.midY - textSize.height / 2 - 0.5,
            width: textSize.width,
            height: textSize.height
        )
        label.draw(in: textRect, withAttributes: attributes)
    }

    private func backgroundColor(for protocolText: String, severity: PacketSeverity) -> NSColor {
        if severity != .normal {
            return .systemOrange.withAlphaComponent(0.18)
        }

        switch protocolText.uppercased() {
        case "TCP":
            return .systemOrange.withAlphaComponent(0.16)
        case "UDP":
            return .systemBlue.withAlphaComponent(0.16)
        case "TLS", "SSL", "HTTPS":
            return .systemGreen.withAlphaComponent(0.16)
        case "HTTP":
            return .systemPink.withAlphaComponent(0.16)
        case "DNS":
            return .systemPurple.withAlphaComponent(0.16)
        case "ICMP":
            return .systemRed.withAlphaComponent(0.14)
        case "ARP":
            return .systemTeal.withAlphaComponent(0.16)
        default:
            return .controlAccentColor.withAlphaComponent(0.14)
        }
    }

    private func textColor(for protocolText: String, severity: PacketSeverity) -> NSColor {
        if severity != .normal {
            return .systemOrange
        }

        switch protocolText.uppercased() {
        case "TCP":
            return .systemOrange
        case "UDP":
            return .systemBlue
        case "TLS", "SSL", "HTTPS":
            return .systemGreen
        case "HTTP":
            return .systemPink
        case "DNS":
            return .systemPurple
        case "ICMP":
            return .systemRed
        case "ARP":
            return .systemTeal
        default:
            return .controlAccentColor
        }
    }
}

final class PacketClientIconCache {
    private var imagesByKey: [String: NSImage] = [:]

    // Return one shared icon instance per app path so repeated packet rows stay cheap.
    func image(for client: PacketClient?) -> NSImage? {
        guard let client else {
            return nil
        }

        let key = client.bundlePath ?? client.executablePath ?? client.name
        if let image = imagesByKey[key] {
            return image
        }

        guard let path = client.bundlePath ?? client.executablePath else {
            return nil
        }

        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        imagesByKey[key] = image
        return image
    }
}

final class PacketClientCell: NSTextFieldCell {
    private static let iconCache = PacketClientIconCache()
    private var client: PacketClient?

    override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
        textColor = .labelColor
    }

    convenience init() {
        self.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Configure the reused cell with the current row's client metadata.
    func configure(client: PacketClient?, configuration: AppConfiguration) {
        self.client = client
        stringValue = client?.displayName ?? "-"
        font = configuration.packetFont(weight: .regular)
        textColor = client == nil ? .secondaryLabelColor : .labelColor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    private func verticallyCenteredRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: drawingRect).height
        drawingRect.origin.y += floor((drawingRect.height - textHeight) / 2)
        drawingRect.size.height = textHeight
        return drawingRect
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let icon = Self.iconCache.image(for: client) else {
            let textFrame = cellFrame.insetBy(dx: 6, dy: 0)
            super.drawInterior(withFrame: textFrame, in: controlView)
            return
        }

        let iconSize: CGFloat = 16
        let iconFrame = NSRect(
            x: cellFrame.minX + 6,
            y: cellFrame.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        icon.draw(in: iconFrame)

        let textFrame = cellFrame.insetBy(dx: 6, dy: 0).offsetBy(dx: iconSize + 4, dy: 0)
        super.drawInterior(withFrame: textFrame, in: controlView)
    }
}
