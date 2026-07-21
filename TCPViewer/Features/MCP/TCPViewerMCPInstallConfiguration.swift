//
//  TCPViewerMCPInstallConfiguration.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation

enum TCPViewerMCPClientConfiguration: String, CaseIterable, Identifiable {
    case codex
    case claude
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        case .manual:
            return "Manual"
        }
    }
}

struct TCPViewerMCPInstallConfiguration {
    let executableURL: URL

    init(executableURL: URL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/tcpviewer-mcp")) {
        self.executableURL = executableURL
    }

    func text(for client: TCPViewerMCPClientConfiguration) -> String {
        switch client {
        case .codex:
            return "codex mcp add tcpviewer -- \(Self.shellQuoted(executableURL.path))"
        case .claude:
            return "claude mcp add --transport stdio --scope user tcpviewer -- \(Self.shellQuoted(executableURL.path))"
        case .manual:
            return manualJSON
        }
    }

    func detail(for client: TCPViewerMCPClientConfiguration) -> String {
        switch client {
        case .codex:
            return "Run this command in Terminal to add TCP Viewer MCP to Codex."
        case .claude:
            return "Run this command in Terminal to add TCP Viewer MCP to Claude Code for your user account."
        case .manual:
            return "Add this entry to an MCP client's JSON configuration, then restart that client."
        }
    }

    private var manualJSON: String {
        let object: [String: Any] = [
            "mcpServers": [
                "tcpviewer": [
                    "args": [],
                    "command": executableURL.path,
                ] as [String: Any],
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
