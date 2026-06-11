//
//  StatusStripViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import AppKit
import PcapPlusPlusCore

protocol StatusStripViewControllerDelegate: AnyObject {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController)
    func statusStripViewControllerDidRequestClearPackets(_ controller: StatusStripViewController)
    func statusStripViewControllerDidToggleStructuredFilter(_ controller: StatusStripViewController)
}

final class StatusStripViewModel {
    private(set) var totalText = "0 packets"
    private(set) var canCancelLoad = false
    private(set) var canClear = false
    private(set) var isStructuredFilterVisible = false
    private(set) var metricsText = TCPViewerStatusMetricsFormatter.displayText(for: .empty)

    // Build the compact bottom strip controls from the current packet/capture snapshot.
    func render(snapshot: NetworkInspectorSnapshot) {
        let packetCount = snapshot.totalPacketCount
        totalText = packetCount == 1 ? "1 packet" : "\(packetCount) packets"
        canCancelLoad = snapshot.base.loadState.canCancel
        canClear = snapshot.visiblePacketCount > 0 && !canCancelLoad
        isStructuredFilterVisible = snapshot.isStructuredFilterVisible
    }

    // Format the lightweight process and captured-traffic metrics for the strip.
    func render(metrics: TCPViewerStatusMetricsSnapshot) {
        metricsText = TCPViewerStatusMetricsFormatter.displayText(for: metrics)
    }
}

final class StatusStripViewController: NSViewController {
    weak var delegate: StatusStripViewControllerDelegate?

    private let viewModel = StatusStripViewModel()
    private let cancelButton = NSButton(title: "Cancel Load", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let filterButton = NSButton(title: "Filter", target: nil, action: nil)
    private let totalLabel = TCPViewerUI.label(
        "",
        font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .secondaryLabelColor
    )
    private let metricsLabel = TCPViewerUI.label(
        "",
        font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .secondaryLabelColor
    )

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        cancelButton.target = self
        cancelButton.action = #selector(cancelLoad(_:))
        clearButton.target = self
        clearButton.action = #selector(clearPackets(_:))
        filterButton.target = self
        filterButton.action = #selector(toggleStructuredFilter(_:))
    }

    func render(snapshot: NetworkInspectorSnapshot, metrics: TCPViewerStatusMetricsSnapshot = .empty) {
        viewModel.render(snapshot: snapshot)
        viewModel.render(metrics: metrics)
        cancelButton.isHidden = !viewModel.canCancelLoad
        clearButton.isHidden = viewModel.canCancelLoad
        clearButton.isEnabled = viewModel.canClear
        filterButton.state = viewModel.isStructuredFilterVisible ? .on : .off
        totalLabel.stringValue = viewModel.totalText
        metricsLabel.stringValue = viewModel.metricsText
    }

    func render(metrics: TCPViewerStatusMetricsSnapshot) {
        viewModel.render(metrics: metrics)
        metricsLabel.stringValue = viewModel.metricsText
    }

    private func setupLayout() {
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small

        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.image = TCPViewerUI.image("trash")
        clearButton.imagePosition = .imageLeading

        filterButton.setButtonType(.pushOnPushOff)
        filterButton.bezelStyle = .rounded
        filterButton.controlSize = .small
        filterButton.image = TCPViewerUI.image("line.3.horizontal.decrease.circle")
        filterButton.imagePosition = .imageLeading
        filterButton.toolTip = "Show or hide packet filters"

        totalLabel.alignment = .center
        totalLabel.translatesAutoresizingMaskIntoConstraints = false

        metricsLabel.alignment = .right
        metricsLabel.toolTip = "App memory and captured upload/download speed"
        metricsLabel.translatesAutoresizingMaskIntoConstraints = false
        metricsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let controlStack = NSStackView(views: [
            cancelButton,
            clearButton,
            filterButton,
        ])
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 8
        controlStack.translatesAutoresizingMaskIntoConstraints = false

        let separator = TCPViewerUI.separator()
        view.addSubview(separator)
        view.addSubview(controlStack)
        view.addSubview(totalLabel)
        view.addSubview(metricsLabel)

        let totalCenterConstraint = totalLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        totalCenterConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 33),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: view.topAnchor),

            controlStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            controlStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            totalLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            totalLabel.leadingAnchor.constraint(greaterThanOrEqualTo: controlStack.trailingAnchor, constant: 12),
            totalLabel.trailingAnchor.constraint(lessThanOrEqualTo: metricsLabel.leadingAnchor, constant: -12),

            metricsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            metricsLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            metricsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: controlStack.trailingAnchor, constant: 12),
        ])
        totalCenterConstraint.isActive = true
    }

    @objc private func cancelLoad(_ sender: Any?) {
        delegate?.statusStripViewControllerDidRequestCancelLoad(self)
    }

    @objc private func clearPackets(_ sender: Any?) {
        delegate?.statusStripViewControllerDidRequestClearPackets(self)
    }

    @objc private func toggleStructuredFilter(_ sender: Any?) {
        delegate?.statusStripViewControllerDidToggleStructuredFilter(self)
    }
}
