import AppKit
import PcapPlusPlusCore

protocol FieldsTabViewControllerDelegate: AnyObject {
    func fieldsTab(_ controller: FieldsTabViewController, didSelectNodeID nodeID: String?)
    func fieldsTabRequestsReveal(_ controller: FieldsTabViewController, nodeID: String)
}

final class FieldsTabViewController: NSViewController {
    weak var delegate: FieldsTabViewControllerDelegate?

    private let searchField = NSSearchField()
    private let outlineView = FieldsOutlineTableView()
    private let scrollView = NSScrollView()
    private let footer: FieldDetailFooterView
    private let contextMenuController = FieldsContextMenuController()
    private let placeholderContainer = NSView()

    private var configuration: AppConfiguration
    private var rootItems: [FieldsOutlineItem] = []
    private var itemByID: [String: FieldsOutlineItem] = [:]
    private var rawNodes: [PacketDetailNode] = []
    private var rawBytes: Data = Data()
    private var currentFilter: String = ""
    private var currentSelectedNodeID: String?
    private var isSyncingSelection = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.footer = FieldDetailFooterView(configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = InspectorTheme.Palette.panelBackground.cgColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search fields…"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        configureOutline()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        footer.delegate = self

        placeholderContainer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(placeholderContainer)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: InspectorTheme.Spacing.outerPadding),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -InspectorTheme.Spacing.outerPadding),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            placeholderContainer.topAnchor.constraint(equalTo: scrollView.topAnchor),
            placeholderContainer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            placeholderContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            placeholderContainer.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    func applyConfiguration(_ configuration: AppConfiguration) {
        self.configuration = configuration
        outlineView.rowHeight = max(22, configuration.packetRowHeight)
        footer.applyConfiguration(configuration)
        outlineView.reloadData()
    }

    func render(state: PacketInspectorRenderState) {
        guard let inspection = state.inspection else {
            rawNodes = []
            rawBytes = Data()
            rootItems = []
            itemByID = [:]
            outlineView.reloadData()
            footer.render(node: nil, rawBytes: nil)
            renderPlaceholder(message: state.statusMessage, isLoading: state.isLoading, hasPacket: state.selectedPacketID != nil)
            return
        }

        renderPlaceholder(message: nil, isLoading: false, hasPacket: true)

        let nodesChanged = inspection.detailNodes != rawNodes
        rawBytes = inspection.rawBytes
        rawNodes = inspection.detailNodes
        contextMenuController.rootNodes = rawNodes

        if nodesChanged || currentFilter != searchField.stringValue {
            rebuildTree(filter: searchField.stringValue)
        }

        currentFilter = searchField.stringValue
        syncSelection(to: state.selectedDetailNodeID)
        currentSelectedNodeID = state.selectedDetailNodeID
        let node = state.selectedDetailNodeID.flatMap { id in itemByID[id]?.node }
        footer.render(node: node, rawBytes: rawBytes)
    }

    // MARK: - Tree

    private func rebuildTree(filter: String) {
        let (items, lookup) = FieldsOutlineTreeBuilder.build(nodes: rawNodes, filter: filter)
        rootItems = items
        itemByID = lookup
        outlineView.reloadData()
        for item in rootItems {
            outlineView.expandItem(item, expandChildren: true)
        }
    }

    private func syncSelection(to nodeID: String?) {
        guard let nodeID, let item = itemByID[nodeID] else {
            if !outlineView.selectedRowIndexes.isEmpty {
                isSyncingSelection = true
                outlineView.deselectAll(nil)
                isSyncingSelection = false
            }
            return
        }

        let row = outlineView.row(forItem: item)
        guard row >= 0, !outlineView.selectedRowIndexes.contains(row) else { return }
        isSyncingSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isSyncingSelection = false
    }

    // MARK: - Outline setup

    private func configureOutline() {
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        outlineView.rowHeight = max(22, configuration.packetRowHeight)
        outlineView.indentationPerLevel = 14
        outlineView.indentationMarkerFollowsCell = true
        outlineView.headerView = nil
        outlineView.style = .fullWidth
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = true
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.copyHandler = self
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Field"
        nameColumn.minWidth = 120
        nameColumn.width = 200
        nameColumn.resizingMask = .userResizingMask
        outlineView.addTableColumn(nameColumn)

        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = "Value"
        valueColumn.minWidth = 100
        valueColumn.width = 200
        valueColumn.resizingMask = .autoresizingMask
        outlineView.addTableColumn(valueColumn)

        outlineView.outlineTableColumn = nameColumn

        contextMenuController.delegate = self
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        rebuildTree(filter: sender.stringValue)
    }

    private func renderPlaceholder(message: String?, isLoading: Bool, hasPacket: Bool) {
        for view in placeholderContainer.subviews {
            view.removeFromSuperview()
        }
        guard let message else {
            placeholderContainer.isHidden = true
            return
        }
        placeholderContainer.isHidden = false
        let placeholder: NSView
        if isLoading {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.startAnimation(nil)
            let label = NSTextField(labelWithString: "Decoding packet…")
            label.textColor = .secondaryLabelColor
            placeholder = NSStackView(views: [progress, label], orientation: .vertical, spacing: 8)
            (placeholder as? NSStackView)?.alignment = .centerX
        } else if hasPacket {
            placeholder = TCPViewerUI.placeholder(title: "No Fields", imageName: "list.bullet.indent", message: message, placement: .top)
        } else {
            placeholder = TCPViewerUI.placeholder(title: "Select a Packet", imageName: "sidebar.trailing", message: message, placement: .top)
        }
        TCPViewerUI.pin(placeholder, to: placeholderContainer)
    }
}

// MARK: - Data source / delegate

extension FieldsTabViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let item = item as? FieldsOutlineItem {
            return item.children.count
        }
        return rootItems.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? FieldsOutlineItem {
            return item.children[index]
        }
        return rootItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? FieldsOutlineItem else { return false }
        return !item.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FieldsOutlineItem else { return nil }
        let isValue = tableColumn?.identifier.rawValue == "value"
        let identifier = isValue ? FieldRowCellView.valueReuseIdentifier : FieldRowCellView.nameReuseIdentifier
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FieldRowCellView ?? FieldRowCellView(frame: .zero)
        cell.identifier = identifier
        cell.delegate = self
        cell.render(
            item: item,
            isValueColumn: isValue,
            searchHighlight: currentFilter.isEmpty ? nil : currentFilter,
            configuration: configuration,
            showInfoButton: !isValue && FieldExplanations.hasExplanation(for: item.node.id)
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = outlineView.selectedRowIndexes.first
        let item = row.flatMap { outlineView.item(atRow: $0) as? FieldsOutlineItem }
        delegate?.fieldsTab(self, didSelectNodeID: item?.node.id)
    }
}

// MARK: - Copy / context menu / footer / info popover

extension FieldsTabViewController: FieldsOutlineCopyHandling {
    func copySelectedRows() {
        let rows = outlineView.selectedRowIndexes.compactMap { row -> PacketDetailCopyRow? in
            guard let item = outlineView.item(atRow: row) as? FieldsOutlineItem else { return nil }
            return PacketDetailCopyRow(node: item.node, depth: outlineView.level(forRow: row))
        }
        copy(text: PacketDetailCopyFormatter.text(for: rows))
    }

    func copySelectedTree() {
        guard let row = outlineView.selectedRowIndexes.first,
              let item = outlineView.item(atRow: row) as? FieldsOutlineItem else { return }
        var rows: [PacketDetailCopyRow] = []
        flatten(item.node, depth: 0, into: &rows)
        copy(text: PacketDetailCopyFormatter.text(for: rows))
    }

    private func flatten(_ node: PacketDetailNode, depth: Int, into rows: inout [PacketDetailCopyRow]) {
        rows.append(PacketDetailCopyRow(node: node, depth: depth))
        for child in node.children {
            flatten(child, depth: depth + 1, into: &rows)
        }
    }

    private func copy(text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension FieldsTabViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let event = NSApp.currentEvent
        let location = event.flatMap { outlineView.convert($0.locationInWindow, from: nil) } ?? .zero
        let row = event != nil ? outlineView.row(at: location) : -1
        let node: PacketDetailNode? = {
            guard row >= 0, let item = outlineView.item(atRow: row) as? FieldsOutlineItem else { return nil }
            // Make sure right-click also selects the row so subsequent actions act on it.
            if !outlineView.selectedRowIndexes.contains(row) {
                isSyncingSelection = true
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isSyncingSelection = false
                delegate?.fieldsTab(self, didSelectNodeID: item.node.id)
            }
            return item.node
        }()

        let newMenu = contextMenuController.makeMenu(for: node)
        menu.removeAllItems()
        for item in newMenu.items {
            newMenu.removeItem(item)
            menu.addItem(item)
        }
    }
}

extension FieldsTabViewController: FieldsContextMenuControllerDelegate {
    func fieldsContextMenuRequestsRevealInRaw(forNodeID nodeID: String) {
        delegate?.fieldsTabRequestsReveal(self, nodeID: nodeID)
    }
}

extension FieldsTabViewController: FieldDetailFooterViewDelegate {
    func fieldDetailFooterDidRequestRevealInRaw(_ view: FieldDetailFooterView) {
        guard let id = currentSelectedNodeID else { return }
        delegate?.fieldsTabRequestsReveal(self, nodeID: id)
    }
}

extension FieldsTabViewController: FieldRowCellViewDelegate {
    func fieldRow(_ cell: FieldRowCellView, didTapInfoForNodeID nodeID: String) {
        guard let text = FieldExplanations.explanation(for: nodeID) else { return }
        FieldInfoPopoverController.present(text: text, relativeTo: cell.infoButtonAnchorView())
    }
}
