//
//  TCPViewerMCPInitializeCompatibility.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/10/26.
//

import Foundation

/// MCP Swift SDK 0.12.1 decodes `ClientCapabilities.experimental` as `[String: String]`, but the MCP
/// schema allows object values. Clients such as Codex send `{"codex/auth-change": {}}`, which makes the
/// SDK fail `initialize` with -32603. tcpviewer-mcp does not consume experimental capabilities, so
/// unsupported entries are dropped before SDK decoding (modelcontextprotocol/swift-sdk#287).
enum TCPViewerMCPInitializeCompatibility {
    // Return the message with non-string experimental capabilities removed, or the original bytes when nothing changes.
    static func normalize(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return data }
        let normalized: Any
        if let batch = object as? [Any] {
            var changed = false
            normalized = batch.map { item -> Any in
                guard let request = item as? [String: Any],
                      let updated = normalizeRequest(request) else { return item }
                changed = true
                return updated
            }
            guard changed else { return data }
        } else if let request = object as? [String: Any],
                  let updated = normalizeRequest(request) {
            normalized = updated
        } else {
            return data
        }
        return (try? JSONSerialization.data(withJSONObject: normalized)) ?? data
    }

    // Return an updated initialize request, or nil when the message is not one or is already decodable.
    private static func normalizeRequest(_ request: [String: Any]) -> [String: Any]? {
        guard request["jsonrpc"] as? String == "2.0",
              request["id"] != nil,
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any] else { return nil }

        let supported = experimental.filter { $0.value is String }
        guard supported.count != experimental.count else { return nil }
        capabilities["experimental"] = supported
        params["capabilities"] = capabilities
        var result = request
        result["params"] = params
        return result
    }
}
