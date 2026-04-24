import AppKit
import SwiftUI
import PcapPlusPlusCore

struct NetworkPacketTableView: NSViewRepresentable {
    let rows: [PacketTableRow]
    let contentGeneration: UInt64
    let updatePlan: PacketTableUpdatePlan
    let density: PacketTableDensity
    let selectedPacketID: PacketSummary.ID?
    let selectedRowIndex: Int?
    let onSelectPacket: (PacketSummary.ID?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectPacket: onSelectPacket)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = density.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.style = .inset

        Self.addColumn("number", title: "No.", width: 68, minWidth: 52, to: tableView)
        Self.addColumn("time", title: "Time", width: 112, minWidth: 96, to: tableView)
        Self.addColumn("source", title: "Source", width: 180, minWidth: 130, to: tableView)
        Self.addColumn("destination", title: "Destination", width: 180, minWidth: 130, to: tableView)
        Self.addColumn("protocol", title: "Protocol", width: 96, minWidth: 82, to: tableView)
        Self.addColumn("length", title: "Length", width: 80, minWidth: 68, to: tableView)
        Self.addColumn("summary", title: "Summary", width: 320, minWidth: 180, to: tableView)
        Self.addColumn("tags", title: "Tags", width: 140, minWidth: 90, to: tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        context.coordinator.rows = rows
        context.coordinator.contentGeneration = contentGeneration
        context.coordinator.suppressSelectionCallbacks {
            tableView.reloadData()
            context.coordinator.syncSelection(
                in: tableView,
                selectedPacketID: selectedPacketID,
                selectedRowIndex: selectedRowIndex
            )
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else {
            return
        }

        let resolvedUpdatePlan = PacketTableUpdatePlanner.plan(
            previousGeneration: context.coordinator.contentGeneration,
            currentGeneration: contentGeneration,
            proposedPlan: updatePlan
        )
        let previousRowCount = context.coordinator.rows.count

        context.coordinator.rows = rows
        context.coordinator.contentGeneration = contentGeneration
        context.coordinator.onSelectPacket = onSelectPacket
        tableView.rowHeight = density.rowHeight

        context.coordinator.suppressSelectionCallbacks {
            switch resolvedUpdatePlan {
            case .none:
                break
            case .append(let range):
                if range.lowerBound == previousRowCount, range.upperBound <= rows.count {
                    print("[Packetry] \(NetworkInspectorDebugLog.timestamp()) Packet table inserting rows: \(range.lowerBound)..<\(range.upperBound), totalRows=\(rows.count)")
                    tableView.noteNumberOfRowsChanged()
                } else {
                    Self.preserveScrollPosition(in: scrollView) {
                        tableView.reloadData()
                    }
                }
            case .reload:
                Self.preserveScrollPosition(in: scrollView) {
                    tableView.reloadData()
                }
            }

            context.coordinator.syncSelection(
                in: tableView,
                selectedPacketID: selectedPacketID,
                selectedRowIndex: selectedRowIndex
            )
        }
    }

    private static func preserveScrollPosition(in scrollView: NSScrollView, updates: () -> Void) {
        let clipView = scrollView.contentView
        let visibleOrigin = clipView.bounds.origin

        updates()

        clipView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private static func addColumn(
        _ identifier: String,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        to tableView: NSTableView
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.resizingMask = .userResizingMask
        tableView.addTableColumn(column)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [PacketTableRow] = []
        var contentGeneration: UInt64 = 0
        var onSelectPacket: (PacketSummary.ID?) -> Void
        private var lastAppliedSelectedPacketID: PacketSummary.ID?
        private var selectionCallbackSuppressionDepth = 0

        private var isSuppressingSelectionCallbacks: Bool {
            selectionCallbackSuppressionDepth > 0
        }

        init(onSelectPacket: @escaping (PacketSummary.ID?) -> Void) {
            self.onSelectPacket = onSelectPacket
        }

        func suppressSelectionCallbacks(_ updates: () -> Void) {
            selectionCallbackSuppressionDepth += 1
            defer {
                selectionCallbackSuppressionDepth -= 1
            }

            updates()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row),
                  let identifier = tableColumn?.identifier else {
                return nil
            }

            let packetRow = rows[row]
            switch identifier.rawValue {
            case "protocol":
                let view = tableView.makeView(
                    withIdentifier: ProtocolCellView.reuseIdentifier,
                    owner: self
                ) as? ProtocolCellView ?? ProtocolCellView()
                view.configure(protocolText: packetRow.protocolText, severity: packetRow.severity)
                return view
            case "tags":
                let view = tableView.makeView(
                    withIdentifier: TextCellView.reuseIdentifier,
                    owner: self
                ) as? TextCellView ?? TextCellView()
                view.configure(text: packetRow.tagText, style: .secondary, monospaced: false)
                return view
            default:
                let view = tableView.makeView(
                    withIdentifier: TextCellView.reuseIdentifier,
                    owner: self
                ) as? TextCellView ?? TextCellView()
                view.configure(
                    text: text(for: identifier.rawValue, in: packetRow),
                    style: textStyle(for: identifier.rawValue, in: packetRow),
                    monospaced: usesMonospacedFont(identifier.rawValue)
                )
                return view
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSuppressingSelectionCallbacks,
                  let tableView = notification.object as? NSTableView else {
                return
            }

            let selectedRow = tableView.selectedRow
            let selectedID = rows.indices.contains(selectedRow) ? rows[selectedRow].id : nil
            guard selectedID != lastAppliedSelectedPacketID else {
                return
            }

            lastAppliedSelectedPacketID = selectedID
            let onSelectPacket = onSelectPacket
            DispatchQueue.main.async {
                onSelectPacket(selectedID)
            }
        }

        // Applies model selection to AppKit only when the visible table selection is stale.
        func syncSelection(
            in tableView: NSTableView,
            selectedPacketID: PacketSummary.ID?,
            selectedRowIndex: Int?
        ) {
            suppressSelectionCallbacks {
                let action = PacketTableSelectionSyncPlanner.action(
                    rows: rows,
                    selectedPacketID: selectedPacketID,
                    selectedRowIndex: selectedRowIndex,
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

                lastAppliedSelectedPacketID = selectedPacketID
            }
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
            case "length":
                row.lengthText
            case "summary":
                row.summaryText
            default:
                ""
            }
        }

        private func textStyle(for column: String, in row: PacketTableRow) -> TextCellView.Style {
            if column == "summary", row.severity != .normal {
                return .warning
            }

            if column == "number" || column == "time" || column == "length" {
                return .secondary
            }

            return .primary
        }

        private func usesMonospacedFont(_ column: String) -> Bool {
            column == "number" || column == "time" || column == "length"
        }
    }
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

private final class TextCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("Packetry.TextCell")

    enum Style {
        case primary
        case secondary
        case warning
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, style: Style, monospaced: Bool) {
        label.stringValue = text
        label.font = monospaced ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)

        switch style {
        case .primary:
            label.textColor = .labelColor
        case .secondary:
            label.textColor = .secondaryLabelColor
        case .warning:
            label.textColor = .systemOrange
        }
    }
}

private final class ProtocolCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("Packetry.ProtocolCell")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.masksToBounds = true
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(protocolText: String, severity: PacketSeverity) {
        label.stringValue = protocolText
        label.textColor = severity == .normal ? .labelColor : .systemOrange
        label.layer?.backgroundColor = backgroundColor(for: severity).cgColor
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
