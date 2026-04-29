import AppKit
import PcapPlusPlusCore

protocol PacketInspectorViewControllerDelegate: AnyObject {
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?)
}

enum PacketInspectorTreeItemKind: Equatable {
    case layer
    case field
    case warning
    case message
}

final class PacketInspectorTreeItem: NSObject {
    let id: String
    let nodeID: String?
    let name: String
    let value: String?
    let kind: PacketInspectorTreeItemKind
    let byteRange: PacketByteRange?
    let children: [PacketInspectorTreeItem]

    init(
        id: String,
        nodeID: String? = nil,
        name: String,
        value: String? = nil,
        kind: PacketInspectorTreeItemKind,
        byteRange: PacketByteRange? = nil,
        children: [PacketInspectorTreeItem] = []
    ) {
        self.id = id
        self.nodeID = nodeID
        self.name = name
        self.value = value
        self.kind = kind
        self.byteRange = byteRange
        self.children = children
    }

    var displayText: String {
        guard let value, !value.isEmpty else {
            return name
        }

        return "\(name): \(value)"
    }
}

final class PacketInspectorTreeViewModel {
    private(set) var rootItems: [PacketInspectorTreeItem] = []
    private(set) var selectedNodeID: String?
    private var itemByNodeID: [String: PacketInspectorTreeItem] = [:]
    private var renderedInspectionState: PacketInspectionState?

    @discardableResult
    func render(snapshot: NetworkInspectorSnapshot) -> Bool {
        let inspectionState = snapshot.base.inspectionState
        guard inspectionState != renderedInspectionState else {
            return false
        }

        renderedInspectionState = inspectionState
        itemByNodeID = [:]
        rootItems = makeRootItems(from: inspectionState)

        if let selectedDetailNodeID = inspectionState.selectedDetailNodeID,
           itemByNodeID[selectedDetailNodeID] != nil {
            selectedNodeID = selectedDetailNodeID
        } else {
            selectedNodeID = nil
        }

        return true
    }

    func item(withNodeID nodeID: String?) -> PacketInspectorTreeItem? {
        guard let nodeID else {
            return nil
        }

        return itemByNodeID[nodeID]
    }

    private func makeRootItems(from inspectionState: PacketInspectionState) -> [PacketInspectorTreeItem] {
        if inspectionState.isLoading {
            return [messageItem(id: "loading", message: inspectionState.statusMessage)]
        }

        guard let inspection = inspectionState.inspection else {
            let message = inspectionState.selectedPacketID == nil
                ? "Select a packet to inspect its decode tree."
                : inspectionState.statusMessage
            return [messageItem(id: "empty", message: message)]
        }

        guard !inspection.detailNodes.isEmpty else {
            return [messageItem(id: "empty-details", message: "No packet details are available.")]
        }

        return inspection.detailNodes.map { makeItem(from: $0, parentPath: "") }
    }

    private func messageItem(id: String, message: String) -> PacketInspectorTreeItem {
        PacketInspectorTreeItem(id: "__\(id)", name: message, kind: .message)
    }

    private func makeItem(from node: PacketDetailNode, parentPath: String) -> PacketInspectorTreeItem {
        let path = parentPath.isEmpty ? node.id : "\(parentPath).\(node.id)"
        let children = node.children.map { makeItem(from: $0, parentPath: path) }
        let treeItem = PacketInspectorTreeItem(
            id: path,
            nodeID: node.id,
            name: node.name,
            value: node.value,
            kind: itemKind(from: node.kind),
            byteRange: node.byteRange,
            children: children
        )
        itemByNodeID[node.id] = treeItem
        return treeItem
    }

    private func itemKind(from kind: PacketDetailNodeKind) -> PacketInspectorTreeItemKind {
        switch kind {
        case .layer:
            .layer
        case .field:
            .field
        case .warning:
            .warning
        @unknown default:
            .field
        }
    }
}

final class PacketInspectorViewController: NSViewController {
    private enum Metrics {
        static let rowHeight: CGFloat = 20
        static let cellIdentifier = NSUserInterfaceItemIdentifier("PacketInspectorCell")
    }

    weak var delegate: PacketInspectorViewControllerDelegate?

    private let configuration: AppConfiguration
    private let viewModel = PacketInspectorTreeViewModel()
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
    private var isApplyingSelection = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupOutlineView()
    }

    // Render the current packet inspection tree as a single Wireshark-style outline.
    func render(snapshot: NetworkInspectorSnapshot) {
        guard viewModel.render(snapshot: snapshot) else {
            return
        }

        outlineView.reloadData()
        expandAllItems()
        applySelectedNode()
    }

    private func setupOutlineView() {
        detailColumn.minWidth = 160
        detailColumn.width = 320
        detailColumn.resizingMask = .autoresizingMask
        detailColumn.title = ""

        outlineView.addTableColumn(detailColumn)
        outlineView.outlineTableColumn = detailColumn
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.headerView = nil
        outlineView.rowHeight = Metrics.rowHeight
        outlineView.indentationPerLevel = 14
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.selectionHighlightStyle = .regular
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsEmptySelection = true
        outlineView.backgroundColor = .controlBackgroundColor

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView

        TCPViewerUI.pin(scrollView, to: view)
    }

    private func expandAllItems() {
        for item in viewModel.rootItems {
            expand(item)
        }
    }

    private func expand(_ item: PacketInspectorTreeItem) {
        outlineView.expandItem(item)
        for child in item.children {
            expand(child)
        }
    }

    private func applySelectedNode() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }

        guard let item = viewModel.item(withNodeID: viewModel.selectedNodeID) else {
            outlineView.deselectAll(nil)
            return
        }

        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func configuredCell(for item: PacketInspectorTreeItem) -> NSTableCellView {
        let cell = outlineView.makeView(withIdentifier: Metrics.cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell()
        let textField = cell.textField ?? NSTextField(labelWithString: "")
        if cell.textField == nil {
            cell.textField = textField
            cell.addSubview(textField)
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        textField.stringValue = item.displayText
        textField.font = font(for: item.kind)
        textField.textColor = textColor(for: item.kind)
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Metrics.cellIdentifier
        return cell
    }

    private func font(for kind: PacketInspectorTreeItemKind) -> NSFont {
        switch kind {
        case .layer:
            configuration.packetFont(weight: .semibold)
        case .field, .warning, .message:
            configuration.packetFont()
        }
    }

    private func textColor(for kind: PacketInspectorTreeItemKind) -> NSColor {
        switch kind {
        case .warning:
            .systemOrange
        case .message:
            .secondaryLabelColor
        case .layer, .field:
            .labelColor
        }
    }
}

extension PacketInspectorViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? PacketInspectorTreeItem else {
            return viewModel.rootItems.count
        }

        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? PacketInspectorTreeItem else {
            return viewModel.rootItems[index]
        }

        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? PacketInspectorTreeItem else {
            return false
        }

        return !item.children.isEmpty
    }
}

extension PacketInspectorViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? PacketInspectorTreeItem else {
            return nil
        }

        return configuredCell(for: item)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else {
            return
        }

        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let item = outlineView.item(atRow: selectedRow) as? PacketInspectorTreeItem else {
            delegate?.packetInspectorViewController(self, didSelectDetailNode: nil)
            return
        }

        delegate?.packetInspectorViewController(self, didSelectDetailNode: item.nodeID)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? PacketInspectorTreeItem else {
            return false
        }

        return item.nodeID != nil
    }
}
