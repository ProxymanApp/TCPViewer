//
//  TCPViewerMCPHTTPServerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPViewerMCPHTTPServerTests {
    @Test func authenticatesRoutesAndRemovesHandshakeOnStop() async throws {
        let fixture = try await startFixture()
        defer { fixture.server.stop() }

        let authorized = try await request(
            port: fixture.handshake.port,
            token: fixture.handshake.token,
            body: TCPViewerMCPRequest(command: TCPViewerMCPCommand.getAppStatus.rawValue)
        )
        #expect(authorized.status == 200)
        #expect(authorized.response.success)
        #expect(authorized.response.value("echo") == .string("get_app_status"))

        let unauthorized = try await request(
            port: fixture.handshake.port,
            token: "wrong-token",
            body: TCPViewerMCPRequest(command: TCPViewerMCPCommand.getAppStatus.rawValue)
        )
        #expect(unauthorized.status == 401)
        #expect(!unauthorized.response.success)

        fixture.server.stop()
        try await waitUntil(timeout: 2) {
            !FileManager.default.fileExists(atPath: fixture.handshakeURL.path)
        }
        #expect(fixture.server.state == .stopped)
    }

    @Test func rejectsWrongMethodPathContentTypeAndJSON() async throws {
        let fixture = try await startFixture()
        defer { fixture.server.stop() }
        let baseURL = URL(string: "http://127.0.0.1:\(fixture.handshake.port)/mcp")!

        var wrongMethod = URLRequest(url: baseURL)
        wrongMethod.httpMethod = "GET"
        wrongMethod.httpBody = Data()
        wrongMethod.setValue("0", forHTTPHeaderField: "Content-Length")
        wrongMethod.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wrongMethod.setValue("Bearer \(fixture.handshake.token)", forHTTPHeaderField: "Authorization")
        #expect(try await status(for: wrongMethod) == 405)

        var wrongPath = wrongMethod
        wrongPath.url = URL(string: "http://127.0.0.1:\(fixture.handshake.port)/wrong")!
        wrongPath.httpMethod = "POST"
        #expect(try await status(for: wrongPath) == 404)

        var wrongContentType = wrongMethod
        wrongContentType.httpMethod = "POST"
        wrongContentType.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        #expect(try await status(for: wrongContentType) == 415)
        wrongContentType.setValue("application/json-malformed", forHTTPHeaderField: "Content-Type")
        #expect(try await status(for: wrongContentType) == 415)

        var invalidJSON = wrongMethod
        invalidJSON.httpMethod = "POST"
        invalidJSON.httpBody = Data("not json".utf8)
        invalidJSON.setValue(String(invalidJSON.httpBody!.count), forHTTPHeaderField: "Content-Length")
        #expect(try await status(for: invalidJSON) == 400)
    }

    @Test func boundsCommandDurationAndResponseSize() async throws {
        let timeoutFixture = try await startFixture(
            router: TCPViewerMCPNeverCompletingRouter(),
            commandTimeout: 0.05
        )
        defer { timeoutFixture.server.stop() }
        let timedOut = try await request(
            port: timeoutFixture.handshake.port,
            token: timeoutFixture.handshake.token,
            body: TCPViewerMCPRequest(command: TCPViewerMCPCommand.getAppStatus.rawValue)
        )
        #expect(timedOut.status == 504)
        #expect(!timedOut.response.success)

        let largeResponseRouter = TCPViewerMCPRecordingRouter { _ in
            .success(["value": .string(String(repeating: "x", count: 2_048))])
        }
        let sizeFixture = try await startFixture(
            router: largeResponseRouter,
            maximumResponseByteCount: 1_024
        )
        defer { sizeFixture.server.stop() }
        let oversized = try await request(
            port: sizeFixture.handshake.port,
            token: sizeFixture.handshake.token,
            body: TCPViewerMCPRequest(command: TCPViewerMCPCommand.getAppStatus.rawValue)
        )
        #expect(oversized.status == 500)
        #expect(!oversized.response.success)
    }

    private func startFixture(
        router: (any TCPViewerMCPCommandRouting)? = nil,
        commandTimeout: TimeInterval = 115,
        maximumResponseByteCount: Int = 16 * 1_024 * 1_024
    ) async throws -> HTTPServerFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewerMCPHTTPServer-\(UUID().uuidString)")
        let handshakeURL = directory.appendingPathComponent("handshake.json")
        let defaultRouter = TCPViewerMCPRecordingRouter { request in
            .success(["echo": .string(request.command)])
        }
        let server = TCPViewerMCPHTTPServer(
            router: router ?? defaultRouter,
            handshakeStore: TCPViewerMCPHandshakeStore(fileURL: handshakeURL),
            queue: DispatchQueue(label: "TCPViewerMCPHTTPServerTests.\(UUID().uuidString)"),
            commandTimeout: commandTimeout,
            maximumResponseByteCount: maximumResponseByteCount
        )
        server.start()
        try await waitUntil(timeout: 5) {
            if case .running = server.state {
                return FileManager.default.fileExists(atPath: handshakeURL.path)
            }
            return false
        }
        let handshake = try JSONDecoder().decode(TCPViewerMCPHandshake.self, from: Data(contentsOf: handshakeURL))
        return HTTPServerFixture(server: server, handshakeURL: handshakeURL, handshake: handshake)
    }

    private func request(
        port: Int,
        token: String,
        body: TCPViewerMCPRequest
    ) async throws -> (status: Int, response: TCPViewerMCPResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        return (httpResponse.statusCode, try JSONDecoder().decode(TCPViewerMCPResponse.self, from: data))
    }

    private func status(for request: URLRequest) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require((response as? HTTPURLResponse)?.statusCode)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TCPViewerMCPHTTPServerTestError.timeout
    }
}

private struct HTTPServerFixture {
    let server: TCPViewerMCPHTTPServer
    let handshakeURL: URL
    let handshake: TCPViewerMCPHandshake
}

final class TCPViewerMCPRecordingRouter: TCPViewerMCPCommandRouting {
    private let handler: (TCPViewerMCPRequest) -> TCPViewerMCPResponse

    init(handler: @escaping (TCPViewerMCPRequest) -> TCPViewerMCPResponse) {
        self.handler = handler
    }

    func route(_ request: TCPViewerMCPRequest, completion: @escaping (TCPViewerMCPResponse) -> Void) {
        completion(handler(request))
    }
}

private final class TCPViewerMCPNeverCompletingRouter: TCPViewerMCPCommandRouting {
    func route(_ request: TCPViewerMCPRequest, completion: @escaping (TCPViewerMCPResponse) -> Void) {}
}

private enum TCPViewerMCPHTTPServerTestError: Error {
    case timeout
}
