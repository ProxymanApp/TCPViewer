//
//  TCPViewerMCPBridgeClient.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import MCP

enum TCPViewerMCPBridgeClientError: Error, LocalizedError {
    case invalidHandshake(String)
    case appUnavailable
    case invalidHTTPResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidHandshake(let message):
            return message
        case .appUnavailable:
            return "TCP Viewer MCP is unavailable. Open TCP Viewer, activate PRO, and enable MCP Server in Settings."
        case .invalidHTTPResponse:
            return "TCP Viewer returned an invalid MCP bridge response."
        case .rejected(let message):
            return message
        }
    }
}

struct TCPViewerMCPBridgeClient: Sendable {
    private static let handshakeEnvironmentKey = "TCPVIEWER_MCP_HANDSHAKE_FILE"

    // Read the current per-launch handshake for every call so app restarts recover cleanly.
    func send(command: String, arguments: [String: MCP.Value]?) async throws -> [String: TCPViewerMCPValue] {
        let handshake = try loadHandshake()
        guard let url = URL(string: "http://127.0.0.1:\(handshake.port)/mcp") else {
            throw TCPViewerMCPBridgeClientError.invalidHandshake("TCP Viewer published an invalid MCP port.")
        }
        let parameters = arguments?.mapValues(TCPViewerMCPValue.init(mcpValue:))
        let bridgeRequest = TCPViewerMCPRequest(command: command, params: parameters)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(handshake.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(bridgeRequest)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TCPViewerMCPBridgeClientError.appUnavailable
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TCPViewerMCPBridgeClientError.invalidHTTPResponse
        }
        guard let bridgeResponse = try? JSONDecoder().decode(TCPViewerMCPResponse.self, from: data) else {
            throw TCPViewerMCPBridgeClientError.invalidHTTPResponse
        }
        guard httpResponse.statusCode == 200, bridgeResponse.success else {
            throw TCPViewerMCPBridgeClientError.rejected(bridgeResponse.error ?? "TCP Viewer rejected the MCP request.")
        }
        return bridgeResponse.data ?? [:]
    }

    private func loadHandshake() throws -> TCPViewerMCPHandshake {
        let url = handshakeFileURL()
        let data: Data
        do {
            data = try TCPViewerMCPHandshakeFile.readSecurely(at: url)
        } catch TCPViewerMCPHandshakeFileError.unsafeMetadata {
            throw TCPViewerMCPBridgeClientError.invalidHandshake(
                "The TCP Viewer MCP handshake file has unsafe ownership or permissions."
            )
        } catch {
            throw TCPViewerMCPBridgeClientError.appUnavailable
        }
        guard let handshake = try? JSONDecoder().decode(TCPViewerMCPHandshake.self, from: data),
              handshake.isValid else {
            throw TCPViewerMCPBridgeClientError.appUnavailable
        }
        return handshake
    }

    private func handshakeFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment[Self.handshakeEnvironmentKey],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(TCPViewerMCPHandshake.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(TCPViewerMCPHandshake.fileName)
    }
}

private extension TCPViewerMCPValue {
    init(mcpValue: MCP.Value) {
        switch mcpValue {
        case .null:
            self = .null
        case .bool(let value):
            self = .bool(value)
        case .int(let value):
            self = .int(value)
        case .double(let value):
            self = .double(value)
        case .string(let value):
            self = .string(value)
        case .data(_, let value):
            self = .string(value.base64EncodedString())
        case .array(let values):
            self = .array(values.map(TCPViewerMCPValue.init(mcpValue:)))
        case .object(let values):
            self = .object(values.mapValues(TCPViewerMCPValue.init(mcpValue:)))
        }
    }
}

extension MCP.Value {
    init(bridgeValue: TCPViewerMCPValue) {
        switch bridgeValue {
        case .null:
            self = .null
        case .bool(let value):
            self = .bool(value)
        case .int(let value):
            self = .int(value)
        case .double(let value):
            self = .double(value)
        case .string(let value):
            self = .string(value)
        case .array(let values):
            self = .array(values.map(MCP.Value.init(bridgeValue:)))
        case .object(let values):
            self = .object(values.mapValues(MCP.Value.init(bridgeValue:)))
        }
    }
}
