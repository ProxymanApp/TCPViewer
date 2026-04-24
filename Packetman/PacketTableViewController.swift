import AppKit
import PcapPlusPlusCore

protocol PacketTableViewControllerDelegate: AnyObject {
    func packetTableViewController(_ controller: PacketTableViewController, didSelectPacket identifier: PacketSummary.ID?)
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
        tableSelectedRow: Int
    ) -> PacketTableSelectionSyncAction {
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
    private static let compactRowHeight: CGFloat = 24

    weak var delegate: PacketTableViewControllerDelegate?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let viewModel = PacketTableViewModel()
    private var selectionCallbackSuppressionDepth = 0
    private var lastAppliedSelectedPacketID: PacketSummary.ID?

    private var rows: [PacketTableRow] {
        viewModel.rows
    }

    private var isSuppressingSelectionCallbacks: Bool {
        selectionCallbackSuppressionDepth > 0
    }

    override func loadView() {
        setupTable()
        view = scrollView
    }

    // Apply packet rows, using append plans when the model says only new visible rows arrived.
    func render(snapshot: NetworkInspectorSnapshot) {
        let previousRowCount = rows.count
        let updatePlan = viewModel.render(snapshot: snapshot)
        tableView.rowHeight = Self.compactRowHeight

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

    private func setupTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = Self.compactRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.focusRingType = .none
        
        addColumn("number", title: "No.", width: 68, minWidth: 52, cell: PacketTextCell())
        addColumn("time", title: "Time", width: 112, minWidth: 96, cell: PacketTextCell())
        addColumn("source", title: "Source", width: 180, minWidth: 130, cell: PacketTextCell())
        addColumn("destination", title: "Destination", width: 180, minWidth: 130, cell: PacketTextCell())
        addColumn("domain", title: "Domain", width: 180, minWidth: 120, cell: PacketTextCell())
        addColumn("client", title: "Client", width: 160, minWidth: 120, cell: PacketClientCell())
        addColumn("protocol", title: "Protocol", width: 96, minWidth: 82, cell: PacketProtocolCell())
        addColumn("length", title: "Length", width: 80, minWidth: 68, cell: PacketTextCell())
        addColumn("summary", title: "Summary", width: 320, minWidth: 180, cell: PacketTextCell())
        addColumn("tags", title: "Tags", width: 140, minWidth: 90, cell: PacketTextCell())

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
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
            tableSelectedRow: tableView.selectedRow
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
        switch column {
        case "number":
            row.numberText
        case "time":
            row.timeText
        case "source":
            row.sourceText
        case "destination":
            row.destinationText
        case "domain":
            row.domainText
        case "client":
            row.clientText
        case "protocol":
            row.protocolText
        case "length":
            row.lengthText
        case "summary":
            row.summaryText
        case "tags":
            row.tagText
        default:
            ""
        }
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

    private func usesMonospacedFont(_ column: String) -> Bool {
        column == "number" || column == "time" || column == "length"
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
            cell.configure(protocolText: packetRow.protocolText, severity: packetRow.severity)
        } else if let cell = cell as? PacketClientCell {
            cell.configure(client: packetRow.packet.client)
        } else if let cell = cell as? PacketTextCell {
            cell.configure(
                style: textStyle(for: column, in: packetRow),
                monospaced: usesMonospacedFont(column)
            )
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSuppressingSelectionCallbacks else {
            return
        }

        let selectedRow = tableView.selectedRow
        let selectedID = rows.indices.contains(selectedRow) ? rows[selectedRow].id : nil
        guard selectedID != lastAppliedSelectedPacketID else {
            return
        }

        lastAppliedSelectedPacketID = selectedID
        delegate?.packetTableViewController(self, didSelectPacket: selectedID)
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

    func configure(style: Style, monospaced: Bool) {
        font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)

        switch style {
        case .primary:
            textColor = .labelColor
        case .secondary:
            textColor = .secondaryLabelColor
        case .warning:
            textColor = .systemOrange
        }
    }
}

final class PacketProtocolCell: NSTextFieldCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        alignment = .center
        isEditable = false
        isBordered = false
        drawsBackground = true
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
        font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    }

    convenience init() {
        self.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(protocolText: String, severity: PacketSeverity) {
        stringValue = protocolText
        textColor = severity == .normal ? .labelColor : .systemOrange
        backgroundColor = backgroundColor(for: severity)
    }

    private func backgroundColor(for severity: PacketSeverity) -> NSColor {
        switch severity {
        case .normal:
            return .controlAccentColor.withAlphaComponent(0.14)
        case .partial, .malformed, .unsupported, .truncated:
            return .systemOrange.withAlphaComponent(0.16)
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
        font = .systemFont(ofSize: NSFont.systemFontSize)
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
    func configure(client: PacketClient?) {
        self.client = client
        stringValue = client?.displayName ?? "-"
        textColor = client == nil ? .secondaryLabelColor : .labelColor
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let icon = Self.iconCache.image(for: client) else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
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
