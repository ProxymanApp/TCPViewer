//
//  PacketCustomFilterService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/6/26.
//

import Foundation

struct PacketCustomFilter: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var group: PacketStructuredFilterGroup
}

enum PacketCustomFilterValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case nameTooLong(maxLength: Int)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a custom filter name."
        case .nameTooLong(let maxLength):
            return "Custom filter names must be \(maxLength) characters or fewer."
        }
    }
}

final class PacketCustomFilterService {
    static let maxNameLength = 40

    private let storageURL: URL
    private let fileManager: FileManager
    private let userDataDirectory: TCPViewerUserDataDirectory
    private let usesUserDataDirectoryStorage: Bool
    private var cachedFilters: [PacketCustomFilter]

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        userDataDirectory: TCPViewerUserDataDirectory = .shared
    ) {
        self.userDataDirectory = userDataDirectory
        self.usesUserDataDirectoryStorage = storageURL == nil
        self.storageURL = storageURL ?? PacketCustomFilterService.defaultStorageURL(userDataDirectory: userDataDirectory)
        self.fileManager = fileManager
        self.cachedFilters = (try? Self.loadFilters(from: self.storageURL, fileManager: fileManager)) ?? []
    }

    // Return cached filters in saved order for stable titlebar rendering.
    func filters() -> [PacketCustomFilter] {
        cachedFilters
    }

    // Look up a saved filter by stable identifier for quick button actions.
    func filter(id: PacketCustomFilter.ID) -> PacketCustomFilter? {
        cachedFilters.first { $0.id == id }
    }

    // Validate and trim display names before they reach disk or UI snapshots.
    static func normalizedName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PacketCustomFilterValidationError.emptyName
        }
        guard trimmedName.count <= maxNameLength else {
            throw PacketCustomFilterValidationError.nameTooLong(maxLength: maxNameLength)
        }
        return trimmedName
    }

    // Append a new custom filter while allowing duplicate display names by design.
    @discardableResult
    func save(name: String, group: PacketStructuredFilterGroup, now: Date = Date()) throws -> PacketCustomFilter {
        let normalizedName = try Self.normalizedName(name)
        let filter = PacketCustomFilter(
            id: UUID().uuidString,
            name: normalizedName,
            createdAt: now,
            updatedAt: now,
            group: PacketStructuredFilterGroup(filters: group.filters, operator: group.operator)
        )
        cachedFilters.append(filter)
        do {
            try persist()
        } catch {
            cachedFilters.removeAll { $0.id == filter.id }
            throw error
        }
        return filter
    }

    // Rename one saved filter without changing the structured filter payload.
    func rename(id: PacketCustomFilter.ID, name: String, now: Date = Date()) throws {
        guard let index = cachedFilters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let normalizedName = try Self.normalizedName(name)
        let previousFilter = cachedFilters[index]
        cachedFilters[index].name = normalizedName
        cachedFilters[index].updatedAt = now
        do {
            try persist()
        } catch {
            cachedFilters[index] = previousFilter
            throw error
        }
    }

    // Replace a saved filter payload while keeping its user-facing name and identity.
    func updateGroup(id: PacketCustomFilter.ID, group: PacketStructuredFilterGroup, now: Date = Date()) throws {
        guard let index = cachedFilters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let previousFilter = cachedFilters[index]
        cachedFilters[index].group = PacketStructuredFilterGroup(filters: group.filters, operator: group.operator)
        cachedFilters[index].updatedAt = now
        do {
            try persist()
        } catch {
            cachedFilters[index] = previousFilter
            throw error
        }
    }

    // Duplicate a saved filter beside its source without changing either filter payload.
    @discardableResult
    func duplicate(id: PacketCustomFilter.ID, now: Date = Date()) throws -> PacketCustomFilter? {
        guard let index = cachedFilters.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let sourceFilter = cachedFilters[index]
        let duplicatedFilter = PacketCustomFilter(
            id: UUID().uuidString,
            name: sourceFilter.name,
            createdAt: now,
            updatedAt: now,
            group: PacketStructuredFilterGroup(filters: sourceFilter.group.filters, operator: sourceFilter.group.operator)
        )
        cachedFilters.insert(duplicatedFilter, at: cachedFilters.index(after: index))
        do {
            try persist()
        } catch {
            cachedFilters.removeAll { $0.id == duplicatedFilter.id }
            throw error
        }
        return duplicatedFilter
    }

    // Delete one saved filter and roll back the cache if persistence fails.
    func delete(id: PacketCustomFilter.ID) throws {
        guard let index = cachedFilters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedFilter = cachedFilters.remove(at: index)
        do {
            try persist()
        } catch {
            cachedFilters.insert(removedFilter, at: index)
            throw error
        }
    }

    private func persist() throws {
        if usesUserDataDirectoryStorage {
            try userDataDirectory.createSettingsDirectoryIfNeeded()
        } else {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cachedFilters).write(to: storageURL, options: .atomic)
    }

    private static func loadFilters(from url: URL, fileManager: FileManager) throws -> [PacketCustomFilter] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PacketCustomFilter].self, from: Data(contentsOf: url))
    }

    private static func defaultStorageURL(userDataDirectory: TCPViewerUserDataDirectory) -> URL {
        userDataDirectory.settingsFileURL(named: "CustomFilters.json")
    }
}
