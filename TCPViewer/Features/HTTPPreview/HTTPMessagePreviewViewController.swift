//
//  HTTPMessagePreviewViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit

// The bundled Monaco page with the HTTP message grammar.
final class HTTPMessagePreviewEditorViewController: MonacoPageViewController {
    override class var page: MonacoPage { .httpPreview }

    // JSON bodies switch the page to the grammar that also colors JSON tokens.
    func render(_ preview: HTTPMessagePreview) {
        send(content: ["text": preview.text, "json": preview.isJSONBody])
    }
}

// The Preview popover: what the message is, a Copy button, and the highlighted message below.
final class HTTPMessagePreviewViewController: NSViewController {
    static let contentSize = NSSize(width: 640, height: 460)

    private let preview: HTTPMessagePreview
    private let configuration: AppConfiguration
    private let editor = HTTPMessagePreviewEditorViewController()
    private let copyButton = NSButton(title: "Copy", image: NSImage(), target: nil, action: nil)

    init(preview: HTTPMessagePreview, configuration: AppConfiguration) {
        self.preview = preview
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // A header row above a separator and the editor.
    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        preferredContentSize = Self.contentSize

        let titleLabel = TCPViewerUI.label(preview.title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kindLabel = TCPViewerUI.label(Self.subtitle(for: preview), font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)

        copyButton.image = TCPViewerUI.image("doc.on.doc")
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyMessage)
        copyButton.toolTip = "Copy the message as shown"

        let header = NSStackView(views: [titleLabel, kindLabel, NSView(), copyButton])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 10)

        let separator = TCPViewerUI.separator()
        let content = NSStackView(views: [header, separator, editor.view])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        TCPViewerUI.pin(content, to: view)
        for row in [header, separator, editor.view] {
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        addChild(editor)
    }

    // Load the editor only when the popover is about to show.
    override func viewWillAppear() {
        super.viewWillAppear()
        editor.configure(configuration)
        editor.render(preview)
    }

    // The popover owns the web view only while it is visible.
    func closeEditor() {
        editor.closeEditor()
    }

    // "HTTP/1.1 Response · JSON" style summary under the title.
    static func subtitle(for preview: HTTPMessagePreview) -> String {
        let kind = switch preview.kind {
        case .request: "Request"
        case .response: "Response"
        case .body: "Body"
        }
        return preview.isJSONBody ? "\(kind) · JSON prettified" : kind
    }

    // Copy the text the editor shows, with JSON already prettified.
    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.text, forType: .string)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = "Copy"
        }
    }
}
