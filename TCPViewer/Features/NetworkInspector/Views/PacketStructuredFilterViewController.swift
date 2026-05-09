//
//  PacketStructuredFilterViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/5/26.
//

import AppKit

protocol PacketStructuredFilterViewControllerDelegate: AnyObject {
    func packetStructuredFilterViewController(_ controller: PacketStructuredFilterViewController, didUpdate group: PacketStructuredFilterGroup)
}

private final class PacketStructuredFilterRowView: NSView {
    let filterID: PacketStructuredFilter.ID
    let enabledCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let queryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let conditionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let textField = NSSearchField()
    let removeButton = NSButton(title: "", target: nil, action: nil)
    let addButton = NSButton(title: "", target: nil, action: nil)

    init(filter: PacketStructuredFilter, target: AnyObject, actionProvider: PacketStructuredFilterActionProvider) {
        self.filterID = filter.id
        super.init(frame: .zero)
        setupControls(target: target, actionProvider: actionProvider)
        render(filter: filter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Configure one editable filter row and wire all AppKit controls through target-action.
    private func setupControls(target: AnyObject, actionProvider: PacketStructuredFilterActionProvider) {
        enabledCheckbox.target = target
        enabledCheckbox.action = actionProvider.toggleEnabled
        enabledCheckbox.controlSize = .regular
        enabledCheckbox.toolTip = "Enable filter"

        configurePopup(queryPopup, target: target, action: actionProvider.changeQuery)
        PacketStructuredFilterQuery.allCases.forEach { query in
            let item = queryPopup.menu?.addItem(withTitle: query.title, action: nil, keyEquivalent: "")
            item?.representedObject = query.rawValue
        }

        configurePopup(conditionPopup, target: target, action: actionProvider.changeCondition)
        PacketStructuredFilterCondition.allCases.forEach { condition in
            let item = conditionPopup.menu?.addItem(withTitle: condition.title, action: nil, keyEquivalent: "")
            item?.representedObject = condition.rawValue
        }

        textField.target = target
        textField.action = actionProvider.changeText
        textField.delegate = target as? NSSearchFieldDelegate
        textField.placeholderString = "Text"
        textField.controlSize = .regular
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.focusRingType = .default
        textField.sendsWholeSearchString = false
        textField.cell?.lineBreakMode = .byTruncatingTail

        configureIconButton(removeButton, systemName: "minus", toolTip: "Remove filter", target: target, action: actionProvider.remove)
        configureIconButton(addButton, systemName: "plus", toolTip: "Add filter", target: target, action: actionProvider.add)

        let stack = NSStackView(views: [enabledCheckbox, queryPopup, conditionPopup, textField, removeButton, addButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            enabledCheckbox.widthAnchor.constraint(equalToConstant: 24),
            queryPopup.widthAnchor.constraint(equalToConstant: 180),
            conditionPopup.widthAnchor.constraint(equalToConstant: 156),
            removeButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.widthAnchor.constraint(equalToConstant: 24),
        ])

        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func render(filter: PacketStructuredFilter) {
        enabledCheckbox.state = filter.isEnabled ? .on : .off
        queryPopup.selectItem(withTitle: filter.query.title)
        conditionPopup.selectItem(withTitle: filter.condition.title)
        textField.stringValue = filter.text
    }

    private func configurePopup(_ popup: NSPopUpButton, target: AnyObject, action: Selector) {
        popup.target = target
        popup.action = action
        popup.controlSize = .regular
        popup.bezelStyle = .rounded
        popup.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    private func configureIconButton(
        _ button: NSButton,
        systemName: String,
        toolTip: String,
        target: AnyObject,
        action: Selector
    ) {
        button.target = target
        button.action = action
        button.image = TCPViewerUI.image(systemName)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .recessed
        button.controlSize = .regular
        button.toolTip = toolTip
    }
}

private struct PacketStructuredFilterActionProvider {
    let toggleEnabled: Selector
    let changeQuery: Selector
    let changeCondition: Selector
    let changeText: Selector
    let remove: Selector
    let add: Selector
}

final class PacketStructuredFilterViewController: NSViewController {
    private enum Metrics {
        static let horizontalInset: CGFloat = 14
        static let verticalInset: CGFloat = 8
        static let footerLeadingOffset: CGFloat = 34
        static let operatorWidth: CGFloat = 150
    }

    weak var delegate: PacketStructuredFilterViewControllerDelegate?

    private let rootStack = NSStackView()
    private let rowStack = NSStackView()
    private let footerStack = NSStackView()
    private let operatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bottomSeparator = TCPViewerUI.separator()
    private var rowViews: [PacketStructuredFilterRowView] = []
    private var group = PacketStructuredFilterGroup.default

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupLayout()
        rebuildRows()
    }

    func render(group: PacketStructuredFilterGroup) {
        let normalizedGroup = PacketStructuredFilterGroup(filters: group.filters, operator: group.operator)
        guard normalizedGroup != self.group else {
            updateAddButtonStates()
            return
        }

        self.group = normalizedGroup
        rebuildRows()
    }

    private func setupLayout() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 4
        rootStack.edgeInsets = NSEdgeInsets(
            top: Metrics.verticalInset,
            left: Metrics.horizontalInset,
            bottom: Metrics.verticalInset,
            right: Metrics.horizontalInset
        )
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 4
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 18
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        configureOperatorPopup()
        rebuildFooter()

        view.addSubview(rootStack)
        view.addSubview(bottomSeparator)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            rowStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -(Metrics.horizontalInset * 2)),
            footerStack.widthAnchor.constraint(lessThanOrEqualTo: rootStack.widthAnchor, constant: -(Metrics.horizontalInset * 2)),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        rootStack.addArrangedSubview(rowStack)
        rootStack.addArrangedSubview(footerStack)
    }

    private func configureOperatorPopup() {
        operatorPopup.target = self
        operatorPopup.action = #selector(changeOperator(_:))
        operatorPopup.controlSize = .regular
        operatorPopup.bezelStyle = .rounded
        operatorPopup.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        PacketStructuredFilterGroupOperator.allCases.forEach { filterOperator in
            let item = operatorPopup.menu?.addItem(withTitle: filterOperator.title, action: nil, keyEquivalent: "")
            item?.representedObject = filterOperator.rawValue
        }
        operatorPopup.widthAnchor.constraint(equalToConstant: Metrics.operatorWidth).isActive = true
    }

    private func rebuildFooter() {
        footerStack.arrangedSubviews.forEach { arrangedView in
            footerStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Metrics.footerLeadingOffset).isActive = true
        footerStack.addArrangedSubview(spacer)
        footerStack.addArrangedSubview(operatorPopup)

        ["Show: ⌘F", "New: ⌘N", "Remove: ⇧⌘N", "Up: ⌘↑", "Down: ⌘↓", "On/Off: ⌘B", "Hide: ESC"].forEach { title in
            let label = TCPViewerUI.label(
                title,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                color: .secondaryLabelColor
            )
            footerStack.addArrangedSubview(label)
        }
    }

    private func rebuildRows() {
        rowStack.arrangedSubviews.forEach { arrangedView in
            rowStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        rowViews.removeAll(keepingCapacity: true)

        let actionProvider = PacketStructuredFilterActionProvider(
            toggleEnabled: #selector(toggleEnabled(_:)),
            changeQuery: #selector(changeQuery(_:)),
            changeCondition: #selector(changeCondition(_:)),
            changeText: #selector(changeText(_:)),
            remove: #selector(removeFilter(_:)),
            add: #selector(addFilter(_:))
        )

        for filter in group.filters {
            let rowView = PacketStructuredFilterRowView(filter: filter, target: self, actionProvider: actionProvider)
            rowView.translatesAutoresizingMaskIntoConstraints = false
            rowViews.append(rowView)
            rowStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

        operatorPopup.selectItem(withTitle: group.operator.title)
        updateAddButtonStates()
    }

    private func updateAddButtonStates() {
        rowViews.forEach { rowView in
            rowView.addButton.isEnabled = group.canAddFilter
        }
    }

    private func rowView(for sender: Any?) -> PacketStructuredFilterRowView? {
        var view = sender as? NSView
        while let currentView = view {
            if let rowView = currentView as? PacketStructuredFilterRowView {
                return rowView
            }
            view = currentView.superview
        }
        return nil
    }

    private func filter(withID filterID: PacketStructuredFilter.ID) -> PacketStructuredFilter? {
        group.filters.first { $0.id == filterID }
    }

    private func apply(_ nextGroup: PacketStructuredFilterGroup, rebuildsRows: Bool = false) {
        group = PacketStructuredFilterGroup(filters: nextGroup.filters, operator: nextGroup.operator)
        if rebuildsRows {
            rebuildRows()
        } else {
            updateAddButtonStates()
        }
        delegate?.packetStructuredFilterViewController(self, didUpdate: group)
    }

    @objc private func toggleEnabled(_ sender: Any?) {
        guard let rowView = rowView(for: sender),
              var filter = filter(withID: rowView.filterID) else {
            return
        }

        filter.isEnabled = rowView.enabledCheckbox.state == .on
        apply(group.replacing(filter))
    }

    @objc private func changeQuery(_ sender: Any?) {
        guard let rowView = rowView(for: sender),
              var filter = filter(withID: rowView.filterID),
              let rawValue = rowView.queryPopup.selectedItem?.representedObject as? String,
              let query = PacketStructuredFilterQuery(rawValue: rawValue) else {
            return
        }

        filter.query = query
        apply(group.replacing(filter))
    }

    @objc private func changeCondition(_ sender: Any?) {
        guard let rowView = rowView(for: sender),
              var filter = filter(withID: rowView.filterID),
              let rawValue = rowView.conditionPopup.selectedItem?.representedObject as? String,
              let condition = PacketStructuredFilterCondition(rawValue: rawValue) else {
            return
        }

        filter.condition = condition
        apply(group.replacing(filter))
    }

    @objc private func changeText(_ sender: Any?) {
        guard let rowView = rowView(for: sender),
              var filter = filter(withID: rowView.filterID) else {
            return
        }

        filter.text = rowView.textField.stringValue
        apply(group.replacing(filter))
    }

    @objc private func removeFilter(_ sender: Any?) {
        guard let rowView = rowView(for: sender) else {
            return
        }

        apply(group.removingOrClearing(filterID: rowView.filterID), rebuildsRows: true)
    }

    @objc private func addFilter(_ sender: Any?) {
        guard group.canAddFilter else {
            return
        }

        apply(group.addingCopy(of: rowView(for: sender)?.filterID), rebuildsRows: true)
    }

    @objc private func changeOperator(_ sender: Any?) {
        guard let rawValue = operatorPopup.selectedItem?.representedObject as? String,
              let nextOperator = PacketStructuredFilterGroupOperator(rawValue: rawValue) else {
            return
        }

        apply(group.updatingOperator(nextOperator))
    }
}

extension PacketStructuredFilterViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        changeText(notification.object)
    }
}
