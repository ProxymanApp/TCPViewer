//
//  TCPViewerMCPHandshakeStoreTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerMCPHandshakeStoreTests {
    @Test func generatesStrongTokensAndAtomicallyWritesPrivateHandshake() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPHandshake-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("handshake.json")
        let store = TCPViewerMCPHandshakeStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstToken = try store.makeToken()
        let secondToken = try store.makeToken()
        #expect(firstToken.utf8.count >= 32)
        #expect(firstToken != secondToken)

        let handshake = TCPViewerMCPHandshake(port: 49_999, token: firstToken)
        try store.write(handshake)
        let decoded = try JSONDecoder().decode(TCPViewerMCPHandshake.self, from: Data(contentsOf: fileURL))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
        #expect(decoded == handshake)
        #expect(permissions & 0o077 == 0)

        let replacement = TCPViewerMCPHandshake(port: 50_000, token: secondToken)
        try store.write(replacement)
        let replaced = try JSONDecoder().decode(TCPViewerMCPHandshake.self, from: Data(contentsOf: fileURL))
        #expect(replaced == replacement)

        store.remove(ifMatching: handshake)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        store.remove(ifMatching: replacement)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func rejectsInvalidHandshake() {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPInvalid-\(UUID().uuidString).json")
        let store = TCPViewerMCPHandshakeStore(fileURL: fileURL)
        #expect(throws: Error.self) {
            try store.write(TCPViewerMCPHandshake(port: 0, token: "short"))
        }
    }

    @Test func secureReaderRejectsLoosePermissionsSymlinksAndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPSecureRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("handshake.json")
        let data = try JSONEncoder().encode(TCPViewerMCPHandshake(
            port: 50_001,
            token: String(repeating: "a", count: 43)
        ))
        try data.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        #expect(try TCPViewerMCPHandshakeFile.readSecurely(at: fileURL) == data)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        #expect(throws: TCPViewerMCPHandshakeFileError.self) {
            try TCPViewerMCPHandshakeFile.readSecurely(at: fileURL)
        }

        let linkURL = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
        #expect(throws: TCPViewerMCPHandshakeFileError.self) {
            try TCPViewerMCPHandshakeFile.readSecurely(at: linkURL)
        }

        let oversizedURL = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: TCPViewerMCPHandshakeFile.maximumByteCount + 1).write(to: oversizedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversizedURL.path)
        #expect(throws: TCPViewerMCPHandshakeFileError.self) {
            try TCPViewerMCPHandshakeFile.readSecurely(at: oversizedURL)
        }
    }
}
