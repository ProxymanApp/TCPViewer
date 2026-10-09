//
//  TLSKeyLogFileMonitorTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TLSKeyLogFileMonitorTests {
    private let firstLine = "CLIENT_RANDOM \(String(repeating: "a1", count: 32)) \(String(repeating: "01", count: 48))\n"
    private let secondLine = "CLIENT_RANDOM \(String(repeating: "b2", count: 32)) \(String(repeating: "02", count: 48))\n"

    @Test func appendedLineIsDeliveredOnlyOnceItIsComplete() async throws {
        let fixture = try MonitorFixture(initialContent: firstLine)
        defer { fixture.tearDown() }
        let monitor = fixture.makeMonitor(startOffset: UInt64(firstLine.utf8.count))
        monitor.start()

        // A writer can be caught mid-line; half a secret must never reach the dissector.
        let splitIndex = secondLine.index(secondLine.startIndex, offsetBy: 40)
        try fixture.append(String(secondLine[..<splitIndex]))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fixture.events.appended.isEmpty)

        try fixture.append(String(secondLine[splitIndex...]))
        await fixture.waitUntil { !fixture.events.appended.isEmpty }

        #expect(fixture.events.appended.joined() == secondLine)
        #expect(fixture.events.resetCount == 0)
    }

    @Test func linesWrittenBeforeTheMonitorStartedAreNotMissed() async throws {
        let fixture = try MonitorFixture(initialContent: firstLine + secondLine)
        defer { fixture.tearDown() }
        // The owner read only the first line before the second one landed.
        let monitor = fixture.makeMonitor(startOffset: UInt64(firstLine.utf8.count))

        monitor.start()
        await fixture.waitUntil { !fixture.events.appended.isEmpty }

        #expect(fixture.events.appended == [secondLine])
    }

    @Test func truncatedFileAsksForAFullReload() async throws {
        let fixture = try MonitorFixture(initialContent: firstLine + secondLine)
        defer { fixture.tearDown() }
        let monitor = fixture.makeMonitor(startOffset: UInt64((firstLine + secondLine).utf8.count))
        monitor.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        try FileHandle(forWritingTo: fixture.url).truncate(atOffset: 0)
        await fixture.waitUntil { fixture.events.resetCount > 0 }

        #expect(fixture.events.resetCount == 1)
        #expect(fixture.events.appended.isEmpty)
    }

    @Test func replacedFileAsksForAFullReload() async throws {
        let fixture = try MonitorFixture(initialContent: firstLine)
        defer { fixture.tearDown() }
        let monitor = fixture.makeMonitor(startOffset: UInt64(firstLine.utf8.count))
        monitor.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Editors and log rotation write a new file and rename it over the old one.
        try Data((firstLine + secondLine).utf8).write(to: fixture.url, options: .atomic)
        await fixture.waitUntil { fixture.events.resetCount > 0 }

        #expect(fixture.events.resetCount == 1)
    }

    @MainActor
    @Test func storeHandsAppendedKeysToTheDissectorWithoutReplacingTheKeyLog() async throws {
        let fixture = try MonitorFixture(initialContent: firstLine)
        defer { fixture.tearDown() }
        let suiteName = "TLSKeyLogFileMonitorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appliedCount = Counter()
        let appendedLines = Counter()
        let store = TLSDecryptionStore(
            defaults: defaults,
            applyKeyLogs: { _, completion in
                appliedCount.increment()
                completion()
            },
            appendKeyLog: { keyLog, completion in
                appendedLines.record(String(decoding: keyLog.lines, as: UTF8.self))
                completion()
            }
        )
        store.addFiles(at: [fixture.url])
        await withCheckedContinuation { continuation in store.reload { continuation.resume() } }
        #expect(appliedCount.value == 1)

        try fixture.append(secondLine)
        await fixture.waitUntil { !appendedLines.texts.isEmpty }

        // The running capture gets the new key at once; a full replace waits for the next reload.
        #expect(appendedLines.texts == [secondLine])
        #expect(appliedCount.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var recordedTexts: [String] = []

    var value: Int { lock.withLock { count } }
    var texts: [String] { lock.withLock { recordedTexts } }

    func increment() {
        lock.withLock { count += 1 }
    }

    func record(_ text: String) {
        lock.withLock { recordedTexts.append(text) }
    }
}

private final class MonitorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var appendedTexts: [String] = []
    private var resets = 0

    var appended: [String] { lock.withLock { appendedTexts } }
    var resetCount: Int { lock.withLock { resets } }

    func didAppend(_ data: Data) {
        lock.withLock { appendedTexts.append(String(decoding: data, as: UTF8.self)) }
    }

    func didReset() {
        lock.withLock { resets += 1 }
    }
}

private struct MonitorFixture {
    let directory: URL
    let url: URL
    let events = MonitorEvents()
    private let queue = DispatchQueue(label: "TLSKeyLogFileMonitorTests")

    init(initialContent: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TLSKeyLogFileMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("keys.log").standardizedFileURL
        try Data(initialContent.utf8).write(to: url)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeMonitor(startOffset: UInt64) -> TLSKeyLogFileMonitor {
        TLSKeyLogFileMonitor(
            url: url,
            startOffset: startOffset,
            queue: queue,
            appendHandler: events.didAppend,
            resetHandler: events.didReset
        )
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
