//
//  DiffMonacoEditorViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit
import WebKit

private final class DiffEditorHostView: NSView {
    var appearanceChanged: (() -> Void)?

    // AppKit appearance changes also update the locally embedded editor.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

final class DiffMonacoEditorViewController: NSViewController, WKNavigationDelegate {
    private struct Content: Equatable {
        var left = ""
        var right = ""
        var mode = DiffDisplayMode.sideBySide
    }

    private var webView: WKWebView?
    private var configuration: AppConfiguration?
    private var content = Content()
    private var isReady = false
    private var isRendering = false
    private var appliedContent: Content?
    private var pendingFind = false
    private let errorLabel = NSTextField(wrappingLabelWithString: "Could not load the packet comparison. Close and reopen the Diff window to retry.")

    // The editor's complete runtime is copied into the app, with no Swift package or CDN.
    static var resourceURL: URL? {
        Bundle(for: DiffMonacoEditorViewController.self).url(forResource: "index", withExtension: "html", subdirectory: "MonacoDiff")
    }

    // Keep the native host responsible for sizing and appearance notifications.
    override func loadView() {
        let host = DiffEditorHostView()
        host.appearanceChanged = { [weak self] in self?.updateAppearance() }
        view = host
    }

    // Load only local assets into an ephemeral WebKit store; packet text never becomes HTML.
    func configure(_ configuration: AppConfiguration) {
        NotificationCenter.default.removeObserver(self)
        self.configuration = configuration
        NotificationCenter.default.addObserver(self, selector: #selector(updateAppearance), name: AppConfiguration.didChangeNotification, object: configuration)
        guard webView == nil else { updateAppearance(); return }
        let settings = WKWebViewConfiguration()
        settings.websiteDataStore = .nonPersistent()
        settings.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: settings)
        self.webView = webView
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)
        ])
        guard let url = Self.resourceURL else { showLoadFailure(); return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // Presentation changes preserve the models, selection, and scroll position.
    @objc private func updateAppearance() {
        guard isReady, let configuration, let webView else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.callAsyncJavaScript("window.tcpviewerDiff.appearance(settings);", arguments: [
            "settings": ["dark": dark, "fontSize": Int(configuration.packetFontSize)]
        ], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView else { return }
            if case .failure = result { self.showLoadFailure() }
        }
    }

    // Retain only the latest requested comparison while the page or a previous render is loading.
    func render(left: String, right: String, mode: DiffDisplayMode) {
        content = Content(left: left, right: right, mode: mode)
        flushContent()
    }

    // Serialize bridge calls so a late completion cannot replace a newer packet selection.
    private func flushContent() {
        guard isReady, !isRendering, content != appliedContent, let webView else { return }
        let next = content
        isRendering = true
        webView.callAsyncJavaScript("window.tcpviewerDiff.render(content);", arguments: [
            "content": ["left": next.left, "right": next.right, "sideBySide": next.mode == .sideBySide]
        ], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView else { return }
            self.isRendering = false
            switch result {
            case .success:
                self.appliedContent = next
                self.flushContent()
                if self.pendingFind, !self.isRendering { self.showSearchBar() }
            case .failure:
                self.showLoadFailure()
            }
        }
    }

    // Find targets the last focused text pane, including a request made before the page is ready.
    func showSearchBar() {
        pendingFind = true
        guard isReady, !isRendering else { return }
        pendingFind = false
        webView?.evaluateJavaScript("window.tcpviewerDiff.find();", completionHandler: nil)
    }

    // Keep F7 navigation available even while focus is in the native packet pool.
    func navigateDifference(backwards: Bool) {
        guard isReady else { return }
        webView?.callAsyncJavaScript("window.tcpviewerDiff.navigate(backwards);", arguments: ["backwards": backwards], in: nil, in: .page, completionHandler: nil)
    }

    // The deferred bundle has executed when navigation finishes; verify it before sending content.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("Boolean(window.tcpviewerDiff)") { [weak self, weak webView] value, error in
            guard let self, let webView, self.webView === webView else { return }
            guard error == nil, value as? Bool == true else { self.showLoadFailure(); return }
            self.isReady = true
            self.appliedContent = nil
            self.updateAppearance()
            self.flushContent()
        }
    }

    // Packet contents cannot navigate the embedded page or open remote resources.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url == Self.resourceURL ? .allow : .cancel)
    }

    // Failed loads replace stale comparison content with an actionable message.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showLoadFailure() }

    // Provisional failures happen before the bundled page can initialize.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showLoadFailure() }

    // A terminated WebKit process must not leave an apparently valid blank comparison.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showLoadFailure() }

    // Hide failed content without logging potentially sensitive packet details.
    private func showLoadFailure() {
        isReady = false
        webView?.isHidden = true
        errorLabel.isHidden = false
    }

    // Release both models, the diff worker, and the entire ephemeral web view on window close.
    func closeEditor() {
        NotificationCenter.default.removeObserver(self)
        webView?.evaluateJavaScript("window.tcpviewerDiff?.dispose();", completionHandler: nil)
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        errorLabel.removeFromSuperview()
        webView = nil
        isReady = false
        isRendering = false
        appliedContent = nil
        content = Content()
        pendingFind = false
    }

    deinit { closeEditor() }
}
