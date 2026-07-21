//
//  TCPViewerMCPHandshakeStore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Darwin
import Foundation
import Security

enum TCPViewerMCPHandshakeStoreError: Error, LocalizedError {
    case randomTokenGenerationFailed(OSStatus)
    case couldNotOpenFile(Int32)
    case couldNotWriteFile(Int32)
    case couldNotCommitFile(Int32)

    var errorDescription: String? {
        switch self {
        case .randomTokenGenerationFailed(let status):
            return "Could not generate the MCP authentication token (Security status \(status))."
        case .couldNotOpenFile(let code):
            return "Could not create the MCP handshake file (errno \(code))."
        case .couldNotWriteFile(let code):
            return "Could not write the MCP handshake file (errno \(code))."
        case .couldNotCommitFile(let code):
            return "Could not commit the MCP handshake file (errno \(code))."
        }
    }
}

struct TCPViewerMCPHandshakeStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = TCPViewerUserDataDirectory.shared.appDirectoryURL
            .appendingPathComponent(TCPViewerMCPHandshake.fileName),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    // Generate an unguessable bearer token without persisting raw random bytes elsewhere.
    func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TCPViewerMCPHandshakeStoreError.randomTokenGenerationFailed(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // Atomically publish a mode-0600 handshake after the loopback listener is ready.
    func write(_ handshake: TCPViewerMCPHandshake) throws {
        guard handshake.isValid else {
            throw TCPViewerMCPCommandRouterError.invalidParameter("The MCP handshake is invalid.")
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let data = try JSONEncoder().encode(handshake)
        let temporaryURL = directory.appendingPathComponent(".mcp-handshake-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw TCPViewerMCPHandshakeStoreError.couldNotOpenFile(errno)
        }

        var descriptorIsOpen = true
        var didCommit = false
        defer {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            if !didCommit {
                _ = unlink(temporaryURL.path)
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var writtenByteCount = 0
            while writtenByteCount < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenByteCount),
                    buffer.count - writtenByteCount
                )
                if result < 0 && errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw TCPViewerMCPHandshakeStoreError.couldNotWriteFile(errno)
                }
                writtenByteCount += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw TCPViewerMCPHandshakeStoreError.couldNotWriteFile(errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            throw TCPViewerMCPHandshakeStoreError.couldNotWriteFile(errno)
        }
        descriptorIsOpen = false
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw TCPViewerMCPHandshakeStoreError.couldNotCommitFile(errno)
        }
        didCommit = true
    }

    // Remove only the handshake owned by this server instance to avoid deleting a replacement.
    func remove(ifMatching handshake: TCPViewerMCPHandshake) {
        guard let data = try? TCPViewerMCPHandshakeFile.readSecurely(at: fileURL),
              let current = try? JSONDecoder().decode(TCPViewerMCPHandshake.self, from: data),
              current == handshake else {
            return
        }
        try? fileManager.removeItem(at: fileURL)
    }
}
