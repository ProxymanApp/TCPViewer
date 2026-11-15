//
//  TLSInspectorNoticeView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit

protocol TLSInspectorNoticeViewDelegate: AnyObject {
    func tlsInspectorNoticeViewDidRequestSettings(_ view: TLSInspectorNoticeView)
    func tlsInspectorNoticeViewDidRequestDecryptAgain(_ view: TLSInspectorNoticeView)
    func tlsInspectorNoticeViewDidRequestShowDecryptedBytes(_ view: TLSInspectorNoticeView)
}

// A strip above the packet details that says whether the selected TLS packet is decrypted, and what to do if not.
final class TLSInspectorNoticeView: NSView {
    private enum Action: Int {
        case settings
        case decryptAgain
        case showDecryptedBytes
    }

    weak var delegate: TLSInspectorNoticeViewDelegate?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonStack = NSStackView()
    private let separator = NSBox()
    private let textStack = NSStackView()
    private(set) var notice: TLSInspectorNotice?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var buttonTitles: [String] {
        buttonStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
    }

    var title: String { titleLabel.stringValue }
    var message: String { messageLabel.stringValue }

    func render(_ notice: TLSInspectorNotice?) {
        isHidden = notice == nil
        guard let notice, notice != self.notice else {
            self.notice = notice
            return
        }
        self.notice = notice
        let content = Self.content(for: notice)
        iconView.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: content.title)
        iconView.contentTintColor = content.tint
        titleLabel.stringValue = content.title
        messageLabel.stringValue = content.message
        layer?.backgroundColor = content.tint.withAlphaComponent(0.09).cgColor
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.actions.map(makeButton).forEach(buttonStack.addArrangedSubview)
    }

    // Wrapping labels need their width before Auto Layout can size their height.
    override func layout() {
        super.layout()
        let width = textStack.frame.width
        if width > 0, messageLabel.preferredMaxLayoutWidth != width {
            messageLabel.preferredMaxLayoutWidth = width
            messageLabel.invalidateIntrinsicContentSize()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // CGColor does not follow appearance changes, so resolve the tint again.
        if let notice {
            layer?.backgroundColor = Self.content(for: notice).tint.withAlphaComponent(0.09).cgColor
        }
    }

    private struct Content {
        let symbol: String
        let tint: NSColor
        let title: String
        let message: String
        let actions: [Action]
    }

    private static func content(for notice: TLSInspectorNotice) -> Content {
        switch notice {
        case .encryptedWithKeyLog(let fileName):
            Content(
                symbol: "lock.trianglebadge.exclamationmark.fill",
                tint: .systemYellow,
                title: "Not decrypted",
                message: "“\(fileName)” has no keys for this connection yet, or the capture missed its TLS handshake. A live capture tries again when it stops; only connections made by the app that wrote the key log can be decrypted.",
                actions: [.decryptAgain, .settings]
            )
        case .decrypted(let fileName):
            Content(
                symbol: "lock.open.fill",
                tint: .systemGreen,
                title: fileName.map { "Decrypted with “\($0)”" } ?? "Decrypted with keys saved in this capture file",
                message: "The HTTP inside is in the details below; the plaintext bytes are in the Decrypted TLS tab.",
                actions: [.showDecryptedBytes]
            )
        }
    }

    private func makeButton(_ action: Action) -> NSButton {
        let title: String
        switch action {
        case .settings: title = "TLS Settings…"
        case .decryptAgain: title = "Decrypt Again"
        case .showDecryptedBytes: title = "Show Decrypted Bytes"
        }
        let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        button.tag = action.rawValue
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.bezelStyle = .push
        return button
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        switch Action(rawValue: sender.tag) {
        case .settings: delegate?.tlsInspectorNoticeViewDidRequestSettings(self)
        case .decryptAgain: delegate?.tlsInspectorNoticeViewDidRequestDecryptAgain(self)
        case .showDecryptedBytes: delegate?.tlsInspectorNoticeViewDidRequestShowDecryptedBytes(self)
        case nil: break
        }
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        [titleLabel, messageLabel, buttonStack].forEach(textStack.addArrangedSubview)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.setCustomSpacing(8, after: messageLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        addSubview(separator)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8),
            messageLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
