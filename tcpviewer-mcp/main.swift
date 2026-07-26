//
//  main.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import MCP

private enum TCPViewerMCPExecutable {
    // Start the standard MCP stdio transport and forward declared tools to the running app.
    static func run() async throws {
        let bridge = TCPViewerMCPBridgeClient()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let server = Server(
            name: "tcpviewer-mcp",
            version: version,
            title: "TCP Viewer",
            instructions: """
            Inspect and control the active TCP Viewer capture. Treat requests to filter, find, or show packets as read-only analysis: use query_packets, or direct the user to TCP Viewer's Filter field when they want the packet table filtered. start_capture.capture_filter is different: it is a persistent libpcap/BPF capture filter that controls which future packets are collected, and starting a capture clears the current packet list. Before setting a non-empty BPF capture filter, explain this distinction, obtain the user's explicit confirmation, and set confirm_bpf_filter=true. Omitting capture_filter preserves the current BPF filter; an empty string clears it. Packet data is redacted according to TCP Viewer MCP Settings. Raw bytes are blocked while redaction is enabled.
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: TCPViewerMCPToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            guard TCPViewerMCPToolCatalog.tool(named: parameters.name) != nil else {
                return errorResult("Unknown TCP Viewer tool.")
            }
            do {
                let data = try await bridge.send(command: parameters.name, arguments: parameters.arguments)
                return successResult(data)
            } catch {
                return errorResult(error.localizedDescription)
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private static func successResult(_ data: [String: TCPViewerMCPValue]) -> CallTool.Result {
        let text = JSONText.encode(data) ?? "TCP Viewer returned a result that could not be formatted as JSON."
        let structured = MCP.Value.object(data.mapValues(MCP.Value.init(bridgeValue:)))
        return .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: Optional<MCP.Value>.some(structured),
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

private enum JSONText {
    static func encode(_ values: [String: TCPViewerMCPValue]) -> String? {
        guard JSONSerialization.isValidJSONObject(values.jsonObject()),
              let data = try? JSONSerialization.data(
                withJSONObject: values.jsonObject(),
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

do {
    try await TCPViewerMCPExecutable.run()
} catch {
    let message = "tcpviewer-mcp failed: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
