//
//  TCPFollowStreamViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import AppKit
import PcapPlusPlusCore

private final class TCPFollowTextView: NSTextView {
    var packetRanges: [TCPFollowPacketRange] = []
    var revealPacket: ((PacketSummary.ID) -> Void)?

    // Open the originating packet when a transcript turn is double-clicked.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else {
            return
        }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard let packetID = packetRanges.first(where: { NSLocationInRange(index, $0.range) })?.packetID else {
            return
        }
        revealPacket?(packetID)
    }
}

final class TCPFollowStreamViewController: NSViewController {
    var revealPacket: ((PacketSummary.ID) -> Void)?

    private let viewModel = TCPFollowStreamViewModel()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "Reassembling TCP stream…")
    private let progressIndicator = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let textView = TCPFollowTextView()
    private let placeholderStack = NSStackView()
    private var latestRenderedContent: TCPFollowRenderedContent?

    var stream: TCPFollowStream? {
        viewModel.stream
    }

    var renderedContent: TCPFollowRenderedContent {
        latestRenderedContent ?? viewModel.renderedContent()
    }

    override func loadView() {
        view = NSView()
        setupView()
    }

    // Display an indeterminate loading state before the core reports packet counts.
    func showLoading() {
        summaryLabel.stringValue = "Preparing packet snapshot"
        placeholderLabel.stringValue = "Reassembling TCP stream…"
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        placeholderStack.isHidden = false
        scrollView.isHidden = true
    }

    // Update bounded reassembly progress without exposing payload data.
    func updateProgress(_ progress: TCPFollowProgress) {
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(max(progress.totalPacketCount, 1))
        progressIndicator.doubleValue = Double(progress.processedPacketCount)
        placeholderLabel.stringValue = "Reassembling packet \(progress.processedPacketCount.formatted()) of \(progress.totalPacketCount.formatted())…"
    }

    // Render the completed immutable stream snapshot.
    func show(stream: TCPFollowStream) {
        progressIndicator.stopAnimation(nil)
        viewModel.setStream(stream)
        let client = endpointLabel(stream.client)
        let server = endpointLabel(stream.server)
        summaryLabel.stringValue = "\(client)  ⇄  \(server)"
        placeholderStack.isHidden = true
        scrollView.isHidden = false
        render()
    }

    // Replace the progress state with a concise recoverable error.
    func show(error: Error) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        placeholderLabel.stringValue = error.localizedDescription
        summaryLabel.stringValue = "Follow TCP Stream"
        placeholderStack.isHidden = false
        scrollView.isHidden = true
    }

    // Apply the direction control to the already-reassembled snapshot.
    func setDirectionFilter(_ filter: TCPFollowDirectionFilter) {
        viewModel.setDirectionFilter(filter)
        render()
    }

    // Apply the text/hex control to the already-reassembled snapshot.
    func setRepresentation(_ representation: TCPFollowRepresentation) {
        viewModel.setRepresentation(representation)
        render()
    }

    private func setupView() {
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.revealPacket = { [weak self] packetID in
            self?.revealPacket?(packetID)
        }
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 3
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 12
        placeholderStack.addArrangedSubview(placeholderLabel)
        placeholderStack.addArrangedSubview(progressIndicator)

        [summaryLabel, statusLabel, scrollView, placeholderStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: summaryLabel.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholderStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderStack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
            progressIndicator.widthAnchor.constraint(equalToConstant: 260),
        ])
        showLoading()
    }

    // Refresh only presentation state; core reassembly is intentionally not repeated.
    private func render() {
        guard viewModel.stream != nil else {
            return
        }
        let content = viewModel.renderedContent()
        latestRenderedContent = content
        textView.textStorage?.setAttributedString(content.attributedText)
        textView.packetRanges = content.packetRanges
        statusLabel.stringValue = content.statusText
    }

    private func endpointLabel(_ endpoint: PacketEndpoint) -> String {
        let address = endpoint.address ?? "Unknown"
        return endpoint.port.map { "\(address):\($0)" } ?? address
    }
}
