//
//  PacketTableColumnService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/4/26.
//

import Foundation

enum PacketTableColumnSource: Equatable {
    case builtIn(PacketTableColumnRole)
    case custom(identifier: String)

    var identifier: String {
        switch self {
        case .builtIn(let role):
            role.rawValue
        case .custom(let identifier):
            identifier
        }
    }

    var role: PacketTableColumnRole {
        switch self {
        case .builtIn(let role):
            role
        case .custom:
            .unknown
        }
    }
}

enum PacketTableColumnCellKind: Equatable {
    case text
    case client
    case `protocol`
}

struct PacketTableColumnDefinition: Equatable {
    let source: PacketTableColumnSource
    let title: String
    let defaultWidth: Double
    let minimumWidth: Double
    let cellKind: PacketTableColumnCellKind
    let isDefaultVisible: Bool
    let canUserHide: Bool

    var identifier: String {
        source.identifier
    }

    var role: PacketTableColumnRole {
        source.role
    }

    var tableTitle: String {
        " \(title)"
    }

    static func builtIn(
        _ role: PacketTableColumnRole,
        title: String,
        defaultWidth: Double,
        minimumWidth: Double,
        cellKind: PacketTableColumnCellKind = .text,
        isDefaultVisible: Bool = true,
        canUserHide: Bool = true
    ) -> PacketTableColumnDefinition {
        PacketTableColumnDefinition(
            source: .builtIn(role),
            title: title,
            defaultWidth: defaultWidth,
            minimumWidth: minimumWidth,
            cellKind: cellKind,
            isDefaultVisible: isDefaultVisible,
            canUserHide: canUserHide
        )
    }

    static func custom(
        identifier: String,
        title: String,
        defaultWidth: Double,
        minimumWidth: Double,
        cellKind: PacketTableColumnCellKind = .text,
        isDefaultVisible: Bool = false,
        canUserHide: Bool = true
    ) -> PacketTableColumnDefinition {
        PacketTableColumnDefinition(
            source: .custom(identifier: identifier),
            title: title,
            defaultWidth: defaultWidth,
            minimumWidth: minimumWidth,
            cellKind: cellKind,
            isDefaultVisible: isDefaultVisible,
            canUserHide: canUserHide
        )
    }
}

struct PacketTableColumnMenuEntry: Equatable {
    let identifier: String
    let title: String
    let isVisible: Bool
    let isEnabled: Bool
}

struct PacketTableColumnLayout: Codable, Equatable {
    struct Column: Codable, Equatable {
        let identifier: String
        let isVisible: Bool
        let width: Double
    }

    static let currentVersion = 1

    let version: Int
    let columns: [Column]

    init(version: Int = PacketTableColumnLayout.currentVersion, columns: [Column]) {
        self.version = version
        self.columns = columns
    }
}

struct PacketTableColumnLayoutStore {
    private static let defaultKey = "TCPViewer.packetTable.columnLayout.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = PacketTableColumnLayoutStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PacketTableColumnLayout? {
        guard let data = defaults.data(forKey: key),
              let layout = try? JSONDecoder().decode(PacketTableColumnLayout.self, from: data),
              layout.version == PacketTableColumnLayout.currentVersion else {
            return nil
        }

        return layout
    }

    func save(_ layout: PacketTableColumnLayout) {
        guard let data = try? JSONEncoder().encode(layout) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

final class PacketTableColumnService {
    static let defaultDefinitions: [PacketTableColumnDefinition] = [
        .builtIn(.number, title: "#", defaultWidth: 68, minimumWidth: 52),
        .builtIn(.time, title: "Time", defaultWidth: 112, minimumWidth: 96),
        .builtIn(.source, title: "Source", defaultWidth: 180, minimumWidth: 100),
        .builtIn(.destination, title: "Destination", defaultWidth: 180, minimumWidth: 100),
        .builtIn(.sourcePort, title: "Source Port", defaultWidth: 92, minimumWidth: 76, isDefaultVisible: false),
        .builtIn(.destinationPort, title: "Destination Port", defaultWidth: 118, minimumWidth: 92, isDefaultVisible: false),
        .builtIn(.protocol, title: "Protocol", defaultWidth: 96, minimumWidth: 82, cellKind: .protocol),
        .builtIn(.client, title: "Client", defaultWidth: 140, minimumWidth: 60, cellKind: .client),
        .builtIn(.domain, title: "Domain", defaultWidth: 150, minimumWidth: 60),
        .builtIn(.streamID, title: "Stream ID", defaultWidth: 96, minimumWidth: 76, isDefaultVisible: false),
        .builtIn(.direction, title: "Direction", defaultWidth: 90, minimumWidth: 76, isDefaultVisible: false),
        .builtIn(.deltaTime, title: "Delta Time", defaultWidth: 96, minimumWidth: 78, isDefaultVisible: false),
        .builtIn(.streamDeltaTime, title: "Stream Delta", defaultWidth: 106, minimumWidth: 88, isDefaultVisible: false),
        .builtIn(.tcpFlags, title: "TCP Flags", defaultWidth: 118, minimumWidth: 88, isDefaultVisible: false),
        .builtIn(.tcpPayloadBytes, title: "TCP Payload", defaultWidth: 104, minimumWidth: 86, isDefaultVisible: false),
        .builtIn(.pid, title: "PID", defaultWidth: 76, minimumWidth: 58, isDefaultVisible: false),
        .builtIn(.bundleIdentifier, title: "Bundle ID", defaultWidth: 220, minimumWidth: 120, isDefaultVisible: false),
        .builtIn(.decodeStatus, title: "Decode Status", defaultWidth: 120, minimumWidth: 96, isDefaultVisible: false),
        .builtIn(.interface, title: "Interface", defaultWidth: 112, minimumWidth: 84, isDefaultVisible: false),
        .builtIn(.length, title: "Length", defaultWidth: 80, minimumWidth: 68),
        .builtIn(.summary, title: "Summary", defaultWidth: 320, minimumWidth: 120),
        .builtIn(.tags, title: "Tags", defaultWidth: 140, minimumWidth: 90),
    ]

    let definitions: [PacketTableColumnDefinition]
    private var visibilityByIdentifier: [String: Bool]

    // Start each known column from its declared default visibility.
    init(definitions: [PacketTableColumnDefinition] = PacketTableColumnService.defaultDefinitions) {
        self.definitions = Self.uniqueDefinitions(definitions)
        self.visibilityByIdentifier = Dictionary(
            uniqueKeysWithValues: self.definitions.map { ($0.identifier, $0.isDefaultVisible) }
        )
    }

    var visibleColumnIdentifiers: [String] {
        definitions.compactMap { isColumnVisible(identifier: $0.identifier) ? $0.identifier : nil }
    }

    var menuEntries: [PacketTableColumnMenuEntry] {
        definitions.map { definition in
            PacketTableColumnMenuEntry(
                identifier: definition.identifier,
                title: definition.title,
                isVisible: isColumnVisible(identifier: definition.identifier),
                isEnabled: canToggleColumnVisibility(identifier: definition.identifier)
            )
        }
    }

    func definition(identifier: String) -> PacketTableColumnDefinition? {
        definitions.first { $0.identifier == identifier }
    }

    func isColumnVisible(identifier: String) -> Bool {
        visibilityByIdentifier[identifier] ?? false
    }

    func canToggleColumnVisibility(identifier: String) -> Bool {
        guard let definition = definition(identifier: identifier) else {
            return false
        }

        if isColumnVisible(identifier: identifier), visibleColumnIdentifiers.count <= 1 {
            return false
        }

        return definition.canUserHide
    }

    // Toggle a known column while keeping at least one table column visible.
    @discardableResult
    func toggleColumnVisibility(identifier: String) -> Bool {
        guard visibilityByIdentifier[identifier] != nil else {
            return false
        }

        return setColumnVisibility(identifier: identifier, isVisible: !isColumnVisible(identifier: identifier))
    }

    // Set explicit visibility for built-in or future custom columns.
    @discardableResult
    func setColumnVisibility(identifier: String, isVisible: Bool) -> Bool {
        guard let definition = definition(identifier: identifier) else {
            return false
        }

        if !isVisible {
            guard definition.canUserHide, visibleColumnIdentifiers.count > 1 else {
                return false
            }
        }

        visibilityByIdentifier[identifier] = isVisible
        return true
    }

    // Restore each column to the initial visibility declared by the catalog.
    func resetToDefaults() {
        definitions.forEach { definition in
            visibilityByIdentifier[definition.identifier] = definition.isDefaultVisible
        }
    }

    // Apply persisted visibility while ignoring stale or unknown column identifiers.
    func applyVisibility(from layout: PacketTableColumnLayout) {
        var nextVisibility = visibilityByIdentifier
        layout.columns.forEach { column in
            guard let definition = definition(identifier: column.identifier) else {
                return
            }

            nextVisibility[column.identifier] = column.isVisible || !definition.canUserHide
        }

        guard definitions.contains(where: { nextVisibility[$0.identifier] == true }) else {
            return
        }

        visibilityByIdentifier = nextVisibility
    }

    // Reflect AppKit-restored autosave state back into the service.
    func syncColumnVisibility(identifier: String, isVisible: Bool) {
        guard visibilityByIdentifier[identifier] != nil else {
            return
        }

        visibilityByIdentifier[identifier] = isVisible
    }

    // Keep the first definition for duplicate IDs so future custom columns cannot shadow built-ins.
    private static func uniqueDefinitions(_ definitions: [PacketTableColumnDefinition]) -> [PacketTableColumnDefinition] {
        var seenIdentifiers = Set<String>()
        return definitions.filter { definition in
            seenIdentifiers.insert(definition.identifier).inserted
        }
    }
}
