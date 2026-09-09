//
//  TCPViewerWorkspaceTabBar.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import Cocoa

final class TCPViewerWorkspaceTabBar: NSView {
    struct Item: Equatable {
        let id: UUID
        let title: String
        let isSnapshot: Bool
    }

    fileprivate static let pasteboardType = NSPasteboard.PasteboardType("com.proxyman.tcpviewer.workspace-tab")
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onCloseOthers: ((UUID) -> Void)?
    var onCloseToRight: ((UUID) -> Void)?
    var onMove: ((UUID, Int) -> Void)?
    var onAdd: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let scrollView = NSScrollView()
    private let rowView = NSView()
    private let addButton = NSButton()
    private let overflowButton = NSButton()
    private let insertionMarker = NSView()
    private var overflowButtonWidth: NSLayoutConstraint!
    private var items: [Item] = []
    private var tabViews: [TCPViewerWorkspaceTabItem] = []
    private var selectedID: UUID?
    private var canGoBack = false
    private var canGoForward = false
    private let minimumTabWidth: CGFloat = 140
    private let tabHeight: CGFloat = 28
    private var tabWidth: CGFloat = 140
    private var shouldRevealSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 14
        scrollView.layer?.masksToBounds = true
        scrollView.documentView = rowView
        let backTitle = NSLocalizedString("Back", comment: "Tab selection history")
        let forwardTitle = NSLocalizedString("Forward", comment: "Tab selection history")
        configureButton(backButton, symbol: "chevron.backward", title: backTitle, action: #selector(goBack))
        configureButton(forwardButton, symbol: "chevron.forward", title: forwardTitle, action: #selector(goForward))
        let navigationSymbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        backButton.symbolConfiguration = navigationSymbol
        forwardButton.symbolConfiguration = navigationSymbol
        backButton.toolTip = String.localizedStringWithFormat(NSLocalizedString("Back (%@)", comment: "Tab history tooltip"), "⌘[")
        forwardButton.toolTip = String.localizedStringWithFormat(NSLocalizedString("Forward (%@)", comment: "Tab history tooltip"), "⌘]")
        backButton.isEnabled = false
        forwardButton.isEnabled = false
        configureButton(addButton, symbol: "plus", title: NSLocalizedString("New Tab", comment: ""), action: #selector(addTab))
        configureButton(overflowButton, symbol: "chevron.down", title: NSLocalizedString("Show All Tabs", comment: ""), action: #selector(showAllTabs))
        overflowButton.isHidden = true
        for child in [backButton, forwardButton, scrollView, overflowButton, addButton] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        overflowButtonWidth = overflowButton.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            overflowButtonWidth,
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 24),
            forwardButton.heightAnchor.constraint(equalToConstant: 24),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
            overflowButton.heightAnchor.constraint(equalToConstant: 24),
            scrollView.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            scrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: tabHeight),
            scrollView.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -4),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        insertionMarker.wantsLayer = true
        insertionMarker.layer?.cornerRadius = 1
        insertionMarker.isHidden = true
        addSubview(insertionMarker)
        registerForDraggedTypes([Self.pasteboardType])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private func configureButton(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = title
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        needsDisplay = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            insertionMarker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: scrollView.frame, xRadius: 14, yRadius: 14).fill()
    }

    // Reuse item views while selecting or renaming tabs so hover, menus, and native drag tracking stay intact.
    func update(items: [Item], selectedID: UUID?, canGoBack: Bool, canGoForward: Bool) {
        guard self.items != items || self.selectedID != selectedID ||
                self.canGoBack != canGoBack || self.canGoForward != canGoForward else { return }
        let existing = Dictionary(uniqueKeysWithValues: tabViews.map { ($0.item.id, $0) })
        self.items = items
        self.selectedID = selectedID
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        tabViews.filter { view in !items.contains { $0.id == view.item.id } }.forEach { $0.removeFromSuperview() }
        tabViews = items.enumerated().map { index, item in
            let initialFrame = NSRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: tabHeight)
            let tab = existing[item.id] ?? TCPViewerWorkspaceTabItem(item: item, frame: initialFrame)
            tab.update(item: item, selected: item.id == selectedID,
                       showsSeparator: index + 1 < items.count && items[index + 1].id != selectedID)
            tab.onSelect = { [weak self] in self?.onSelect?(item.id) }
            tab.onClose = { [weak self] in self?.onClose?(item.id) }
            tab.onCloseOthers = { [weak self] in self?.onCloseOthers?(item.id) }
            tab.onDragEnd = { [weak self] in self?.insertionMarker.isHidden = true }
            tab.contextMenu = { [weak self] in self?.contextMenu(for: item.id) }
            if tab.superview == nil { rowView.addSubview(tab) }
            return tab
        }
        shouldRevealSelection = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let widthWithoutOverflow = scrollView.contentSize.width + overflowButtonWidth.constant
        let overflow = CGFloat(items.count) * minimumTabWidth > widthWithoutOverflow
        let overflowWidth: CGFloat = overflow ? 26 : 0
        overflowButton.isHidden = !overflow
        if overflowButtonWidth.constant != overflowWidth {
            overflowButtonWidth.constant = overflowWidth
            needsLayout = true
        }
        needsDisplay = true
        let available = max(1, widthWithoutOverflow - overflowWidth)
        tabWidth = max(minimumTabWidth, available / CGFloat(max(items.count, 1)))
        rowView.frame = NSRect(x: 0, y: 0, width: max(available, CGFloat(items.count) * tabWidth), height: scrollView.contentSize.height)
        for (index, tab) in tabViews.enumerated() {
            tab.frame = NSRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: rowView.bounds.height)
        }
        if shouldRevealSelection, let tab = tabViews.first(where: { $0.item.id == selectedID }) {
            rowView.scrollToVisible(tab.frame)
            shouldRevealSelection = false
        }
    }

    private func contextMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let newTabItem = menu.addItem(withTitle: NSLocalizedString("New Tab", comment: ""), action: #selector(addTab), keyEquivalent: "")
        newTabItem.target = self
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = enabled
        }
        add(NSLocalizedString("Close Tab", comment: ""), #selector(closeTab(_:)))
        add(NSLocalizedString("Close Other Tabs", comment: ""), #selector(closeOtherTabs(_:)), enabled: items.count > 1)
        add(NSLocalizedString("Close Tabs to the Right", comment: ""), #selector(closeTabsToRight(_:)), enabled: items.last?.id != id)
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: NSLocalizedString("New Tab", comment: ""), action: #selector(addTab), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func addTab() { onAdd?() }
    @objc private func goBack() { onBack?() }
    @objc private func goForward() { onForward?() }
    @objc private func closeTab(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { onClose?(id) } }
    @objc private func closeOtherTabs(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { onCloseOthers?(id) } }
    @objc private func closeTabsToRight(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { onCloseToRight?(id) } }
    @objc private func selectFromList(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { onSelect?(id) } }

    @objc private func showAllTabs() {
        let menu = NSMenu()
        for item in items {
            let entry = menu.addItem(withTitle: item.title, action: #selector(selectFromList(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.state = item.id == selectedID ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.minY), in: overflowButton)
    }

    private func draggedID(_ sender: NSDraggingInfo) -> UUID? {
        guard let value = sender.draggingPasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: value), items.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func insertionIndex(_ sender: NSDraggingInfo) -> Int {
        let location = rowView.convert(sender.draggingLocation, from: nil)
        return min(items.count, max(0, Int((location.x + tabWidth / 2) / tabWidth)))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedID(sender) != nil else { return [] }
        // Scroll the row at its edges so a tab can be moved beyond the visible tabs.
        let pointer = scrollView.convert(sender.draggingLocation, from: nil).x
        let clip = scrollView.contentView
        let delta: CGFloat = pointer < 24 ? -12 : (pointer > scrollView.bounds.width - 24 ? 12 : 0)
        if delta != 0 {
            clip.scroll(to: NSPoint(x: min(max(0, clip.bounds.origin.x + delta), max(0, rowView.bounds.width - clip.bounds.width)), y: 0))
        }
        let x = convert(NSPoint(x: CGFloat(insertionIndex(sender)) * tabWidth, y: 0), from: rowView).x
        insertionMarker.frame = NSRect(x: min(max(scrollView.frame.minX, x - 1), scrollView.frame.maxX - 2), y: 4, width: 2, height: bounds.height - 8)
        insertionMarker.isHidden = false
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { insertionMarker.isHidden = true }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { insertionMarker.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionMarker.isHidden = true
        guard let id = draggedID(sender) else { return false }
        onMove?(id, insertionIndex(sender))
        return true
    }
}

/// Item tracking controls hover and drag behavior without retaining a workspace controller.
private final class TCPViewerWorkspaceTabItem: NSView, NSDraggingSource {
    private(set) var item: TCPViewerWorkspaceTabBar.Item
    private var isSelected = false
    private var isHovered = false
    private var showsSeparator = false
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOthers: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private let titleStack = NSStackView()
    private let iconView = NSImageView()
    private let sessionStatusButton = NSButton()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let separator = NSBox()
    private var hoverTrackingArea: NSTrackingArea?
    private var sessionInfoPopover: NSPopover?

    private static let sessionInfo = "This tab contains an imported capture. It does not receive live packets."

    init(item: TCPViewerWorkspaceTabBar.Item, frame: NSRect) {
        self.item = item
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        iconView.contentTintColor = .secondaryLabelColor
        titleStack.orientation = .horizontal
        titleStack.spacing = 4
        titleStack.addArrangedSubview(iconView)
        titleStack.addArrangedSubview(sessionStatusButton)
        titleStack.addArrangedSubview(label)
        sessionStatusButton.attributedTitle = NSAttributedString(
            string: NSLocalizedString("Not Live", comment: "Session tab status"),
            attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 10, weight: .semibold)]
        )
        sessionStatusButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: Self.sessionInfo)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        sessionStatusButton.imagePosition = .imageLeading
        sessionStatusButton.font = .systemFont(ofSize: 10, weight: .semibold)
        sessionStatusButton.bezelStyle = .inline
        sessionStatusButton.controlSize = .mini
        sessionStatusButton.contentTintColor = .systemOrange
        sessionStatusButton.target = self
        sessionStatusButton.action = #selector(showSessionInfo)
        sessionStatusButton.toolTip = Self.sessionInfo
        sessionStatusButton.setContentHuggingPriority(.required, for: .horizontal)
        sessionStatusButton.isHidden = true
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: NSLocalizedString("Close Tab", comment: ""))
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = NSLocalizedString("Close Tab. Option-click to close other tabs.", comment: "")
        separator.boxType = .separator
        for child in [titleStack, closeButton, separator] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            titleStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 30),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: NSLocalizedString("Close Tab", comment: ""), handler: { [weak self] in self?.onClose?(); return true })])
    }

    required init?(coder: NSCoder) { fatalError("Use init(item:)") }

    func update(item: TCPViewerWorkspaceTabBar.Item, selected: Bool, showsSeparator: Bool) {
        self.item = item
        isSelected = selected
        self.showsSeparator = showsSeparator
        label.stringValue = item.title
        if item.isSnapshot {
            iconView.image = NSImage(systemSymbolName: "network.slash", accessibilityDescription: Self.sessionInfo)
                ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: Self.sessionInfo)
            sessionStatusButton.isHidden = false
            toolTip = "\(item.title)\n\(Self.sessionInfo)"
            setAccessibilityHelp(Self.sessionInfo)
        } else {
            sessionInfoPopover?.close()
            sessionInfoPopover = nil
            iconView.image = NSImage(systemSymbolName: "network", accessibilityDescription: item.title)
            sessionStatusButton.isHidden = true
            toolTip = item.title
            setAccessibilityHelp(nil)
        }
        setAccessibilityLabel(item.title)
        setAccessibilityValue(NSNumber(value: selected))
        updateAppearance()
    }

    @objc private func showSessionInfo() {
        guard item.isSnapshot else { return }
        onSelect?()
        sessionInfoPopover?.close()

        let title = NSTextField(labelWithString: NSLocalizedString("Session Tab", comment: "Session tab popover title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: Self.sessionInfo)
        message.maximumNumberOfLines = 0
        let stack = NSStackView(views: [title, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 76))
        controller.preferredContentSize = controller.view.frame.size
        controller.view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.bottomAnchor, constant: -12)
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        sessionInfoPopover = popover
        popover.show(relativeTo: sessionStatusButton.bounds, of: sessionStatusButton, preferredEdge: .minY)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        if let window = window { isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        updateAppearance()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateAppearance() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let selectedFill = isDark ? NSColor.white.withAlphaComponent(0.15) : NSColor.white.withAlphaComponent(0.9)
            layer?.backgroundColor = (isSelected ? selectedFill : NSColor.labelColor.withAlphaComponent(isHovered ? 0.04 : 0)).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.15 : 0).cgColor
        }
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        closeButton.isHidden = !isHovered
        separator.isHidden = isSelected || isHovered || !showsSeparator
    }

    @objc private func closeTab() {
        if NSEvent.modifierFlags.contains(.option) { onCloseOthers?() }
        else { onClose?() }
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } else { super.otherMouseUp(with: event) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton || hit === sessionStatusButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        onSelect?()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            if abs(next.locationInWindow.x - event.locationInWindow.x) < 5 && abs(next.locationInWindow.y - event.locationInWindow.y) < 5 { continue }
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(item.id.uuidString, forType: TCPViewerWorkspaceTabBar.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboard)
            let image = NSImage(size: bounds.size)
            if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: bitmap)
                image.addRepresentation(bitmap)
            }
            draggingItem.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [draggingItem], event: next, source: self)
            return
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnd?()
    }
}
