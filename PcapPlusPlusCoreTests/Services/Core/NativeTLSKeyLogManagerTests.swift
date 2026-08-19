//
//  NativeTLSKeyLogManagerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct NativeTLSKeyLogManagerTests {
    @Test func acceptsEveryFormatRecognizedByPinnedWireshark() throws {
        let url = try temporaryFile(contents: [
            "PMS_CLIENT_RANDOM \(hex(bytes: 32)) aa",
            "RSA \(hex(bytes: 8)) \(hex(bytes: 48))",
            "RSA Session-ID:aa Master-Key:\(hex(bytes: 48))",
            "CLIENT_RANDOM \(hex(bytes: 32)) \(hex(bytes: 48))",
            "CLIENT_EARLY_TRAFFIC_SECRET \(hex(bytes: 32)) aa",
            "CLIENT_HANDSHAKE_TRAFFIC_SECRET \(hex(bytes: 32)) aa",
            "SERVER_HANDSHAKE_TRAFFIC_SECRET \(hex(bytes: 32)) aa",
            "CLIENT_TRAFFIC_SECRET_0 \(hex(bytes: 32)) aa",
            "SERVER_TRAFFIC_SECRET_0 \(hex(bytes: 32)) aa",
            "EARLY_EXPORTER_SECRET \(hex(bytes: 32)) aa",
            "EXPORTER_SECRET \(hex(bytes: 32)) aa",
            "ECH_SECRET \(hex(bytes: 32)) aa",
            "ECH_CONFIG \(hex(bytes: 22)) aa",
        ].joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try NativeTLSKeyLogManager.validateFile(at: url)

        #expect(result.validRecordCount == 13)
        #expect(result.warningCount == 0)
    }

    @Test func acceptsCommentsCRLFLowercaseAndIgnoresIncompleteFinalLine() throws {
        let valid = "client_random \(hex(bytes: 32)) \(hex(bytes: 48))"
            .replacingOccurrences(of: "client_random", with: "CLIENT_RANDOM")
        let url = try temporaryFile(contents: "# generated\r\n\r\n\(valid)\r\nBROKEN value\r\nCLIENT_RANDOM aa")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try NativeTLSKeyLogManager.validateFile(at: url)

        #expect(result.validRecordCount == 1)
        #expect(result.warningCount == 1)
        #expect(result.scannedLineCount == 4)
    }

    @Test func rejectsDirectoriesAndFilesWithoutRecognizedRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidURL = directory.appendingPathComponent("invalid.keys")
        try Data("CLIENT_RANDOM aa abc\n".utf8).write(to: invalidURL)

        #expect(throws: TCPViewerCoreError.self) {
            try NativeTLSKeyLogManager.validateFile(at: directory)
        }
        #expect(throws: TCPViewerCoreError.self) {
            try NativeTLSKeyLogManager.validateFile(at: invalidURL)
        }
    }

    @Test func missingFileErrorDoesNotExposeItsPath() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SECRET-PATH-(UUID().uuidString)")

        do {
            _ = try NativeTLSKeyLogManager.validateFile(at: missingURL)
            Issue.record("Expected the missing file to be rejected.")
        } catch let error as TCPViewerCoreError {
            #expect(error.message == "TCP Viewer cannot access the selected TLS key-log file.")
            #expect(!error.message.contains(missingURL.path))
        }
    }

    @Test func stopsAtCompleteLineLimit() throws {
        var lines = ["CLIENT_RANDOM \(hex(bytes: 32)) \(hex(bytes: 48))"]
        lines.append(contentsOf: repeatElement("# comment", count: 20_100))
        let url = try temporaryFile(contents: lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try NativeTLSKeyLogManager.validateFile(at: url)

        #expect(result.validRecordCount == 1)
        #expect(result.scannedLineCount == 20_000)
        #expect(result.reachedScanLimit)
    }

    @Test func replacementAndRemovalUpdateState() throws {
        let firstURL = try temporaryFile(contents: "CLIENT_RANDOM \(hex(bytes: 32)) \(hex(bytes: 48))\n")
        let directory = firstURL.deletingLastPathComponent()
        let secondURL = directory.appendingPathComponent("replacement.log")
        try Data("CLIENT_RANDOM \(String(repeating: "cd", count: 32)) \(hex(bytes: 48))\n".utf8).write(to: secondURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = NativeTLSKeyLogManager()

        let first = try apply(manager, fileURL: firstURL)
        let replacement = try apply(manager, fileURL: secondURL)
        let removed = try remove(manager)

        #expect(first.fileURL == firstURL)
        #expect(replacement.fileURL == secondURL)
        #expect(removed.fileURL == nil)
    }

    private func hex(bytes: Int) -> String {
        String(repeating: "ab", count: bytes)
    }

    private func temporaryFile(contents: String) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("test key ü.keys")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func apply(_ manager: NativeTLSKeyLogManager, fileURL: URL) throws -> TLSKeyLogState {
        try waitForResult { manager.apply(fileURL: fileURL, completion: $0) }
    }

    private func remove(_ manager: NativeTLSKeyLogManager) throws -> TLSKeyLogState {
        try waitForResult(manager.remove)
    }

    private func waitForResult<Value>(
        _ operation: (@escaping TCPViewerCompletion<Value>) -> Void
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var storedResult: Result<Value, Error>?
        operation { result in
            lock.lock()
            storedResult = result
            lock.unlock()
            semaphore.signal()
        }
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return try #require(storedResult).get()
    }
}
