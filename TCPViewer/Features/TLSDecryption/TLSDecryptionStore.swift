//
//  TLSDecryptionStore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import Foundation
import PcapPlusPlusCore

// The app-wide TLS key log: it remembers the file, hands it to Wireshark and re-dissects open captures.
// Only the file path is saved; key contents stay in the file and are never copied or logged.
final class TLSDecryptionStore {
    static let didChangeNotification = Notification.Name("TLSDecryptionStoreDidChange")
    static let shared = TLSDecryptionStore()

    private enum Key {
        static let keyLogPath = "TCPViewer.settings.tlsDecryption.keyLogPath"
        static let isEnabled = "TCPViewer.settings.tlsDecryption.isEnabled"
    }

    private static let statusRefreshDelay: DispatchTimeInterval = .milliseconds(500)

    private let defaults: UserDefaults
    private let workQueue: DispatchQueue
    private let applyKeyLogFile: (URL?) -> Void
    private let summarizeKeyLog: (URL) throws -> TLSKeyLogSummary
    private let redissectOpenCaptures: () -> Void
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var pendingStatusRefresh: DispatchWorkItem?
    private var statusRequestGeneration = 0

    private(set) var status: TLSKeyLogStatus = .notConfigured {
        didSet {
            guard status != oldValue else { return }
            notifyChange()
        }
    }

    init(
        defaults: UserDefaults = .standard,
        workQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.tls-decryption", qos: .utility),
        applyKeyLogFile: @escaping (URL?) -> Void = TLSKeyLog.setKeyLogFile,
        summarizeKeyLog: @escaping (URL) throws -> TLSKeyLogSummary = TLSKeyLog.summarize(fileAt:),
        redissectOpenCaptures: @escaping () -> Void = TCPViewerWorkspaceController.redissectAllForTLSKeyLog
    ) {
        self.defaults = defaults
        self.workQueue = workQueue
        self.applyKeyLogFile = applyKeyLogFile
        self.summarizeKeyLog = summarizeKeyLog
        self.redissectOpenCaptures = redissectOpenCaptures
        defaults.register(defaults: [Key.isEnabled: true])
    }

    deinit {
        fileMonitor?.cancel()
    }

    var keyLogFileURL: URL? {
        guard let path = defaults.string(forKey: Key.keyLogPath), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Key.isEnabled)
    }

    // The file Wireshark reads: the chosen key log while decryption is on.
    var activeKeyLogFileURL: URL? {
        isEnabled ? keyLogFileURL : nil
    }

    // Hand the saved key log to Wireshark at launch, before any capture is dissected.
    func start() {
        applyKeyLogFile(activeKeyLogFileURL)
        refreshStatus()
    }

    // Check the file first so a capture or a README is never used as a key log; nothing changes on failure.
    func useKeyLogFile(at url: URL, completion: @escaping (Result<TLSKeyLogSummary, TLSKeyLogFileError>) -> Void) {
        let fileURL = url.standardizedFileURL
        let summarizeKeyLog = summarizeKeyLog
        workQueue.async {
            let result: Result<TLSKeyLogSummary, TLSKeyLogFileError>
            do {
                let summary = try summarizeKeyLog(fileURL)
                result = summary.isKeyLog ? .success(summary) : .failure(.notKeyLog(fileName: fileURL.lastPathComponent))
            } catch {
                result = .failure(.unreadable(fileName: fileURL.lastPathComponent, reason: Self.readFailureReason(error)))
            }
            DispatchQueue.main.async {
                if case .success(let summary) = result {
                    self.save(keyLogURL: fileURL, isEnabled: true)
                    self.statusRequestGeneration += 1
                    self.status = .ready(summary)
                    self.monitorKeyLogFile()
                }
                completion(result)
            }
        }
    }

    func removeKeyLogFile() {
        guard keyLogFileURL != nil else { return }
        save(keyLogURL: nil, isEnabled: true)
        refreshStatus()
    }

    func setEnabled(_ isEnabled: Bool) {
        guard isEnabled != self.isEnabled else { return }
        save(keyLogURL: keyLogFileURL, isEnabled: isEnabled)
    }

    // Dissect open captures again, e.g. after the key log gained keys for a capture that is already open.
    func decryptOpenCapturesAgain() {
        redissectOpenCaptures()
    }

    // Read the key log in the background; the newest request wins when the file changes quickly.
    func refreshStatus() {
        statusRequestGeneration += 1
        let generation = statusRequestGeneration
        guard let url = keyLogFileURL else {
            stopMonitoringKeyLogFile()
            status = .notConfigured
            return
        }
        if case .ready = status {} else {
            status = .reading
        }
        let summarizeKeyLog = summarizeKeyLog
        workQueue.async {
            let nextStatus: TLSKeyLogStatus
            if !FileManager.default.fileExists(atPath: url.path) {
                nextStatus = .missing
            } else {
                do {
                    let summary = try summarizeKeyLog(url)
                    nextStatus = summary.isKeyLog ? .ready(summary) : .notKeyLog
                } catch {
                    nextStatus = .unreadable(Self.readFailureReason(error))
                }
            }
            DispatchQueue.main.async {
                guard generation == self.statusRequestGeneration else { return }
                self.status = nextStatus
                self.monitorKeyLogFile()
            }
        }
    }

    // Persist the choice, give Wireshark the file it should read now and re-dissect when that file changed.
    private func save(keyLogURL: URL?, isEnabled: Bool) {
        let previousActiveURL = activeKeyLogFileURL
        if let keyLogURL {
            defaults.set(keyLogURL.path, forKey: Key.keyLogPath)
        } else {
            defaults.removeObject(forKey: Key.keyLogPath)
        }
        defaults.set(isEnabled, forKey: Key.isEnabled)
        applyKeyLogFile(activeKeyLogFileURL)
        notifyChange()
        // Choosing a key log again also re-dissects: it may hold keys it did not have before.
        if previousActiveURL != activeKeyLogFileURL || (keyLogURL != nil && isEnabled) {
            redissectOpenCaptures()
        }
    }

    // Keep the key count current while Proxyman appends keys; Wireshark itself reads appended lines on demand.
    private func monitorKeyLogFile() {
        stopMonitoringKeyLogFile()
        guard let url = keyLogFileURL else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleStatusRefresh()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileMonitor = source
        source.resume()
    }

    private func stopMonitoringKeyLogFile() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    private func scheduleStatusRefresh() {
        pendingStatusRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshStatus()
        }
        pendingStatusRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusRefreshDelay, execute: workItem)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func readFailureReason(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return "Check that you have permission to read it."
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return "The file was moved or deleted."
        }
        return nsError.localizedDescription
    }
}
