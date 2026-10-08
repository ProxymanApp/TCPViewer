//
//  TLSDecryptionStoreTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct TLSDecryptionStoreTests {
    private let firstRandom = String(repeating: "a1", count: 32)
    private let secondRandom = String(repeating: "b2", count: 32)
    private let secret = String(repeating: "0f", count: 32)

    @Test func addingAFileAppliesItsKeysAndPersistsOnlyThePath() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let url = try fixture.writeKeyLog(named: "browser.keys", clientRandoms: [firstRandom, secondRandom], secret: secret)

        fixture.store.addFiles(at: [url])
        await fixture.settle()

        #expect(fixture.store.snapshot.files.map(\.status) == [.ready(sessionCount: 2, keyCount: 2, skippedLineCount: 0)])
        #expect(fixture.applier.appliedLines.last == "CLIENT_RANDOM \(firstRandom) \(secret)\nCLIENT_RANDOM \(secondRandom) \(secret)\n")
        #expect(fixture.delegate.applyCount == 1)
        #expect(fixture.store.snapshot.activityMessage == "Keys loaded.")
        // Key material must never reach the preferences file; only the location does.
        let persisted = fixture.persistedText
        #expect(persisted.contains("browser.keys"))
        #expect(!persisted.contains(secret))
        #expect(!persisted.contains(firstRandom))
    }

    @Test func masterSwitchOffAppliesNoKeysAndBackOnRestoresThem() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.store.addFiles(at: [try fixture.writeKeyLog(named: "a.keys", clientRandoms: [firstRandom], secret: secret)])
        await fixture.settle()

        fixture.store.setEnabled(false)
        await fixture.settle()

        #expect(fixture.applier.appliedLines.last == "")
        #expect(fixture.store.snapshot.activityMessage == "TLS decryption is off.")
        // The list stays as configured, so switching back on needs no re-adding.
        #expect(fixture.store.snapshot.files.count == 1)

        fixture.store.setEnabled(true)
        await fixture.settle()

        #expect(fixture.applier.appliedLines.last == "CLIENT_RANDOM \(firstRandom) \(secret)\n")
        #expect(fixture.delegate.applyCount == 3)
    }

    @Test func enabledFilesAreMergedInListOrderAndUncheckedOnesAreLeftOut() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let first = try fixture.writeKeyLog(named: "first.keys", clientRandoms: [firstRandom], secret: secret)
        let second = try fixture.writeKeyLog(named: "second.keys", clientRandoms: [secondRandom], secret: secret)

        fixture.store.addFiles(at: [first, second])
        await fixture.settle()
        #expect(fixture.applier.appliedLines.last == "CLIENT_RANDOM \(firstRandom) \(secret)\nCLIENT_RANDOM \(secondRandom) \(secret)\n")

        fixture.store.setFile(withID: first.path, enabled: false)
        await fixture.settle()

        #expect(fixture.applier.appliedLines.last == "CLIENT_RANDOM \(secondRandom) \(secret)\n")
        #expect(fixture.store.snapshot.files.map(\.isEnabled) == [false, true])
    }

    @Test func duplicatesAndFoldersAreNotAdded() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let url = try fixture.writeKeyLog(named: "dup.keys", clientRandoms: [firstRandom], secret: secret)

        fixture.store.addFiles(at: [url, url, fixture.directory])
        fixture.store.addFiles(at: [url])
        await fixture.settle()

        #expect(fixture.store.snapshot.files.map(\.id) == [url.path])
        #expect(fixture.applier.appliedLines.count == 1)
    }

    @Test func missingAndUnusableFilesAreFlaggedAndContributeNoKeys() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let missing = fixture.directory.appendingPathComponent("gone.keys")
        let capture = fixture.directory.appendingPathComponent("capture.pcap")
        try Data([0xd4, 0xc3, 0xb2, 0xa1, 0x02, 0x00, 0x04, 0x00]).write(to: capture)

        fixture.store.addFiles(at: [missing, capture])
        await fixture.settle()

        #expect(fixture.store.snapshot.files.map(\.status) == [.missing, .noKeys])
        // Nothing usable changed, so loaded captures are not dissected again.
        #expect(fixture.applier.appliedLines.isEmpty)
        #expect(fixture.delegate.applyCount == 0)
    }

    @Test func reloadAppliesOnlyWhenTheKeysChanged() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let url = try fixture.writeKeyLog(named: "growing.keys", clientRandoms: [firstRandom], secret: secret)
        fixture.store.addFiles(at: [url])
        await fixture.settle()

        await fixture.settle()
        #expect(fixture.applier.appliedLines.count == 1)

        // A key log grows while its app keeps running; the next reload picks the new session up.
        _ = try fixture.writeKeyLog(named: "growing.keys", clientRandoms: [firstRandom, secondRandom], secret: secret)
        await fixture.settle()

        #expect(fixture.applier.appliedLines.count == 2)
        #expect(fixture.store.snapshot.files.map(\.status) == [.ready(sessionCount: 2, keyCount: 2, skippedLineCount: 0)])

        try FileManager.default.removeItem(at: url)
        await fixture.settle()

        #expect(fixture.store.snapshot.files.map(\.status) == [.missing])
        #expect(fixture.applier.appliedLines.last == "")
    }

    @Test func listAndSwitchAreRestoredFromPreferences() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let first = try fixture.writeKeyLog(named: "first.keys", clientRandoms: [firstRandom], secret: secret)
        let second = try fixture.writeKeyLog(named: "second.keys", clientRandoms: [secondRandom], secret: secret)
        fixture.store.addFiles(at: [first, second])
        fixture.store.setFile(withID: second.path, enabled: false)
        fixture.store.setEnabled(false)
        await fixture.settle()

        let restored = TLSDecryptionStore(defaults: fixture.defaults, monitorsFiles: false, applyKeyLogs: fixture.applier.apply)

        #expect(!restored.snapshot.isEnabled)
        #expect(restored.snapshot.files.map(\.id) == [first.path, second.path])
        #expect(restored.snapshot.files.map(\.isEnabled) == [true, false])
        #expect(restored.snapshot.files.allSatisfy { $0.status == .reading })
    }

    @Test func listStopsAtTheFileLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let urls = try (0...TLSDecryptionStore.maximumFileCount).map {
            try fixture.writeKeyLog(named: "log-\($0).keys", clientRandoms: [firstRandom], secret: secret)
        }

        fixture.store.addFiles(at: urls)

        #expect(fixture.store.snapshot.files.count == TLSDecryptionStore.maximumFileCount)
        #expect(fixture.store.snapshot.activityMessage == "Up to 16 key log files can be listed.")
    }

    @Test func redissectionOutcomeIsReportedInPlainWords() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        fixture.store.reportRedissection(captureTitle: "a.pcapng", result: .success(214))
        #expect(fixture.store.snapshot.activityMessage == "Updated 214 packets in a.pcapng.")

        fixture.store.reportRedissection(captureTitle: "a.pcapng", result: .success(1))
        #expect(fixture.store.snapshot.activityMessage == "Updated 1 packet in a.pcapng.")

        fixture.store.reportRedissection(captureTitle: "a.pcapng", result: .success(0))
        #expect(fixture.store.snapshot.activityMessage == "No packets changed in a.pcapng.")

        fixture.store.addFiles(at: [try fixture.writeKeyLog(named: "a.keys", clientRandoms: [firstRandom], secret: secret)])
        await fixture.settle()
        fixture.store.reportRedissection(captureTitle: "a.pcapng", result: .success(0))
        #expect(fixture.store.snapshot.activityMessage == "No packets in a.pcapng match these keys.")

        let busy = TCPViewerCoreError(code: .unavailableFeature, message: "Wireshark is busy with another capture.")
        fixture.store.reportRedissection(captureTitle: "Live", result: .failure(busy))
        #expect(fixture.store.snapshot.activityMessage == "Live: Wireshark is busy with another capture.")

        // A superseded pass is not an outcome worth showing.
        let cancelled = TCPViewerCoreError(code: .operationCancelled, message: "Re-dissecting packets was cancelled.")
        fixture.store.reportRedissection(captureTitle: "Live", result: .failure(cancelled))
        #expect(fixture.store.snapshot.activityMessage == "Live: Wireshark is busy with another capture.")
    }
}

// Records what the store hands to the dissector instead of touching the process-wide key log.
@MainActor
private final class KeyLogApplierSpy {
    private(set) var appliedLines: [String] = []

    func apply(_ keyLogs: [TLSKeyLog], completion: @escaping () -> Void) {
        appliedLines.append(keyLogs.map { String(decoding: $0.lines, as: UTF8.self) }.joined())
        completion()
    }
}

@MainActor
private final class StoreDelegateSpy: TLSDecryptionStoreDelegate {
    private(set) var applyCount = 0

    func tlsDecryptionStoreDidChange(_ store: TLSDecryptionStore) {}

    func tlsDecryptionStoreDidApplyKeyLog(_ store: TLSDecryptionStore) {
        applyCount += 1
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let defaults: UserDefaults
    let applier = KeyLogApplierSpy()
    let delegate = StoreDelegateSpy()
    let store: TLSDecryptionStore
    private let defaultsSuiteName: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TLSDecryptionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuiteName = "TLSDecryptionStoreTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        store = TLSDecryptionStore(defaults: defaults, monitorsFiles: false, applyKeyLogs: applier.apply)
        store.delegate = delegate
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    var persistedText: String {
        defaults.dictionaryRepresentation().values
            .compactMap { $0 as? Data }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
    }

    func writeKeyLog(named name: String, clientRandoms: [String], secret: String) throws -> URL {
        let url = directory.appendingPathComponent(name).standardizedFileURL
        let text = clientRandoms.map { "CLIENT_RANDOM \($0) \(secret)\n" }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }

    // Reload and wait for it, which also supersedes the reload a mutation started.
    func settle() async {
        await withCheckedContinuation { continuation in
            store.reload { continuation.resume() }
        }
    }
}
