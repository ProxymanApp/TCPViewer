//
//  PacketPinService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import PcapPlusPlusCore

struct PacketPinID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum PacketPinKind: String, Codable, Hashable, Sendable {
    case domain
    case ip
    case client
}

struct PacketPin: Identifiable, Codable, Hashable, Sendable {
    let id: PacketPinID
    let kind: PacketPinKind
    let title: String
    let createdAt: Date
    let domain: String?
    let ipAddress: String?
    let clientKey: String?
    let clientDisplayName: String?
    let clientIconFilePath: String?
}

enum PacketPinCreationKind: Equatable, Sendable {
    case domain
    case ip
    case client
}

enum PacketPinCreationError: Error, Equatable {
    case missingDomain
    case missingIPAddress
    case missingClient
}

enum PacketPinMatcher {
    static func matches(_ packet: PacketSummary, pin: PacketPin) -> Bool {
        switch pin.kind {
        case .domain:
            return normalizedDomain(packet.sniDomainName) == pin.domain
        case .ip:
            return packet.endpoints.source.address == pin.ipAddress ||
                packet.endpoints.destination.address == pin.ipAddress
        case .client:
            return PacketSourceListClassifier.clientIdentity(for: packet)?.key.rawValue == pin.clientKey
        }
    }

    static func normalizedDomain(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed.lowercased()
    }
}

final class PacketPinService {
    private let storageURL: URL
    private let fileManager: FileManager
    private let userDataDirectory: TCPViewerUserDataDirectory
    private let usesUserDataDirectoryStorage: Bool
    private var cachedPins: [PacketPin]

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        userDataDirectory: TCPViewerUserDataDirectory = .shared
    ) {
        self.userDataDirectory = userDataDirectory
        self.usesUserDataDirectoryStorage = storageURL == nil
        self.storageURL = storageURL ?? PacketPinService.defaultStorageURL(userDataDirectory: userDataDirectory)
        self.fileManager = fileManager
        self.cachedPins = (try? Self.loadPins(from: self.storageURL, fileManager: fileManager)) ?? []
    }

    func pins() -> [PacketPin] {
        cachedPins
    }

    func deletePin(id: PacketPinID) throws {
        guard let index = cachedPins.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedPin = cachedPins.remove(at: index)
        do {
            try persist()
        } catch {
            cachedPins.insert(removedPin, at: index)
            throw error
        }
    }

    // Create or reuse a stable pin for the selected packet criteria.
    @discardableResult
    func upsertPin(
        from packet: PacketSummary,
        kind: PacketPinCreationKind,
        clickedColumn: PacketTableColumnRole,
        now: Date = Date()
    ) throws -> PacketPin {
        let pin = try makePin(from: packet, kind: kind, clickedColumn: clickedColumn, now: now)
        if let existingIndex = cachedPins.firstIndex(where: { $0.id == pin.id }) {
            return cachedPins[existingIndex]
        }

        cachedPins.append(pin)
        try persist()
        return pin
    }

    func matchingPackets(in packets: [PacketSummary], for selection: PacketSourceListSelection) -> [PacketSummary] {
        switch selection {
        case .pinned:
            return packets.filter { packet in
                cachedPins.contains { pin in PacketPinMatcher.matches(packet, pin: pin) }
            }
        case .pinnedItem(let pinID):
            guard let pin = cachedPins.first(where: { $0.id == pinID }) else {
                return []
            }
            return packets.filter { PacketPinMatcher.matches($0, pin: pin) }
        default:
            return []
        }
    }

    private func makePin(
        from packet: PacketSummary,
        kind: PacketPinCreationKind,
        clickedColumn: PacketTableColumnRole,
        now: Date
    ) throws -> PacketPin {
        switch kind {
        case .domain:
            guard let domain = PacketPinMatcher.normalizedDomain(packet.sniDomainName) else {
                throw PacketPinCreationError.missingDomain
            }

            return PacketPin(
                id: PacketPinID(rawValue: "domain:\(domain)"),
                kind: .domain,
                title: packet.sniDomainName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? domain,
                createdAt: now,
                domain: domain,
                ipAddress: nil,
                clientKey: nil,
                clientDisplayName: nil,
                clientIconFilePath: nil
            )
        case .ip:
            guard let ipAddress = Self.ipAddress(from: packet, clickedColumn: clickedColumn) else {
                throw PacketPinCreationError.missingIPAddress
            }

            return PacketPin(
                id: PacketPinID(rawValue: "ip:\(ipAddress)"),
                kind: .ip,
                title: ipAddress,
                createdAt: now,
                domain: nil,
                ipAddress: ipAddress,
                clientKey: nil,
                clientDisplayName: nil,
                clientIconFilePath: nil
            )
        case .client:
            guard let identity = PacketSourceListClassifier.clientIdentity(for: packet) else {
                throw PacketPinCreationError.missingClient
            }

            return PacketPin(
                id: PacketPinID(rawValue: "client:\(identity.key.rawValue)"),
                kind: .client,
                title: identity.displayName,
                createdAt: now,
                domain: nil,
                ipAddress: nil,
                clientKey: identity.key.rawValue,
                clientDisplayName: identity.displayName,
                clientIconFilePath: identity.iconFilePath
            )
        }
    }

    private static func ipAddress(from packet: PacketSummary, clickedColumn: PacketTableColumnRole) -> String? {
        switch clickedColumn {
        case .source:
            return packet.endpoints.source.address ?? packet.endpoints.destination.address
        case .destination:
            return packet.endpoints.destination.address ?? packet.endpoints.source.address
        default:
            return packet.endpoints.destination.address ?? packet.endpoints.source.address
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
        try encoder.encode(cachedPins).write(to: storageURL, options: .atomic)
    }

    private static func loadPins(from url: URL, fileManager: FileManager) throws -> [PacketPin] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PacketPin].self, from: Data(contentsOf: url))
    }

    private static func defaultStorageURL(userDataDirectory: TCPViewerUserDataDirectory) -> URL {
        userDataDirectory.settingsFileURL(named: "PinnedPackets.json")
    }
}
