//
//  TLSKeyLogWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import AppKit
import PcapPlusPlusCore
import UniformTypeIdentifiers

final class TLSKeyLogWindowController: NSWindowController {
    var configurationDidChange: (() -> Void)?

    private let manager: any TLSKeyLogManaging
    private let fileLabel = NSTextField(labelWithString: "No key-log file selected")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Choose an NSS/SSL key-log file to enable Wireshark decryption.")
    private let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private var selectedURL: URL?

    init(manager: any TLSKeyLogManaging) {
        self.manager = manager
        let contentController = NSViewController()
        let window = NSWindow(contentViewController: contentController)
        window.title = "TLS Key Log"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 330))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupView(contentController.view)
        refreshState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView(_ contentView: NSView) {
        fileLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        statusLabel.textColor = .secondaryLabelColor

        chooseButton.target = self
        chooseButton.action = #selector(chooseFile(_:))
        reloadButton.target = self
        reloadButton.action = #selector(reloadFile(_:))
        removeButton.target = self
        removeButton.action = #selector(removeFile(_:))

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let warning = NSTextField(wrappingLabelWithString: "TLS key logs expose encrypted session contents. Keep the file private. TCP Viewer uses the original file by reference, does not copy it, and forgets the selection when the app quits.")
        warning.textColor = .systemOrange

        let buttonRow = NSStackView(views: [chooseButton, reloadButton, removeButton, progressIndicator])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [fileLabel, pathLabel, statusLabel, warning, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
    }

    private func refreshState() {
        manager.currentState { [weak self] state in
            DispatchQueue.main.async {
                self?.render(state)
            }
        }
    }

    private func render(_ state: TLSKeyLogState) {
        selectedURL = state.fileURL
        fileLabel.stringValue = state.fileURL?.lastPathComponent ?? "No key-log file selected"
        pathLabel.stringValue = state.fileURL?.path ?? ""
        chooseButton.title = state.fileURL == nil ? "Choose File…" : "Replace…"
        reloadButton.isEnabled = state.fileURL != nil
        removeButton.isEnabled = state.fileURL != nil
        if let validation = state.validation {
            var message = "Valid records: \(validation.validRecordCount). Warnings: \(validation.warningCount)."
            if validation.reachedScanLimit {
                message += " Validation stopped at the safe scan limit."
            }
            message += " Syntax validation cannot prove that these secrets match the capture."
            statusLabel.stringValue = message
        } else {
            statusLabel.stringValue = "Choose an NSS/SSL key-log file to enable Wireshark decryption."
        }
    }

    private func setLoading(_ loading: Bool, message: String) {
        statusLabel.stringValue = message
        chooseButton.isEnabled = !loading
        reloadButton.isEnabled = !loading && selectedURL != nil
        removeButton.isEnabled = !loading && selectedURL != nil
        loading ? progressIndicator.startAnimation(nil) : progressIndicator.stopAnimation(nil)
    }

    @objc private func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose TLS Key Log"
        panel.message = "Choose a .txt, .log, .keys, or extensionless NSS/SSL key-log file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .data]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        apply(url)
    }

    @objc private func reloadFile(_ sender: Any?) {
        guard let selectedURL else {
            return
        }
        apply(selectedURL)
    }

    @objc private func removeFile(_ sender: Any?) {
        setLoading(true, message: "Removing TLS key log…")
        manager.remove { [weak self] result in
            DispatchQueue.main.async {
                self?.finish(result)
            }
        }
    }

    private func apply(_ url: URL) {
        setLoading(true, message: "Validating TLS key log…")
        manager.apply(fileURL: url) { [weak self] result in
            DispatchQueue.main.async {
                self?.finish(result)
            }
        }
    }

    private func finish(_ result: Result<TLSKeyLogState, Error>) {
        progressIndicator.stopAnimation(nil)
        chooseButton.isEnabled = true
        switch result {
        case .success(let state):
            render(state)
            configurationDidChange?()
        case .failure(let error):
            reloadButton.isEnabled = selectedURL != nil
            removeButton.isEnabled = selectedURL != nil
            statusLabel.stringValue = (error as? TCPViewerCoreError)?.message ?? error.localizedDescription
        }
    }
}
