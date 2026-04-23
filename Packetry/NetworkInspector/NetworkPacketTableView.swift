import AppKit
import SwiftUI
import PcapPlusPlusCore

struct NetworkPacketTableView: NSViewRepresentable {
    let rows: [PacketTableRow]
    let density: PacketTableDensity
    @Binding var selectedPacketID: PacketSummary.ID?
    let onSelectPacket: (PacketSummary.ID?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedPacketID: $selectedPacketID,
            onSelectPacket: onSelectPacket
        )
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
        tableView.reloadData()
        context.coordinator.syncSelection(in: tableView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else {
            return
        }

        let previousIDs = context.coordinator.rows.map(\.id)
        let currentIDs = rows.map(\.id)
        let updatePlan = PacketTableUpdatePlanner.plan(
            previousIDs: previousIDs,
            currentIDs: currentIDs
        )

        context.coordinator.rows = rows
        context.coordinator.selectedPacketID = $selectedPacketID
        context.coordinator.onSelectPacket = onSelectPacket
        tableView.rowHeight = density.rowHeight

        switch updatePlan {
        case .none:
            break
        case .append(let range):
            tableView.insertRows(
                at: IndexSet(integersIn: range),
                withAnimation: []
            )
        case .reload:
            tableView.reloadData()
        }

        context.coordinator.syncSelection(in: tableView)
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
        var selectedPacketID: Binding<PacketSummary.ID?>
        var onSelectPacket: (PacketSummary.ID?) -> Void
        private var isApplyingSelection = false

        init(
            selectedPacketID: Binding<PacketSummary.ID?>,
            onSelectPacket: @escaping (PacketSummary.ID?) -> Void
        ) {
            self.selectedPacketID = selectedPacketID
            self.onSelectPacket = onSelectPacket
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
            guard !isApplyingSelection,
                  let tableView = notification.object as? NSTableView else {
                return
            }

            let selectedRow = tableView.selectedRow
            let selectedID = rows.indices.contains(selectedRow) ? rows[selectedRow].id : nil
            onSelectPacket(selectedID)
        }

        func syncSelection(in tableView: NSTableView) {
            isApplyingSelection = true
            defer {
                isApplyingSelection = false
            }

            guard let selectedPacketID = selectedPacketID.wrappedValue,
                  let rowIndex = rows.firstIndex(where: { $0.id == selectedPacketID }) else {
                tableView.deselectAll(nil)
                return
            }

            guard tableView.selectedRow != rowIndex else {
                return
            }

            tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(rowIndex)
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
