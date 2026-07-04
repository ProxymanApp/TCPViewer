//
//  TCPViewerNetworkHelperLogger.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 7/5/26.
//

import Foundation
import ServiceManagement

enum TCPViewerNetworkHelperLogOperation {
    case statusCheck
    case launchStatus
    case install
    case repair
    case remove

    var label: String {
        switch self {
        case .statusCheck:
            "Helper status check"
        case .launchStatus:
            "Launch helper status"
        case .install:
            "Install helper tool"
        case .repair:
            "Repair helper tool"
        case .remove:
            "Remove helper tool"
        }
    }

    func succeeded(with snapshot: TCPViewerNetworkHelperToolSnapshot) -> Bool {
        switch self {
        case .statusCheck, .launchStatus:
            snapshot.status == .ready
        case .install, .repair:
            snapshot.status == .ready ||
                snapshot.status == .installedNeedsRelaunch ||
                snapshot.status == .waitingForApproval
        case .remove:
            snapshot.status == .notInstalled
        }
    }
}

final class TCPViewerNetworkHelperLogger {
    enum Mode: String {
        case debug
        case error

        var emoji: String {
            switch self {
            case .debug:
                "🔧"
            case .error:
                "❌"
            }
        }
    }

    private let output: (String) -> Void

    init(output: @escaping (String) -> Void = TCPViewerNetworkHelperLogFileWriter.shared.append) {
        self.output = output
    }

    // Log a successful or failed helper lifecycle result in one compact line.
    func log(_ operation: TCPViewerNetworkHelperLogOperation, snapshot: TCPViewerNetworkHelperToolSnapshot) {
        let succeeded = operation.succeeded(with: snapshot)
        let mode: Mode = succeeded ? .debug : .error
        let resultEmoji = succeeded ? "✅" : "⚠️"
        log(
            mode,
            "\(resultEmoji) \(operation.label) \(succeeded ? "succeeded" : "failed"): \(snapshot.logDescription)"
        )
    }

    // Always include the underlying error when ServiceManagement or authorization fails.
    func logFailure(
        _ operation: TCPViewerNetworkHelperLogOperation,
        error: Error,
        snapshot: TCPViewerNetworkHelperToolSnapshot? = nil
    ) {
        let suffix = snapshot.map { " | \($0.logDescription)" } ?? ""
        log(.error, "💥 \(operation.label) failed: \(error.localizedDescription)\(suffix)")
    }

    func log(_ mode: Mode, _ message: String) {
        output("[TCPViewer][HelperTool] \(Self.timestamp()) \(mode.emoji) \(mode.rawValue.uppercased()): \(message)")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

final class TCPViewerNetworkHelperLogFileWriter {
    static let shared = TCPViewerNetworkHelperLogFileWriter(userDataDirectory: .shared)
    static let logFileName = "network-helper.log"

    private let userDataDirectory: TCPViewerUserDataDirectory
    private let fileManager: FileManager
    private let mirrorToConsole: Bool
    private let queue = DispatchQueue(label: "com.proxyman.tcpviewer.NetworkHelperLogFileWriter")

    init(
        userDataDirectory: TCPViewerUserDataDirectory,
        fileManager: FileManager = .default,
        mirrorToConsole: Bool = true
    ) {
        self.userDataDirectory = userDataDirectory
        self.fileManager = fileManager
        self.mirrorToConsole = mirrorToConsole
    }

    var logFileURL: URL {
        userDataDirectory.logsDirectoryURL.appendingPathComponent(Self.logFileName)
    }

    // Append synchronously so launch-time helper failures are on disk before the user opens Logs.
    func append(_ message: String) {
        queue.sync {
            do {
                let logsURL = try userDataDirectory.createLogsDirectoryIfNeeded()
                let fileURL = logsURL.appendingPathComponent(Self.logFileName)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    _ = fileManager.createFile(atPath: fileURL.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(Data((message + "\n").utf8))
            } catch {
                print("[TCPViewer][HelperTool] Failed to write helper log: \(error.localizedDescription)")
            }

            if mirrorToConsole {
                print(message)
            }
        }
    }
}

private extension TCPViewerNetworkHelperToolSnapshot {
    var logDescription: String {
        let diagnosticSuffix = diagnosticDescription.map { ", diagnostics=\"\($0)\"" } ?? ""
        return "status=\(status.rawValue), authorization=\(authorizationStatus.logDescription), installedVersion=\(installedHelperToolVersion ?? "none"), message=\"\(message)\"\(diagnosticSuffix)"
    }
}

extension TCPViewerNetworkHelperAuthorizationStatus {
    var logDescription: String {
        switch self {
        case .notRegistered:
            "notRegistered"
        case .enabled:
            "enabled"
        case .requiresApproval:
            "requiresApproval"
        case .notFound:
            "notFound"
        case .unknown(let rawValue):
            "unknown(\(rawValue))"
        }
    }
}

extension SMAppService.Status {
    var logDescription: String {
        switch self {
        case .notRegistered:
            "notRegistered"
        case .enabled:
            "enabled"
        case .requiresApproval:
            "requiresApproval"
        case .notFound:
            "notFound"
        @unknown default:
            "unknown(\(rawValue))"
        }
    }
}
