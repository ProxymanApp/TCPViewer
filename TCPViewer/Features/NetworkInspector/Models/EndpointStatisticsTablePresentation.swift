//
//  EndpointStatisticsTablePresentation.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation

enum EndpointStatisticsTableColumn: String, CaseIterable, Sendable {
    case address
    case port
    case protocolName = "protocol"
    case client
    case domain
    case packets
    case bytes
    case txPackets
    case txBytes
    case rxPackets
    case rxBytes
    case summary

    var title: String {
        switch self {
        case .address: "Address"
        case .port: "Port"
        case .protocolName: "Protocol"
        case .client: "Client"
        case .domain: "Domain"
        case .packets: "Packets"
        case .bytes: "Bytes"
        case .txPackets: "Tx Packets"
        case .txBytes: "Tx Bytes"
        case .rxPackets: "Rx Packets"
        case .rxBytes: "Rx Bytes"
        case .summary: "Summary"
        }
    }

    var jsonKey: String {
        switch self {
        case .protocolName: "protocol"
        case .txPackets: "tx_packets"
        case .txBytes: "tx_bytes"
        case .rxPackets: "rx_packets"
        case .rxBytes: "rx_bytes"
        default: rawValue
        }
    }

    var isNumeric: Bool {
        switch self {
        case .packets, .bytes, .txPackets, .txBytes, .rxPackets, .rxBytes:
            true
        default:
            false
        }
    }

    func stringValue(in row: EndpointStatisticsRow) -> String {
        switch self {
        case .address: row.address ?? ""
        case .port: row.port ?? ""
        case .protocolName: row.protocolName ?? ""
        case .client: row.client ?? ""
        case .domain: row.domain ?? ""
        case .packets: String(row.packets)
        case .bytes: String(row.bytes)
        case .txPackets: String(row.txPackets)
        case .txBytes: String(row.txBytes)
        case .rxPackets: String(row.rxPackets)
        case .rxBytes: String(row.rxBytes)
        case .summary: row.summary
        }
    }

    func isAggregatePlaceholder(in row: EndpointStatisticsRow) -> Bool {
        switch self {
        case .address: row.isAddressMultiple
        case .port: row.isPortMultiple
        case .protocolName: row.isProtocolMultiple
        case .client: row.isClientMultiple
        case .domain: row.isDomainMultiple
        case .packets, .bytes, .txPackets, .txBytes, .rxPackets, .rxBytes, .summary: false
        }
    }

    fileprivate func stringSortValue(in row: EndpointStatisticsRow) -> String? {
        switch self {
        case .address: row.address
        case .port: row.port
        case .protocolName: row.protocolName
        case .client: row.client
        case .domain: row.domain
        case .summary: row.summary
        default: nil
        }
    }

    fileprivate func numericSortValue(in row: EndpointStatisticsRow) -> UInt64? {
        switch self {
        case .packets: row.packets
        case .bytes: row.bytes
        case .txPackets: row.txPackets
        case .txBytes: row.txBytes
        case .rxPackets: row.rxPackets
        case .rxBytes: row.rxBytes
        default: nil
        }
    }
}

struct EndpointStatisticsTableSort: Equatable, Sendable {
    let column: EndpointStatisticsTableColumn
    let isAscending: Bool

    static let busiestFirst = EndpointStatisticsTableSort(column: .bytes, isAscending: false)
}

struct EndpointStatisticsTablePresentation: Equatable, Sendable {
    let rows: [EndpointStatisticsRow]
    let rowIndexByID: [EndpointStatisticsRow.ID: Int]
    let unfilteredRowCount: Int
    let totals: EndpointStatisticsTotals
}

enum EndpointStatisticsSelectionRestoration {
    static func selectedRowIDs(
        rows: [EndpointStatisticsRow],
        selectedIndexes: IndexSet
    ) -> [EndpointStatisticsRow.ID] {
        guard !selectedIndexes.isEmpty else {
            return []
        }
        return selectedIndexes.compactMap { index in
            rows.indices.contains(index) ? rows[index].id : nil
        }
    }

    static func rowIndexes(
        for selectedRowIDs: [EndpointStatisticsRow.ID],
        rowIndexByID: [EndpointStatisticsRow.ID: Int]
    ) -> IndexSet {
        guard !selectedRowIDs.isEmpty else {
            return []
        }
        return IndexSet(selectedRowIDs.compactMap { rowIndexByID[$0] })
    }
}

struct EndpointStatisticsContextTarget: Equatable, Sendable {
    let rowID: EndpointStatisticsRow.ID?
    let column: EndpointStatisticsTableColumn?

    static let none = EndpointStatisticsContextTarget(rowID: nil, column: nil)

    func resolvedRowIndex(
        rowIndexByID: [EndpointStatisticsRow.ID: Int],
        rowCount: Int
    ) -> Int? {
        guard let rowID,
              let index = rowIndexByID[rowID],
              index >= 0,
              index < rowCount else {
            return nil
        }
        return index
    }
}

enum EndpointStatisticsRowSelection: Equatable, Sendable {
    case all
    case indexes(IndexSet)

    func isEmpty(rowCount: Int) -> Bool {
        switch self {
        case .all: rowCount == 0
        case .indexes(let indexes): indexes.isEmpty
        }
    }

    func firstIndex(rowCount: Int) -> Int? {
        switch self {
        case .all: rowCount > 0 ? 0 : nil
        case .indexes(let indexes): indexes.first(where: { $0 >= 0 && $0 < rowCount })
        }
    }

    func containsCopyableValue(
        in rows: [EndpointStatisticsRow],
        field: EndpointStatisticsSemanticCopyField
    ) -> Bool {
        switch self {
        case .all:
            return rows.contains { field.copyableValue(in: $0) != nil }
        case .indexes(let indexes):
            return indexes.contains { index in
                rows.indices.contains(index) && field.copyableValue(in: rows[index]) != nil
            }
        }
    }

    // Selected rows are resolved after leaving AppKit's main thread.
    func resolvedRows(
        from rows: [EndpointStatisticsRow],
        cancellationToken: EndpointStatisticsCancellationToken
    ) -> [EndpointStatisticsRow]? {
        guard !cancellationToken.isCancelled() else {
            return nil
        }
        switch self {
        case .all:
            return rows
        case .indexes(let indexes):
            var result: [EndpointStatisticsRow] = []
            result.reserveCapacity(min(indexes.count, rows.count))
            for (offset, index) in indexes.enumerated() {
                if offset.isMultiple(of: 256), cancellationToken.isCancelled() {
                    return nil
                }
                if rows.indices.contains(index) {
                    result.append(rows[index])
                }
            }
            return cancellationToken.isCancelled() ? nil : result
        }
    }
}

enum EndpointStatisticsSemanticCopyPolicy {
    static func copyableValue(_ value: String?, isAggregatePlaceholder: Bool = false) -> String? {
        guard let value, !value.isEmpty, !isAggregatePlaceholder else {
            return nil
        }
        return value
    }
}

enum EndpointStatisticsSemanticCopyField: Sendable {
    case address
    case domain
    case client

    func copyableValue(in row: EndpointStatisticsRow) -> String? {
        switch self {
        case .address:
            EndpointStatisticsSemanticCopyPolicy.copyableValue(
                row.address,
                isAggregatePlaceholder: row.isAddressMultiple
            )
        case .domain:
            EndpointStatisticsSemanticCopyPolicy.copyableValue(
                row.domain,
                isAggregatePlaceholder: row.isDomainMultiple
            )
        case .client:
            EndpointStatisticsSemanticCopyPolicy.copyableValue(
                row.client,
                isAggregatePlaceholder: row.isClientMultiple
            )
        }
    }
}

enum EndpointStatisticsSemanticValueFormatter {
    static func joinedValues(
        rows: [EndpointStatisticsRow],
        field: EndpointStatisticsSemanticCopyField,
        cancellationToken: EndpointStatisticsCancellationToken
    ) -> String? {
        guard !cancellationToken.isCancelled() else {
            return nil
        }
        var seen = Set<String>()
        var values: [String] = []
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256), cancellationToken.isCancelled() {
                return nil
            }
            if let value = field.copyableValue(in: row), seen.insert(value).inserted {
                values.append(value)
            }
        }
        return cancellationToken.isCancelled() ? nil : values.joined(separator: "\n")
    }
}

enum EndpointStatisticsTablePresenter {
    // Search every identity field, then sort with a stable endpoint-key tie breaker.
    static func presentation(
        rows: [EndpointStatisticsRow],
        searchText: String,
        sort: EndpointStatisticsTableSort
    ) -> EndpointStatisticsTablePresentation {
        presentation(
            rows: rows,
            searchText: searchText,
            sort: sort,
            cancellationToken: nil
        )!
    }

    static func presentation(
        rows: [EndpointStatisticsRow],
        searchText: String,
        sort: EndpointStatisticsTableSort,
        cancellationToken: EndpointStatisticsCancellationToken
    ) -> EndpointStatisticsTablePresentation? {
        presentation(
            rows: rows,
            searchText: searchText,
            sort: sort,
            cancellationToken: Optional(cancellationToken)
        )
    }

    private static func presentation(
        rows: [EndpointStatisticsRow],
        searchText: String,
        sort: EndpointStatisticsTableSort,
        cancellationToken: EndpointStatisticsCancellationToken?
    ) -> EndpointStatisticsTablePresentation? {
        let searchTerms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        var filteredRows: [EndpointStatisticsRow] = []
        filteredRows.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return nil
            }
            guard !searchTerms.isEmpty else {
                filteredRows.append(row)
                continue
            }
            let searchableText = [
                row.id.key,
                row.address,
                row.port,
                row.protocolName,
                row.client,
                row.domain,
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            if searchTerms.allSatisfy(searchableText.contains) {
                filteredRows.append(row)
            }
        }
        guard let sortedRows = cancellableSortedRows(
            filteredRows,
            sort: sort,
            cancellationToken: cancellationToken
        ),
        let totals = cancellableTotals(for: sortedRows, cancellationToken: cancellationToken) else {
            return nil
        }
        var rowIndexByID: [EndpointStatisticsRow.ID: Int] = [:]
        rowIndexByID.reserveCapacity(sortedRows.count)
        for (index, row) in sortedRows.enumerated() {
            if index.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return nil
            }
            rowIndexByID[row.id] = index
        }
        return EndpointStatisticsTablePresentation(
            rows: sortedRows,
            rowIndexByID: rowIndexByID,
            unfilteredRowCount: rows.count,
            totals: totals
        )
    }

    static func totals(for rows: [EndpointStatisticsRow]) -> EndpointStatisticsTotals {
        cancellableTotals(for: rows, cancellationToken: nil) ?? .zero
    }

    private static func cancellableTotals(
        for rows: [EndpointStatisticsRow],
        cancellationToken: EndpointStatisticsCancellationToken?
    ) -> EndpointStatisticsTotals? {
        var result = EndpointStatisticsTotals.zero
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return nil
            }
            result.packets = addingClamped(result.packets, row.packets)
            result.bytes = addingClamped(result.bytes, row.bytes)
            result.txPackets = addingClamped(result.txPackets, row.txPackets)
            result.txBytes = addingClamped(result.txBytes, row.txBytes)
            result.rxPackets = addingClamped(result.rxPackets, row.rxPackets)
            result.rxBytes = addingClamped(result.rxBytes, row.rxBytes)
            result.unclassifiedPackets = addingClamped(result.unclassifiedPackets, row.unclassifiedPackets)
            result.unclassifiedBytes = addingClamped(result.unclassifiedBytes, row.unclassifiedBytes)
        }
        return result
    }

    // A bottom-up merge sort checks cancellation without retaining the window controller.
    private static func cancellableSortedRows(
        _ rows: [EndpointStatisticsRow],
        sort: EndpointStatisticsTableSort,
        cancellationToken: EndpointStatisticsCancellationToken?
    ) -> [EndpointStatisticsRow]? {
        guard rows.count > 1 else {
            return cancellationToken?.isCancelled() == true ? nil : rows
        }
        var source = rows
        var destination = rows
        var width = 1
        var comparisonCount = 0
        while width < source.count {
            var start = 0
            while start < source.count {
                if cancellationToken?.isCancelled() == true {
                    return nil
                }
                let middle = min(start + width, source.count)
                let end = min(start + width + width, source.count)
                var left = start
                var right = middle
                var output = start
                while left < middle || right < end {
                    comparisonCount &+= 1
                    if comparisonCount.isMultiple(of: 256),
                       cancellationToken?.isCancelled() == true {
                        return nil
                    }
                    if right >= end ||
                        (left < middle && !isOrderedBefore(source[right], source[left], sort: sort)) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                start = end
            }
            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
        }
        return cancellationToken?.isCancelled() == true ? nil : source
    }

    private static func isOrderedBefore(
        _ lhs: EndpointStatisticsRow,
        _ rhs: EndpointStatisticsRow,
        sort: EndpointStatisticsTableSort
    ) -> Bool {
        let comparison: ComparisonResult
        if let lhsNumber = sort.column.numericSortValue(in: lhs),
           let rhsNumber = sort.column.numericSortValue(in: rhs) {
            comparison = lhsNumber == rhsNumber ? .orderedSame : (lhsNumber < rhsNumber ? .orderedAscending : .orderedDescending)
        } else if sort.column == .summary {
            comparison = compareSummary(lhs, rhs)
        } else {
            let lhsValue = sort.column.stringSortValue(in: lhs)
            let rhsValue = sort.column.stringSortValue(in: rhs)
            if lhsValue == nil || rhsValue == nil {
                if lhsValue == nil, rhsValue != nil {
                    return false
                }
                if lhsValue != nil, rhsValue == nil {
                    return true
                }
                comparison = .orderedSame
            } else if sort.column == .port,
                      let lhsPort = UInt64(lhsValue!),
                      let rhsPort = UInt64(rhsValue!) {
                comparison = lhsPort == rhsPort ? .orderedSame : (lhsPort < rhsPort ? .orderedAscending : .orderedDescending)
            } else {
                comparison = lhsValue!.localizedStandardCompare(rhsValue!)
            }
        }

        if comparison == .orderedSame {
            return lhs.id.key.localizedStandardCompare(rhs.id.key) == .orderedAscending
        }
        return sort.isAscending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private static func compareSummary(
        _ lhs: EndpointStatisticsRow,
        _ rhs: EndpointStatisticsRow
    ) -> ComparisonResult {
        let lhsTotal = Double(lhs.txBytes) + Double(lhs.rxBytes) + Double(lhs.unclassifiedBytes)
        let rhsTotal = Double(rhs.txBytes) + Double(rhs.rxBytes) + Double(rhs.unclassifiedBytes)
        let lhsShare = lhsTotal == 0 ? 0 : Double(lhs.txBytes) / lhsTotal
        let rhsShare = rhsTotal == 0 ? 0 : Double(rhs.txBytes) / rhsTotal
        if lhsShare == rhsShare {
            return .orderedSame
        }
        return lhsShare < rhsShare ? .orderedAscending : .orderedDescending
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

enum EndpointStatisticsTableExportFormatter {
    static func csv(
        rows: [EndpointStatisticsRow],
        columns: [EndpointStatisticsTableColumn]
    ) -> String {
        csv(rows: rows, columns: columns, cancellationToken: nil) ?? ""
    }

    static func csv(
        rows: [EndpointStatisticsRow],
        columns: [EndpointStatisticsTableColumn],
        cancellationToken: EndpointStatisticsCancellationToken
    ) -> String? {
        csv(rows: rows, columns: columns, cancellationToken: Optional(cancellationToken))
    }

    private static func csv(
        rows: [EndpointStatisticsRow],
        columns: [EndpointStatisticsTableColumn],
        cancellationToken: EndpointStatisticsCancellationToken?
    ) -> String? {
        guard !columns.isEmpty else {
            return ""
        }
        guard cancellationToken?.isCancelled() != true else {
            return nil
        }
        let header = columns.map { csvField($0.title, protectsFormula: false) }.joined(separator: ",")
        var lines = [header]
        lines.reserveCapacity(rows.count + 1)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return nil
            }
            lines.append(columns.map { column in
                csvField(column.stringValue(in: row), protectsFormula: !column.isNumeric)
            }.joined(separator: ","))
        }
        return cancellationToken?.isCancelled() == true ? nil : lines.joined(separator: "\r\n")
    }

    static func json(
        rows: [EndpointStatisticsRow],
        columns: [EndpointStatisticsTableColumn]
    ) -> String {
        json(rows: rows, columns: columns, cancellationToken: nil) ?? "[]"
    }

    static func json(
        rows: [EndpointStatisticsRow],
        columns: [EndpointStatisticsTableColumn],
        cancellationToken: EndpointStatisticsCancellationToken
    ) -> String? {
        json(rows: rows, columns: columns, cancellationToken: Optional(cancellationToken))
    }

    // Build JSON incrementally so cancellation never waits behind one monolithic encoder pass.
    private static func json(
        rows: [EndpointStatisticsRow],
        columns: [EndpointStatisticsTableColumn],
        cancellationToken: EndpointStatisticsCancellationToken?
    ) -> String? {
        guard cancellationToken?.isCancelled() != true else {
            return nil
        }
        guard !rows.isEmpty else {
            return "[]"
        }
        var result = "[\n"
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return nil
            }
            if rowIndex > 0 {
                result.append(",\n")
            }
            if columns.isEmpty {
                result.append("  {}")
                continue
            }
            result.append("  {\n")
            for (columnIndex, column) in columns.enumerated() {
                if columnIndex > 0 {
                    result.append(",\n")
                }
                result.append("    \(jsonString(column.jsonKey)): \(jsonValue(column: column, row: row))")
            }
            result.append("\n  }")
        }
        result.append("\n]")
        return cancellationToken?.isCancelled() == true ? nil : result
    }

    private static func csvField(_ value: String, protectsFormula: Bool) -> String {
        let protectedValue = protectsFormula && needsFormulaProtection(value) ? "'\(value)" : value
        guard protectedValue.contains(",") || protectedValue.contains("\"") || protectedValue.contains("\r") || protectedValue.contains("\n") else {
            return protectedValue
        }
        return "\"\(protectedValue.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func needsFormulaProtection(_ value: String) -> Bool {
        if let first = value.first, first == "\t" || first == "\r" {
            return true
        }
        let firstNonWhitespace = value.drop(while: \.isWhitespace).first
        guard let first = firstNonWhitespace else {
            return false
        }
        return "=+-@".contains(first)
    }

    private static func jsonValue(
        column: EndpointStatisticsTableColumn,
        row: EndpointStatisticsRow
    ) -> String {
        switch column {
        case .packets: String(row.packets)
        case .bytes: String(row.bytes)
        case .txPackets: String(row.txPackets)
        case .txBytes: String(row.txBytes)
        case .rxPackets: String(row.rxPackets)
        case .rxBytes: String(row.rxBytes)
        default: jsonString(column.stringValue(in: row))
        }
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        result.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result.append("\\\"")
            case 0x5C: result.append("\\\\")
            case 0x08: result.append("\\b")
            case 0x0C: result.append("\\f")
            case 0x0A: result.append("\\n")
            case 0x0D: result.append("\\r")
            case 0x09: result.append("\\t")
            case 0x00...0x1F: result.append(String(format: "\\u%04x", scalar.value))
            default: result.unicodeScalars.append(scalar)
            }
        }
        result.append("\"")
        return result
    }
}
