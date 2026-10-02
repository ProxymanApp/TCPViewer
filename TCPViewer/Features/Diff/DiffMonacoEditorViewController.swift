//
//  DiffMonacoEditorViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit
import MonacoEditor
import WebKit

private final class DiffEditorHostView: NSView {
    var appearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

final class DiffMonacoEditorViewController: NSViewController {
    private var editor: MonacoViewController?
    private var configuration: AppConfiguration?
    private var lastLeft: String?
    private var lastRight: String?
    private var lastMode: DiffDisplayMode?

    override func loadView() {
        let host = DiffEditorHostView()
        host.appearanceChanged = { [weak self] in self?.updateAppearance() }
        view = host
    }

    // Use the same private Monaco factory and diff mode as Proxyman; text stays read-only.
    func configure(_ configuration: AppConfiguration) {
        self.configuration = configuration
        let setting = MonacoSetting(isDarkTheme: isDark, readOnly: true, language: .plaintext,
                                    minimap: false, wordWarp: false, scrollBeyondLastLine: false,
                                    fontSize: Int(configuration.packetFontSize), tabWidth: 4, isUseMonospacedFont: true)
        let controller = MonacoEditorFactory.shared.buildMonacoEditor(mode: .diff, setting: setting)
        editor = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(updateAppearance), name: AppConfiguration.didChangeNotification, object: configuration)
    }

    private var isDark: Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var webView: WKWebView? { editor?.view.subviews.compactMap { $0 as? WKWebView }.first }

    @objc private func updateAppearance() {
        editor?.setTheme(name: isDark ? "vs-dark-v2" : "vs-v2")
        if let configuration { editor?.setFontSize(fontSize: Int(configuration.packetFontSize)) }
    }

    func render(left: String, right: String, mode: DiffDisplayMode) {
        guard lastLeft != left || lastRight != right || lastMode != mode else { return }
        lastLeft = left
        lastRight = right
        lastMode = mode
        editor?.setDiffContent(left: DiffContent(text: left, mode: "plaintext"),
                               right: DiffContent(text: right, mode: "plaintext"), options: mode.editorOptions) { [weak self] result in
            guard case .success = result else { return }
            // A mode change can expose a previously hidden pane; repaint it without stealing table focus.
            self?.webView?.evaluateJavaScript("editor.editor.layout(); editor.editor.getOriginalEditor().render(true); editor.editor.getModifiedEditor().render(true);")
        }
    }

    // Monaco's Find action belongs to an inner text editor, rather than the diff-editor wrapper.
    func showSearchBar() {
        webView?.evaluateJavaScript("(() => { const original = editor.editor.getOriginalEditor(); const pane = original.hasTextFocus() ? original : editor.editor.getModifiedEditor(); pane.focus(); pane.getAction('actions.find').run(); })();")
    }

    // Removing the WKWebView explicitly matches Proxyman's editor lifecycle.
    func closeEditor() {
        NotificationCenter.default.removeObserver(self)
        editor?.cleanWebview()
        editor?.view.removeFromSuperview()
        editor?.removeFromParent()
        editor = nil
    }

    deinit { closeEditor() }
}
