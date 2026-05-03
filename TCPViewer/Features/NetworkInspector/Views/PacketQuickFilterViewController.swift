//
//  PacketQuickFilterViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/5/26.
//

import AppKit

protocol PacketQuickFilterViewControllerDelegate: AnyObject {
    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didToggle filterID: PacketQuickFilterID)
    func packetQuickFilterViewControllerDidRequestReset(_ controller: PacketQuickFilterViewController)
}

private final class PacketQuickFilterButton: NSButton {
    let filterID: PacketQuickFilterID

    init(filterID: PacketQuickFilterID, target: AnyObject?, action: Selector?) {
        self.filterID = filterID
        super.init(frame: .zero)
        title = filterID.title
        self.target = target
        self.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PacketQuickFilterViewController: NSTitlebarAccessoryViewController {
    private enum Metrics {
        static let height: CGFloat = 34
        static let buttonHeight: CGFloat = 24
        static let horizontalInset: CGFloat = 16
        static let buttonHorizontalPadding: CGFloat = 16
        static let bottomSeparatorHeight: CGFloat = 1
    }

    weak var delegate: PacketQuickFilterViewControllerDelegate?

    private let stackView = NSStackView()
    private let resetSeparator = NSBox()
    private let bottomSeparator = NSBox()
    private let resetButton = NSButton(title: "Reset Filters", target: nil, action: nil)
    private var buttons: [PacketQuickFilterID: PacketQuickFilterButton] = [:]

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        layoutAttribute = .bottom
        automaticallyAdjustsSize = false
        preferredContentSize = NSSize(width: 0, height: Metrics.height)
    }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: Metrics.height))
        setupLayout()
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        ensureButtons(for: snapshot.quickFilterItems)
        for item in snapshot.quickFilterItems {
            guard let button = buttons[item.id] else {
                continue
            }
            render(button: button, title: item.title, toolTip: item.id.toolTip, isSelected: item.isSelected)
        }

        resetButton.isHidden = !snapshot.isQuickFilterResetVisible
        resetSeparator.isHidden = resetButton.isHidden
    }

    private func setupLayout() {
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(
            top: 4,
            left: Metrics.horizontalInset,
            bottom: 4,
            right: Metrics.horizontalInset
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false

        resetSeparator.boxType = .separator
        resetSeparator.translatesAutoresizingMaskIntoConstraints = false
        resetSeparator.isHidden = true

        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        resetButton.target = self
        resetButton.action = #selector(resetFilters(_:))
        resetButton.image = TCPViewerUI.image("arrow.counterclockwise")
        resetButton.imagePosition = .imageLeading
        configure(button: resetButton, isToggle: false)
        render(button: resetButton, title: "Reset Filters", toolTip: "Reset quick filters", isSelected: false)
        resetButton.isHidden = true

        view.addSubview(stackView)
        view.addSubview(bottomSeparator)
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: Metrics.height),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            resetSeparator.heightAnchor.constraint(equalToConstant: 18),
            resetButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: Metrics.bottomSeparatorHeight),
        ])
    }

    private func ensureButtons(for items: [PacketQuickFilterItem]) {
        guard buttons.count != items.count else {
            return
        }

        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons.removeAll(keepingCapacity: true)

        for item in items {
            let button = PacketQuickFilterButton(filterID: item.id, target: self, action: #selector(toggleFilter(_:)))
            configure(button: button, isToggle: true)
            buttons[item.id] = button
            stackView.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: measuredWidth(for: item.title)).isActive = true
        }

        stackView.addArrangedSubview(resetSeparator)
        stackView.addArrangedSubview(resetButton)
    }

    private func configure(button: NSButton, isToggle: Bool) {
        if isToggle {
            button.setButtonType(.pushOnPushOff)
        } else {
            button.setButtonType(.momentaryPushIn)
        }
        button.bezelStyle = .recessed
        button.isBordered = false
        button.controlSize = .small
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.cell?.lineBreakMode = .byTruncatingTail
    }

    private func render(button: NSButton, title: String, toolTip: String, isSelected: Bool) {
        button.state = isSelected ? .on : .off
        button.toolTip = toolTip
        button.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
        )
    }

    private func measuredWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        return ceil(title.size(withAttributes: [.font: font]).width + Metrics.buttonHorizontalPadding)
    }

    @objc private func toggleFilter(_ sender: NSButton) {
        guard let sender = sender as? PacketQuickFilterButton else {
            return
        }

        delegate?.packetQuickFilterViewController(self, didToggle: sender.filterID)
    }

    @objc private func resetFilters(_ sender: NSButton) {
        delegate?.packetQuickFilterViewControllerDidRequestReset(self)
    }
}
