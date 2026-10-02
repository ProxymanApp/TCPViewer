//
//  PacketTablePresentation.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit

// Both packet tables use the same native cells, spacing, and appearance rules.
enum PacketTablePresentation {
    static func configure(_ tableView: NSTableView, configuration: AppConfiguration) {
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
    }

    static func column(_ definition: PacketTableColumnDefinition) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.identifier))
        column.title = definition.tableTitle
        column.width = CGFloat(definition.defaultWidth)
        column.minWidth = CGFloat(definition.minimumWidth)
        column.resizingMask = definition.role == .comment ? [.userResizingMask, .autoresizingMask] : .userResizingMask
        switch definition.cellKind {
        case .text: column.dataCell = PacketTextCell()
        case .client: column.dataCell = PacketClientCell()
        case .protocol: column.dataCell = PacketProtocolCell()
        }
        return column
    }

    static func configure(_ cell: Any, column: String, row: PacketTableRow, configuration: AppConfiguration) {
        if let cell = cell as? PacketProtocolCell {
            cell.configure(protocolText: row.protocolText, severity: row.severity, textStyle: row.textStyle, configuration: configuration)
        } else if let cell = cell as? PacketClientCell {
            cell.configure(displayName: row.clientText, iconFilePath: row.clientIconFilePath, textStyle: row.textStyle, configuration: configuration)
        } else if let cell = cell as? PacketTextCell {
            cell.configure(style: textStyle(for: column, in: row), textStyle: row.textStyle, configuration: configuration)
        }
    }

    static func textStyle(for column: String, in row: PacketTableRow) -> PacketTextCell.Style {
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

}
