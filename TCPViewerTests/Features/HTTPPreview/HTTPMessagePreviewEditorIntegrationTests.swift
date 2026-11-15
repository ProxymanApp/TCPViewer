//
//  HTTPMessagePreviewEditorIntegrationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit
import WebKit
import XCTest
@testable import TCPViewer

// Load the real bundled preview page and check its HTTP grammar through Monaco's tokenizer.
@MainActor
final class HTTPMessagePreviewEditorIntegrationTests: XCTestCase {
    private let preview = "window.tcpviewerPreview"

    // A JSON response colors the status line, headers, and JSON tokens; packet text is never run.
    func testResponseWithJSONBodyIsHighlighted() async throws {
        let (controller, webView) = try makeEditor()
        defer { controller.closeEditor() }
        let text = "HTTP/1.1 404 Not Found\nContent-Type: application/json\n\n{\n  \"error\": \"</script><script>window.injected=true</script>\",\n  \"code\": 404,\n  \"retry\": false\n}"
        controller.render(HTTPMessagePreview(kind: .response, title: "404 Not Found", text: text, isJSONBody: true))
        try await eventually("\(preview).editor.getModel().getValue() === \(try jsString(text))", in: webView)
        try await expectValue("\(preview).editor.getModel().getLanguageId()", in: webView, equals: "http-message-json")
        try await expectTokens(line: 1, include: ["http.version", "http.status.client", "http.reason"], in: webView)
        try await expectTokens(line: 2, include: ["http.header.name", "http.delimiter", "http.header.value"], in: webView)
        try await expectTokens(line: 5, include: ["http.json.key", "http.json.string"], in: webView)
        try await expectTokens(line: 6, include: ["http.json.key", "http.json.number"], in: webView)
        try await expectTokens(line: 7, include: ["http.json.literal"], in: webView)
        try await expectValue("Boolean(window.injected)", in: webView, equals: false)
        try await expectValue("\(preview).editor.getRawOptions().readOnly", in: webView, equals: true)
    }

    // A request without JSON uses the plain grammar, and HTTP/2 pseudo-headers keep their colon.
    func testRequestAndAppearance() async throws {
        let (controller, webView) = try makeEditor()
        defer { controller.closeEditor() }
        let text = "POST /upload HTTP/2\n:authority: example.com\n\nname=value"
        controller.render(HTTPMessagePreview(kind: .request, title: "POST /upload", text: text, isJSONBody: false))
        try await eventually("\(preview).editor.getModel().getValue() === \(try jsString(text))", in: webView)
        try await expectValue("\(preview).editor.getModel().getLanguageId()", in: webView, equals: "http-message")
        try await expectTokens(line: 1, include: ["http.method", "http.target", "http.version"], in: webView)
        try await expectTokens(line: 2, include: ["http.header.name"], in: webView)
        try await expectValue("\(preview).tokenTypes(4).some(type => type.startsWith('http.'))", in: webView, equals: false)
        // An HTTP/2 status line has no reason phrase; its headers must still be colored.
        let response = "HTTP/2 200\ncontent-type: text/plain\n\nok"
        controller.render(HTTPMessagePreview(kind: .response, title: "200", text: response, isJSONBody: false))
        try await eventually("\(preview).editor.getModel().getValue() === \(try jsString(response))", in: webView)
        try await expectTokens(line: 1, include: ["http.version", "http.status.success"], in: webView)
        try await expectTokens(line: 2, include: ["http.header.name", "http.header.value"], in: webView)
        controller.view.appearance = NSAppearance(named: .darkAqua)
        try await eventually("document.querySelector('.monaco-editor.vs-dark') !== null", in: webView)
    }

    // Each case gets isolated preferences and a real, locally loaded WebKit view.
    private func makeEditor() throws -> (HTTPMessagePreviewEditorViewController, WKWebView) {
        XCTAssertNotNil(HTTPMessagePreviewEditorViewController.resourceURL)
        let suite = "HTTPMessagePreviewEditorIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = HTTPMessagePreviewEditorViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        controller.configure(AppConfiguration(defaults: defaults))
        controller.view.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        return (controller, webView)
    }

    // Monarch token types carry the language as a suffix, e.g. "http.method.http-message".
    private func expectTokens(line: Int, include expected: [String], in webView: WKWebView) async throws {
        let types = try await awaitValue("\(preview).tokenTypes(\(line))", in: webView) as? [String] ?? []
        for token in expected {
            XCTAssertTrue(types.contains { $0.hasPrefix(token + ".") }, "Line \(line) has no \(token) token: \(types)")
        }
    }

    private func jsString(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }

    // Poll bounded asynchronous results rather than assuming a fixed rendering delay.
    private func eventually(_ condition: String, in webView: WKWebView) async throws {
        for _ in 0..<150 {
            if let value = try? await awaitValue("Boolean(window.tcpviewerPreview && (\(condition)))", in: webView), value as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for the bundled preview: \(condition)")
        throw NSError(domain: "HTTPMessagePreviewEditorIntegrationTests", code: 1)
    }

    // Keep asynchronous values outside XCTest's synchronous assertion autoclosures.
    private func expectValue<T: Equatable>(_ script: String, in webView: WKWebView, equals expected: T) async throws {
        let actual = try await awaitValue(script, in: webView)
        XCTAssertEqual(actual as? T, expected)
    }

    // Evaluate assertions through WebKit's callback API in the existing app test process.
    private func awaitValue(_ script: String, in webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }
}
