//
//  TCPViewerCLIFileStore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Darwin
import Foundation

enum TCPViewerCLIFileStoreError: Error, LocalizedError {
    case invalidIdentifier
    case unavailable
    case unsafeFile
    case fileTooLarge
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "The CLI request identifier is invalid."
        case .unavailable:
            return "The CLI request file is unavailable."
        case .unsafeFile:
            return "The CLI request file has unsafe metadata."
        case .fileTooLarge:
            return "The CLI request file is too large."
        case .invalidPayload:
            return "The CLI request file contains invalid JSON."
        }
    }
}

final class TCPViewerCLIFileStore {
    static let requestMaximumByteCount = 1 * 1_024 * 1_024
    // Text JSON can expand a 4 MiB TCP payload, so leave bounded headroom for escaping and record metadata.
    static let responseMaximumByteCount = 32 * 1_024 * 1_024
    static let orphanMaximumAge: TimeInterval = 24 * 60 * 60

    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    var requestsDirectoryURL: URL {
        rootURL.appendingPathComponent("Requests", isDirectory: true)
    }

    var responsesDirectoryURL: URL {
        rootURL.appendingPathComponent("Responses", isDirectory: true)
    }

    func prepareDirectories() throws {
        try createPrivateDirectory(rootURL)
        try createPrivateDirectory(requestsDirectoryURL)
        try createPrivateDirectory(responsesDirectoryURL)
    }

    func writeRequest(_ request: TCPViewerCLIRequest) throws {
        try prepareDirectories()
        try writeSecurely(
            encoder.encode(request),
            to: try requestURL(for: request.requestID),
            maximumByteCount: Self.requestMaximumByteCount
        )
    }

    func writeResponse(_ response: TCPViewerCLIResponse) throws {
        try prepareDirectories()
        try writeSecurely(
            encoder.encode(response),
            to: try responseURL(for: response.requestID),
            maximumByteCount: Self.responseMaximumByteCount
        )
    }

    func readResponse(requestID: String) throws -> TCPViewerCLIResponse {
        let data = try readSecurely(
            at: try responseURL(for: requestID),
            maximumByteCount: Self.responseMaximumByteCount
        )
        guard let response = try? decoder.decode(TCPViewerCLIResponse.self, from: data),
              response.schemaVersion == TCPViewerCLIResponse.schemaVersion,
              response.requestID == requestID else {
            throw TCPViewerCLIFileStoreError.invalidPayload
        }
        return response
    }

    // Read valid work in creation order and delete unsafe or expired request files.
    func pendingRequests(now: Date = Date()) -> [TCPViewerCLIRequest] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: requestsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "json" else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            do {
                let data = try readSecurely(at: url, maximumByteCount: Self.requestMaximumByteCount)
                let request = try decoder.decode(TCPViewerCLIRequest.self, from: data)
                let expectedName = try requestURL(for: request.requestID).lastPathComponent
                guard request.schemaVersion == TCPViewerCLIRequest.schemaVersion,
                      expectedName == url.lastPathComponent,
                      request.expiresAt > now else {
                    try? fileManager.removeItem(at: url)
                    return nil
                }
                return request
            } catch {
                try? fileManager.removeItem(at: url)
                return nil
            }
        }
        .sorted {
            if $0.createdAt == $1.createdAt { return $0.requestID < $1.requestID }
            return $0.createdAt < $1.createdAt
        }
    }

    func removeRequest(requestID: String) {
        guard let url = try? requestURL(for: requestID) else { return }
        try? fileManager.removeItem(at: url)
    }

    func removeResponse(requestID: String) {
        guard let url = try? responseURL(for: requestID) else { return }
        try? fileManager.removeItem(at: url)
    }

    func cleanupOrphans(now: Date = Date()) {
        cleanup(directory: requestsDirectoryURL, olderThan: now.addingTimeInterval(-Self.orphanMaximumAge))
        cleanup(directory: responsesDirectoryURL, olderThan: now.addingTimeInterval(-Self.orphanMaximumAge))
    }

    private func requestURL(for requestID: String) throws -> URL {
        try fileURL(for: requestID, in: requestsDirectoryURL)
    }

    private func responseURL(for requestID: String) throws -> URL {
        try fileURL(for: requestID, in: responsesDirectoryURL)
    }

    private func fileURL(for identifier: String, in directory: URL) throws -> URL {
        guard UUID(uuidString: identifier) != nil,
              !identifier.contains("/"),
              !identifier.contains("\\") else {
            throw TCPViewerCLIFileStoreError.invalidIdentifier
        }
        return directory.appendingPathComponent(identifier.lowercased()).appendingPathExtension("json")
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw TCPViewerCLIFileStoreError.unsafeFile
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw TCPViewerCLIFileStoreError.unavailable
        }
    }

    private func writeSecurely(_ data: Data, to url: URL, maximumByteCount: Int) throws {
        guard data.count <= maximumByteCount else {
            throw TCPViewerCLIFileStoreError.fileTooLarge
        }
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw errno == ELOOP ? TCPViewerCLIFileStoreError.unsafeFile : .unavailable
        }
        var shouldRemoveTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporaryFile { try? fileManager.removeItem(at: temporaryURL) }
        }

        var writtenByteCount = 0
        while writtenByteCount < data.count {
            let result = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: writtenByteCount),
                    buffer.count - writtenByteCount
                )
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw TCPViewerCLIFileStoreError.unavailable }
            writtenByteCount += result
        }
        guard fsync(descriptor) == 0 else { throw TCPViewerCLIFileStoreError.unavailable }
        guard renamex_np(temporaryURL.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            throw TCPViewerCLIFileStoreError.unavailable
        }
        shouldRemoveTemporaryFile = false
    }

    private func readSecurely(at url: URL, maximumByteCount: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? TCPViewerCLIFileStoreError.unsafeFile : .unavailable
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw TCPViewerCLIFileStoreError.unavailable }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw TCPViewerCLIFileStoreError.unsafeFile
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumByteCount else {
            throw TCPViewerCLIFileStoreError.fileTooLarge
        }

        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var readByteCount = 0
        while readByteCount < bytes.count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: readByteCount),
                    buffer.count - readByteCount
                )
            }
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw TCPViewerCLIFileStoreError.unavailable }
            guard result > 0 else { break }
            readByteCount += result
        }
        return Data(bytes.prefix(readByteCount))
    }

    private func cleanup(directory: URL, olderThan cutoff: Date) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return
        }
        for url in urls {
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if date.map({ $0 < cutoff }) ?? true {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("TCPViewer", isDirectory: true)
            .appendingPathComponent("CLI", isDirectory: true)
    }
}
