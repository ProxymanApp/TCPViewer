import AppKit
import PcapPlusPlusCore

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?)
    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String)
    func sidebarViewController(_ controller: SidebarViewController, didRequestDelete action: PacketSourceListDeletionAction)
    func sidebarViewController(_ controller: SidebarViewController, didRequestExport selection: PacketSourceListSelection, format: CaptureFileFormat)
}

enum SidebarOutlineReloadTiming: Equatable {
    case none
    case immediate
    case deferred
}

struct SidebarOutlineReloadState: Equatable {
    let sourceListSnapshot: PacketSourceListSnapshot
    let filterText: String
    let selectedSelection: PacketSourceListSelection
    let packetMutation: PacketIngestMutation

    init(
        sourceListSnapshot: PacketSourceListSnapshot,
        filterText: String,
        selectedSelection: PacketSourceListSelection,
        packetMutation: PacketIngestMutation
    ) {
        self.sourceListSnapshot = sourceListSnapshot
        self.filterText = filterText
        self.selectedSelection = selectedSelection
        self.packetMutation = packetMutation
    }

    init(snapshot: NetworkInspectorSnapshot) {
        self.init(
            sourceListSnapshot: snapshot.sourceListSnapshot,
            filterText: snapshot.sourceListFilterText,
            selectedSelection: snapshot.selectedSourceListSelection,
            packetMutation: snapshot.base.packetIngestState.lastMutation
        )
    }
}

enum SidebarOutlineReloadPolicy {
    static func timing(
        previous: SidebarOutlineReloadState?,
        next: SidebarOutlineReloadState
    ) -> SidebarOutlineReloadTiming {
        guard let previous else {
            return .immediate
        }

        guard previous.sourceListSnapshot != next.sourceListSnapshot ||
                previous.filterText != next.filterText ||
                previous.selectedSelection != next.selectedSelection else {
            return .none
        }

        if previous.filterText != next.filterText ||
            previous.selectedSelection != next.selectedSelection {
            return .immediate
        }

        return next.packetMutation.isBatchableSidebarMutation ? .deferred : .immediate
    }
}

private extension PacketIngestMutation {
    var isBatchableSidebarMutation: Bool {
        switch self {
        case .append, .appendWithMetadataUpdates, .metadataUpdate:
            return true
        case .none, .reset, .replace:
            return false
        }
    }
}

private extension PacketSourceListItem {
    var reservesDisclosureSpace: Bool {
        kind == .folder || !children.isEmpty
    }
}

private protocol SidebarOutlineKeyboardActionHandling: AnyObject {
    func sidebarOutlineViewDidRequestDeleteFromKeyboard(_ outlineView: SidebarOutlineView)
}

private final class SidebarOutlineView: NSOutlineView {
    weak var keyboardActionHandler: SidebarOutlineKeyboardActionHandling?

    @objc func delete(_ sender: Any?) {
        keyboardActionHandler?.sidebarOutlineViewDidRequestDeleteFromKeyboard(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
        if flags.contains(.command), isDeleteKey {
            delete(nil)
            return
        }

        super.keyDown(with: event)
    }
}

private final class SidebarOutlineItem: NSObject {
    let sourceItem: PacketSourceListItem
    let children: [SidebarOutlineItem]

    init(sourceItem: PacketSourceListItem) {
        self.sourceItem = sourceItem
        self.children = sourceItem.children.map(SidebarOutlineItem.init)
    }
}

private final class SidebarViewModel {
    private(set) var roots: [SidebarOutlineItem] = []
    private(set) var selectedSelection: PacketSourceListSelection = .allPackets
    private(set) var filterText = ""

    private var itemsByID: [String: SidebarOutlineItem] = [:]
    private var itemIDBySelection: [PacketSourceListSelection: String] = [:]

    // Convert source-list render data into outline-view objects with no parent references.
    func render(state: SidebarOutlineReloadState) {
        selectedSelection = state.selectedSelection
        filterText = state.filterText
        let filteredSnapshot = state.sourceListSnapshot.filtered(matching: filterText)
        roots = filteredSnapshot.roots.map(SidebarOutlineItem.init)
        rebuildLookupTables()
    }

    func item(for selection: PacketSourceListSelection) -> SidebarOutlineItem? {
        guard let itemID = itemIDBySelection[selection] else {
            return nil
        }

        return itemsByID[itemID]
    }

    func item(withID itemID: String) -> SidebarOutlineItem? {
        itemsByID[itemID]
    }

    func allItems() -> [SidebarOutlineItem] {
        roots.flatMap(flatten)
    }

    private func rebuildLookupTables() {
        itemsByID = [:]
        itemIDBySelection = [:]

        for item in roots {
            register(item)
        }
    }

    private func register(_ item: SidebarOutlineItem) {
        itemsByID[item.sourceItem.id] = item
        if let selection = item.sourceItem.selection {
            itemIDBySelection[selection] = item.sourceItem.id
        }

        for child in item.children {
            register(child)
        }
    }

    private func flatten(_ item: SidebarOutlineItem) -> [SidebarOutlineItem] {
        [item] + item.children.flatMap(flatten)
    }
}

final class SidebarViewController: NSViewController {
    private static let batchedReloadInterval: TimeInterval = 0.5

    weak var delegate: SidebarViewControllerDelegate?

    private let viewModel = SidebarViewModel()
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let effectView = NSVisualEffectView()
    private let iconCache = SidebarIconCache()

    private var expandedItemIDs = PacketSourceListTreeBuilder.defaultExpandedItemIDs
    private var hasRenderedOutline = false
    private var appliedReloadState: SidebarOutlineReloadState?
    private var pendingReloadState: SidebarOutlineReloadState?
    private var pendingReloadWorkItem: DispatchWorkItem?
    private var isSyncingSelection = false
    private var isSyncingFilter = false

    deinit {
        pendingReloadWorkItem?.cancel()
    }

    override func loadView() {
        view = effectView
        setupEffectView()
        setupOutlineView()
        setupSearchField()
        setupLayout()
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        let nextReloadState = SidebarOutlineReloadState(snapshot: snapshot)
        switch SidebarOutlineReloadPolicy.timing(previous: appliedReloadState, next: nextReloadState) {
        case .none:
            return
        case .immediate:
            cancelPendingReload()
            apply(state: nextReloadState)
        case .deferred:
            scheduleBatchedReload(state: nextReloadState)
        }
    }

    private func apply(state: SidebarOutlineReloadState) {
        if hasRenderedOutline, viewModel.filterText.isEmpty {
            captureExpandedItemIDs()
        }

        viewModel.render(state: state)
        syncSearchField(state.filterText)
        outlineView.reloadData()
        restoreExpandedItems(expandAll: !viewModel.filterText.isEmpty)
        syncSelection()
        appliedReloadState = state
        hasRenderedOutline = true
    }

    private func scheduleBatchedReload(state: SidebarOutlineReloadState) {
        pendingReloadState = state
        guard pendingReloadWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            pendingReloadWorkItem = nil
            guard let state = pendingReloadState else {
                return
            }

            pendingReloadState = nil
            apply(state: state)
        }
        pendingReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchedReloadInterval, execute: workItem)
    }

    private func cancelPendingReload() {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        pendingReloadState = nil
    }

    private func setupEffectView() {
        effectView.blendingMode = .behindWindow
        effectView.material = .sidebar
        effectView.state = .active
    }

    private func setupOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sourceList"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.style = .sourceList
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 18
        outlineView.indentationMarkerFollowsCell = false
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        outlineView.keyboardActionHandler = self

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupSearchField() {
        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupLayout() {
        effectView.addSubview(scrollView)
        effectView.addSubview(searchField)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: effectView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: searchField.topAnchor, constant: -6),

            searchField.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            searchField.bottomAnchor.constraint(equalTo: effectView.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func captureExpandedItemIDs() {
        expandedItemIDs = Set(viewModel.allItems().compactMap { item in
            outlineView.isItemExpanded(item) ? item.sourceItem.id : nil
        })
    }

    private func restoreExpandedItems(expandAll: Bool) {
        let items = viewModel.allItems()
        let itemsToExpand = expandAll ? items : items.filter { expandedItemIDs.contains($0.sourceItem.id) }

        for item in itemsToExpand where item.sourceItem.reservesDisclosureSpace {
            outlineView.expandItem(item)
        }
    }

    private func syncSelection() {
        isSyncingSelection = true
        defer {
            isSyncingSelection = false
        }

        guard viewModel.selectedSelection != .allPackets,
              let selectedItem = viewModel.item(for: viewModel.selectedSelection) else {
            outlineView.deselectAll(nil)
            return
        }

        let row = outlineView.row(forItem: selectedItem)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    private func syncSearchField(_ filterText: String) {
        guard searchField.stringValue != filterText else {
            return
        }

        isSyncingFilter = true
        searchField.stringValue = filterText
        isSyncingFilter = false
    }

    private func sourceItem(for item: Any?) -> PacketSourceListItem? {
        (item as? SidebarOutlineItem)?.sourceItem
    }

    private func outlineItem(for item: Any?) -> SidebarOutlineItem? {
        item as? SidebarOutlineItem
    }

    private func selectedSourceItem() -> PacketSourceListItem? {
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0 else {
            return nil
        }

        return sourceItem(for: outlineView.item(atRow: selectedRow))
    }

    private func selectedDeletionAction() -> PacketSourceListDeletionAction {
        PacketSourceListDeletionPolicy.action(for: selectedSourceItem())
    }

    private func selectedExportSelection() -> PacketSourceListSelection? {
        PacketSourceListExportPolicy.selection(for: selectedSourceItem())
    }

    private func updateSelectionFromCurrentMenuEvent() {
        guard let event = view.window?.currentEvent,
              event.type == .rightMouseDown || event.type == .leftMouseDown || event.type == .otherMouseDown else {
            return
        }

        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        guard row >= 0,
              let item = outlineView.item(atRow: row),
              sourceItem(for: item)?.selection != nil else {
            outlineView.deselectAll(nil)
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func deleteSelectedSourceListItem(_ sender: Any?) {
        let action = selectedDeletionAction()
        guard action.isEnabled else {
            return
        }

        delegate?.sidebarViewController(self, didRequestDelete: action)
    }

    @objc private func exportSelectedSourceListItemAsPcap(_ sender: Any?) {
        exportSelectedSourceListItem(format: .pcap)
    }

    @objc private func exportSelectedSourceListItemAsPcapng(_ sender: Any?) {
        exportSelectedSourceListItem(format: .pcapng)
    }

    private func exportSelectedSourceListItem(format: CaptureFileFormat) {
        guard let selection = selectedExportSelection() else {
            return
        }

        delegate?.sidebarViewController(self, didRequestExport: selection, format: format)
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        guard !isSyncingFilter else {
            return
        }

        delegate?.sidebarViewController(self, didUpdateFilterText: sender.stringValue)
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        outlineItem(for: item)?.children.count ?? viewModel.roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = outlineItem(for: item)?.children ?? viewModel.roots
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        outlineItem(for: item)?.sourceItem.reservesDisclosureSpace == true
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        sourceItem(for: item)?.isGroup == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        sourceItem(for: item)?.selection != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sourceItem = sourceItem(for: item) else {
            return nil
        }

        return cell(for: sourceItem, in: outlineView)
    }

    private func cell(for item: PacketSourceListItem, in outlineView: NSOutlineView) -> NSTableCellView {
        switch item.kind {
        case .group:
            let cell = reusedCell(
                identifier: SidebarGroupCell.reuseIdentifier,
                in: outlineView,
                make: { SidebarGroupCell(frame: .zero) }
            )
            cell.render(item: item)
            return cell
        case .favorite:
            let cell = reusedCell(
                identifier: SidebarFavoriteCell.reuseIdentifier,
                in: outlineView,
                make: { SidebarFavoriteCell(frame: .zero) }
            )
            cell.render(item: item, iconCache: iconCache)
            return cell
        case .folder:
            let cell = reusedCell(
                identifier: SidebarFolderCell.reuseIdentifier,
                in: outlineView,
                make: { SidebarFolderCell(frame: .zero) }
            )
            cell.render(item: item, iconCache: iconCache)
            return cell
        case .app:
            let cell = reusedCell(
                identifier: SidebarAppCell.reuseIdentifier,
                in: outlineView,
                make: { SidebarAppCell(frame: .zero) }
            )
            cell.render(item: item, iconCache: iconCache)
            return cell
        case .domain:
            let cell = reusedCell(
                identifier: SidebarDomainCell.reuseIdentifier,
                in: outlineView,
                make: { SidebarDomainCell(frame: .zero) }
            )
            cell.render(item: item, iconCache: iconCache)
            return cell
        case .pin:
            let cell = reusedCell(
                identifier: SidebarPinCell.reuseIdentifier,
                in: outlineView,
                make: { SidebarPinCell(frame: .zero) }
            )
            cell.render(item: item, iconCache: iconCache)
            return cell
        }
    }

    private func reusedCell<Cell: NSTableCellView>(
        identifier: NSUserInterfaceItemIdentifier,
        in outlineView: NSOutlineView,
        make: () -> Cell
    ) -> Cell {
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? Cell ?? make()
        cell.identifier = identifier
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else {
            return
        }

        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let item = outlineView.item(atRow: selectedRow) as? SidebarOutlineItem else {
            delegate?.sidebarViewController(self, didSelect: nil)
            return
        }

        delegate?.sidebarViewController(self, didSelect: item.sourceItem.selection)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarOutlineItem else {
            return
        }

        expandedItemIDs.insert(item.sourceItem.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarOutlineItem else {
            return
        }

        expandedItemIDs.remove(item.sourceItem.id)
    }
}

extension SidebarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard !isSyncingFilter else {
            return
        }

        delegate?.sidebarViewController(self, didUpdateFilterText: searchField.stringValue)
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSelectionFromCurrentMenuEvent()
        let action = selectedDeletionAction()
        let exportSelection = selectedExportSelection()

        menu.removeAllItems()
        guard action.isEnabled || exportSelection != nil else {
            return
        }

        if exportSelection != nil {
            let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
            let exportSubmenu = NSMenu(title: "Export")
            let exportPcapItem = NSMenuItem(title: "as pcap...", action: #selector(exportSelectedSourceListItemAsPcap(_:)), keyEquivalent: "")
            exportPcapItem.target = self
            exportSubmenu.addItem(exportPcapItem)

            let exportPcapngItem = NSMenuItem(title: "as pcapng...", action: #selector(exportSelectedSourceListItemAsPcapng(_:)), keyEquivalent: "")
            exportPcapngItem.target = self
            exportSubmenu.addItem(exportPcapngItem)

            exportItem.submenu = exportSubmenu
            exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
            menu.addItem(exportItem)
        }

        if action.isEnabled {
            if exportSelection != nil {
                menu.addItem(.separator())
            }

            let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteSelectedSourceListItem(_:)), keyEquivalent: "\u{8}")
            deleteItem.keyEquivalentModifierMask = [.command]
            deleteItem.target = self
            deleteItem.isEnabled = true
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            menu.addItem(deleteItem)
        }
    }
}

extension SidebarViewController: SidebarOutlineKeyboardActionHandling {
    fileprivate func sidebarOutlineViewDidRequestDeleteFromKeyboard(_ outlineView: SidebarOutlineView) {
        deleteSelectedSourceListItem(nil)
    }
}

private final class SidebarGroupCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarGroupCell")

    private let titleLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.systemFontSize - 2, weight: .semibold),
        color: .secondaryLabelColor
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(item: PacketSourceListItem) {
        titleLabel.stringValue = item.title
    }

    private func setupLayout() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private class SidebarIconCountCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .labelColor
    )
    private let countLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        color: .secondaryLabelColor
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(item: PacketSourceListItem, iconCache: SidebarIconCache) {
        iconView.image = iconCache.image(for: item)
        titleLabel.stringValue = item.title
        countLabel.stringValue = item.countText ?? ""
        countLabel.isHidden = item.countText == nil
    }

    private func setupLayout() {
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }
}

private final class SidebarFavoriteCell: SidebarIconCountCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarFavoriteCell")
}

private final class SidebarFolderCell: SidebarIconCountCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarFolderCell")
}

private final class SidebarAppCell: SidebarIconCountCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarAppCell")
}

private final class SidebarDomainCell: SidebarIconCountCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarDomainCell")
}

private final class SidebarPinCell: SidebarIconCountCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarPinCell")
}

private final class SidebarIconCache {
    private var imagesByKey: [String: NSImage] = [:]

    // Return one small image per source-list item so row reuse stays cheap.
    func image(for item: PacketSourceListItem) -> NSImage? {
        if let iconFilePath = item.iconFilePath {
            let key = "file:\(iconFilePath)"
            if let cachedImage = imagesByKey[key] {
                return cachedImage
            }

            let image = NSWorkspace.shared.icon(forFile: iconFilePath)
            image.size = NSSize(width: 16, height: 16)
            imagesByKey[key] = image
            return image
        }

        guard let systemImageName = item.systemImageName else {
            return nil
        }

        let key = "system:\(systemImageName)"
        if let cachedImage = imagesByKey[key] {
            return cachedImage
        }

        let image = TCPViewerUI.image(systemImageName)
        image?.size = NSSize(width: 16, height: 16)
        imagesByKey[key] = image
        return image
    }
}
