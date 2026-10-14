//
//  DiffMonacoEditorIntegrationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 14/10/26.
//

import AppKit
import WebKit
import XCTest
@testable import TCPViewer

// Exercise the real local-file runtime and bridge without UI automation or network fixtures.
@MainActor
final class DiffMonacoEditorIntegrationTests: XCTestCase {
    private let editor = "window.tcpviewerDiff.editor"

    // Queue before navigation completes, then check rapid replacements and untrusted text round-trip.
    func testLatestContentWinsAndPacketTextIsNeverExecuted() async throws {
        let (controller, webView, _) = try makeEditor()
        defer { controller.closeEditor() }
        let text = "TCP\n\tQuotes: '\" \\ 😀\u{2028}\u{2029}\n</script><script>window.injected=true</script>\n"
        controller.render(left: "stale", right: "stale", mode: .sideBySide)
        controller.render(left: text, right: "latest before load", mode: .unified)
        try await eventually("\(editor).getModel().modified.getValue() === 'latest before load'", in: webView)
        try await expectValue("\(editor).getModel().original.getValue()", in: webView, equals: text)
        try await expectValue("Boolean(window.injected)", in: webView, equals: false)
        for index in 0..<50 {
            controller.render(left: text, right: "packet \(index)", mode: .sideBySide)
        }
        try await eventually("\(editor).getModel().modified.getValue() === 'packet 49'", in: webView)
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
    }

    // Real worker results must include whitespace changes, additions, removals, and empty sides.
    func testDiffWorkerAndBothDisplayModes() async throws {
        let (controller, webView, _) = try makeEditor()
        defer { controller.closeEditor() }
        controller.render(left: "header\n  value\nend", right: "header\nvalue\nend", mode: .sideBySide)
        try await eventually("\(editor).getLineChanges()?.length === 1", in: webView)
        // A real worker handshake detects file-origin/CSP failures that Monaco's fallback could hide.
        _ = try await awaitValue("""
            window.workerReady = false;
            const worker = window.MonacoEnvironment.getWorker();
            worker.onmessage = event => {
                window.workerReady = event.data.type === 1 && !event.data.err;
                worker.terminate();
            };
            worker.postMessage('start');
            worker.postMessage({ vsWorker: 99, type: 0, req: '1', channel: 'default', method: '$initialize', args: [99] });
            true;
            """, in: webView)
        try await eventually("window.workerReady", in: webView)
        try await expectValue("\(editor).getLineChanges()[0].originalStartLineNumber", in: webView, equals: 2)
        try await expectValue("\(editor).getOriginalEditor().getRawOptions().readOnly", in: webView, equals: true)
        try await expectValue("\(editor).getModifiedEditor().getRawOptions().readOnly", in: webView, equals: true)
        _ = try await awaitValue("window.savedModel = \(editor).getModel().original; true", in: webView)
        controller.render(left: "header\n  value\nend", right: "header\nvalue\nend", mode: .unified)
        try await eventually("!document.querySelector('.monaco-diff-editor').classList.contains('side-by-side')", in: webView)
        try await expectValue("window.savedModel === \(editor).getModel().original", in: webView, equals: true)

        controller.render(left: "", right: "added\nsecond", mode: .sideBySide)
        try await eventually("\(editor).getLineChanges()?.[0]?.modifiedEndLineNumber === 2 && \(editor).getModel().original.getValue() === ''", in: webView)
        controller.render(left: "removed\nsecond", right: "", mode: .unified)
        try await eventually("\(editor).getLineChanges()?.[0]?.originalEndLineNumber === 2 && \(editor).getModel().modified.getValue() === ''", in: webView)
        controller.render(left: "same", right: "same", mode: .sideBySide)
        try await eventually("\(editor).getModel().original.getValue() === 'same' && \(editor).getLineChanges()?.length === 0", in: webView)
    }

    // Keep Find settings, text selection, and long-line rendering usable.
    func testSearchSettingsAndLongLines() async throws {
        let (controller, webView, _) = try makeEditor()
        defer { controller.closeEditor() }
        let text = "Packet packet packets\npacket42\nTCP\n    Source: 1\n    Destination: 2\nEnd\n" + String(repeating: "x", count: 12_000)
        controller.render(left: text, right: text, mode: .sideBySide)
        try await eventually("\(editor).getModel().modified.getLineCount() === 7", in: webView)
        controller.showSearchBar()
        try await eventually("document.querySelector('.find-widget.visible') !== null", in: webView)
        let findState = "\(editor).getModifiedEditor().getContribution('editor.contrib.findController').getState()"
        _ = try await awaitValue("\(findState).change({searchString: 'packet', matchCase: true, wholeWord: true, isRegex: false}, false); true", in: webView)
        try await eventually("\(findState).matchesCount === 1", in: webView)
        _ = try await awaitValue("\(findState).change({matchCase: false}, false); true", in: webView)
        try await eventually("\(findState).matchesCount === 2", in: webView)
        _ = try await awaitValue("\(findState).change({searchString: 'packet[0-9]+', wholeWord: false, isRegex: true}, false); true", in: webView)
        try await eventually("\(findState).matchesCount === 1", in: webView)
        _ = try await awaitValue("\(editor).getOriginalEditor().setSelection({startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 7}); true", in: webView)
        try await expectValue("\(editor).getModel().original.getValueInRange(\(editor).getOriginalEditor().getSelection())", in: webView, equals: "Packet")
        try await expectValue("\(editor).getModel().original.getLineLength(7)", in: webView, equals: 12_000)
        // The icon font must be embedded as well as the editor's CSS.
        try await expectValue("document.fonts.check('16px codicon')", in: webView, equals: true)
    }

    // Find, navigation, and appearance updates must operate on the same read-only models.
    func testFindNavigationAndAppearance() async throws {
        let (controller, webView, configuration) = try makeEditor()
        defer { controller.closeEditor() }
        controller.render(left: "A\nold\nC\nD\nE\nF\nG\nold tail", right: "A\nnew\nC\nD\nE\nF\nG\nnew tail", mode: .sideBySide)
        controller.showSearchBar()
        try await eventually("\(editor).getLineChanges()?.length === 2 && document.querySelectorAll('.find-widget.visible').length === 1", in: webView)
        _ = try await awaitValue("\(editor).getModifiedEditor().getContribution('editor.contrib.findController').closeFindWidget(); true", in: webView)
        controller.navigateDifference(backwards: false)
        try await eventually("\(editor).getModifiedEditor().getPosition().lineNumber === 2", in: webView)
        controller.navigateDifference(backwards: false)
        try await eventually("\(editor).getModifiedEditor().getPosition().lineNumber === 8", in: webView)
        controller.navigateDifference(backwards: true)
        try await eventually("\(editor).getModifiedEditor().getPosition().lineNumber === 2", in: webView)
        configuration.packetFontSize = 17
        controller.view.appearance = NSAppearance(named: .darkAqua)
        try await eventually("\(editor).getModifiedEditor().getRawOptions().fontSize === 17 && document.querySelector('.monaco-editor.vs-dark') !== null", in: webView)
        try await expectValue("\(editor).getModel().original.getValue()", in: webView, equals: "A\nold\nC\nD\nE\nF\nG\nold tail")
        controller.view.appearance = NSAppearance(named: .aqua)
        try await eventually("document.querySelector('.monaco-editor.vs') !== null", in: webView)
    }

    // Closing must dispose the models and permit a fresh editor without stale content or callbacks.
    func testCloseDisposesModelsAndCanReconfigure() async throws {
        let (controller, webView, configuration) = try makeEditor()
        controller.render(left: "left", right: "right", mode: .unified)
        try await eventually("\(editor).getModel().modified.getValue() === 'right'", in: webView)
        _ = try await awaitValue("window.savedModel = \(editor).getModel().original; true", in: webView)
        controller.closeEditor()
        try await eventually("window.savedModel.isDisposed()", in: webView)
        XCTAssertNil(webView.superview)
        controller.configure(configuration)
        defer { controller.closeEditor() }
        let reopened = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertFalse(reopened === webView)
        controller.render(left: "reopened", right: "", mode: .sideBySide)
        try await eventually("\(editor).getModel().original.getValue() === 'reopened'", in: reopened)
    }

    // Each integration case gets isolated preferences and a real, locally loaded WebKit view.
    private func makeEditor() throws -> (DiffMonacoEditorViewController, WKWebView, AppConfiguration) {
        XCTAssertNotNil(DiffMonacoEditorViewController.resourceURL)
        let suite = "DiffMonacoEditorIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let configuration = AppConfiguration(defaults: defaults)
        let controller = DiffMonacoEditorViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        controller.configure(configuration)
        controller.view.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        return (controller, webView, configuration)
    }

    // Poll bounded asynchronous worker results rather than assuming a fixed rendering delay.
    private func eventually(_ condition: String, in webView: WKWebView) async throws {
        for _ in 0..<150 {
            if let value = try? await awaitValue("Boolean(window.tcpviewerDiff && (\(condition)))", in: webView), value as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for bundled diff: \(condition)")
        throw NSError(domain: "DiffMonacoEditorIntegrationTests", code: 1)
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
