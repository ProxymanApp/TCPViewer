//
//  InterfaceSelectionHistoryStore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation

final class InterfaceSelectionHistoryStore {
    static let storageKey = "TCPViewer.settings.interfaceSelection.lastUsedInterfaceIDs"
    static let defaultMaximumInterfaceCount = 5

    private static let legacyStorageKey = "TCPViewer.lastUsedInterfaceIDs"

    private let defaults: UserDefaults
    private let maximumInterfaceCount: Int

    init(
        defaults: UserDefaults = .standard,
        maximumInterfaceCount: Int = InterfaceSelectionHistoryStore.defaultMaximumInterfaceCount
    ) {
        self.defaults = defaults
        self.maximumInterfaceCount = max(1, maximumInterfaceCount)
    }

    var lastUsedInterfaceIDs: [String] {
        sanitizedHistory(from: storedInterfaceIDs())
    }

    @discardableResult
    func recordInterfaceUsage(_ interfaceID: String) -> [String] {
        let normalizedID = interfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return lastUsedInterfaceIDs
        }

        return replaceHistory(with: [normalizedID] + lastUsedInterfaceIDs)
    }

    @discardableResult
    func replaceHistory(with interfaceIDs: [String]) -> [String] {
        let history = sanitizedHistory(from: interfaceIDs)
        defaults.set(history, forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.legacyStorageKey)
        return history
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.legacyStorageKey)
    }

    private func storedInterfaceIDs() -> [String] {
        if let ids = defaults.stringArray(forKey: Self.storageKey) {
            return ids
        }

        return defaults.stringArray(forKey: Self.legacyStorageKey) ?? []
    }

    private func sanitizedHistory(from interfaceIDs: [String]) -> [String] {
        var seen = Set<String>()
        var history: [String] = []

        for interfaceID in interfaceIDs {
            let normalizedID = interfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty, seen.insert(normalizedID).inserted else {
                continue
            }

            history.append(normalizedID)
            if history.count == maximumInterfaceCount {
                break
            }
        }

        return history
    }
}
