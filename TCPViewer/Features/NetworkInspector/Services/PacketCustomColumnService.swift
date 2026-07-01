//
//  PacketCustomColumnService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/7/26.
//

import Foundation
import PcapPlusPlusCore

struct PacketCustomColumn: Codable, Equatable, Sendable {
    let identifier: String
    let fieldName: String
    let title: String
    let defaultWidth: Double
    let minimumWidth: Double

    init(
        identifier: String,
        fieldName: String,
        title: String,
        defaultWidth: Double = 140,
        minimumWidth: Double = 90
    ) {
        self.identifier = identifier
        self.fieldName = fieldName
        self.title = title
        self.defaultWidth = defaultWidth
        self.minimumWidth = minimumWidth
    }
}

struct PacketCustomColumnRequest: Equatable, Sendable {
    let fieldName: String
    let title: String
    let packetID: PacketSummary.ID?
    let sampleValue: String?
}

enum PacketCustomColumnCreationResult: Equatable {
    case created(PacketCustomColumn)
    case existing(PacketCustomColumn)
    case invalid

    var column: PacketCustomColumn? {
        switch self {
        case .created(let column), .existing(let column):
            return column
        case .invalid:
            return nil
        }
    }

    var didCreate: Bool {
        if case .created = self {
            return true
        }

        return false
    }
}

final class PacketCustomColumnService {
    private(set) var columns: [PacketCustomColumn]
    private var valuesByColumnID: [String: [PacketSummary.ID: String]] = [:]

    init(columns: [PacketCustomColumn] = []) {
        self.columns = Self.uniqueColumns(columns)
    }

    // Create or reveal an existing column for the normalized protocol field name.
    @discardableResult
    func createColumn(from request: PacketCustomColumnRequest) -> PacketCustomColumnCreationResult {
        guard let normalizedFieldName = Self.normalizedFieldName(request.fieldName) else {
            return .invalid
        }

        if let existingColumn = columns.first(where: { Self.normalizedFieldName($0.fieldName) == normalizedFieldName }) {
            storeSampleValue(from: request, column: existingColumn)
            return .existing(existingColumn)
        }

        let column = PacketCustomColumn(
            identifier: Self.identifier(forNormalizedFieldName: normalizedFieldName),
            fieldName: normalizedFieldName,
            title: Self.title(from: request.title, fieldName: normalizedFieldName)
        )
        columns.append(column)
        storeSampleValue(from: request, column: column)
        return .created(column)
    }

    func restoreColumns(_ columns: [PacketCustomColumn]) {
        self.columns = Self.uniqueColumns(columns)
        valuesByColumnID = valuesByColumnID.filter { columnID, _ in
            self.columns.contains { $0.identifier == columnID }
        }
    }

    func reset() {
        columns = []
        valuesByColumnID = [:]
    }

    func value(columnIdentifier: String, packetID: PacketSummary.ID) -> String? {
        valuesByColumnID[columnIdentifier]?[packetID]
    }

    func hasResolvedValue(columnIdentifier: String, packetID: PacketSummary.ID) -> Bool {
        valuesByColumnID[columnIdentifier]?[packetID] != nil
    }

    func storeValue(_ value: String, columnIdentifier: String, packetID: PacketSummary.ID) {
        valuesByColumnID[columnIdentifier, default: [:]][packetID] = value
    }

    func clearValues() {
        valuesByColumnID = [:]
    }

    // Return unresolved packet IDs from an already-bounded packet list.
    func unresolvedPacketIDs(
        for column: PacketCustomColumn,
        packetIDs: [PacketSummary.ID]
    ) -> [PacketSummary.ID] {
        var seenIDs = Set<PacketSummary.ID>()
        return packetIDs.filter { packetID in
            seenIDs.insert(packetID).inserted &&
                !hasResolvedValue(columnIdentifier: column.identifier, packetID: packetID)
        }
    }

    // Return unresolved packet IDs with visible/current rows first, then the remaining rows.
    func unresolvedPacketIDs(
        for column: PacketCustomColumn,
        rows: [PacketTableRow],
        preferredPacketIDs: [PacketSummary.ID]
    ) -> [PacketSummary.ID] {
        let rowIDs = rows.map(\.id)
        let rowIDSet = Set(rowIDs)
        var seenIDs = Set<PacketSummary.ID>()
        var orderedIDs: [PacketSummary.ID] = []

        for packetID in preferredPacketIDs where rowIDSet.contains(packetID) && seenIDs.insert(packetID).inserted {
            orderedIDs.append(packetID)
        }

        for packetID in rowIDs where seenIDs.insert(packetID).inserted {
            orderedIDs.append(packetID)
        }

        return orderedIDs.filter {
            !hasResolvedValue(columnIdentifier: column.identifier, packetID: $0)
        }
    }

    static func resolvedValue(fieldName: String, in inspection: PacketInspection) -> String {
        guard let normalizedFieldName = normalizedFieldName(fieldName),
              let node = firstNode(matching: normalizedFieldName, in: inspection.detailNodes) else {
            return ""
        }

        return node.value ?? node.rawValue ?? ""
    }

    static func normalizedFieldName(_ fieldName: String) -> String? {
        let normalized = fieldName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func identifier(forNormalizedFieldName fieldName: String) -> String {
        let sanitized = fieldName
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" {
                    return character
                }

                return "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }

                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return "custom.field.\(sanitized.isEmpty ? "field" : sanitized)"
    }

    private static func title(from value: String, fieldName: String) -> String {
        let trimmedTitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        return fieldName
    }

    private static func firstNode(matching normalizedFieldName: String, in nodes: [PacketDetailNode]) -> PacketDetailNode? {
        for node in nodes {
            if self.normalizedFieldName(node.fieldName) == normalizedFieldName {
                return node
            }

            if let match = firstNode(matching: normalizedFieldName, in: node.children) {
                return match
            }
        }

        return nil
    }

    private static func uniqueColumns(_ columns: [PacketCustomColumn]) -> [PacketCustomColumn] {
        var seenFieldNames = Set<String>()
        return columns.filter { column in
            guard let normalizedFieldName = normalizedFieldName(column.fieldName) else {
                return false
            }

            return seenFieldNames.insert(normalizedFieldName).inserted
        }
    }

    private func storeSampleValue(from request: PacketCustomColumnRequest, column: PacketCustomColumn) {
        guard let packetID = request.packetID,
              let sampleValue = request.sampleValue else {
            return
        }

        storeValue(sampleValue, columnIdentifier: column.identifier, packetID: packetID)
    }
}
