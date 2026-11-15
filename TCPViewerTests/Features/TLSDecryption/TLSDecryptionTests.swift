//
//  TLSDecryptionTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit
import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct TLSDecryptionStoreTests {
    private static let keyLogText = "CLIENT_RANDOM \(String(repeating: "ab", count: 32)) \(String(repeating: "cd", count: 48))\n"

    @Test func usingAKeyLogSavesOnlyItsPathAppliesItAndDecryptsOpenCaptures() async throws {
        let harness = try Harness()
        let url = try harness.writeFile("proxyman-keylog.txt", Self.keyLogText)

        let result = await harness.use(url)

        #expect(try result.get().sessionCount == 1)
        #expect(harness.store.keyLogFileURL == url)
        #expect(harness.store.activeKeyLogFileURL == url)
        #expect(harness.applied.last == url)
        #expect(harness.redissectCount == 1)
        #expect(harness.store.status == .ready(try result.get()))
        // Key contents stay in the file; defaults hold the path and the switch only.
        #expect(harness.defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { !$0.contains("CLIENT_RANDOM") })
    }

    @Test func aFileThatIsNotAKeyLogChangesNothing() async throws {
        let harness = try Harness()
        let current = try harness.writeFile("current.keys", Self.keyLogText)
        _ = await harness.use(current)
        let readme = try harness.writeFile("README.md", "Release notes\nNot a key log.\n")

        let result = await harness.use(readme)

        #expect(throws: TLSKeyLogFileError.notKeyLog(fileName: "README.md")) { try result.get() }
        #expect(harness.store.keyLogFileURL == current)
        #expect(harness.applied.last == current)
        #expect(harness.redissectCount == 1)
    }

    @Test func aMissingFileIsUnreadable() async throws {
        let harness = try Harness()

        let result = await harness.use(harness.directory.appendingPathComponent("gone.txt"))

        guard case .failure(.unreadable(let fileName, _)) = result else {
            Issue.record("Expected an unreadable-file error, got \(result).")
            return
        }
        #expect(fileName == "gone.txt")
        #expect(harness.store.keyLogFileURL == nil)
        #expect(harness.redissectCount == 0)
    }

    @Test func turningDecryptionOffKeepsTheFileButStopsUsingIt() async throws {
        let harness = try Harness()
        let url = try harness.writeFile("keys.txt", Self.keyLogText)
        _ = await harness.use(url)

        harness.store.setEnabled(false)
        #expect(harness.store.keyLogFileURL == url)
        #expect(harness.store.activeKeyLogFileURL == nil)
        #expect(harness.applied.last == .some(nil))
        #expect(harness.redissectCount == 2)

        harness.store.setEnabled(true)
        #expect(harness.applied.last == url)
        #expect(harness.redissectCount == 3)
    }

    @Test func removingTheKeyLogStopsDecryptionAndStartRestoresASavedOne() async throws {
        let harness = try Harness()
        let url = try harness.writeFile("keys.txt", Self.keyLogText)
        _ = await harness.use(url)

        // A new store (a later launch) hands the saved key log to Wireshark before any capture opens.
        let relaunched = harness.makeStore()
        relaunched.start()
        #expect(harness.applied.last == url)

        harness.store.removeKeyLogFile()
        #expect(harness.store.keyLogFileURL == nil)
        #expect(harness.applied.last == .some(nil))
        #expect(harness.store.status == .notConfigured)
    }

    @Test func refreshingReportsAKeyLogThatWasMovedAway() async throws {
        let harness = try Harness()
        let url = try harness.writeFile("keys.txt", Self.keyLogText)
        _ = await harness.use(url)
        try FileManager.default.removeItem(at: url)

        harness.store.refreshStatus()
        await harness.waitForStatus { $0 == .missing }

        #expect(harness.store.status == .missing)
        #expect(harness.store.activeKeyLogFileURL == url)
    }

    // An isolated store: its own defaults and folder, recording what it would hand to Wireshark.
    @MainActor
    private final class Harness {
        let defaults: UserDefaults
        let directory: URL
        private(set) var applied: [URL?] = []
        private(set) var redissectCount = 0
        private(set) var store: TLSDecryptionStore!

        init() throws {
            let suiteName = "TCPViewer.TLSDecryptionStoreTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = makeStore()
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func makeStore() -> TLSDecryptionStore {
            TLSDecryptionStore(
                defaults: defaults,
                applyKeyLogFile: { [weak self] in self?.applied.append($0) },
                redissectOpenCaptures: { [weak self] in self?.redissectCount += 1 }
            )
        }

        func writeFile(_ name: String, _ contents: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url.standardizedFileURL
        }

        func use(_ url: URL) async -> Result<TLSKeyLogSummary, TLSKeyLogFileError> {
            await withCheckedContinuation { continuation in
                store.useKeyLogFile(at: url) { continuation.resume(returning: $0) }
            }
        }

        func waitForStatus(_ condition: (TLSKeyLogStatus) -> Bool) async {
            for _ in 0..<200 where !condition(store.status) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }
}

struct TLSInspectorNoticeTests {
    private let keyLogURL = URL(fileURLWithPath: "/tmp/tlskeylog.txt")

    @Test func encryptedApplicationDataAsksForAKeyLogOrExplainsMissingKeys() {
        let inspection = makeInspection(fieldNames: ["tls", "tls.app_data"])

        #expect(TLSInspectorNotice.make(for: inspection, activeKeyLogURL: nil) == .encryptedWithoutKeyLog)
        #expect(TLSInspectorNotice.make(for: inspection, activeKeyLogURL: keyLogURL) == .encryptedWithKeyLog(fileName: "tlskeylog.txt"))
    }

    @Test func decryptedPacketsNameTheirKeySource() {
        let inspection = makeInspection(fieldNames: ["tls.app_data", "http.request.method"], byteViewLabels: ["Frame", "Decrypted TLS"])

        #expect(TLSInspectorNotice.make(for: inspection, activeKeyLogURL: keyLogURL) == .decrypted(keyLogFileName: "tlskeylog.txt"))
        // Keys from a PCAPNG Decryption Secrets Block decrypt without any key log.
        #expect(TLSInspectorNotice.make(for: inspection, activeKeyLogURL: nil) == .decrypted(keyLogFileName: nil))
    }

    @Test func packetsWithoutEncryptedPayloadShowNoNotice() {
        #expect(TLSInspectorNotice.make(for: makeInspection(fieldNames: ["tls.handshake.type"]), activeKeyLogURL: nil) == nil)
        #expect(TLSInspectorNotice.make(for: nil, activeKeyLogURL: keyLogURL) == nil)
    }

    @Test func noticeViewShowsTheActionsForEachState() {
        let view = TLSInspectorNoticeView(frame: .zero)

        view.render(.encryptedWithoutKeyLog)
        #expect(!view.isHidden && view.buttonTitles == ["Add Key Log File…", "TLS Settings…"])
        view.render(.encryptedWithKeyLog(fileName: "tlskeylog.txt"))
        #expect(view.message.contains("tlskeylog.txt") && view.buttonTitles == ["Decrypt Again", "TLS Settings…"])
        view.render(.decrypted(keyLogFileName: "tlskeylog.txt"))
        #expect(view.title == "Decrypted with “tlskeylog.txt”" && view.buttonTitles == ["Show Decrypted Bytes"])
        view.render(nil)
        #expect(view.isHidden)
    }

    @Test func onlyUndecryptedTLSRowsCountAsEncryptedApplicationData() {
        func packet(_ protocolSummary: String?, _ info: String) -> PacketSummary {
            PacketSummary(
                packetNumber: 1,
                timestamp: Date(timeIntervalSince1970: 1),
                source: .offline,
                transportHint: .tls,
                protocolSummary: protocolSummary,
                endpoints: PacketEndpoints(source: PacketEndpoint(address: "10.0.0.1", port: 50_000), destination: PacketEndpoint(address: "10.0.0.2", port: 443)),
                originalLength: 100,
                capturedLength: 100,
                infoSummary: info,
                layers: [],
                decodeStatus: PacketDecodeStatus(kind: .complete),
                captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
            )
        }

        #expect(packet("TLSv1.3", "Application Data").tcpviewerIsEncryptedTLSApplicationData)
        #expect(packet("QUIC", "Protected Payload (KP0)").tcpviewerIsEncryptedTLSApplicationData)
        #expect(!packet("HTTP", "GET / HTTP/1.1").tcpviewerIsEncryptedTLSApplicationData)
        #expect(!packet("TLSv1.3", "Client Hello (SNI=example.com)").tcpviewerIsEncryptedTLSApplicationData)
        #expect(!packet(nil, "Application Data").tcpviewerIsEncryptedTLSApplicationData)
    }

    private func makeInspection(fieldNames: [String], byteViewLabels: [String] = ["Frame"]) -> PacketInspection {
        PacketInspection(
            packetID: 1,
            packetNumber: 1,
            rawBytes: Data([0x17, 0x03, 0x03]),
            byteViews: byteViewLabels.enumerated().map { PacketByteView(id: "source-\($0.offset)", label: $0.element, bytes: Data([0x01])) },
            detailNodes: [PacketDetailNode(
                id: "root",
                name: "Transport Layer Security",
                kind: .layer,
                children: fieldNames.map { PacketDetailNode(id: $0, name: $0, fieldName: $0) }
            )],
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }
}

@Suite(.serialized)
@MainActor
struct TCPViewerMCPTLSDecryptionTests {
    @Test func readsAndChangesTheKeyLogThroughMCP() async throws {
        let suiteName = "TCPViewer.TCPViewerMCPTLSDecryptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TLSDecryptionStore(defaults: defaults, applyKeyLogFile: { _ in }, redissectOpenCaptures: {})
        let router = TCPViewerMCPCommandRouter(
            dataSourceProvider: { nil },
            isLicenseAuthorized: { true },
            redactionEnabled: { true },
            tlsDecryption: { store }
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyLog = directory.appendingPathComponent("tlskeylog.txt")
        try Data("CLIENT_HANDSHAKE_TRAFFIC_SECRET \(String(repeating: "ab", count: 32)) \(String(repeating: "cd", count: 32))\n".utf8).write(to: keyLog)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("not keys\n".utf8).write(to: notes)

        let empty = await routeMCP(router, command: .getTLSDecryption)
        #expect(empty.success && empty.value("key_log") == .null)

        // Bad arguments and files that are not key logs leave the setting alone.
        let invalidRequests: [[String: TCPViewerMCPValue]?] = [
            nil,
            ["key_log_path": .string("relative/keys.txt")],
            ["key_log_path": .string(directory.path)],
            ["key_log_path": .string(notes.path)],
            ["key_log_path": .string(keyLog.path), "tab_id": .string(UUID().uuidString)],
        ]
        for params in invalidRequests {
            #expect(!(await routeMCP(router, command: .updateTLSDecryption, params: params)).success)
        }
        #expect(store.keyLogFileURL == nil)

        let set = await routeMCP(router, command: .updateTLSDecryption, params: ["key_log_path": .string(keyLog.path)])
        guard case .object(let file)? = set.value("key_log") else {
            Issue.record("Expected key_log details, got \(set).")
            return
        }
        #expect(set.success && set.value("decrypting") == .bool(true))
        #expect(file["status"] == .string("ready") && file["tls_connection_count"] == .int(1) && file["key_count"] == .int(1))

        let off = await routeMCP(router, command: .updateTLSDecryption, params: ["enabled": .bool(false)])
        #expect(off.value("enabled") == .bool(false) && off.value("decrypting") == .bool(false))

        let removed = await routeMCP(router, command: .updateTLSDecryption, params: ["key_log_path": .string("")])
        #expect(removed.success && removed.value("key_log") == .null && store.keyLogFileURL == nil)
    }
}
