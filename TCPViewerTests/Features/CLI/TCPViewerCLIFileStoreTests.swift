//
//  TCPViewerCLIFileStoreTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Darwin
import Foundation
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPViewerCLIFileStoreTests {
    @Test func roundTripsCorrelatedResponseWithPrivatePermissions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requestID = UUID().uuidString.lowercased()
        let response = TCPViewerCLIResponse.success(
            requestID: requestID,
            command: .packetsBytes,
            data: ["packet_id": .string(String(UInt64.max)), "data": .string("AQID")]
        )

        try fixture.store.writeResponse(response)
        #expect(try fixture.store.readResponse(requestID: requestID) == response)
        #expect(try mode(fixture.store.requestsDirectoryURL) == 0o700)
        #expect(try mode(fixture.store.responsesDirectoryURL) == 0o700)
        #expect(try mode(fixture.responseURL(requestID)) == 0o600)
    }

    @Test func scansPendingRequestsInCreationOrderAndDropsExpiredWork() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let later = TCPViewerCLIRequest(
            command: .captureStatus,
            createdAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(60)
        )
        let first = TCPViewerCLIRequest(
            command: .interfacesList,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let expired = TCPViewerCLIRequest(
            command: .packetsList,
            createdAt: now.addingTimeInterval(-2),
            expiresAt: now.addingTimeInterval(-1)
        )
        try fixture.store.writeRequest(later)
        try fixture.store.writeRequest(first)
        try fixture.store.writeRequest(expired)

        #expect(fixture.store.pendingRequests(now: now).map(\.requestID) == [first.requestID, later.requestID])
        #expect(!FileManager.default.fileExists(atPath: fixture.requestURL(expired.requestID).path))
    }

    @Test func rejectsSymlinkedResponsesAndOversizedRequests() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requestID = UUID().uuidString.lowercased()
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: fixture.responseURL(requestID), withDestinationURL: target)

        #expect(throws: TCPViewerCLIFileStoreError.self) {
            try fixture.store.readResponse(requestID: requestID)
        }

        let oversizedID = UUID().uuidString.lowercased()
        let oversizedURL = fixture.requestURL(oversizedID)
        let oversizedData = Data(repeating: 0x20, count: TCPViewerCLIFileStore.requestMaximumByteCount + 1)
        try oversizedData.write(to: oversizedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversizedURL.path)
        #expect(fixture.store.pendingRequests().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: oversizedURL.path))
    }

    @Test func cleansOrphanedResponsesAfterTwentyFourHours() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requestID = UUID().uuidString.lowercased()
        try fixture.store.writeResponse(.success(requestID: requestID, command: .appStatus, data: [:]))
        let oldDate = Date().addingTimeInterval(-TCPViewerCLIFileStore.orphanMaximumAge - 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fixture.responseURL(requestID).path)

        fixture.store.cleanupOrphans()

        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL(requestID).path))
    }

    @Test func rejectsSymlinkedTransportDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerCLISymlinkDirectoryTests-\(UUID().uuidString)")
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let root = parent.appendingPathComponent("CLI", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        let store = TCPViewerCLIFileStore(rootURL: root)

        #expect(throws: TCPViewerCLIFileStoreError.self) {
            try store.prepareDirectories()
        }
    }

    private func mode(_ url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw TCPViewerCLIFileStoreError.unavailable
        }
        return metadata.st_mode & 0o777
    }

    private struct Fixture {
        let root: URL
        let store: TCPViewerCLIFileStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerCLIFileStoreTests-\(UUID().uuidString)")
            store = TCPViewerCLIFileStore(rootURL: root)
            try store.prepareDirectories()
        }

        func requestURL(_ requestID: String) -> URL {
            store.requestsDirectoryURL.appendingPathComponent(requestID).appendingPathExtension("json")
        }

        func responseURL(_ requestID: String) -> URL {
            store.responsesDirectoryURL.appendingPathComponent(requestID).appendingPathExtension("json")
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
