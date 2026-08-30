//
//  WiresharkTLSDecryptionTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkTLSDecryptionTests {
    @Test func decryptsRFC8446TLS13IntoDirectionalStreams() throws {
        let root = repositoryRoot()
        let captureURL = root.appendingPathComponent("Vendor/Wireshark/test/captures/tls13-rfc8446.pcap")
        let keyURL = root.appendingPathComponent("Vendor/Wireshark/test/keys/tls13-rfc8446.keys")
        let manager = NativeTLSKeyLogManager()
        _ = try apply(manager: manager, fileURL: keyURL)
        defer { remove(manager: manager) }

        let records = try NativeCaptureFile.load(from: captureURL).records
        let selected = try #require(records.first(where: { $0.identifier == 5 }))
        let result = try WiresharkEpanSession.followDecryptedStreamInTemporarySession(
            containing: selected,
            records: records,
            limits: .default,
            progress: nil,
            shouldCancel: nil
        )

        #expect(result.protocolName == .tls)
        #expect(String(data: result.request.data, encoding: .utf8)?.contains("/first") == true)
        #expect(!result.response.data.isEmpty)
    }

    @Test func mismatchedKeysDoNotExposePlaintextOrCrash() throws {
        let root = repositoryRoot()
        let captureURL = root.appendingPathComponent("Vendor/Wireshark/test/captures/tls13-rfc8446.pcap")
        let keyURL = root.appendingPathComponent("Vendor/Wireshark/test/keys/tls12-chacha20poly1305.keys")
        let manager = NativeTLSKeyLogManager()
        _ = try apply(manager: manager, fileURL: keyURL)
        defer { remove(manager: manager) }

        let records = try NativeCaptureFile.load(from: captureURL).records
        let selected = try #require(records.first(where: { $0.identifier == 5 }))
        let result = try WiresharkEpanSession.followDecryptedStreamInTemporarySession(
            containing: selected,
            records: records,
            limits: .default,
            progress: nil,
            shouldCancel: nil
        )

        #expect(result.request.data.isEmpty)
        #expect(result.response.data.isEmpty)
    }

    @Test func decryptsTLS12ChaCha20Poly1305Fixture() throws {
        let root = repositoryRoot()
        let captureURL = root.appendingPathComponent("Vendor/Wireshark/test/captures/tls12-chacha20poly1305.pcap")
        let keyURL = root.appendingPathComponent("Vendor/Wireshark/test/keys/tls12-chacha20poly1305.keys")
        let manager = NativeTLSKeyLogManager()
        _ = try apply(manager: manager, fileURL: keyURL)
        defer { remove(manager: manager) }

        let records = try NativeCaptureFile.load(from: captureURL).records
        let session = try WiresharkEpanSession(purpose: .follow)
        for record in records {
            try session.observe(record)
        }
        try session.finishFirstPass()
        let selected = try #require(records.first { record in
            (try? session.summarize(record).protocolSummary?.lowercased().contains("tls")) == true
        })
        let result = try session.followObservedDecryptedStream(
            containing: selected,
            records: records,
            limits: .default,
            progress: nil,
            shouldCancel: nil
        )
        let plaintext = result.request.data + result.response.data

        #expect(String(data: plaintext, encoding: .utf8)?.contains("Cipher is") == true)
    }

    @Test func capsEachDirectionAndReportsObservedBytes() throws {
        let root = repositoryRoot()
        let captureURL = root.appendingPathComponent("Vendor/Wireshark/test/captures/tls13-rfc8446.pcap")
        let keyURL = root.appendingPathComponent("Vendor/Wireshark/test/keys/tls13-rfc8446.keys")
        let manager = NativeTLSKeyLogManager()
        _ = try apply(manager: manager, fileURL: keyURL)
        defer { remove(manager: manager) }
        let records = try NativeCaptureFile.load(from: captureURL).records
        let selected = try #require(records.first(where: { $0.identifier == 5 }))

        let result = try WiresharkEpanSession.followDecryptedStreamInTemporarySession(
            containing: selected,
            records: records,
            limits: DecryptedStreamLimits(maximumBytesPerDirection: 4),
            progress: nil,
            shouldCancel: nil
        )

        #expect(result.request.data.count == 4)
        #expect(result.response.data.count == 4)
        #expect(result.request.observedByteCount > result.request.data.count)
        #expect(result.response.observedByteCount > result.response.data.count)
        #expect(result.request.isTruncated)
        #expect(result.response.isTruncated)
    }

    @Test func detectsSecretsAppendedToSelectedFileWithoutReapplyingPreference() throws {
        let root = repositoryRoot()
        let captureURL = root.appendingPathComponent("Vendor/Wireshark/test/captures/tls13-rfc8446.pcap")
        let sourceKeyURL = root.appendingPathComponent("Vendor/Wireshark/test/keys/tls13-rfc8446.keys")
        let keyData = try Data(contentsOf: sourceKeyURL)
        let newline = try #require(keyData.firstIndex(of: 0x0A))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedKeyURL = directory.appendingPathComponent("growing.keys")
        try keyData[...newline].write(to: selectedKeyURL)
        let manager = NativeTLSKeyLogManager()
        _ = try apply(manager: manager, fileURL: selectedKeyURL)
        defer { remove(manager: manager) }
        let records = try NativeCaptureFile.load(from: captureURL).records
        let selected = try #require(records.first(where: { $0.identifier == 5 }))

        let beforeAppend = try WiresharkEpanSession.followDecryptedStreamInTemporarySession(
            containing: selected,
            records: records,
            limits: .default,
            progress: nil,
            shouldCancel: nil
        )
        let handle = try FileHandle(forWritingTo: selectedKeyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: keyData[keyData.index(after: newline)...])
        try handle.close()
        let afterAppend = try WiresharkEpanSession.followDecryptedStreamInTemporarySession(
            containing: selected,
            records: records,
            limits: .default,
            progress: nil,
            shouldCancel: nil
        )

        #expect(beforeAppend.request.data.isEmpty)
        #expect(beforeAppend.response.data.isEmpty)
        #expect(!afterAppend.request.data.isEmpty)
        #expect(!afterAppend.response.data.isEmpty)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func apply(manager: NativeTLSKeyLogManager, fileURL: URL) throws -> TLSKeyLogState {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var storedResult: Result<TLSKeyLogState, Error>?
        manager.apply(fileURL: fileURL) { result in
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

    private func remove(manager: NativeTLSKeyLogManager) {
        let semaphore = DispatchSemaphore(value: 0)
        manager.remove { _ in semaphore.signal() }
        semaphore.wait()
    }
}
