//
//  PacketInspectorViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

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

enum PacketInspectorTreeRenderChange: Equatable {
    case none
    case reload
    case selection
}

struct PacketInspectorCopyRow: Equatable {
    let text: String
    let indentationLevel: Int
}

enum PacketInspectorCopyFormatter {
    // Build copy text that mirrors the outline hierarchy with stable plain-text indentation.
    static func text(for rows: [PacketInspectorCopyRow]) -> String {
        rows
            .map { row in
                let indentation = String(repeating: "    ", count: max(0, row.indentationLevel))
                return row.text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "\(indentation)\($0)" }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n")
    }
}

final class PacketInspectorTreeItem: NSObject {
    let id: String
    let nodeID: String?
    let name: String
    let value: String?
    let kind: PacketInspectorTreeItemKind
    let severity: PacketDetailNodeSeverity
    let byteRange: PacketByteRange?
    let children: [PacketInspectorTreeItem]

    init(
        id: String,
        nodeID: String? = nil,
        name: String,
        value: String? = nil,
        kind: PacketInspectorTreeItemKind,
        severity: PacketDetailNodeSeverity = .normal,
        byteRange: PacketByteRange? = nil,
        children: [PacketInspectorTreeItem] = []
    ) {
        self.id = id
        self.nodeID = nodeID
        self.name = name
        self.value = value
        self.kind = kind
        self.severity = severity
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
    private enum Metrics {
        static let maximumInlineDisplayLength = 64
    }

    private struct DisplayParts {
        let name: String
        let value: String?
        let summaryRows: [SummaryRow]
    }

    private struct SummaryRow {
        let name: String
        let value: String?
    }

    private(set) var rootItems: [PacketInspectorTreeItem] = []
    private(set) var selectedNodeID: String?
    private var itemByNodeID: [String: PacketInspectorTreeItem] = [:]
    private var renderedContentState: PacketInspectorTreeContentState?

    @discardableResult
    func render(snapshot: NetworkInspectorSnapshot) -> PacketInspectorTreeRenderChange {
        let inspectionState = snapshot.base.inspectionState
        let contentState = nextContentState(from: inspectionState)
        let contentChanged = contentState.map { $0 != renderedContentState } ?? false

        if contentChanged, let contentState {
            renderedContentState = contentState
            itemByNodeID = [:]
            rootItems = makeRootItems(from: inspectionState)
        }

        let nextSelectedNodeID = validSelectedNodeID(from: inspectionState)
        guard nextSelectedNodeID != selectedNodeID else {
            return contentChanged ? .reload : .none
        }

        selectedNodeID = nextSelectedNodeID
        return contentChanged ? .reload : .selection
    }

    func item(withNodeID nodeID: String?) -> PacketInspectorTreeItem? {
        guard let nodeID else {
            return nil
        }

        return itemByNodeID[nodeID]
    }

    private func makeRootItems(from inspectionState: PacketInspectionState) -> [PacketInspectorTreeItem] {
        if inspectionState.isLoading, inspectionState.currentInspection == nil {
            return [messageItem(id: "loading", message: inspectionState.statusMessage)]
        }

        guard let inspection = inspectionState.currentInspection else {
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

    private func validSelectedNodeID(from inspectionState: PacketInspectionState) -> String? {
        guard let selectedDetailNodeID = inspectionState.selectedDetailNodeID,
              itemByNodeID[selectedDetailNodeID] != nil else {
            return nil
        }

        return selectedDetailNodeID
    }

    // Keep decoded rows visible during a packet-selection inspection request.
    private func nextContentState(from inspectionState: PacketInspectionState) -> PacketInspectorTreeContentState? {
        let contentState = PacketInspectorTreeContentState(inspectionState: inspectionState)
        guard inspectionState.isLoading,
              contentState.inspection == nil,
              renderedContentState?.inspection != nil else {
            return contentState
        }

        return nil
    }

    private func messageItem(id: String, message: String) -> PacketInspectorTreeItem {
        PacketInspectorTreeItem(id: "__\(id)", name: message, kind: .message)
    }

    private func makeItem(from node: PacketDetailNode, parentPath: String) -> PacketInspectorTreeItem {
        let path = parentPath.isEmpty ? node.id : "\(parentPath).\(node.id)"
        let displayParts = displayParts(for: node)
        let summaryChildren = makeSummaryItems(from: displayParts.summaryRows, parentPath: path, severity: node.severity)
        let children = summaryChildren + node.children.map { makeItem(from: $0, parentPath: path) }
        let treeItem = PacketInspectorTreeItem(
            id: path,
            nodeID: node.id,
            name: displayParts.name,
            value: displayParts.value,
            kind: itemKind(from: node.kind),
            severity: node.severity,
            byteRange: node.byteRange,
            children: children
        )
        itemByNodeID[node.id] = treeItem
        return treeItem
    }

    // Split oversized layer summaries into child rows so the outline stays readable at inspector width.
    private func displayParts(for node: PacketDetailNode) -> DisplayParts {
        guard shouldSplitDisplayText(name: node.name, value: node.value, kind: node.kind) else {
            return DisplayParts(name: node.name, value: node.value, summaryRows: [])
        }

        var displayName = node.name
        var displayValue = node.value
        var summaryRows: [SummaryRow] = []
        var didSplitDisplay = false

        let nameParts = commaSeparatedParts(from: node.name)
        if nameParts.count > 1 {
            displayName = nameParts[0]
            summaryRows.append(contentsOf: nameParts.dropFirst().map(summaryRow(from:)))
            didSplitDisplay = true
        }

        if let value = node.value, !value.isEmpty {
            let valueSummaryRows = summaryRowsForValue(value)
            if !valueSummaryRows.isEmpty {
                summaryRows.append(contentsOf: valueSummaryRows)
                displayValue = nil
                didSplitDisplay = true
            }
        }

        summaryRows = removingRowsAlreadyRepresentedByChildren(summaryRows, from: node.children)

        guard didSplitDisplay else {
            return DisplayParts(name: node.name, value: node.value, summaryRows: [])
        }

        return DisplayParts(name: displayName, value: displayValue, summaryRows: summaryRows)
    }

    // Only layer rows carry protocol summaries; field rows should keep their exact label/value pairing.
    private func shouldSplitDisplayText(name: String, value: String?, kind: PacketDetailNodeKind) -> Bool {
        guard kind == .layer else {
            return false
        }

        let displayText: String
        if let value, !value.isEmpty {
            displayText = "\(name): \(value)"
        } else {
            displayText = name
        }

        return displayText.count > Metrics.maximumInlineDisplayLength
    }

    // Build non-selectable rows that preserve long summary content under the original selectable node.
    private func makeSummaryItems(
        from rows: [SummaryRow],
        parentPath: String,
        severity: PacketDetailNodeSeverity
    ) -> [PacketInspectorTreeItem] {
        rows.enumerated().map { index, row in
            PacketInspectorTreeItem(
                id: "\(parentPath).__summary.\(index)",
                name: row.name,
                value: row.value,
                kind: .field,
                severity: severity
            )
        }
    }

    // Prefer protocol-shaped pieces such as "Src: ..." over one very long inline summary string.
    private func summaryRowsForValue(_ value: String) -> [SummaryRow] {
        if value.hasPrefix("Detailed field decoding is not available yet for ") {
            return [SummaryRow(name: "Decode Status", value: "Field decoding is not available yet.")]
        }

        let parts = commaSeparatedParts(from: value)
        guard parts.count > 1 else {
            return [SummaryRow(name: "Summary", value: value)]
        }

        return parts.map(summaryRow(from:))
    }

    // Split simple comma-separated protocol summaries without changing values that contain no separators.
    private func commaSeparatedParts(from value: String) -> [String] {
        value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { trimmed(String($0)) }
            .filter { !$0.isEmpty }
    }

    // Convert a summary fragment into the same "name: value" shape used by decoded field rows.
    private func summaryRow(from part: String) -> SummaryRow {
        let pieces = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else {
            return SummaryRow(name: "Summary", value: part)
        }

        let name = normalizedSummaryName(trimmed(String(pieces[0])))
        let value = trimmed(String(pieces[1]))
        return SummaryRow(name: name, value: value.isEmpty ? nil : value)
    }

    // Expand common packet-summary abbreviations into clearer inspector row names.
    private func normalizedSummaryName(_ name: String) -> String {
        switch name.lowercased() {
        case "src":
            return "Source"
        case "dst":
            return "Destination"
        default:
            return name
        }
    }

    // Keep whitespace cleanup local to the summary splitter.
    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Avoid duplicating decoded child fields that already show a long layer summary's key details.
    private func removingRowsAlreadyRepresentedByChildren(
        _ rows: [SummaryRow],
        from children: [PacketDetailNode]
    ) -> [SummaryRow] {
        let existingDisplayTexts = Set(children.map { displayText(name: $0.name, value: $0.value) })
        return rows.filter { !existingDisplayTexts.contains(displayText(name: $0.name, value: $0.value)) }
    }

    // Mirror PacketInspectorTreeItem display text for pre-render duplicate checks.
    private func displayText(name: String, value: String?) -> String {
        guard let value, !value.isEmpty else {
            return name
        }

        return "\(name): \(value)"
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

private struct PacketInspectorTreeContentState: Equatable {
    let selectedPacketID: PacketSummary.ID?
    let inspection: PacketInspection?
    let isLoading: Bool
    let statusMessage: String

    init(inspectionState: PacketInspectionState) {
        selectedPacketID = inspectionState.selectedPacketID
        inspection = inspectionState.currentInspection
        isLoading = inspectionState.isLoading
        statusMessage = inspectionState.statusMessage
    }
}

private extension PacketInspectionState {
    var currentInspection: PacketInspection? {
        guard let inspection,
              selectedPacketID == inspection.packetID else {
            return nil
        }

        return inspection
    }
}

fileprivate protocol PacketInspectorOutlineViewCopyHandling: AnyObject {
    func packetInspectorOutlineViewDidRequestCopy(_ outlineView: PacketInspectorOutlineView)
}

fileprivate final class PacketInspectorOutlineView: NSOutlineView {
    weak var copyActionHandler: PacketInspectorOutlineViewCopyHandling?

    @objc func copy(_ sender: Any?) {
        copyActionHandler?.packetInspectorOutlineViewDidRequestCopy(self)
    }
}

final class PacketInspectorViewController: NSViewController {
    private enum Metrics {
        static let rowHeight: CGFloat = 20
        static let cellIdentifier = NSUserInterfaceItemIdentifier("PacketInspectorCell")
        static let hexPanelHeight: CGFloat = 180
        static let minimumHexPanelHeight: CGFloat = 120
    }

    weak var delegate: PacketInspectorViewControllerDelegate?

    private let configuration: AppConfiguration
    private let viewModel = PacketInspectorTreeViewModel()
    private let hexViewController: PacketHexViewController
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let outlineView = PacketInspectorOutlineView()
    private let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
    private var emptyStateView: NSView?
    private var emptyStateMessage: String?
    private var isApplyingSelection = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.hexViewController = PacketHexViewController(configuration: configuration)
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
        setupLayout()
    }

    // Render the current packet inspection tree as a single Wireshark-style outline.
    func render(snapshot: NetworkInspectorSnapshot) {
        let renderChange = viewModel.render(snapshot: snapshot)
        hexViewController.render(snapshot: snapshot)
        updateContentVisibility(for: snapshot.base.inspectionState)

        switch renderChange {
        case .none:
            return
        case .selection:
            applySelectedNode(preservingExistingSelection: true)
            return
        case .reload:
            break
        }

        if let inspection = snapshot.base.inspectionState.inspection,
           snapshot.base.inspectionState.selectedPacketID == inspection.packetID {
            print("[TCPViewer] \(NetworkInspectorDebugLog.timestamp()) ✅ Inspector View rendering data: packet=#\(inspection.packetNumber), rootNodes=\(viewModel.rootItems.count)")
        }
        outlineView.reloadData()
        expandAllItems()
        applySelectedNode(preservingExistingSelection: false)
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
        outlineView.allowsMultipleSelection = true
        outlineView.backgroundColor = .controlBackgroundColor
        outlineView.style = .fullWidth
        outlineView.copyActionHandler = self
        outlineView.menu = makeContextMenu()

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView
    }

    private func setupLayout() {
        addChild(hexViewController)

        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsetsZero
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(scrollView)
        stackView.addArrangedSubview(hexViewController.view)

        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hexViewController.view.setContentHuggingPriority(.defaultHigh, for: .vertical)

        let hexHeight = hexViewController.view.heightAnchor.constraint(equalToConstant: Metrics.hexPanelHeight)
        hexHeight.priority = .defaultHigh

        view.addSubview(stackView)
        TCPViewerUI.pin(stackView, to: view)
        NSLayoutConstraint.activate([
            hexHeight,
            hexViewController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHexPanelHeight),
        ])
    }

    // Swap between the launch empty state and packet-detail controls.
    private func updateContentVisibility(for inspectionState: PacketInspectionState) {
        let shouldShowEmptyState = inspectionState.selectedPacketID == nil
        scrollView.isHidden = shouldShowEmptyState
        outlineView.isHidden = shouldShowEmptyState
        hexViewController.view.isHidden = shouldShowEmptyState

        if shouldShowEmptyState {
            showEmptyState(message: inspectionState.statusMessage)
        } else {
            hideEmptyState()
        }
    }

    // Build the centered no-selection placeholder only when the message changes.
    private func showEmptyState(message: String) {
        guard emptyStateView == nil || emptyStateMessage != message else {
            return
        }

        emptyStateView?.removeFromSuperview()
        let placeholder = TCPViewerUI.placeholder(
            title: "No Packet Selected",
            imageName: "list.bullet.rectangle",
            message: message
        )
        TCPViewerUI.pin(placeholder, to: view)
        emptyStateView = placeholder
        emptyStateMessage = message
    }

    // Restore the outline and hex views once a packet selection exists.
    private func hideEmptyState() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        emptyStateMessage = nil
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

    private func applySelectedNode(preservingExistingSelection: Bool) {
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

        if preservingExistingSelection, outlineView.selectedRowIndexes.contains(row) {
            outlineView.scrollRowToVisible(row)
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // Create the inspector outline context menu and update its state before it opens.
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    // Keep an existing multi-selection when right-clicking one of its rows, otherwise target the clicked row.
    private func updateSelectionFromCurrentMenuEvent() {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown || event.type == .leftMouseDown || event.type == .otherMouseDown else {
            return
        }

        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? PacketInspectorTreeItem,
              item.nodeID != nil else {
            return
        }

        if outlineView.selectedRowIndexes.contains(row) {
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // Collect selected visible outline rows in display order for copy formatting.
    private func selectedCopyRows() -> [PacketInspectorCopyRow] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard let item = outlineView.item(atRow: row) as? PacketInspectorTreeItem else {
                return nil
            }

            return PacketInspectorCopyRow(
                text: item.displayText,
                indentationLevel: outlineView.level(forRow: row)
            )
        }
    }

    // Write the selected inspector rows to the system pasteboard as plain text.
    private func copySelectedRowsToPasteboard() {
        let text = PacketInspectorCopyFormatter.text(for: selectedCopyRows())
        guard !text.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copySelectedRowsFromMenu(_ sender: Any?) {
        copySelectedRowsToPasteboard()
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
        textField.textColor = textColor(for: item)
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

    private func textColor(for item: PacketInspectorTreeItem) -> NSColor {
        switch item.severity {
        case .error:
            return .systemRed
        case .warning:
            return .systemOrange
        case .info, .normal:
            break
        @unknown default:
            break
        }

        switch item.kind {
        case .warning:
            return .systemOrange
        case .message:
            return .secondaryLabelColor
        case .layer, .field:
            return .labelColor
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

extension PacketInspectorViewController: PacketInspectorOutlineViewCopyHandling {
    fileprivate func packetInspectorOutlineViewDidRequestCopy(_ outlineView: PacketInspectorOutlineView) {
        copySelectedRowsToPasteboard()
    }
}

extension PacketInspectorViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSelectionFromCurrentMenuEvent()

        menu.removeAllItems()
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(copySelectedRowsFromMenu(_:)),
            keyEquivalent: "c"
        )
        copyItem.target = self
        copyItem.isEnabled = !selectedCopyRows().isEmpty
        copyItem.toolTip = "Copy the selected inspector rows."
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        menu.addItem(copyItem)
    }
}
