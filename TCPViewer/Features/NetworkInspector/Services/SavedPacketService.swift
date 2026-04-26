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

    private func persist() throws {
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
