//
//  PacketQuickFilterViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/5/26.
//

import AppKit

protocol PacketQuickFilterViewControllerDelegate: AnyObject {
    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didToggle filterID: PacketQuickFilterID)
    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didApplyCustomFilter filterID: PacketCustomFilter.ID)
    func packetQuickFilterViewController(
        _ controller: PacketQuickFilterViewController,
        didRenameCustomFilter filterID: PacketCustomFilter.ID,
        name: String
    )
    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didDuplicateCustomFilter filterID: PacketCustomFilter.ID)
    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didDeleteCustomFilter filterID: PacketCustomFilter.ID)
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

private final class PacketCustomFilterButton: NSButton {
    let filterID: PacketCustomFilter.ID
    var rightClickHandler: ((PacketCustomFilterButton, NSEvent) -> Void)?

    init(filterID: PacketCustomFilter.ID, title: String, target: AnyObject?, action: Selector?) {
        self.filterID = filterID
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func rightMouseDown(with event: NSEvent) {
        rightClickHandler?(self, event)
    }
}

private struct PacketCustomFilterButtonSignature: Equatable {
    let id: PacketCustomFilter.ID
    let title: String
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
    private let customSeparator = NSBox()
    private let resetSeparator = NSBox()
    private let bottomSeparator = NSBox()
    private let resetButton = NSButton(title: "Reset Filters", target: nil, action: nil)
    private var buttons: [PacketQuickFilterID: PacketQuickFilterButton] = [:]
    private var customButtons: [PacketCustomFilter.ID: PacketCustomFilterButton] = [:]
    private var customItemsByID: [PacketCustomFilter.ID: PacketCustomFilterItem] = [:]
    private var renderedQuickFilterIDs: [PacketQuickFilterID] = []
    private var renderedCustomFilterSignatures: [PacketCustomFilterButtonSignature] = []

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
        ensureButtons(for: snapshot.quickFilterItems, customItems: snapshot.customFilterItems)
        customItemsByID = Dictionary(uniqueKeysWithValues: snapshot.customFilterItems.map { ($0.id, $0) })
        for item in snapshot.quickFilterItems {
            guard let button = buttons[item.id] else {
                continue
            }
            render(button: button, title: item.title, toolTip: item.id.toolTip, isSelected: item.isSelected)
        }
        for item in snapshot.customFilterItems {
            guard let button = customButtons[item.id] else {
                continue
            }
            render(
                button: button,
                title: item.title,
                toolTip: "Apply custom filter \"\(item.title)\"",
                isSelected: item.isSelected
            )
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

        customSeparator.boxType = .separator
        customSeparator.translatesAutoresizingMaskIntoConstraints = false

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
            customSeparator.heightAnchor.constraint(equalToConstant: 18),
            resetSeparator.heightAnchor.constraint(equalToConstant: 18),
            resetButton.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: Metrics.bottomSeparatorHeight),
        ])
    }

    private func ensureButtons(for items: [PacketQuickFilterItem], customItems: [PacketCustomFilterItem]) {
        let nextQuickFilterIDs = items.map(\.id)
        let nextCustomFilterSignatures = customItems.map {
            PacketCustomFilterButtonSignature(id: $0.id, title: $0.title)
        }
        guard renderedQuickFilterIDs != nextQuickFilterIDs ||
                renderedCustomFilterSignatures != nextCustomFilterSignatures else {
            return
        }

        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons.removeAll(keepingCapacity: true)
        customButtons.removeAll(keepingCapacity: true)
        renderedQuickFilterIDs = nextQuickFilterIDs
        renderedCustomFilterSignatures = nextCustomFilterSignatures

        for item in items {
            let button = PacketQuickFilterButton(filterID: item.id, target: self, action: #selector(toggleFilter(_:)))
            configure(button: button, isToggle: true)
            buttons[item.id] = button
            stackView.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: measuredWidth(for: item.title)).isActive = true
        }

        if !customItems.isEmpty {
            stackView.addArrangedSubview(customSeparator)
            for item in customItems {
                let button = PacketCustomFilterButton(
                    filterID: item.id,
                    title: item.title,
                    target: self,
                    action: #selector(applyCustomFilter(_:))
                )
                button.rightClickHandler = { [weak self] button, event in
                    self?.showCustomFilterMenu(for: button, event: event)
                }
                configure(button: button, isToggle: true)
                customButtons[item.id] = button
                stackView.addArrangedSubview(button)
                button.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight).isActive = true
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: measuredWidth(for: item.title)).isActive = true
            }
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

    @objc private func applyCustomFilter(_ sender: NSButton) {
        guard let sender = sender as? PacketCustomFilterButton else {
            return
        }

        delegate?.packetQuickFilterViewController(self, didApplyCustomFilter: sender.filterID)
    }

    @objc private func resetFilters(_ sender: NSButton) {
        delegate?.packetQuickFilterViewControllerDidRequestReset(self)
    }

    // Build the per-custom-filter context menu from the current snapshot item.
    private func showCustomFilterMenu(for button: PacketCustomFilterButton, event: NSEvent) {
        guard let item = customItemsByID[button.filterID] else {
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let renameItem = NSMenuItem(title: "Edit Name", action: #selector(renameCustomFilter(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = item.id
        menu.addItem(renameItem)

        menu.addItem(.separator())
        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(duplicateCustomFilter(_:)), keyEquivalent: "")
        duplicateItem.target = self
        duplicateItem.representedObject = item.id
        duplicateItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Duplicate")
        menu.addItem(duplicateItem)

        menu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteCustomFilter(_:)), keyEquivalent: "\u{8}")
        deleteItem.target = self
        deleteItem.representedObject = item.id
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func renameCustomFilter(_ sender: NSMenuItem) {
        guard let filterID = sender.representedObject as? PacketCustomFilter.ID,
              let item = customItemsByID[filterID],
              let name = requestCustomFilterName(initialName: item.title) else {
            return
        }

        delegate?.packetQuickFilterViewController(self, didRenameCustomFilter: filterID, name: name)
    }

    @objc private func duplicateCustomFilter(_ sender: NSMenuItem) {
        guard let filterID = sender.representedObject as? PacketCustomFilter.ID else {
            return
        }

        delegate?.packetQuickFilterViewController(self, didDuplicateCustomFilter: filterID)
    }

    @objc private func deleteCustomFilter(_ sender: NSMenuItem) {
        guard let filterID = sender.representedObject as? PacketCustomFilter.ID,
              let item = customItemsByID[filterID],
              confirmDeleteCustomFilter(named: item.title) else {
            return
        }

        delegate?.packetQuickFilterViewController(self, didDeleteCustomFilter: filterID)
    }

    // Ask for a new custom filter name and trim it before handing it to the model layer.
    private func requestCustomFilterName(initialName: String) -> String? {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = initialName

        let alert = NSAlert()
        alert.messageText = "Rename Custom Filter"
        alert.informativeText = "Enter a new name for this custom filter."
        alert.alertStyle = .informational
        alert.accessoryView = textField
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        do {
            return try PacketCustomFilterService.normalizedName(textField.stringValue)
        } catch {
            showCustomFilterNameValidationError(error)
            return nil
        }
    }

    // Confirm deletion because custom filters are persisted user settings.
    private func confirmDeleteCustomFilter(named name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete Custom Filter?"
        alert.informativeText = "This removes \"\(name)\" from the quick filter bar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Show validation feedback before dispatching a rename action.
    private func showCustomFilterNameValidationError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Invalid Filter Name"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
