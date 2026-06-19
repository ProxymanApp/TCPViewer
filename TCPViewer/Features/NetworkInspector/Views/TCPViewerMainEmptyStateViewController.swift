//
//  TCPViewerMainEmptyStateViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/6/26.
//

import AppKit

protocol TCPViewerMainEmptyStateViewControllerDelegate: AnyObject {
    func tcpViewerMainEmptyStateViewController(
        _ controller: TCPViewerMainEmptyStateViewController,
        didSelectInterface identifier: String
    )
    func tcpViewerMainEmptyStateViewControllerDidRequestStartCapture(_ controller: TCPViewerMainEmptyStateViewController)
}

final class TCPViewerMainEmptyStateViewController: NSViewController {
    weak var delegate: TCPViewerMainEmptyStateViewControllerDelegate?

    private let imageView = NSImageView(image: TCPViewerUI.image("network") ?? NSImage())
    private let titleLabel = TCPViewerUI.label(
        "Getting Started",
        font: .systemFont(ofSize: 24, weight: .semibold)
    )
    private let messageLabel = TCPViewerUI.label(
        "Choose a network interface, then start capturing TCP traffic.",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .secondaryLabelColor
    )
    private let interfacePopup = NSPopUpButton(
        frame: NSRect(
            x: 0,
            y: 0,
            width: TCPViewerInterfacePopupMetrics.minimumWidth,
            height: TCPViewerInterfacePopupMetrics.controlHeight
        ),
        pullsDown: false
    )
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private var interfacePopupWidthConstraint: NSLayoutConstraint?
    private var selectedInterfaceID: String?

    override func loadView() {
        view = TCPViewerDynamicBackgroundView(backgroundColor: .controlBackgroundColor)
        setupLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        // Reuse the toolbar menu renderer so interface selection behaves identically here.
        let sessionState = snapshot.base.sessionState
        selectedInterfaceID = sessionState.selectedInterfaceID
        TCPViewerInterfacePopupRenderer.render(
            interfacePopup,
            state: TCPViewerInterfacePopupState(
                interfaces: sessionState.interfaceInventory,
                selectedInterfaceID: sessionState.selectedInterfaceID,
                lastUsedInterfaceIDs: sessionState.lastUsedInterfaceIDs,
                activeInterfaceID: sessionState.activeInterfaceID,
                isCaptureLocked: snapshot.isCaptureLocked
            ),
            widthConstraint: interfacePopupWidthConstraint,
            maximumWidth: nil
        )
        renderStartButton(canStart: sessionState.canStart, statusMessage: sessionState.statusMessage)
    }

    private func setupLayout() {
        // Center a compact first-run guide in the same region normally occupied by packet content.
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 52, weight: .regular)
        imageView.contentTintColor = .controlAccentColor

        titleLabel.alignment = .center
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

        interfacePopup.translatesAutoresizingMaskIntoConstraints = false
        let interfacePopupWidthConstraint = interfacePopup.widthAnchor.constraint(
            equalToConstant: TCPViewerInterfacePopupMetrics.minimumWidth
        )
        self.interfacePopupWidthConstraint = interfacePopupWidthConstraint

        startButton.translatesAutoresizingMaskIntoConstraints = false

        let controlStack = NSStackView(views: [interfacePopup, startButton])
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 10
        controlStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [imageView, titleLabel, messageLabel, controlStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 10
        contentStack.setCustomSpacing(18, after: imageView)
        contentStack.setCustomSpacing(20, after: messageLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            interfacePopupWidthConstraint,
            interfacePopup.heightAnchor.constraint(equalToConstant: TCPViewerInterfacePopupMetrics.controlHeight),
            startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            startButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func configureControls() {
        // Wire controls through a delegate to keep root navigation and capture policy centralized.
        TCPViewerInterfacePopupRenderer.configure(interfacePopup)
        interfacePopup.target = self
        interfacePopup.action = #selector(interfaceChanged(_:))

        startButton.target = self
        startButton.action = #selector(startCapture(_:))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        startButton.image = TCPViewerUI.image("play.fill")
        startButton.imagePosition = .imageLeading
        startButton.imageHugsTitle = true
        startButton.keyEquivalent = "\r"
        startButton.toolTip = "Start Capture"
    }

    private func renderStartButton(canStart: Bool, statusMessage: String) {
        // Keep the empty state's primary action aligned with the live capture state machine.
        startButton.isEnabled = canStart
        startButton.alphaValue = canStart ? 1 : 0.5
        startButton.bezelColor = canStart ? .controlAccentColor : nil
        startButton.toolTip = canStart ? "Start Capture" : statusMessage
    }

    @objc private func interfaceChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else {
            if !TCPViewerInterfacePopupRenderer.selectInterfaceItem(
                with: selectedInterfaceID,
                in: interfacePopup,
                widthConstraint: interfacePopupWidthConstraint,
                maximumWidth: nil
            ) {
                TCPViewerInterfacePopupRenderer.selectFirstInterfaceItem(
                    in: interfacePopup,
                    widthConstraint: interfacePopupWidthConstraint,
                    maximumWidth: nil
                )
            }
            TCPViewerInterfacePopupRenderer.updateWidth(
                of: interfacePopup,
                widthConstraint: interfacePopupWidthConstraint,
                maximumWidth: nil
            )
            return
        }

        TCPViewerInterfacePopupRenderer.updateWidth(
            of: interfacePopup,
            widthConstraint: interfacePopupWidthConstraint,
            maximumWidth: nil
        )
        delegate?.tcpViewerMainEmptyStateViewController(self, didSelectInterface: identifier)
    }

    @objc private func startCapture(_ sender: NSButton) {
        delegate?.tcpViewerMainEmptyStateViewControllerDidRequestStartCapture(self)
    }
}
