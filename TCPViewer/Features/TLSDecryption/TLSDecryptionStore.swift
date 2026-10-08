//
//  TLSDecryptionStore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import CryptoKit
import Foundation
import PcapPlusPlusCore

struct TLSKeyLogFile: Identifiable, Equatable {
    enum Status: Equatable {
        case reading
        case ready(sessionCount: Int, keyCount: Int, skippedLineCount: Int)
        case noKeys
        case missing
        case unreadable
        case tooLarge
    }

    let url: URL
    var isEnabled: Bool
    var status: Status

    var id: String {
        url.path
    }
}

struct TLSDecryptionSnapshot: Equatable {
    var isEnabled: Bool
    var files: [TLSKeyLogFile]
    var activityMessage: String
}

protocol TLSDecryptionStoreDelegate: AnyObject {
    func tlsDecryptionStoreDidChange(_ store: TLSDecryptionStore)
    // The keys the dissector uses changed, so captures that are already loaded must be dissected again.
    func tlsDecryptionStoreDidApplyKeyLog(_ store: TLSDecryptionStore)
}

// App-wide list of TLS key log files. Only file paths are persisted: key material is read on demand,
// handed to the core, and never stored or logged here.
final class TLSDecryptionStore {
    typealias KeyLogApplier = (_ keyLogs: [TLSKeyLog], _ completion: @escaping () -> Void) -> Void
    typealias KeyLogAppender = (_ keyLog: TLSKeyLog, _ completion: @escaping () -> Void) -> Void

    static let maximumFileCount = 16
    private static let defaultsKey = "TCPViewer.settings.tlsDecryption.v1"

    private struct PersistedState: Codable {
        var isEnabled: Bool
        var files: [PersistedFile]
    }

    private struct PersistedFile: Codable {
        var path: String
        var isEnabled: Bool
    }

    private struct LoadedFile {
        let id: String
        let status: TLSKeyLogFile.Status
        let keyLog: TLSKeyLog
        // End of the last complete line that was read, or nil when the file cannot be followed.
        let monitorOffset: UInt64?
    }

    weak var delegate: TLSDecryptionStoreDelegate?

    private(set) var snapshot: TLSDecryptionSnapshot {
        didSet {
            guard snapshot != oldValue else {
                return
            }
            delegate?.tlsDecryptionStoreDidChange(self)
        }
    }

    private let defaults: UserDefaults
    private let applyKeyLogs: KeyLogApplier
    private let appendKeyLog: KeyLogAppender
    private let monitorsFiles: Bool
    private var monitors: [TLSKeyLogFileMonitor] = []
    private let workQueue = DispatchQueue(label: "com.proxyman.tcpviewer.TLSDecryption.store", qos: .userInitiated)
    private var reloadGeneration = 0
    // A digest instead of the applied lines, so this store never holds a second copy of the secrets.
    private var appliedKeyLogDigest = TLSDecryptionStore.digest(of: [])

    init(
        defaults: UserDefaults,
        monitorsFiles: Bool = true,
        applyKeyLogs: @escaping KeyLogApplier = TLSKeyLogRegistry.apply,
        appendKeyLog: @escaping KeyLogAppender = TLSKeyLogRegistry.append
    ) {
        self.defaults = defaults
        self.monitorsFiles = monitorsFiles
        self.applyKeyLogs = applyKeyLogs
        self.appendKeyLog = appendKeyLog
        let persisted = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) }
        snapshot = TLSDecryptionSnapshot(
            isEnabled: persisted?.isEnabled ?? true,
            files: (persisted?.files ?? []).prefix(Self.maximumFileCount).map {
                TLSKeyLogFile(url: URL(fileURLWithPath: $0.path), isEnabled: $0.isEnabled, status: .reading)
            },
            activityMessage: ""
        )
    }

    func setEnabled(_ isEnabled: Bool) {
        guard snapshot.isEnabled != isEnabled else {
            return
        }
        snapshot.isEnabled = isEnabled
        persistAndReload()
    }

    // Add files that are not listed yet, up to the file limit.
    func addFiles(at urls: [URL]) {
        var files = snapshot.files
        var isOverLimit = false
        for url in urls.map(\.standardizedFileURL) where !url.hasDirectoryPath {
            guard !files.contains(where: { $0.id == url.path }) else {
                continue
            }
            guard files.count < Self.maximumFileCount else {
                isOverLimit = true
                break
            }
            files.append(TLSKeyLogFile(url: url, isEnabled: true, status: .reading))
        }
        guard files != snapshot.files else {
            if isOverLimit {
                snapshot.activityMessage = Self.fileLimitMessage
            }
            return
        }
        snapshot.files = files
        persistAndReload()
        if isOverLimit {
            snapshot.activityMessage = Self.fileLimitMessage
        }
    }

    func removeFiles(withIDs ids: Set<String>) {
        let files = snapshot.files.filter { !ids.contains($0.id) }
        guard files.count != snapshot.files.count else {
            return
        }
        snapshot.files = files
        persistAndReload()
    }

    func setFile(withID id: String, enabled isEnabled: Bool) {
        guard let index = snapshot.files.firstIndex(where: { $0.id == id }),
              snapshot.files[index].isEnabled != isEnabled else {
            return
        }
        snapshot.files[index].isEnabled = isEnabled
        persistAndReload()
    }

    // Read the listed files again and hand their keys to the dissector when the usable keys changed.
    // Called at launch and when a live capture stops, because key logs grow while traffic flows.
    func reload(completion: (() -> Void)? = nil) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let files = snapshot.files
        let isEnabled = snapshot.isEnabled
        workQueue.async {
            let loadedFiles = files.map(Self.load)
            DispatchQueue.main.async { [weak self] in
                // A newer reload already reflects the latest list; applying this one would undo it.
                guard let self, self.reloadGeneration == generation else {
                    completion?()
                    return
                }
                self.finishReload(loadedFiles, files: files, isEnabled: isEnabled, completion: completion)
            }
        }
    }

    // Show what the last in-place re-dissection changed, so the user can tell whether the keys matched.
    func reportRedissection(captureTitle: String, result: Result<Int, Error>) {
        switch result {
        case .success(let changedPacketCount) where changedPacketCount > 0:
            let noun = changedPacketCount == 1 ? "packet" : "packets"
            snapshot.activityMessage = "Updated \(changedPacketCount) \(noun) in \(captureTitle)."
        case .success:
            snapshot.activityMessage = hasUsableKeys
                ? "No packets in \(captureTitle) match these keys."
                : "No packets changed in \(captureTitle)."
        case .failure(let error):
            let coreError = error as? TCPViewerCoreError
            // A superseded pass is followed by the one that replaced it, which reports the real outcome.
            guard coreError?.code != .operationCancelled else {
                return
            }
            snapshot.activityMessage = "\(captureTitle): \(coreError?.message ?? error.localizedDescription)"
        }
    }

    private static let fileLimitMessage = "Up to \(maximumFileCount) key log files can be listed."

    private var hasUsableKeys: Bool {
        snapshot.isEnabled && snapshot.files.contains { file in
            if case .ready = file.status {
                return file.isEnabled
            }
            return false
        }
    }

    private func persistAndReload() {
        let state = PersistedState(
            isEnabled: snapshot.isEnabled,
            files: snapshot.files.map { PersistedFile(path: $0.url.path, isEnabled: $0.isEnabled) }
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        reload()
    }

    private func finishReload(
        _ loadedFiles: [LoadedFile],
        files: [TLSKeyLogFile],
        isEnabled: Bool,
        completion: (() -> Void)?
    ) {
        let statusByID = Dictionary(loadedFiles.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        snapshot.files = files.map { file in
            var file = file
            file.status = statusByID[file.id] ?? file.status
            return file
        }

        let enabledIDs = Set(files.filter(\.isEnabled).map(\.id))
        let contributingFiles = isEnabled ? loadedFiles.filter { enabledIDs.contains($0.id) } : []
        restartMonitors(for: contributingFiles)
        let keyLogs = contributingFiles.filter { !$0.keyLog.isEmpty }.map(\.keyLog)
        let digest = Self.digest(of: keyLogs)
        guard digest != appliedKeyLogDigest else {
            completion?()
            return
        }

        appliedKeyLogDigest = digest
        applyKeyLogs(keyLogs) {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.snapshot.activityMessage = self.appliedMessage(hasKeys: !keyLogs.isEmpty)
                self.delegate?.tlsDecryptionStoreDidApplyKeyLog(self)
                completion?()
            }
        }
    }

    // Follow every file that contributes keys from where this reload stopped reading. Appended keys
    // go straight to the dissector so a running capture can use them; they do not trigger a
    // re-dissection, which a running capture could not do anyway. The reload at capture stop does.
    private func restartMonitors(for loadedFiles: [LoadedFile]) {
        monitors.removeAll()
        guard monitorsFiles else {
            return
        }
        for loadedFile in loadedFiles {
            guard let monitorOffset = loadedFile.monitorOffset else {
                continue
            }
            let monitor = TLSKeyLogFileMonitor(
                url: URL(fileURLWithPath: loadedFile.id),
                startOffset: monitorOffset,
                queue: workQueue,
                appendHandler: { [weak self] data in
                    let keyLog = TLSKeyLogParser.parse(data)
                    guard !keyLog.isEmpty else {
                        return
                    }
                    DispatchQueue.main.async {
                        self?.appendKeyLog(keyLog) {}
                    }
                },
                resetHandler: { [weak self] in
                    DispatchQueue.main.async {
                        self?.reload()
                    }
                }
            )
            monitor.start()
            monitors.append(monitor)
        }
    }

    private func appliedMessage(hasKeys: Bool) -> String {
        if !snapshot.isEnabled {
            return "TLS decryption is off."
        }
        if hasKeys {
            return "Keys loaded."
        }
        return snapshot.files.isEmpty ? "" : "No usable keys in the enabled files."
    }

    // Read and validate one file off the main thread. Sizes are checked first so a wrong pick
    // (e.g. a multi-gigabyte capture) is rejected without being read.
    private static func load(_ file: TLSKeyLogFile) -> LoadedFile {
        func result(
            _ status: TLSKeyLogFile.Status,
            _ keyLog: TLSKeyLog = .empty,
            monitorOffset: UInt64? = nil
        ) -> LoadedFile {
            LoadedFile(id: file.id, status: status, keyLog: keyLog, monitorOffset: monitorOffset)
        }

        let path = file.url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return result(.missing)
        }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= TLSKeyLogParser.maximumInputBytes else {
            return result(.tooLarge)
        }
        guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
            return result(.unreadable)
        }

        // A line still being written is re-read by the monitor once its newline arrives.
        let monitorOffset = UInt64(data.lastIndex(of: UInt8(ascii: "\n")).map { $0 - data.startIndex + 1 } ?? 0)
        let keyLog = TLSKeyLogParser.parse(data)
        guard !keyLog.isEmpty else {
            return result(.noKeys, monitorOffset: monitorOffset)
        }
        return result(
            .ready(
                sessionCount: keyLog.sessionCount,
                keyCount: keyLog.keyCount,
                skippedLineCount: keyLog.skippedLineCount
            ),
            keyLog,
            monitorOffset: monitorOffset
        )
    }

    private static func digest(of keyLogs: [TLSKeyLog]) -> SHA256.Digest {
        var hasher = SHA256()
        for keyLog in keyLogs {
            hasher.update(data: keyLog.lines)
        }
        return hasher.finalize()
    }
}
