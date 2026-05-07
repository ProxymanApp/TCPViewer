//
//  TCPViewerNetworkHelperLogger.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 7/5/26.
//

import Foundation

enum TCPViewerNetworkHelperLogOperation {
    case launchStatus
    case install
    case repair
    case remove

    var label: String {
        switch self {
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
        case .launchStatus:
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

    init(output: @escaping (String) -> Void = { print($0) }) {
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

private extension TCPViewerNetworkHelperToolSnapshot {
    var logDescription: String {
        "status=\(status.rawValue), authorization=\(authorizationStatus.logDescription), message=\"\(message)\""
    }
}

private extension TCPViewerNetworkHelperAuthorizationStatus {
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
