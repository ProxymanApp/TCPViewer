//
//  SidebarViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import AppKit
import PcapPlusPlusCore

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?)
    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String)
    func sidebarViewController(_ controller: SidebarViewController, didRequestPin targets: [PacketSourceListPinTarget])
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

enum SidebarSelectionPolicy {
    static func navigationRow(
        selectedRowIndexes: IndexSet,
        selectedRow: Int,
        currentEventRow: Int?
    ) -> Int? {
        if let currentEventRow,
           selectedRowIndexes.contains(currentEventRow) {
            return currentEventRow
        }

        if selectedRow >= 0,
           selectedRowIndexes.contains(selectedRow) {
            return selectedRow
        }

        return selectedRowIndexes.first
    }
}

enum SidebarOutlineScrollPositionPolicy {
    static func normalized(origin: NSPoint) -> NSPoint {
        NSPoint(x: max(0, origin.x), y: max(0, origin.y))
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
    var suppressesProgrammaticScrollToSelection = false

    @objc func delete(_ sender: Any?) {
        keyboardActionHandler?.sidebarOutlineViewDidRequestDeleteFromKeyboard(self)
    }

    override func scrollRowToVisible(_ row: Int) {
        // Avoid reload-driven selection sync from pulling a scrolled sidebar back to the selected row.
        guard !suppressesProgrammaticScrollToSelection else {
            return
        }

        super.scrollRowToVisible(row)
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

private struct SidebarOutlineViewport {
    let origin: NSPoint
    let anchorItemID: String?
    let anchorOffsetY: CGFloat
}

private struct SidebarOutlineState {
    let viewport: SidebarOutlineViewport
    let selectedItemIDs: [String]
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
    private var contextMenuItemID: String?
    private var outlineReloadGeneration = 0

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

    override func viewDidLayout() {
        super.viewDidLayout()
        normalizeOutlineScrollOriginIfNeeded()
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

    func revealSelectedImportedFileIfNeeded() {
        guard viewModel.selectedSelection.isImportedFileSelection else {
            return
        }

        expandedItemIDs.insert(PacketSourceListTreeBuilder.filesGroupID)
        if let filesItem = viewModel.item(withID: PacketSourceListTreeBuilder.filesGroupID) {
            outlineView.expandItem(filesItem)
        }
        syncSelection(scrollToSelection: true)
    }

    private func apply(state: SidebarOutlineReloadState) {
        outlineReloadGeneration += 1
        let reloadGeneration = outlineReloadGeneration
        let shouldRevealSelectedImportedFile = state.selectedSelection.isImportedFileSelection &&
            appliedReloadState?.selectedSelection != state.selectedSelection
        normalizeOutlineScrollOriginIfNeeded()
        let shouldPreserveOutlineState = shouldPreserveOutlineState(for: state)
        let preservedOutlineState = shouldPreserveOutlineState ? captureOutlineState() : nil
        if hasRenderedOutline, viewModel.filterText.isEmpty {
            captureExpandedItemIDs()
        }

        isSyncingSelection = true
        viewModel.render(state: state)
        syncSearchField(state.filterText)
        if shouldRevealSelectedImportedFile {
            expandedItemIDs.insert(PacketSourceListTreeBuilder.filesGroupID)
        }
        outlineView.reloadData()
        restoreExpandedItems(expandAll: !viewModel.filterText.isEmpty)
        if let preservedOutlineState {
            restoreOutlineState(preservedOutlineState)
        } else {
            syncSelection()
        }
        appliedReloadState = state
        hasRenderedOutline = true
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.outlineReloadGeneration == reloadGeneration,
                  self.appliedReloadState == state else {
                return
            }

            if let preservedOutlineState {
                self.restoreOutlineState(preservedOutlineState)
            } else {
                self.syncSelection()
            }
            self.isSyncingSelection = false
        }
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
        // Multi-selection is only used by context-menu Pin; navigation still picks one active row.
        outlineView.allowsMultipleSelection = true
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 18
        // Keep disclosure arrows aligned with nested source-list row content.
        outlineView.indentationMarkerFollowsCell = true
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        outlineView.keyboardActionHandler = self

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupSearchField() {
        searchField.placeholderString = "Filter (⌘⇧F)"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    // Focus the persistent sidebar filter when the global View menu shortcut is used.
    func focusFilterField() {
        view.window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    private func setupLayout() {
        effectView.addSubview(scrollView)
        effectView.addSubview(searchField)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            // Keep rows below the unified titlebar while the sidebar material still fills it.
            scrollView.topAnchor.constraint(equalTo: effectView.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: searchField.topAnchor, constant: -6),

            searchField.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            searchField.bottomAnchor.constraint(equalTo: effectView.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // Clamp AppKit titlebar inset artifacts before preserving or restoring sidebar position.
    private func normalizeOutlineScrollOriginIfNeeded() {
        let clipView = scrollView.contentView
        let origin = clipView.bounds.origin
        let normalizedOrigin = SidebarOutlineScrollPositionPolicy.normalized(origin: origin)
        guard normalizedOrigin.x != origin.x || normalizedOrigin.y != origin.y else {
            return
        }

        clipView.scroll(to: normalizedOrigin)
        scrollView.reflectScrolledClipView(clipView)
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

    private func shouldPreserveOutlineState(for state: SidebarOutlineReloadState) -> Bool {
        guard hasRenderedOutline,
              let appliedReloadState else {
            return false
        }

        // Preserve the user's outline position only for source data refreshes, not filter or selection changes.
        return appliedReloadState.filterText == state.filterText &&
            appliedReloadState.selectedSelection == state.selectedSelection
    }

    private func captureOutlineState() -> SidebarOutlineState {
        SidebarOutlineState(
            viewport: captureOutlineViewport(),
            selectedItemIDs: selectedOutlineItemIDs()
        )
    }

    private func captureOutlineViewport() -> SidebarOutlineViewport {
        let visibleBounds = scrollView.contentView.bounds
        let visibleRows = outlineView.rows(in: visibleBounds)
        guard visibleRows.location != NSNotFound,
              visibleRows.length > 0,
              let item = outlineView.item(atRow: visibleRows.location) as? SidebarOutlineItem else {
            return SidebarOutlineViewport(origin: visibleBounds.origin, anchorItemID: nil, anchorOffsetY: 0)
        }

        let anchorRect = outlineView.rect(ofRow: visibleRows.location)
        return SidebarOutlineViewport(
            origin: visibleBounds.origin,
            anchorItemID: item.sourceItem.id,
            anchorOffsetY: visibleBounds.origin.y - anchorRect.minY
        )
    }

    private func selectedOutlineItemIDs() -> [String] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard row >= 0,
                  let item = outlineView.item(atRow: row) as? SidebarOutlineItem else {
                return nil
            }

            return item.sourceItem.id
        }
    }

    private func restoreOutlineState(_ state: SidebarOutlineState) {
        restoreSelectedOutlineItemIDs(state.selectedItemIDs)
        restoreOutlineViewport(state.viewport)
    }

    private func restoreSelectedOutlineItemIDs(_ itemIDs: [String]) {
        let rows = itemIDs.compactMap { itemID -> Int? in
            guard let item = viewModel.item(withID: itemID) else {
                return nil
            }

            let row = outlineView.row(forItem: item)
            return row >= 0 ? row : nil
        }

        guard !rows.isEmpty else {
            syncSelection()
            return
        }

        selectOutlineRows(IndexSet(rows))
    }

    private func restoreOutlineViewport(_ viewport: SidebarOutlineViewport) {
        guard let anchorItemID = viewport.anchorItemID,
              let anchorItem = viewModel.item(withID: anchorItemID) else {
            restoreOutlineScrollOrigin(viewport.origin)
            return
        }

        let row = outlineView.row(forItem: anchorItem)
        guard row >= 0 else {
            restoreOutlineScrollOrigin(viewport.origin)
            return
        }

        let anchorRect = outlineView.rect(ofRow: row)
        restoreOutlineScrollOrigin(NSPoint(
            x: viewport.origin.x,
            y: anchorRect.minY + viewport.anchorOffsetY
        ))
    }

    // Put the sidebar viewport back where it was, clamped to the new content height.
    @discardableResult
    private func restoreOutlineScrollOrigin(_ origin: NSPoint) -> NSPoint {
        guard let documentView = scrollView.documentView else {
            return origin
        }

        scrollView.layoutSubtreeIfNeeded()
        outlineView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let maxX = max(0, documentView.bounds.width - clipView.bounds.width)
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let clampedOrigin = NSPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        )
        clipView.scroll(to: clampedOrigin)
        scrollView.reflectScrolledClipView(clipView)
        return clampedOrigin
    }

    private func syncSelection(scrollToSelection: Bool = false) {
        guard viewModel.selectedSelection != .allPackets,
              let selectedItem = viewModel.item(for: viewModel.selectedSelection) else {
            outlineView.deselectAll(nil)
            return
        }

        let row = outlineView.row(forItem: selectedItem)
        if row >= 0 {
            selectOutlineRows(IndexSet(integer: row), scrollToSelection: scrollToSelection)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    private func selectOutlineRows(_ rows: IndexSet, scrollToSelection: Bool = false) {
        guard !scrollToSelection else {
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
            if let firstRow = rows.first {
                outlineView.scrollRowToVisible(firstRow)
            }
            return
        }

        outlineView.suppressesProgrammaticScrollToSelection = true
        defer {
            outlineView.suppressesProgrammaticScrollToSelection = false
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
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

    private func selectedSourceItems() -> [PacketSourceListItem] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard row >= 0 else {
                return nil
            }
            return sourceItem(for: outlineView.item(atRow: row))
        }
    }

    private func contextSourceItem() -> PacketSourceListItem? {
        guard let contextMenuItemID else {
            return nil
        }

        return viewModel.item(withID: contextMenuItemID)?.sourceItem
    }

    private func selectedDeletionAction() -> PacketSourceListDeletionAction {
        PacketSourceListDeletionPolicy.action(for: contextSourceItem() ?? selectedSourceItem())
    }

    private func selectedExportSelection() -> PacketSourceListSelection? {
        PacketSourceListExportPolicy.selection(for: contextSourceItem() ?? selectedSourceItem())
    }

    private func selectedFinderURL() -> URL? {
        PacketSourceListFinderPolicy.fileURL(for: contextSourceItem() ?? selectedSourceItem())
    }

    private func selectedPinTargets() -> [PacketSourceListPinTarget] {
        PacketSourceListPinPolicy.targets(for: selectedSourceItems())
    }

    private func updateSelectionFromCurrentMenuEvent() {
        contextMenuItemID = nil
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

        contextMenuItemID = sourceItem(for: item)?.id
        if outlineView.selectedRowIndexes.contains(row) {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func rowFromCurrentMouseEvent() -> Int? {
        guard let event = view.window?.currentEvent,
              event.type == .rightMouseDown || event.type == .leftMouseDown || event.type == .otherMouseDown else {
            return nil
        }

        let row = outlineView.row(at: outlineView.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    @objc private func pinSelectedSourceListItems(_ sender: Any?) {
        let targets = selectedPinTargets()
        guard !targets.isEmpty else {
            return
        }

        delegate?.sidebarViewController(self, didRequestPin: targets)
    }

    @objc private func deleteSelectedSourceListItem(_ sender: Any?) {
        let action = selectedDeletionAction()
        guard action.isEnabled else {
            return
        }

        delegate?.sidebarViewController(self, didRequestDelete: action)
    }

    @objc private func showSelectedSourceListItemInFinder(_ sender: Any?) {
        guard let url = selectedFinderURL() else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
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

        contextMenuItemID = nil
        guard let selectedRow = SidebarSelectionPolicy.navigationRow(
            selectedRowIndexes: outlineView.selectedRowIndexes,
            selectedRow: outlineView.selectedRow,
            currentEventRow: rowFromCurrentMouseEvent()
        ),
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
        let pinTargets = selectedPinTargets()
        let action = selectedDeletionAction()
        let exportSelection = selectedExportSelection()
        let finderURL = selectedFinderURL()

        menu.removeAllItems()
        guard !pinTargets.isEmpty || action.isEnabled || exportSelection != nil || finderURL != nil else {
            return
        }

        if !pinTargets.isEmpty {
            let pinItem = NSMenuItem(title: "Pin", action: #selector(pinSelectedSourceListItems(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.isEnabled = true
            pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
            menu.addItem(pinItem)
        }

        if exportSelection != nil {
            if !pinTargets.isEmpty {
                menu.addItem(.separator())
            }

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

        if finderURL != nil {
            if !pinTargets.isEmpty || exportSelection != nil {
                menu.addItem(.separator())
            }

            let finderItem = NSMenuItem(title: "Show in Finder…", action: #selector(showSelectedSourceListItemInFinder(_:)), keyEquivalent: "")
            finderItem.target = self
            finderItem.isEnabled = true
            finderItem.toolTip = "Reveal the selected app in Finder."
            finderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Show in Finder")
            menu.addItem(finderItem)
        }

        if action.isEnabled {
            if !pinTargets.isEmpty || exportSelection != nil || finderURL != nil {
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
        contextMenuItemID = nil
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
