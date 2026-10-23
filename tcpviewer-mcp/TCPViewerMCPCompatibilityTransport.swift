//
//  TCPViewerMCPCompatibilityTransport.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/10/26.
//

import Foundation
import Logging
import MCP

/// Keeps the SDK's stdio framing and lifecycle while normalizing initialize payloads.
/// The SDK requires `Transport` to be an actor, so this wrapper cannot follow the app's callback style.
actor TCPViewerMCPCompatibilityTransport: Transport {
    nonisolated let logger: Logger
    private let transport: StdioTransport
    private let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var forwardingTask: Task<Void, Never>?

    init(transport: StdioTransport = StdioTransport()) {
        self.transport = transport
        self.logger = transport.logger
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messages = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    // Connect stdio and forward each received message through the initialize normalizer.
    func connect() async throws {
        try await transport.connect()
        guard forwardingTask == nil else { return }
        let task = Task { [transport, continuation] in
            do {
                for try await message in await transport.receive() {
                    try Task.checkCancellation()
                    continuation.yield(TCPViewerMCPInitializeCompatibility.normalize(message))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        // Cancel forwarding when the SDK stops consuming, including EOF and shutdown.
        continuation.onTermination = { @Sendable _ in task.cancel() }
        forwardingTask = task
    }

    // Stop forwarding and close the underlying stdio transport.
    func disconnect() async {
        forwardingTask?.cancel()
        await transport.disconnect()
        continuation.finish()
        forwardingTask = nil
    }

    // Send responses unchanged through stdio.
    func send(_ data: Data) async throws {
        try await transport.send(data)
    }

    // Return the normalized message stream consumed by the SDK server.
    func receive() -> AsyncThrowingStream<Data, Error> {
        messages
    }
}
