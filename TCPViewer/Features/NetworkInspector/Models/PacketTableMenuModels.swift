import Foundation

enum PacketTableColumnRole: String, Equatable, Sendable {
    case number
    case time
    case source
    case destination
    case domain
    case client
    case `protocol`
    case length
    case summary
    case tags
    case unknown

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
    let deleteEnabled: Bool
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
    static let columnOrder: [PacketTableColumnRole] = [
        .number,
        .time,
        .source,
        .destination,
        .domain,
        .client,
        .protocol,
        .length,
        .summary,
        .tags,
    ]

    static func csvRows(_ rows: [PacketTableRow]) -> String {
        rows
            .map { row in
                columnOrder.map { csvEscaped(row.text(for: $0)) }.joined(separator: ",")
            }
            .joined(separator: "\n")
    }

    static func csvCells(_ rows: [PacketTableRow], column: PacketTableColumnRole) -> String {
        rows
            .map { csvEscaped($0.text(for: column)) }
            .joined(separator: "\n")
    }

    private static func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
