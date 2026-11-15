//
//  MonacoPageViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit
import WebKit

// The pages of the bundled Monaco editor (Vendor/MonacoDiff) and the bridge object each page installs.
enum MonacoPage {
    case diff
    case httpPreview

    var fileName: String {
        switch self {
        case .diff: "index"
        case .httpPreview: "preview"
        }
    }

    var bridge: String {
        switch self {
        case .diff: "tcpviewerDiff"
        case .httpPreview: "tcpviewerPreview"
        }
    }

    var failureMessage: String {
        switch self {
        case .diff: "Could not load the packet comparison. Close and reopen the Diff window to retry."
        case .httpPreview: "Could not load the preview. Close it and try again."
        }
    }
}

private final class MonacoEditorHostView: NSView {
    var appearanceChanged: (() -> Void)?

    // AppKit appearance changes also update the locally embedded editor.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

// Hosts one bundled Monaco page in an ephemeral WKWebView. Subclasses name the page and send it content;
// packet text crosses the bridge as data, never HTML or script source.
class MonacoPageViewController: NSViewController, WKNavigationDelegate {
    class var page: MonacoPage {
        preconditionFailure("Subclasses name the Monaco page they host.")
    }

    private var webView: WKWebView?
    private var configuration: AppConfiguration?
    private var content: [String: AnyHashable]?
    private var isReady = false
    private var isRendering = false
    private var appliedContent: [String: AnyHashable]?
    private var pendingFind = false
    private lazy var errorLabel = NSTextField(wrappingLabelWithString: Self.page.failureMessage)

    // The editor's complete runtime is copied into the app, with no Swift package or CDN.
    class var resourceURL: URL? {
        Bundle(for: MonacoPageViewController.self).url(forResource: page.fileName, withExtension: "html", subdirectory: "MonacoDiff")
    }

    // Keep the native host responsible for sizing and appearance notifications.
    override func loadView() {
        let host = MonacoEditorHostView()
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
        webView.callAsyncJavaScript("window.\(Self.page.bridge).appearance(settings);", arguments: [
            "settings": ["dark": dark, "fontSize": Int(configuration.packetFontSize)]
        ], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView else { return }
            if case .failure = result { self.showLoadFailure() }
        }
    }

    // Retain only the latest requested content while the page or a previous render is loading.
    func send(content: [String: AnyHashable]) {
        self.content = content
        flushContent()
    }

    // Serialize bridge calls so a late completion cannot replace newer content.
    private func flushContent() {
        guard isReady, !isRendering, let next = content, next != appliedContent, let webView else { return }
        isRendering = true
        webView.callAsyncJavaScript("window.\(Self.page.bridge).render(content);", arguments: [
            "content": next as [String: Any]
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

    // Find targets the editor, including a request made before the page is ready.
    func showSearchBar() {
        pendingFind = true
        guard isReady, !isRendering else { return }
        pendingFind = false
        webView?.evaluateJavaScript("window.\(Self.page.bridge).find();", completionHandler: nil)
    }

    // Call one more bridge method once the page is ready, e.g. Diff's previous/next difference.
    func callBridge(_ method: String, arguments: [String: Any]) {
        guard isReady else { return }
        webView?.callAsyncJavaScript("window.\(Self.page.bridge).\(method);", arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    // The deferred bundle has executed when navigation finishes; verify it before sending content.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("Boolean(window.\(Self.page.bridge))") { [weak self, weak webView] value, error in
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

    // Failed loads replace stale content with an actionable message.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showLoadFailure() }

    // Provisional failures happen before the bundled page can initialize.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showLoadFailure() }

    // A terminated WebKit process must not leave an apparently valid blank editor.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showLoadFailure() }

    // Hide failed content without logging potentially sensitive packet details.
    private func showLoadFailure() {
        isReady = false
        webView?.isHidden = true
        errorLabel.isHidden = false
    }

    // Release the page's models, workers, and the entire ephemeral web view.
    func closeEditor() {
        NotificationCenter.default.removeObserver(self)
        webView?.evaluateJavaScript("window.\(Self.page.bridge)?.dispose();", completionHandler: nil)
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        errorLabel.removeFromSuperview()
        webView = nil
        isReady = false
        isRendering = false
        appliedContent = nil
        content = nil
        pendingFind = false
    }

    deinit { closeEditor() }
}
