//
//  TCPViewerMCPHTTPServer.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import Network

enum TCPViewerMCPHTTPServerState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)
}

final class TCPViewerMCPHTTPServer {
    static let shared = TCPViewerMCPHTTPServer(router: TCPViewerMCPCommandRouter.shared)
    static let stateDidChangeNotification = Notification.Name("TCPViewerMCPHTTPServerStateDidChange")

    private final class ConnectionContext {
        let id = UUID()
        let connection: NWConnection
        var receivedData = Data()
        var timeoutWorkItem: DispatchWorkItem?
        var didRespond = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private enum Limit {
        static let receiveChunkByteCount = 64 * 1_024
        static let requestTimeout: TimeInterval = 15
        static let maximumRequestByteCount = TCPViewerMCPHTTPParser.maximumHeaderByteCount +
            TCPViewerMCPHTTPParser.maximumBodyByteCount + 4
    }

    private let router: any TCPViewerMCPCommandRouting
    private let handshakeStore: TCPViewerMCPHandshakeStore
    private let queue: DispatchQueue
    private let commandTimeout: TimeInterval
    private let maximumResponseByteCount: Int
    private let maximumConnections: Int
    private let lock = NSLock()
    private var storedState: TCPViewerMCPHTTPServerState = .stopped
    private var listener: NWListener?
    private var sessionID: UUID?
    private var handshake: TCPViewerMCPHandshake?
    private var connections: [UUID: ConnectionContext] = [:]

    init(
        router: any TCPViewerMCPCommandRouting,
        handshakeStore: TCPViewerMCPHandshakeStore = TCPViewerMCPHandshakeStore(),
        queue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.mcp.http", qos: .userInitiated),
        commandTimeout: TimeInterval = 115,
        maximumResponseByteCount: Int = 16 * 1_024 * 1_024,
        maximumConnections: Int = 16
    ) {
        precondition(commandTimeout > 0)
        precondition(maximumResponseByteCount > 0)
        precondition(maximumConnections > 0)
        self.router = router
        self.handshakeStore = handshakeStore
        self.queue = queue
        self.commandTimeout = commandTimeout
        self.maximumResponseByteCount = maximumResponseByteCount
        self.maximumConnections = maximumConnections
    }

    var state: TCPViewerMCPHTTPServerState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    // Start an ephemeral loopback-only listener and publish its per-launch authentication key.
    func start() {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            let token = try handshakeStore.makeToken()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let newListener = try NWListener(using: parameters)
            let newSessionID = UUID()

            lock.lock()
            guard listener == nil else {
                lock.unlock()
                newListener.cancel()
                return
            }
            listener = newListener
            sessionID = newSessionID
            handshake = nil
            lock.unlock()
            updateState(.starting)

            newListener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection, token: token, sessionID: newSessionID)
                }
            }
            newListener.stateUpdateHandler = { [weak self, weak newListener] listenerState in
                guard let self, let newListener else {
                    return
                }
                self.handleListenerState(
                    listenerState,
                    listener: newListener,
                    token: token,
                    sessionID: newSessionID
                )
            }
            newListener.start(queue: queue)
        } catch {
            updateState(.failed(error.localizedDescription))
        }
    }

    // Stop accepting requests and remove only this process's handshake file.
    func stop() {
        lock.lock()
        let activeListener = listener
        let activeHandshake = handshake
        listener = nil
        sessionID = nil
        handshake = nil
        lock.unlock()

        queue.async {
            activeListener?.cancel()
            self.connections.values.forEach { context in
                context.timeoutWorkItem?.cancel()
                context.connection.cancel()
            }
            self.connections.removeAll()
            if let activeHandshake {
                self.handshakeStore.remove(ifMatching: activeHandshake)
            }
        }
        updateState(.stopped)
    }

    private func handleListenerState(
        _ listenerState: NWListener.State,
        listener: NWListener,
        token: String,
        sessionID: UUID
    ) {
        guard isCurrent(listener: listener, sessionID: sessionID) else {
            return
        }

        switch listenerState {
        case .ready:
            guard let port = listener.port.map({ Int($0.rawValue) }) else {
                failSession("The MCP listener did not provide a local port.", listener: listener, sessionID: sessionID)
                return
            }
            let newHandshake = TCPViewerMCPHandshake(port: port, token: token)
            do {
                try handshakeStore.write(newHandshake)
                lock.lock()
                guard self.listener === listener, self.sessionID == sessionID else {
                    lock.unlock()
                    handshakeStore.remove(ifMatching: newHandshake)
                    return
                }
                handshake = newHandshake
                lock.unlock()
                updateState(.running(port: port))
            } catch {
                failSession(error.localizedDescription, listener: listener, sessionID: sessionID)
            }
        case .failed(let error):
            failSession(error.localizedDescription, listener: listener, sessionID: sessionID)
        case .cancelled:
            clearSessionIfCurrent(listener: listener, sessionID: sessionID, state: .stopped)
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection, token: String, sessionID: UUID) {
        guard currentSessionID() == sessionID else {
            connection.cancel()
            return
        }
        guard connections.count < maximumConnections else {
            connection.start(queue: queue)
            sendResponse(
                statusCode: 503,
                response: .failure("The MCP server is busy. Try again shortly."),
                over: connection,
                completion: { connection.cancel() }
            )
            return
        }

        let context = ConnectionContext(connection: connection)
        connections[context.id] = context
        connection.stateUpdateHandler = { [weak self, weak context] connectionState in
            guard let self, let context else {
                return
            }
            if case .failed = connectionState {
                self.queue.async { self.finish(context) }
            } else if case .cancelled = connectionState {
                self.queue.async { self.finish(context) }
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak context] in
            guard let self, let context, self.connections[context.id] != nil else {
                return
            }
            self.respond(
                statusCode: 408,
                response: .failure("The MCP HTTP request timed out."),
                context: context
            )
        }
        context.timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + Limit.requestTimeout, execute: timeout)
        connection.start(queue: queue)
        receive(context, token: token)
    }

    private func receive(_ context: ConnectionContext, token: String) {
        context.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Limit.receiveChunkByteCount
        ) { [weak self, weak context] content, _, isComplete, error in
            guard let self, let context, self.connections[context.id] != nil else {
                return
            }
            if let content {
                context.receivedData.append(content)
            }
            guard context.receivedData.count <= Limit.maximumRequestByteCount else {
                self.respond(statusCode: 413, response: .failure("Request is too large."), context: context)
                return
            }

            switch TCPViewerMCPHTTPParser.parse(context.receivedData) {
            case .needsMoreData:
                if let error {
                    self.respond(statusCode: 400, response: .failure(error.localizedDescription), context: context)
                } else if isComplete {
                    self.respond(statusCode: 400, response: .failure("The HTTP request ended before it was complete."), context: context)
                } else {
                    self.receive(context, token: token)
                }
            case .failure(let statusCode, let message):
                self.respond(statusCode: statusCode, response: .failure(message), context: context)
            case .request(let request):
                context.timeoutWorkItem?.cancel()
                context.timeoutWorkItem = nil
                self.handle(request, token: token, context: context)
            }
        }
    }

    private func handle(_ request: TCPViewerMCPHTTPRequest, token: String, context: ConnectionContext) {
        guard request.method == "POST" else {
            respond(statusCode: 405, response: .failure("Only POST is supported."), context: context)
            return
        }
        guard request.path == "/mcp" else {
            respond(statusCode: 404, response: .failure("Not found."), context: context)
            return
        }
        let mediaType = request.headers["content-type"]?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json" else {
            respond(statusCode: 415, response: .failure("Content-Type must be application/json."), context: context)
            return
        }
        let authorization = request.headers["authorization"] ?? ""
        guard constantTimeEqual(authorization, "Bearer \(token)") else {
            respond(statusCode: 401, response: .failure("Unauthorized."), context: context)
            return
        }

        do {
            let bridgeRequest = try JSONDecoder().decode(TCPViewerMCPRequest.self, from: request.body)
            let timeout = DispatchWorkItem { [weak self, weak context] in
                guard let self, let context, self.connections[context.id] != nil else {
                    return
                }
                self.respond(
                    statusCode: 504,
                    response: .failure("The MCP command timed out."),
                    context: context
                )
            }
            context.timeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + commandTimeout, execute: timeout)
            router.route(bridgeRequest) { [weak self, weak context] response in
                guard let self, let context else {
                    return
                }
                self.queue.async {
                    guard self.connections[context.id] != nil else {
                        return
                    }
                    self.respond(statusCode: 200, response: response, context: context)
                }
            }
        } catch {
            respond(statusCode: 400, response: .failure("Request body is not a valid MCP bridge command."), context: context)
        }
    }

    private func respond(
        statusCode: Int,
        response: TCPViewerMCPResponse,
        context: ConnectionContext
    ) {
        guard !context.didRespond else {
            return
        }
        context.didRespond = true
        context.timeoutWorkItem?.cancel()
        let sendTimeout = DispatchWorkItem { [weak self, weak context] in
            guard let self, let context else {
                return
            }
            self.finish(context)
        }
        context.timeoutWorkItem = sendTimeout
        queue.asyncAfter(deadline: .now() + Limit.requestTimeout, execute: sendTimeout)
        sendResponse(statusCode: statusCode, response: response, over: context.connection) { [weak self, weak context] in
            guard let self, let context else {
                return
            }
            self.queue.async { self.finish(context) }
        }
    }

    private func sendResponse(
        statusCode: Int,
        response: TCPViewerMCPResponse,
        over connection: NWConnection,
        completion: @escaping () -> Void
    ) {
        var effectiveStatusCode = statusCode
        var body = (try? JSONEncoder().encode(response)) ?? Data(#"{"success":false,"error":"Response encoding failed."}"#.utf8)
        if body.count > maximumResponseByteCount {
            effectiveStatusCode = 500
            body = (try? JSONEncoder().encode(TCPViewerMCPResponse.failure("The MCP response exceeded the safe size limit.")))
                ?? Data(#"{"success":false,"error":"Response is too large."}"#.utf8)
        }
        let reason = Self.reasonPhrase(for: effectiveStatusCode)
        let headers = "HTTP/1.1 \(effectiveStatusCode) \(reason)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "Connection: close\r\n\r\n"
        var responseData = Data(headers.utf8)
        responseData.append(body)
        connection.send(content: responseData, completion: .contentProcessed { _ in completion() })
    }

    private func finish(_ context: ConnectionContext) {
        guard connections.removeValue(forKey: context.id) != nil else {
            return
        }
        context.timeoutWorkItem?.cancel()
        context.connection.cancel()
    }

    private func failSession(_ message: String, listener: NWListener, sessionID: UUID) {
        clearSessionIfCurrent(listener: listener, sessionID: sessionID, state: .failed(message))
        listener.cancel()
    }

    private func clearSessionIfCurrent(
        listener: NWListener,
        sessionID: UUID,
        state: TCPViewerMCPHTTPServerState
    ) {
        lock.lock()
        guard self.listener === listener, self.sessionID == sessionID else {
            lock.unlock()
            return
        }
        let activeHandshake = handshake
        self.listener = nil
        self.sessionID = nil
        handshake = nil
        lock.unlock()
        if let activeHandshake {
            handshakeStore.remove(ifMatching: activeHandshake)
        }
        connections.values.forEach { context in
            context.timeoutWorkItem?.cancel()
            context.connection.cancel()
        }
        connections.removeAll()
        updateState(state)
    }

    private func isCurrent(listener: NWListener, sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.listener === listener && self.sessionID == sessionID
    }

    private func currentSessionID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    private func updateState(_ state: TCPViewerMCPHTTPServerState) {
        lock.lock()
        storedState = state
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
        }
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        var difference = UInt(leftBytes.count ^ rightBytes.count)
        let count = max(leftBytes.count, rightBytes.count)
        for index in 0..<count {
            let leftByte = index < leftBytes.count ? leftBytes[index] : 0
            let rightByte = index < rightBytes.count ? rightBytes[index] : 0
            difference |= UInt(leftByte ^ rightByte)
        }
        return difference == 0
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 505: "HTTP Version Not Supported"
        default: "Error"
        }
    }
}
