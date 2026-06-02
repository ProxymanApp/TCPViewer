//
//  PacketStructuredFilterViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/5/26.
//

import AppKit

protocol PacketStructuredFilterViewControllerDelegate: AnyObject {
    func packetStructuredFilterViewController(_ controller: PacketStructuredFilterViewController, didUpdate group: PacketStructuredFilterGroup)
    func packetStructuredFilterViewController(
        _ controller: PacketStructuredFilterViewController,
        didRequestSaveCustomFilterNamed name: String,
        group: PacketStructuredFilterGroup
    )
    func packetStructuredFilterViewController(
        _ controller: PacketStructuredFilterViewController,
        didRequestOverrideCustomFilter filterID: PacketCustomFilter.ID,
        group: PacketStructuredFilterGroup
    )
    func packetStructuredFilterViewControllerCanAddFilter(_ controller: PacketStructuredFilterViewController) -> Bool
    func packetStructuredFilterViewControllerCanSaveCustomFilter(_ controller: PacketStructuredFilterViewController) -> Bool
    func packetStructuredFilterViewControllerDidRequestPaywall(_ controller: PacketStructuredFilterViewController)
    func packetStructuredFilterViewControllerDidRequestHide(_ controller: PacketStructuredFilterViewController)
}

private enum PacketStructuredFilterShortcutKeyCode {
    static let escape: UInt16 = 53
    static let arrowDown: UInt16 = 125
    static let arrowUp: UInt16 = 126
}

private enum PacketStructuredFilterCommandSelector {
    static let cancelOperation = NSSelectorFromString("cancelOperation:")
    static let moveToBeginningOfDocument = NSSelectorFromString("moveToBeginningOfDocument:")
    static let moveToEndOfDocument = NSSelectorFromString("moveToEndOfDocument:")
}

private enum PacketStructuredFilterTextShortcut {
    case show
    case newFilter
    case removeFilter
    case focusPrevious
    case focusNext
    case toggleEnabled
    case hide

    init?(event: NSEvent) {
        let flags = Self.normalizedFlags(for: event)

        let characters = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, characters == "f" {
            self = .show
        } else if flags == .command, characters == "n" {
            self = .newFilter
        } else if flags == [.command, .shift], characters == "n" {
            self = .removeFilter
        } else if flags == .command, event.keyCode == PacketStructuredFilterShortcutKeyCode.arrowUp {
            self = .focusPrevious
        } else if flags == .command, event.keyCode == PacketStructuredFilterShortcutKeyCode.arrowDown {
            self = .focusNext
        } else if flags == .command, characters == "b" {
            self = .toggleEnabled
        } else if flags.isEmpty, event.keyCode == PacketStructuredFilterShortcutKeyCode.escape {
            self = .hide
        } else {
            return nil
        }
    }

    init?(commandSelector: Selector, event: NSEvent?) {
        if let event, let shortcut = Self(event: event) {
            self = shortcut
            return
        }

        if commandSelector == PacketStructuredFilterCommandSelector.cancelOperation {
            self = .hide
            return
        }

        guard let event, Self.normalizedFlags(for: event) == .command else {
            return nil
        }

        if commandSelector == PacketStructuredFilterCommandSelector.moveToBeginningOfDocument {
            self = .focusPrevious
        } else if commandSelector == PacketStructuredFilterCommandSelector.moveToEndOfDocument {
            self = .focusNext
        } else {
            return nil
        }
    }

    private static func normalizedFlags(for event: NSEvent) -> NSEvent.ModifierFlags {
        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        flags.subtract([.capsLock, .numericPad, .function])
        return flags
    }
}

private protocol PacketStructuredFilterTextFieldShortcutHandling: AnyObject {
    func packetStructuredFilterTextField(_ textField: PacketStructuredFilterTextField, didReceive shortcut: PacketStructuredFilterTextShortcut) -> Bool
}

private extension PacketStructuredFilterQuery {
    var menuToolTip: String {
        switch self {
        case .anyText:
            "Search across packet number, protocol, endpoints, client, summary, layers, status, and interface."
        case .urlDomain:
            "Search URL and domain-like values such as SNI, summary text, and decoded layer details."
        case .protocol:
            "Search protocol labels, transport hints, protocol summary, and decoded layer names."
        case .source:
            "Search the source address, source port, and formatted source endpoint."
        case .destination:
            "Search the destination address, destination port, and formatted destination endpoint."
        case .sourcePort:
            "Search or compare the numeric source port."
        case .destinationPort:
            "Search or compare the numeric destination port."
        case .client:
            "Search the client app name, display name, executable path, and bundle path."
        case .pid:
            "Search or compare the client process ID."
        case .bundleIdentifier:
            "Search the client bundle identifier."
        case .streamID:
            "Search or compare the packet stream ID."
        case .direction:
            "Search the packet direction, such as inbound or outbound."
        case .tcpFlags:
            "Search decoded TCP flags."
        case .tcpPayload:
            "Search or compare the TCP payload byte length."
        case .decodeStatus:
            "Search decode status and decode failure reasons."
        case .interface:
            "Search the capture interface name and interface ID."
        case .length:
            "Search or compare the captured packet length."
        case .summary:
            "Search the packet summary column text."
        case .tags:
            "Search generated packet tags such as truncated or malformed."
        }
    }
}

private extension PacketStructuredFilterCondition {
    var menuToolTip: String {
        switch self {
        case .contains:
            "Matches when any selected field value contains the filter text."
        case .notContains:
            "Matches when no selected field value contains the filter text."
        case .hasPrefix:
            "Matches when any selected field value starts with the filter text."
        case .notHasPrefix:
            "Matches when no selected field value starts with the filter text."
        case .hasSuffix:
            "Matches when any selected field value ends with the filter text."
        case .notHasSuffix:
            "Matches when no selected field value ends with the filter text."
        case .lessThan:
            "Matches numeric fields with a value less than the filter number."
        case .greaterThanOrEqual:
            "Matches numeric fields with a value greater than or equal to the filter number."
        case .matchesRegex:
            "Matches when any selected field value matches the regular expression."
        case .notMatchesRegex:
            "Matches when no selected field value matches the regular expression."
        }
    }
}

private extension PacketStructuredFilterGroupOperator {
    var menuToolTip: String {
        switch self {
        case .and:
            "Show packets only when every enabled filter matches."
        case .or:
            "Show packets when any enabled filter matches."
        }
    }
}

// Intercept filter-local shortcuts before the main menu handles equivalents like Cmd-N.
private final class PacketStructuredFilterTextField: NSSearchField {
    weak var shortcutHandler: PacketStructuredFilterTextFieldShortcutHandling?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditing, let shortcut = PacketStructuredFilterTextShortcut(event: event),
           shortcutHandler?.packetStructuredFilterTextField(self, didReceive: shortcut) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isEditing, let shortcut = PacketStructuredFilterTextShortcut(event: event),
           shortcutHandler?.packetStructuredFilterTextField(self, didReceive: shortcut) == true {
            return
        }

        super.keyDown(with: event)
    }

    private var isEditing: Bool {
        guard let editor = currentEditor() else {
            return false
        }

        return window?.firstResponder === editor
    }
}

private final class PacketStructuredFilterRowView: NSView {
    private static let checkboxWidth: CGFloat = 20
    private static let iconButtonSize: CGFloat = 22
    private static let controlSpacing: CGFloat = 10
    private static let queryPopupWidth: CGFloat = 140
    private static let conditionPopupWidth: CGFloat = 146
    private static let rowHeight: CGFloat = 26
    static let queryPopupLeadingOffset = checkboxWidth + controlSpacing
    static let conditionPopupLeadingOffset = queryPopupLeadingOffset + queryPopupWidth + controlSpacing
    static let textFieldLeadingOffset = conditionPopupLeadingOffset + conditionPopupWidth + controlSpacing

    private static let queryMenuGroups: [[PacketStructuredFilterQuery]] = [
        [.anyText, .urlDomain, .summary, .tags],
        [.protocol, .direction, .tcpFlags, .tcpPayload, .decodeStatus],
        [.source, .destination, .sourcePort, .destinationPort],
        [.client, .pid, .bundleIdentifier],
        [.streamID, .interface, .length],
    ]

    private static let conditionMenuGroups: [[PacketStructuredFilterCondition]] = [
        [.contains, .notContains],
        [.hasPrefix, .notHasPrefix, .hasSuffix, .notHasSuffix],
        [.lessThan, .greaterThanOrEqual],
        [.matchesRegex, .notMatchesRegex],
    ]

    let filterID: PacketStructuredFilter.ID
    let enabledCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let queryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let conditionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let textField = PacketStructuredFilterTextField()
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
        enabledCheckbox.controlSize = .small
        enabledCheckbox.toolTip = "Enable filter"

        configurePopup(queryPopup, target: target, action: actionProvider.changeQuery)
        populateQueryMenu()

        configurePopup(conditionPopup, target: target, action: actionProvider.changeCondition)
        populateConditionMenu()

        textField.target = target
        textField.action = actionProvider.changeText
        textField.delegate = target as? NSSearchFieldDelegate
        textField.shortcutHandler = target as? PacketStructuredFilterTextFieldShortcutHandling
        textField.placeholderString = "Filter… (⌘F)"
        textField.controlSize = .small
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.focusRingType = .default
        textField.sendsWholeSearchString = false
        textField.cell?.lineBreakMode = .byTruncatingTail

        configureIconButton(removeButton, systemName: "minus", toolTip: "Remove filter", target: target, action: actionProvider.remove)
        configureIconButton(addButton, systemName: "plus", toolTip: "Add filter", target: target, action: actionProvider.add)

        let stack = NSStackView(views: [enabledCheckbox, queryPopup, conditionPopup, textField, removeButton, addButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.controlSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            enabledCheckbox.widthAnchor.constraint(equalToConstant: Self.checkboxWidth),
            queryPopup.widthAnchor.constraint(equalToConstant: Self.queryPopupWidth),
            conditionPopup.widthAnchor.constraint(equalToConstant: Self.conditionPopupWidth),
            removeButton.widthAnchor.constraint(equalToConstant: Self.iconButtonSize),
            removeButton.heightAnchor.constraint(equalToConstant: Self.iconButtonSize),
            addButton.widthAnchor.constraint(equalToConstant: Self.iconButtonSize),
            addButton.heightAnchor.constraint(equalToConstant: Self.iconButtonSize),
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
        popup.controlSize = .small
        popup.bezelStyle = .rounded
        popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    }

    // Build native popup menus with separators between related filter sections.
    private func populateQueryMenu() {
        queryPopup.removeAllItems()
        Self.queryMenuGroups.enumerated().forEach { index, group in
            if index > 0 {
                queryPopup.menu?.addItem(.separator())
            }
            group.forEach { query in
                let item = queryPopup.menu?.addItem(withTitle: query.title, action: nil, keyEquivalent: "")
                item?.representedObject = query.rawValue
                item?.toolTip = query.menuToolTip
            }
        }
    }

    private func populateConditionMenu() {
        conditionPopup.removeAllItems()
        Self.conditionMenuGroups.enumerated().forEach { index, group in
            if index > 0 {
                conditionPopup.menu?.addItem(.separator())
            }
            group.forEach { condition in
                let item = conditionPopup.menu?.addItem(withTitle: condition.title, action: nil, keyEquivalent: "")
                item?.representedObject = condition.rawValue
                item?.toolTip = condition.menuToolTip
            }
        }
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
        button.controlSize = .small
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
        static let horizontalInset: CGFloat = 10
        static let verticalInset: CGFloat = 6
        static let operatorWidth: CGFloat = 110
        static let footerOperatorLeadingOffset = PacketStructuredFilterRowView.queryPopupLeadingOffset
        static let footerShortcutLeadingOffset = PacketStructuredFilterRowView.textFieldLeadingOffset
        static let footerShortcutSpacing = max(0, footerShortcutLeadingOffset - footerOperatorLeadingOffset - operatorWidth)
        static let textChangeDebounceInterval: TimeInterval = 0.25
    }

    weak var delegate: PacketStructuredFilterViewControllerDelegate?

    private let rootStack = NSStackView()
    private let rowStack = NSStackView()
    private let footerStack = NSStackView()
    private let operatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let bottomSeparator = TCPViewerUI.separator()
    private var rowViews: [PacketStructuredFilterRowView] = []
    private var group = PacketStructuredFilterGroup.default
    private var isFiltering = false
    private var pendingTextChanges: [PacketStructuredFilter.ID: String] = [:]
    private var pendingTextChangeWorkItem: DispatchWorkItem?
    private var customFilterItems: [PacketCustomFilterItem] = []
    private var saveMenuGroup: PacketStructuredFilterGroup?

    deinit {
        pendingTextChangeWorkItem?.cancel()
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupLayout()
        rebuildRows()
    }

    func render(
        group: PacketStructuredFilterGroup,
        isFiltering: Bool,
        customFilterItems: [PacketCustomFilterItem]
    ) {
        let normalizedGroup = PacketStructuredFilterGroup(filters: group.filters, operator: group.operator)
        let rebuildsRows = normalizedGroup != self.group
        let rebuildsFooter = isFiltering != self.isFiltering
        self.customFilterItems = customFilterItems
        self.isFiltering = isFiltering

        guard rebuildsRows || rebuildsFooter else {
            updateAddButtonStates()
            return
        }

        self.group = normalizedGroup
        if rebuildsRows {
            rebuildRows()
        } else {
            rebuildFooter()
            updateAddButtonStates()
        }
    }

    func focusLastFilterTextField() {
        loadViewIfNeeded()
        guard let filterID = group.filters.last?.id else {
            return
        }

        focusTextField(for: filterID)
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
        configureSaveButton()
        rebuildFooter()

        view.addSubview(rootStack)
        view.addSubview(bottomSeparator)
        rootStack.addArrangedSubview(rowStack)
        rootStack.addArrangedSubview(footerStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            rowStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -(Metrics.horizontalInset * 2)),
            footerStack.widthAnchor.constraint(equalTo: rowStack.widthAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureOperatorPopup() {
        operatorPopup.target = self
        operatorPopup.action = #selector(changeOperator(_:))
        operatorPopup.controlSize = .small
        operatorPopup.bezelStyle = .rounded
        operatorPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        operatorPopup.toolTip = "Choose how enabled filters are combined."
        PacketStructuredFilterGroupOperator.allCases.forEach { filterOperator in
            let item = operatorPopup.menu?.addItem(withTitle: filterOperator.title, action: nil, keyEquivalent: "")
            item?.representedObject = filterOperator.rawValue
            item?.toolTip = filterOperator.menuToolTip
        }
        operatorPopup.widthAnchor.constraint(equalToConstant: Metrics.operatorWidth).isActive = true
    }

    // Configure the custom-filter save command independently from row add/remove buttons.
    private func configureSaveButton() {
        saveButton.target = self
        saveButton.action = #selector(showSaveCustomFilterMenu(_:))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        saveButton.toolTip = "Save the current structured filter as a custom filter."
        NSLayoutConstraint.activate([
            saveButton.heightAnchor.constraint(equalToConstant: 24),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
        ])
    }

    private func rebuildFooter() {
        footerStack.arrangedSubviews.forEach { arrangedView in
            footerStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }

        // Keep footer controls aligned with the row controls they describe.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let showsOperatorPopup = group.filters.count > 1
        let leadingOffset = showsOperatorPopup ? Metrics.footerOperatorLeadingOffset : Metrics.footerShortcutLeadingOffset
        spacer.widthAnchor.constraint(equalToConstant: leadingOffset).isActive = true
        footerStack.addArrangedSubview(spacer)
        footerStack.setCustomSpacing(0, after: spacer)

        if showsOperatorPopup {
            footerStack.addArrangedSubview(operatorPopup)
            footerStack.setCustomSpacing(Metrics.footerShortcutSpacing, after: operatorPopup)
        }

        if isFiltering {
            let filteringIndicator = makeFilteringIndicator()
            footerStack.addArrangedSubview(filteringIndicator)
            footerStack.setCustomSpacing(8, after: filteringIndicator)
        }

        ["Show: ⌘F", "New: ⌘N", "Remove: ⇧⌘N", "Up: ⌘↑", "Down: ⌘↓", "On/Off: ⌘B", "Hide: ESC"].forEach { title in
            let label = TCPViewerUI.label(
                title,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                color: .secondaryLabelColor
            )
            footerStack.addArrangedSubview(label)
        }

        // Push Save to the trailing edge while keeping shortcut hints on the same footer row.
        let trailingSpacer = NSView()
        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerStack.addArrangedSubview(trailingSpacer)
        footerStack.addArrangedSubview(saveButton)
    }

    // Build the small inline loader that sits before the shortcut hints.
    private func makeFilteringIndicator() -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.toolTip = "Filtering packets"
        indicator.startAnimation(nil)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 14),
            indicator.heightAnchor.constraint(equalToConstant: 14),
        ])
        return indicator
    }

    private func rebuildRows() {
        rowStack.arrangedSubviews.forEach { arrangedView in
            rowStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        rowViews.removeAll(keepingCapacity: true)
        rebuildFooter()

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

    private func apply(
        _ nextGroup: PacketStructuredFilterGroup,
        rebuildsRows: Bool = false,
        focusFilterID: PacketStructuredFilter.ID? = nil
    ) {
        group = PacketStructuredFilterGroup(filters: nextGroup.filters, operator: nextGroup.operator)
        if rebuildsRows {
            rebuildRows()
        } else {
            updateAddButtonStates()
        }
        delegate?.packetStructuredFilterViewController(self, didUpdate: group)

        if let focusFilterID {
            focusTextField(for: focusFilterID)
        }
    }

    // Delay expensive packet table filtering until the user pauses typing.
    private func scheduleTextChange(rowView: PacketStructuredFilterRowView) {
        pendingTextChangeWorkItem?.cancel()
        pendingTextChanges[rowView.filterID] = rowView.textField.stringValue

        let workItem = DispatchWorkItem { [weak self] in
            self?.applyPendingTextChange()
        }
        pendingTextChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.textChangeDebounceInterval, execute: workItem)
    }

    private func applyPendingTextChange() {
        let nextGroup = consumePendingTextChange()
        guard nextGroup != group else {
            return
        }

        apply(nextGroup)
    }

    private func consumePendingTextChange() -> PacketStructuredFilterGroup {
        pendingTextChangeWorkItem?.cancel()
        pendingTextChangeWorkItem = nil

        guard !pendingTextChanges.isEmpty else {
            return group
        }

        let pendingTextChanges = pendingTextChanges
        self.pendingTextChanges.removeAll()
        return pendingTextChanges.reduce(group) { nextGroup, pendingTextChange in
            guard var filter = nextGroup.filters.first(where: { $0.id == pendingTextChange.key }) else {
                return nextGroup
            }

            filter.text = pendingTextChange.value
            return nextGroup.replacing(filter)
        }
    }

    private func focusTextField(for filterID: PacketStructuredFilter.ID) {
        guard let rowView = rowViews.first(where: { $0.filterID == filterID }) else {
            return
        }

        view.window?.makeFirstResponder(rowView.textField)
    }

    private func selectTextField(for filterID: PacketStructuredFilter.ID) {
        guard let rowView = rowViews.first(where: { $0.filterID == filterID }) else {
            return
        }

        view.window?.makeFirstResponder(rowView.textField)
        rowView.textField.selectText(nil)
    }

    private func focusAdjacentTextField(from filterID: PacketStructuredFilter.ID, offset: Int) {
        guard let currentIndex = rowViews.firstIndex(where: { $0.filterID == filterID }) else {
            return
        }

        let nextIndex = min(max(currentIndex + offset, rowViews.startIndex), rowViews.index(before: rowViews.endIndex))
        view.window?.makeFirstResponder(rowViews[nextIndex].textField)
    }

    private func addFilter(copying filterID: PacketStructuredFilter.ID?) {
        let currentGroup = consumePendingTextChange()
        guard currentGroup.canAddFilter else {
            if currentGroup != group {
                apply(currentGroup)
            }
            return
        }

        guard delegate?.packetStructuredFilterViewControllerCanAddFilter(self) ?? true else {
            if currentGroup != group {
                apply(currentGroup)
            }
            delegate?.packetStructuredFilterViewControllerDidRequestPaywall(self)
            return
        }

        let nextGroup = currentGroup.addingCopy(of: filterID)
        apply(nextGroup, rebuildsRows: true, focusFilterID: nextGroup.filters.last?.id)
    }

    private func removeFilter(rowView: PacketStructuredFilterRowView, focusesReplacement: Bool) {
        let currentGroup = consumePendingTextChange()
        guard currentGroup.filters.count > 1 else {
            if currentGroup != group {
                apply(currentGroup)
            }
            return
        }

        let currentIndex = rowViews.firstIndex(where: { $0.filterID == rowView.filterID }) ?? rowViews.startIndex
        let nextGroup = currentGroup.removing(filterID: rowView.filterID)
        let focusFilterID: PacketStructuredFilter.ID?
        if focusesReplacement {
            let nextIndex = min(currentIndex, nextGroup.filters.index(before: nextGroup.filters.endIndex))
            focusFilterID = nextGroup.filters[nextIndex].id
        } else {
            focusFilterID = nil
        }

        apply(nextGroup, rebuildsRows: true, focusFilterID: focusFilterID)
    }

    private func toggleEnabled(rowView: PacketStructuredFilterRowView) {
        let currentGroup = consumePendingTextChange()
        guard var filter = currentGroup.filters.first(where: { $0.id == rowView.filterID }) else {
            return
        }

        filter.isEnabled.toggle()
        rowView.enabledCheckbox.state = filter.isEnabled ? .on : .off
        apply(currentGroup.replacing(filter), focusFilterID: filter.id)
    }

    private func hideFilterTextFieldFocus() {
        view.window?.makeFirstResponder(nil)
        delegate?.packetStructuredFilterViewControllerDidRequestHide(self)
    }

    @objc private func toggleEnabled(_ sender: Any?) {
        guard let rowView = rowView(for: sender) else {
            return
        }

        let currentGroup = consumePendingTextChange()
        guard var filter = currentGroup.filters.first(where: { $0.id == rowView.filterID }) else {
            return
        }

        filter.isEnabled = rowView.enabledCheckbox.state == .on
        apply(currentGroup.replacing(filter))
    }

    @objc private func changeQuery(_ sender: Any?) {
        guard let rowView = rowView(for: sender),
              let rawValue = rowView.queryPopup.selectedItem?.representedObject as? String,
              let query = PacketStructuredFilterQuery(rawValue: rawValue) else {
            return
        }

        let currentGroup = consumePendingTextChange()
        guard var filter = currentGroup.filters.first(where: { $0.id == rowView.filterID }) else {
            return
        }

        filter.query = query
        apply(currentGroup.replacing(filter))
    }

    @objc private func changeCondition(_ sender: Any?) {
        guard let rowView = rowView(for: sender),
              let rawValue = rowView.conditionPopup.selectedItem?.representedObject as? String,
              let condition = PacketStructuredFilterCondition(rawValue: rawValue) else {
            return
        }

        let currentGroup = consumePendingTextChange()
        guard var filter = currentGroup.filters.first(where: { $0.id == rowView.filterID }) else {
            return
        }

        filter.condition = condition
        apply(currentGroup.replacing(filter))
    }

    @objc private func changeText(_ sender: Any?) {
        guard let rowView = rowView(for: sender) else {
            return
        }

        scheduleTextChange(rowView: rowView)
    }

    @objc private func removeFilter(_ sender: Any?) {
        guard let rowView = rowView(for: sender) else {
            return
        }

        removeFilter(rowView: rowView, focusesReplacement: false)
    }

    @objc private func addFilter(_ sender: Any?) {
        addFilter(copying: rowView(for: sender)?.filterID)
    }

    @objc private func changeOperator(_ sender: Any?) {
        guard let rawValue = operatorPopup.selectedItem?.representedObject as? String,
              let nextOperator = PacketStructuredFilterGroupOperator(rawValue: rawValue) else {
            return
        }

        let currentGroup = consumePendingTextChange()
        apply(currentGroup.updatingOperator(nextOperator))
    }

    @objc private func showSaveCustomFilterMenu(_ sender: Any?) {
        let currentGroup = consumePendingTextChange()
        if currentGroup != group {
            apply(currentGroup)
        }

        guard delegate?.packetStructuredFilterViewControllerCanSaveCustomFilter(self) ?? true else {
            delegate?.packetStructuredFilterViewControllerDidRequestPaywall(self)
            return
        }

        saveMenuGroup = currentGroup
        let menu = makeSaveCustomFilterMenu()
        let button = (sender as? NSButton) ?? saveButton
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func makeSaveCustomFilterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newFilterItem = NSMenuItem(title: "New Filter...", action: #selector(saveNewCustomFilter(_:)), keyEquivalent: "")
        newFilterItem.target = self
        menu.addItem(newFilterItem)
        menu.addItem(.separator())

        let overrideItem = NSMenuItem(title: "Override", action: nil, keyEquivalent: "")
        let overrideMenu = NSMenu()
        if customFilterItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No filters", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            overrideMenu.addItem(emptyItem)
        } else {
            customFilterItems.forEach { customItem in
                let menuItem = NSMenuItem(title: customItem.title, action: #selector(overrideCustomFilter(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = customItem.id
                overrideMenu.addItem(menuItem)
            }
        }
        menu.addItem(overrideItem)
        menu.setSubmenu(overrideMenu, for: overrideItem)
        return menu
    }

    @objc private func saveNewCustomFilter(_ sender: Any?) {
        let currentGroup = saveMenuGroup ?? group
        guard let name = requestCustomFilterName() else {
            return
        }

        delegate?.packetStructuredFilterViewController(self, didRequestSaveCustomFilterNamed: name, group: currentGroup)
    }

    @objc private func overrideCustomFilter(_ sender: NSMenuItem) {
        guard let filterID = sender.representedObject as? PacketCustomFilter.ID else {
            return
        }

        delegate?.packetStructuredFilterViewController(
            self,
            didRequestOverrideCustomFilter: filterID,
            group: saveMenuGroup ?? group
        )
    }

    // Ask for a custom filter name and normalize it before saving.
    private func requestCustomFilterName() -> String? {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = "Custom filter name"

        let alert = NSAlert()
        alert.messageText = "Save Custom Filter"
        alert.informativeText = "Enter a name for this custom filter."
        alert.alertStyle = .informational
        alert.accessoryView = textField
        alert.addButton(withTitle: "Save")
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

    // Show validation feedback close to the Save action without touching persisted filters.
    private func showCustomFilterNameValidationError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Invalid Filter Name"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension PacketStructuredFilterViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        changeText(notification.object)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let textField = control as? PacketStructuredFilterTextField,
              let shortcut = PacketStructuredFilterTextShortcut(commandSelector: commandSelector, event: NSApp.currentEvent) else {
            return false
        }

        return packetStructuredFilterTextField(textField, didReceive: shortcut)
    }
}

extension PacketStructuredFilterViewController: PacketStructuredFilterTextFieldShortcutHandling {
    fileprivate func packetStructuredFilterTextField(
        _ textField: PacketStructuredFilterTextField,
        didReceive shortcut: PacketStructuredFilterTextShortcut
    ) -> Bool {
        guard let rowView = rowView(for: textField) else {
            return false
        }

        switch shortcut {
        case .show:
            selectTextField(for: rowView.filterID)
        case .newFilter:
            addFilter(copying: rowView.filterID)
        case .removeFilter:
            removeFilter(rowView: rowView, focusesReplacement: true)
        case .focusPrevious:
            focusAdjacentTextField(from: rowView.filterID, offset: -1)
        case .focusNext:
            focusAdjacentTextField(from: rowView.filterID, offset: 1)
        case .toggleEnabled:
            toggleEnabled(rowView: rowView)
        case .hide:
            hideFilterTextFieldFocus()
        }

        return true
    }
}
