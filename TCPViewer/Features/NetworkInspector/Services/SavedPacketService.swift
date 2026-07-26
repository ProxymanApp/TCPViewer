//
//  SavedPacketService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import PcapPlusPlusCore

struct SavedPacketRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var savedAt: Date
    var backingIdentity: String?
    var packet: PacketSummary
}

final class SavedPacketService {
    private let storageURL: URL
    private let fileManager: FileManager
    private let userDataDirectory: TCPViewerUserDataDirectory
    private let usesUserDataDirectoryStorage: Bool
    private var cachedRecords: [SavedPacketRecord]
    private var isDocumentScoped = false

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        userDataDirectory: TCPViewerUserDataDirectory = .shared
    ) {
        self.userDataDirectory = userDataDirectory
        self.usesUserDataDirectoryStorage = storageURL == nil
        self.storageURL = storageURL ?? SavedPacketService.defaultStorageURL(userDataDirectory: userDataDirectory)
        self.fileManager = fileManager
        self.cachedRecords = (try? Self.loadRecords(from: self.storageURL, fileManager: fileManager)) ?? []
    }

    func records() -> [SavedPacketRecord] {
        cachedRecords
    }

    func useDocumentRecords(_ records: [SavedPacketRecord]) {
        isDocumentScoped = true
        cachedRecords = records
    }

    func reloadPersistentRecords() {
        isDocumentScoped = false
        cachedRecords = (try? Self.loadRecords(from: storageURL, fileManager: fileManager)) ?? []
    }

    func packets() -> [PacketSummary] {
        cachedRecords.map(\.packet)
    }

    // Persist selected packet summaries without storing raw packet bytes.
    @discardableResult
    func save(_ packets: [PacketSummary], backingIdentity: String? = nil, now: Date = Date()) throws -> [SavedPacketRecord] {
        guard !packets.isEmpty else {
            return []
        }

        var savedRecords: [SavedPacketRecord] = []
        for packet in packets {
            if let index = cachedRecords.firstIndex(where: { $0.packet.id == packet.id }) {
                cachedRecords[index].savedAt = now
                cachedRecords[index].backingIdentity = backingIdentity
                cachedRecords[index].packet = packet
                savedRecords.append(cachedRecords[index])
            } else {
                let record = SavedPacketRecord(id: UUID().uuidString, savedAt: now, backingIdentity: backingIdentity, packet: packet)
                cachedRecords.append(record)
                savedRecords.append(record)
            }
        }

        try persist()
        return savedRecords
    }

    func deletePacketIDs(_ packetIDs: Set<PacketSummary.ID>) throws {
        guard !packetIDs.isEmpty else {
            return
        }

        cachedRecords.removeAll { packetIDs.contains($0.packet.id) }
        try persist()
    }

    // Keep saved-row styles synchronized with their matching active packet summaries.
    @discardableResult
    func applyTextStyleMutation(
        _ mutation: PacketTextStyleMutation,
        packetIDs: Set<PacketSummary.ID>
    ) throws -> Bool {
        let previousRecords = cachedRecords
        var didChange = false
        for index in cachedRecords.indices where packetIDs.contains(cachedRecords[index].packet.id) {
            let packet = cachedRecords[index].packet
            let updatedStyle = mutation.applying(to: packet.resolvedTextStyle)
            guard updatedStyle != packet.resolvedTextStyle else {
                continue
            }

            cachedRecords[index].packet = packet.applying(textStyle: updatedStyle)
            didChange = true
        }

        if didChange {
            do {
                try persist()
            } catch {
                // Keep the in-memory view consistent with the last durable saved-packet state.
                cachedRecords = previousRecords
                throw error
            }
        }
        return didChange
    }

    // Persist one sanitized comment across the matching saved packet copies.
    @discardableResult
    func setCustomComment(_ comment: String, packetIDs: Set<PacketSummary.ID>) throws -> Bool {
        let sanitizedComment = PacketComment.sanitized(comment)
        guard !sanitizedComment.isEmpty else {
            return false
        }

        let previousRecords = cachedRecords
        var didChange = false
        for index in cachedRecords.indices where packetIDs.contains(cachedRecords[index].packet.id) {
            let packet = cachedRecords[index].packet
            guard packet.customComment != sanitizedComment else {
                continue
            }
            cachedRecords[index].packet = packet.applying(customComment: sanitizedComment)
            didChange = true
        }

        if didChange {
            do {
                try persist()
            } catch {
                cachedRecords = previousRecords
                throw error
            }
        }
        return didChange
    }

    private func persist() throws {
        guard !isDocumentScoped else {
            return
        }

        if usesUserDataDirectoryStorage {
            try userDataDirectory.createSettingsDirectoryIfNeeded()
        } else {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cachedRecords).write(to: storageURL, options: .atomic)
    }

    private static func loadRecords(from url: URL, fileManager: FileManager) throws -> [SavedPacketRecord] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SavedPacketRecord].self, from: Data(contentsOf: url))
    }

    private static func defaultStorageURL(userDataDirectory: TCPViewerUserDataDirectory) -> URL {
        userDataDirectory.settingsFileURL(named: "SavedPackets.json")
    }
}
