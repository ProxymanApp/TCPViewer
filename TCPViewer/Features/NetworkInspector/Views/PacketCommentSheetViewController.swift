//
//  PacketCommentSheetViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/7/26.
//

import AppKit
import PcapPlusPlusCore

final class PacketCommentSheetViewController: NSViewController, NSTextViewDelegate {
    private enum Layout {
        static let width: CGFloat = 520
        static let horizontalPadding: CGFloat = 24
        static let verticalPadding: CGFloat = 20
        static let editorHeight: CGFloat = 170
    }

    private let initialComment: String
    private let packetCount: Int
    private let saveHandler: (String) -> Void
    private let textView = NSTextView()
    private let countLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var sheetWindow: NSWindow?

    init(
        initialComment: String?,
        packetCount: Int = 1,
        saveHandler: @escaping (String) -> Void
    ) {
        self.initialComment = initialComment.map(PacketComment.sanitized) ?? ""
        self.packetCount = max(1, packetCount)
        self.saveHandler = saveHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Build a compact AppKit sheet with a multiline editor and explicit actions.
    override func loadView() {
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)

        let detailLabel = NSTextField(labelWithString: detailText)
        detailLabel.textColor = .secondaryLabelColor

        textView.delegate = self
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = initialComment

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        countLabel.alignment = .right
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.contentTintColor = .alternateSelectedControlTextColor
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let footer = NSStackView(views: [countLabel, buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill

        let stackView = NSStackView(views: [titleLabel, detailLabel, scrollView, footer])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.setCustomSpacing(14, after: detailLabel)
        stackView.setCustomSpacing(14, after: scrollView)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let rootView = NSView()
        rootView.addSubview(stackView)
        view = rootView

        NSLayoutConstraint.activate([
            rootView.widthAnchor.constraint(equalToConstant: Layout.width),
            stackView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Layout.horizontalPadding),
            stackView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -Layout.horizontalPadding),
            stackView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Layout.verticalPadding),
            stackView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -Layout.verticalPadding),
            scrollView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Layout.editorHeight),
            footer.widthAnchor.constraint(equalTo: stackView.widthAnchor),
        ])

        updateState()
    }

    // Attach the editor to the packet window and focus its multiline text view.
    func show(attachedTo parentWindow: NSWindow?) {
        loadViewIfNeeded()
        let window = NSWindow(contentViewController: self)
        window.styleMask = [.titled]
        window.title = titleText
        window.isReleasedWhenClosed = false
        sheetWindow = window

        if let parentWindow {
            parentWindow.beginSheet(window)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    private var titleText: String {
        if packetCount > 1 {
            return "Add Comment to \(packetCount) Packets"
        }
        return initialComment.isEmpty ? "Add Comment" : "Edit Comment"
    }

    private var detailText: String {
        packetCount > 1
            ? "This comment will be applied to \(packetCount) selected packets."
            : "Add a note for this packet."
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        // Enforce the same character limit before AppKit commits an edit.
        let current = textView.string as NSString
        let proposed = current.replacingCharacters(in: affectedCharRange, with: replacementString ?? "")
        return proposed.count <= PacketComment.maximumCharacterCount
    }

    // Refresh the counter and Save availability after each text edit.
    func textDidChange(_ notification: Notification) {
        updateState()
    }

    // Keep the footer state in sync with the sanitized editor value.
    private func updateState() {
        countLabel.stringValue = "\(textView.string.count) / \(PacketComment.maximumCharacterCount)"
        saveButton.isEnabled = !PacketComment.sanitized(textView.string).isEmpty
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    // Sanitize once more before forwarding the final comment.
    @objc private func save(_ sender: Any?) {
        let comment = PacketComment.sanitized(textView.string)
        guard !comment.isEmpty else {
            return
        }
        dismiss()
        saveHandler(comment)
    }

    // Close either the attached sheet or a standalone fallback window.
    private func dismiss() {
        guard let sheetWindow else {
            return
        }
        if let parentWindow = sheetWindow.sheetParent {
            parentWindow.endSheet(sheetWindow)
        } else {
            sheetWindow.close()
        }
        self.sheetWindow = nil
    }
}
