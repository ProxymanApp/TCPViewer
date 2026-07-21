//
//  TCPViewerMCPNodeIntegrationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPViewerMCPNodeIntegrationTests {
    @Test func nodeClientConnectsToBundledMCPExecutableAndRetrievesFixtureData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPNode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let handshakeURL = directory.appendingPathComponent("handshake.json")
        let router = TCPViewerMCPRecordingRouter { request in
            switch request.command {
            case TCPViewerMCPCommand.queryPackets.rawValue:
                return .success([
                    "packets": .array([.object(["id": .string("4242"), "protocol": .string("TLS")])]),
                    "returned_count": .int(1),
                ])
            case TCPViewerMCPCommand.getPacketDetails.rawValue:
                return .success([
                    "packet": .object(["packet_id": .string(request.string("packet_id") ?? "")]),
                ])
            default:
                return .failure("Unexpected integration command: \(request.command)")
            }
        }
        let server = TCPViewerMCPHTTPServer(
            router: router,
            handshakeStore: TCPViewerMCPHandshakeStore(fileURL: handshakeURL),
            queue: DispatchQueue(label: "TCPViewerMCPNodeIntegrationTests.server")
        )
        server.start()
        defer { server.stop() }
        try await waitForServer(server, handshakeURL: handshakeURL)

        let executableURL = try bundledExecutableURL()
        let result = try await runNode(executableURL: executableURL, handshakeURL: handshakeURL)

        #expect(result["toolCount"] as? Int == TCPViewerMCPCommand.allCases.count)
        #expect(Set(result["toolNames"] as? [String] ?? []) == Set(TCPViewerMCPCommand.allCases.map(\.rawValue)))
        #expect(result["packetID"] as? String == "4242")
        #expect(result["packetProtocol"] as? String == "TLS")
        #expect(result["detailPacketID"] as? String == "4242")
    }

    @Test func nodeDiscoveryUsesExecutableFromPATH() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewerMCPNodePATH-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("node")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let resolved = try nodeExecutableURL(environment: ["PATH": directory.path])

        #expect(resolved == executable)
    }

    private func bundledExecutableURL() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tcpviewer-mcp"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("tcpviewer-mcp"),
        ]
        return try #require(candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
    }

    private func runNode(executableURL: URL, handshakeURL: URL) async throws -> [String: Any] {
        let script = #"""
        const { spawn } = require('child_process');
        const executable = process.argv[1];
        const handshake = process.argv[2];
        const child = spawn(executable, [], {
          env: { ...process.env, TCPVIEWER_MCP_HANDSHAKE_FILE: handshake },
          stdio: ['pipe', 'pipe', 'pipe']
        });
        let buffer = '';
        let nextID = 1;
        const pending = new Map();
        let stderr = '';
        child.stderr.on('data', chunk => { stderr += chunk.toString(); });
        child.stdout.on('data', chunk => {
          buffer += chunk.toString();
          while (true) {
            const index = buffer.indexOf('\n');
            if (index < 0) break;
            const line = buffer.slice(0, index).trim();
            buffer = buffer.slice(index + 1);
            if (!line) continue;
            const message = JSON.parse(line);
            if (message.id !== undefined && pending.has(message.id)) {
              const callback = pending.get(message.id);
              pending.delete(message.id);
              message.error ? callback.reject(new Error(JSON.stringify(message.error))) : callback.resolve(message.result);
            }
          }
        });
        function request(method, params) {
          return new Promise((resolve, reject) => {
            const id = nextID++;
            pending.set(id, { resolve, reject });
            child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
          });
        }
        function notify(method, params = {}) {
          child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
        }
        const timeout = setTimeout(() => {
          console.error('Node MCP integration timed out. ' + stderr);
          child.kill('SIGKILL');
          process.exit(2);
        }, 15000);
        (async () => {
          await request('initialize', {
            protocolVersion: '2025-11-25',
            capabilities: {},
            clientInfo: { name: 'tcpviewer-node-integration', version: '1.0.0' }
          });
          notify('notifications/initialized');
          const listed = await request('tools/list', {});
          const queried = await request('tools/call', {
            name: 'query_packets',
            arguments: { protocols: ['TLS'], limit: 1 }
          });
          const detailed = await request('tools/call', {
            name: 'get_packet_details',
            arguments: { packet_id: '4242' }
          });
          const packet = queried.structuredContent.packets[0];
          console.log(JSON.stringify({
            toolCount: listed.tools.length,
            toolNames: listed.tools.map(tool => tool.name),
            packetID: packet.id,
            packetProtocol: packet.protocol,
            detailPacketID: detailed.structuredContent.packet.packet_id
          }));
          clearTimeout(timeout);
          child.kill('SIGTERM');
          process.exit(0);
        })().catch(error => {
          clearTimeout(timeout);
          console.error(error.stack + '\n' + stderr);
          child.kill('SIGKILL');
          process.exit(1);
        });
        """#

        let process = Process()
        process.executableURL = try nodeExecutableURL()
        process.arguments = ["-e", script, executableURL.path, handshakeURL.path]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "Node integration failed: \(stderrText)")
        guard process.terminationStatus == 0,
              let object = try JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw TCPViewerMCPNodeIntegrationError.invalidOutput(stderrText)
        }
        return object
    }

    // Resolve the test runner's PATH before common fallback installation locations.
    private func nodeExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let searchPath = environment["PATH"] {
            candidates.append(contentsOf: searchPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("node")
            })
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
        ])
        let versionsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
                $0.appendingPathComponent("bin/node")
            })
        }
        return try #require(candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }))
    }

    private func waitForServer(_ server: TCPViewerMCPHTTPServer, handshakeURL: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .running = server.state,
               FileManager.default.fileExists(atPath: handshakeURL.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TCPViewerMCPNodeIntegrationError.serverTimeout
    }
}


private enum TCPViewerMCPNodeIntegrationError: Error {
    case serverTimeout
    case invalidOutput(String)
}
