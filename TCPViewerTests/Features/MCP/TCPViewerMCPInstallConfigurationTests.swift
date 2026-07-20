//
//  TCPViewerMCPInstallConfigurationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerMCPInstallConfigurationTests {
    @Test func producesCodexClaudeAndManualConfigurations() throws {
        let executable = URL(fileURLWithPath: "/Applications/TCP Viewer.app/Contents/MacOS/tcpviewer-mcp")
        let configuration = TCPViewerMCPInstallConfiguration(executableURL: executable)

        #expect(configuration.text(for: .codex) == "codex mcp add tcpviewer -- '/Applications/TCP Viewer.app/Contents/MacOS/tcpviewer-mcp'")
        #expect(configuration.text(for: .claude) == "claude mcp add --transport stdio --scope user tcpviewer -- '/Applications/TCP Viewer.app/Contents/MacOS/tcpviewer-mcp'")

        let manualData = try #require(configuration.text(for: .manual).data(using: .utf8))
        let manual = try #require(JSONSerialization.jsonObject(with: manualData) as? [String: Any])
        let servers = try #require(manual["mcpServers"] as? [String: Any])
        let tcpviewer = try #require(servers["tcpviewer"] as? [String: Any])
        #expect(tcpviewer["command"] as? String == executable.path)
        #expect((tcpviewer["args"] as? [String])?.isEmpty == true)
    }

    @Test func safelyQuotesExecutablePathsContainingApostrophes() {
        let configuration = TCPViewerMCPInstallConfiguration(
            executableURL: URL(fileURLWithPath: "/Applications/Owner's TCP Viewer.app/tcpviewer-mcp")
        )
        #expect(configuration.text(for: .codex) == "codex mcp add tcpviewer -- '/Applications/Owner'\\''s TCP Viewer.app/tcpviewer-mcp'")
    }
}
