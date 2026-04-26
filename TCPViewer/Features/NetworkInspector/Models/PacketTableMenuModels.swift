import Foundation

enum PacketTableColumnRole: String, Equatable, Sendable {
    case number
    case time
    case source
    case destination
    case sourcePort
    case destinationPort
    case domain
    case client
    case `protocol`
    case streamID
    case direction
    case deltaTime
    case streamDeltaTime
    case tcpFlags
    case tcpPayloadBytes
    case pid
    case bundleIdentifier
    case decodeStatus
    case interface
    case length
    case summary
    case tags
    case unknown

    static let visibleColumnIdentifiers = PacketTableColumnService.defaultDefinitions
        .filter(\.isDefaultVisible)
        .map(\.identifier)

    init(columnIdentifier: String?) {
        guard let columnIdentifier else {
            self = .unknown
            return
        }

        self = PacketTableColumnRole(rawValue: columnIdentifier) ?? .unknown
    }
}

struct PacketTableMenuState: Equatable {
    let targetRows: [Int]
    let clickedColumn: PacketTableColumnRole
    let copyRowEnabled: Bool
    let copyCellEnabled: Bool
    let pinDomainEnabled: Bool
    let pinIPEnabled: Bool
    let pinClientEnabled: Bool
    let saveEnabled: Bool
    let exportEnabled: Bool
    let deleteEnabled: Bool

    static let empty = PacketTableMenuState(
        targetRows: [],
        clickedColumn: .unknown,
        copyRowEnabled: false,
        copyCellEnabled: false,
        pinDomainEnabled: false,
        pinIPEnabled: false,
        pinClientEnabled: false,
        saveEnabled: false,
        exportEnabled: false,
        deleteEnabled: false
    )
}

enum PacketTableCopyFormat: Equatable, Sendable {
    case plainText
    case json
    case markdownTable
    case csv
    case csvWithHeader
}

enum PacketTableMenuLogic {
    static func state(
        rows: [PacketTableRow],
        selectedRowIndexes: IndexSet,
        clickedRowIndex: Int?,
        clickedColumnIdentifier: String?
    ) -> PacketTableMenuState {
        let targetIndexes = targetRowIndexes(
            rowCount: rows.count,
            selectedRowIndexes: selectedRowIndexes,
            clickedRowIndex: clickedRowIndex
        )
        let targetRows = targetIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        let clickedColumn = PacketTableColumnRole(columnIdentifier: clickedColumnIdentifier)
        let singleRow = targetRows.count == 1 ? targetRows[0] : nil

        return PacketTableMenuState(
            targetRows: targetIndexes,
            clickedColumn: clickedColumn,
            copyRowEnabled: !targetRows.isEmpty,
            copyCellEnabled: !targetRows.isEmpty && clickedColumn != .unknown,
            pinDomainEnabled: singleRow?.canPinDomain == true,
            pinIPEnabled: singleRow?.ipAddress(for: clickedColumn) != nil,
            pinClientEnabled: singleRow?.canPinClient == true,
            saveEnabled: !targetRows.isEmpty,
            exportEnabled: !targetRows.isEmpty,
            deleteEnabled: !targetRows.isEmpty
        )
    }

    private static func targetRowIndexes(
        rowCount: Int,
        selectedRowIndexes: IndexSet,
        clickedRowIndex: Int?
    ) -> [Int] {
        if let clickedRowIndex, clickedRowIndex >= 0, clickedRowIndex < rowCount {
            if selectedRowIndexes.contains(clickedRowIndex) {
                return selectedRowIndexes.filter { $0 >= 0 && $0 < rowCount }
            }

            return [clickedRowIndex]
        }

        return selectedRowIndexes.filter { $0 >= 0 && $0 < rowCount }
    }
}

enum PacketTableCopyFormatter {
    private struct CopyColumn {
        let role: PacketTableColumnRole
        let title: String
    }

    private struct JSONRow: Encodable {
        let number: String
        let time: String
        let source: String
        let destination: String
        let domain: String
        let client: String
        let `protocol`: String
        let length: String
        let summary: String
        let tags: String

        init(row: PacketTableRow) {
            self.number = row.text(for: .number)
            self.time = row.text(for: .time)
            self.source = row.text(for: .source)
            self.destination = row.text(for: .destination)
            self.domain = row.text(for: .domain)
            self.client = row.text(for: .client)
            self.protocol = row.text(for: .protocol)
            self.length = row.text(for: .length)
            self.summary = row.text(for: .summary)
            self.tags = row.text(for: .tags)
        }
    }

    private static let copyColumns: [CopyColumn] = [
        CopyColumn(role: .number, title: "#"),
        CopyColumn(role: .time, title: "Time"),
        CopyColumn(role: .source, title: "Source"),
        CopyColumn(role: .destination, title: "Destination"),
        CopyColumn(role: .domain, title: "Domain"),
        CopyColumn(role: .client, title: "Client"),
        CopyColumn(role: .protocol, title: "Protocol"),
        CopyColumn(role: .length, title: "Length"),
        CopyColumn(role: .summary, title: "Summary"),
        CopyColumn(role: .tags, title: "Tags"),
    ]

    static let columnOrder: [PacketTableColumnRole] = copyColumns.map(\.role)

    // Format packet rows for the requested copy menu action.
    static func rows(_ rows: [PacketTableRow], format: PacketTableCopyFormat) -> String {
        switch format {
        case .plainText:
            plainTextRows(rows)
        case .json:
            jsonRows(rows)
        case .markdownTable:
            markdownTableRows(rows)
        case .csv:
            csvRows(rows)
        case .csvWithHeader:
            csvRowsWithHeader(rows)
        }
    }

    // Build tab-separated row text for lightweight plain-text pasting.
    static func plainTextRows(_ rows: [PacketTableRow]) -> String {
        rows
            .map { row in
                copyColumns.map { plainTextEscaped(row.text(for: $0.role)) }.joined(separator: "\t")
            }
            .joined(separator: "\n")
    }

    // Build a JSON array with stable packet-table field names.
    static func jsonRows(_ rows: [PacketTableRow]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        guard let data = try? encoder.encode(rows.map(JSONRow.init(row:))),
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }

        return value
    }

    // Build a GitHub-flavored Markdown table with escaped cell separators.
    static func markdownTableRows(_ rows: [PacketTableRow]) -> String {
        let header = "| " + copyColumns.map(\.title).joined(separator: " | ") + " |"
        let separator = "| " + copyColumns.map { _ in "---" }.joined(separator: " | ") + " |"
        let body = rows
            .map { row in
                "| " + copyColumns.map { markdownEscaped(row.text(for: $0.role)) }.joined(separator: " | ") + " |"
            }
            .joined(separator: "\n")

        return body.isEmpty ? "\(header)\n\(separator)" : "\(header)\n\(separator)\n\(body)"
    }

    // Build CSV row text without headers for the legacy Copy action.
    static func csvRows(_ rows: [PacketTableRow]) -> String {
        rows
            .map { row in
                columnOrder.map { csvEscaped(row.text(for: $0)) }.joined(separator: ",")
            }
            .joined(separator: "\n")
    }

    // Build CSV row text prefixed by the visible packet-table column headers.
    static func csvRowsWithHeader(_ rows: [PacketTableRow]) -> String {
        ([copyColumns.map { csvEscaped($0.title) }.joined(separator: ",")] + [csvRows(rows)])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // Build newline-separated values from the clicked table column.
    static func csvCells(_ rows: [PacketTableRow], column: PacketTableColumnRole) -> String {
        rows
            .map { csvEscaped($0.text(for: column)) }
            .joined(separator: "\n")
    }

    private static func plainTextEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func markdownEscaped(_ value: String) -> String {
        plainTextEscaped(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
