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
    // Build copy text that mirrors the outline hierarchy with tab indentation.
    static func text(for rows: [PacketInspectorCopyRow]) -> String {
        rows
            .map { row in
                let indentation = String(repeating: "\t", count: max(0, row.indentationLevel))
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

final class PacketInspectorOutlineExpansionState {
    private enum Override {
        case expanded
        case collapsed
    }

    private var overrides: [String: Override] = [:]

    // Resolve the persisted user choice first, then fall back to expanding only root groups.
    func shouldExpand(item: PacketInspectorTreeItem, level: Int) -> Bool {
        guard !item.children.isEmpty else {
            return false
        }

        switch overrides[item.id] {
        case .expanded:
            return true
        case .collapsed:
            return false
        case nil:
            return level == 0
        }
    }

    func recordExpanded(item: PacketInspectorTreeItem) {
        overrides[item.id] = .expanded
    }

    func recordCollapsed(item: PacketInspectorTreeItem) {
        overrides[item.id] = .collapsed
    }
}

final class PacketInspectorTreeItem: NSObject {
    let id: String
    let nodeID: String?
    let selectionID: String?
    let name: String
    let fieldName: String?
    let value: String?
    let kind: PacketInspectorTreeItemKind
    let severity: PacketDetailNodeSeverity
    let byteRange: PacketByteRange?
    let children: [PacketInspectorTreeItem]

    init(
        id: String,
        nodeID: String? = nil,
        selectionID: String? = nil,
        name: String,
        fieldName: String? = nil,
        value: String? = nil,
        kind: PacketInspectorTreeItemKind,
        severity: PacketDetailNodeSeverity = .normal,
        byteRange: PacketByteRange? = nil,
        children: [PacketInspectorTreeItem] = []
    ) {
        self.id = id
        self.nodeID = nodeID
        self.selectionID = selectionID ?? nodeID
        self.name = name
        self.fieldName = fieldName
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
    private var unfilteredRootItems: [PacketInspectorTreeItem] = []
    private var allItemBySelectionID: [String: PacketInspectorTreeItem] = [:]
    private var itemBySelectionID: [String: PacketInspectorTreeItem] = [:]
    private var renderedContentState: PacketInspectorTreeContentState?
    private var renderedFilterText = ""

    @discardableResult
    func render(snapshot: NetworkInspectorSnapshot, filterText: String = "") -> PacketInspectorTreeRenderChange {
        render(inspectionState: snapshot.base.inspectionState, filterText: filterText)
    }

    @discardableResult
    func render(inspectionState: PacketInspectionState, filterText: String = "") -> PacketInspectorTreeRenderChange {
        let contentState = nextContentState(from: inspectionState)
        let contentChanged = contentState.map { $0 != renderedContentState } ?? false
        let nextFilterText = normalizedFilterText(filterText)
        let filterChanged = nextFilterText != renderedFilterText

        if contentChanged, let contentState {
            renderedContentState = contentState
            unfilteredRootItems = makeRootItems(from: inspectionState)
            allItemBySelectionID = visibleItemMap(from: unfilteredRootItems)
        }

        if contentChanged || filterChanged {
            renderedFilterText = nextFilterText
            if nextFilterText.isEmpty {
                rootItems = unfilteredRootItems
                itemBySelectionID = allItemBySelectionID
            } else {
                rootItems = visibleRootItems(from: unfilteredRootItems, filterText: nextFilterText)
                itemBySelectionID = visibleItemMap(from: rootItems)
            }
        }

        let nextSelectedNodeID = validSelectedNodeID(from: inspectionState)
        guard nextSelectedNodeID != selectedNodeID else {
            return contentChanged || filterChanged ? .reload : .none
        }

        selectedNodeID = nextSelectedNodeID
        return contentChanged || filterChanged ? .reload : .selection
    }

    func item(withNodeID nodeID: String?) -> PacketInspectorTreeItem? {
        guard let nodeID else {
            return nil
        }

        return itemBySelectionID[nodeID]
    }

    // Report whether the current packet has real detail rows available for Copy All.
    func hasCopyableDetails() -> Bool {
        unfilteredRootItems.contains { $0.kind != .message }
    }

    // Copy All uses the full unfiltered tree, independent of search text or outline expansion.
    func copyRowsForAllDetails() -> [PacketInspectorCopyRow] {
        copyRows(from: unfilteredRootItems, level: 0)
    }

    // Copy selected rows as subtrees while preserving original packet-detail indentation levels.
    func copyRows(forSelectionIDs selectionIDs: [String]) -> [PacketInspectorCopyRow] {
        let selectedIDs = Set(selectionIDs)
        guard !selectedIDs.isEmpty else {
            return []
        }

        var copiedItemIDs: Set<String> = []
        return copyRowsForSelection(from: unfilteredRootItems, level: 0, selectedIDs: selectedIDs, copiedItemIDs: &copiedItemIDs)
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

    private func normalizedFilterText(_ filterText: String) -> String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Keep matching rows plus their ancestors so filtered fields retain packet context.
    private func visibleRootItems(
        from items: [PacketInspectorTreeItem],
        filterText: String
    ) -> [PacketInspectorTreeItem] {
        guard !filterText.isEmpty else {
            return items
        }
        guard !items.allSatisfy({ $0.kind == .message }) else {
            return items
        }

        let filteredItems = items.compactMap { filteredItem($0, filterText: filterText) }
        guard !filteredItems.isEmpty else {
            return [messageItem(id: "filter-empty", message: "No inspector fields match \"\(filterText)\".")]
        }

        return filteredItems
    }

    private func filteredItem(
        _ item: PacketInspectorTreeItem,
        filterText: String
    ) -> PacketInspectorTreeItem? {
        let filteredChildren = item.children.compactMap { filteredItem($0, filterText: filterText) }
        guard matchesFilter(filterText, item: item) || !filteredChildren.isEmpty else {
            return nil
        }

        return PacketInspectorTreeItem(
            id: item.id,
            nodeID: item.nodeID,
            selectionID: item.selectionID,
            name: item.name,
            fieldName: item.fieldName,
            value: item.value,
            kind: item.kind,
            severity: item.severity,
            byteRange: item.byteRange,
            children: filteredChildren
        )
    }

    private func matchesFilter(_ filterText: String, item: PacketInspectorTreeItem) -> Bool {
        [item.name, item.fieldName, item.value]
            .compactMap(\.self)
            .contains { value in
                value.range(of: filterText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
    }

    private func visibleItemMap(from items: [PacketInspectorTreeItem]) -> [String: PacketInspectorTreeItem] {
        var map: [String: PacketInspectorTreeItem] = [:]
        collectVisibleItems(items, into: &map)
        return map
    }

    private func collectVisibleItems(
        _ items: [PacketInspectorTreeItem],
        into map: inout [String: PacketInspectorTreeItem]
    ) {
        for item in items {
            if let selectionID = item.selectionID {
                map[selectionID] = item
            }
            collectVisibleItems(item.children, into: &map)
        }
    }

    // Flatten packet-detail rows depth-first for stable plain-text output.
    private func copyRows(from items: [PacketInspectorTreeItem], level: Int) -> [PacketInspectorCopyRow] {
        items.flatMap { item -> [PacketInspectorCopyRow] in
            guard item.kind != .message else {
                return []
            }

            return [PacketInspectorCopyRow(text: item.displayText, indentationLevel: level)] +
                copyRows(from: item.children, level: level + 1)
        }
    }

    // Walk all roots so multi-selection order follows the original packet-detail tree.
    private func copyRowsForSelection(
        from items: [PacketInspectorTreeItem],
        level: Int,
        selectedIDs: Set<String>,
        copiedItemIDs: inout Set<String>
    ) -> [PacketInspectorCopyRow] {
        var rows: [PacketInspectorCopyRow] = []
        for item in items {
            if let selectionID = item.selectionID, selectedIDs.contains(selectionID) {
                rows.append(contentsOf: copyRowsIfNeeded(from: item, level: level, copiedItemIDs: &copiedItemIDs))
            } else {
                rows.append(contentsOf: copyRowsForSelection(
                    from: item.children,
                    level: level + 1,
                    selectedIDs: selectedIDs,
                    copiedItemIDs: &copiedItemIDs
                ))
            }
        }

        return rows
    }

    // Skip rows already copied through a selected ancestor.
    private func copyRowsIfNeeded(
        from item: PacketInspectorTreeItem,
        level: Int,
        copiedItemIDs: inout Set<String>
    ) -> [PacketInspectorCopyRow] {
        guard item.kind != .message,
              copiedItemIDs.insert(item.id).inserted else {
            return []
        }

        var rows = [PacketInspectorCopyRow(text: item.displayText, indentationLevel: level)]
        for child in item.children {
            rows.append(contentsOf: copyRowsIfNeeded(from: child, level: level + 1, copiedItemIDs: &copiedItemIDs))
        }

        return rows
    }

    private func validSelectedNodeID(from inspectionState: PacketInspectionState) -> String? {
        guard let selectedDetailNodeID = inspectionState.selectedDetailNodeID,
              itemBySelectionID[selectedDetailNodeID] != nil else {
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
            fieldName: node.fieldName,
            value: displayParts.value,
            kind: itemKind(from: node.kind),
            severity: node.severity,
            byteRange: node.byteRange,
            children: children
        )
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
                selectionID: "\(parentPath).__summary.\(index)",
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

fileprivate protocol PacketInspectorOutlineViewActionHandling: AnyObject {
    func packetInspectorOutlineViewDidRequestCopy(_ outlineView: PacketInspectorOutlineView)
}

fileprivate final class PacketInspectorOutlineView: NSOutlineView {
    weak var actionHandler: PacketInspectorOutlineViewActionHandling?

    @objc func copy(_ sender: Any?) {
        actionHandler?.packetInspectorOutlineViewDidRequestCopy(self)
    }
}

private final class PacketInspectorSectionRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else {
            return
        }

        NSColor.separatorColor.withAlphaComponent(0.10).setFill()
        dirtyRect.fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

final class PacketInspectorViewController: NSViewController {
    private enum Metrics {
        static let rowHeight: CGFloat = 20
        static let cellIdentifier = NSUserInterfaceItemIdentifier("PacketInspectorCell")
        static let minimumHexPanelHeight: CGFloat = 120
        static let filterBarHeight: CGFloat = 34
        static let summaryPaneFraction: CGFloat = 0.70
        static let hexPaneFraction: CGFloat = 0.30
    }

    weak var delegate: PacketInspectorViewControllerDelegate?

    private let configuration: AppConfiguration
    private let viewModel = PacketInspectorTreeViewModel()
    private let expansionState = PacketInspectorOutlineExpansionState()
    private let hexViewController: PacketHexViewController
    private let detailSplitViewController = NSSplitViewController()
    private let outlineViewController = NSViewController()
    private let stackView = NSStackView()
    private let detailContainerView = NSView()
    private let filterBarView = NSView()
    private let filterSearchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let outlineView = PacketInspectorOutlineView()
    private let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
    private var outlineItem: NSSplitViewItem?
    private var hexItem: NSSplitViewItem?
    private var emptyStateView: NSView?
    private var emptyStateMessage: String?
    private var latestInspectionState: PacketInspectionState?
    private var appliedPlacement: NetworkInspectorPlacement?
    private var pendingDefaultDetailDividerPlacement: NetworkInspectorPlacement?
    private var isShowingPacketDetail = false
    private var isApplyingSelection = false
    private var isApplyingExpansionState = false

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
        setupFilterBar()
        setupOutlineView()
        setupLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyPendingDefaultDetailDividerPosition()
    }

    // Render the current packet inspection tree as a single Wireshark-style outline.
    func render(snapshot: NetworkInspectorSnapshot) {
        let inspectionState = snapshot.base.inspectionState
        latestInspectionState = inspectionState
        let didRevealPacketDetail = updateContentVisibility(for: inspectionState)
        applyPlacement(
            snapshot.inspectorPlacement,
            resetsDefaultDivider: true,
            forcesDefaultDivider: didRevealPacketDetail
        )
        let renderChange = viewModel.render(inspectionState: inspectionState, filterText: filterSearchField.stringValue)
        hexViewController.render(inspectionState: inspectionState)

        applyTreeRenderChange(renderChange, inspectionState: inspectionState)
    }

    // Switch the outline/hex split to match the outer inspector placement.
    func applyPlacement(_ placement: NetworkInspectorPlacement) {
        applyPlacement(placement, resetsDefaultDivider: true, forcesDefaultDivider: false)
    }

    private func applyPlacement(
        _ placement: NetworkInspectorPlacement,
        resetsDefaultDivider: Bool,
        forcesDefaultDivider: Bool
    ) {
        guard let outlineItem, let hexItem else {
            return
        }

        let placementChanged = appliedPlacement != placement
        detailSplitViewController.splitView.isVertical = placement == .bottom
        outlineItem.preferredThicknessFraction = Metrics.summaryPaneFraction
        hexItem.preferredThicknessFraction = Metrics.hexPaneFraction

        let targetItems = [outlineItem, hexItem]
        let orderChanged = !splitItems(detailSplitViewController.splitViewItems, match: targetItems)
        if orderChanged {
            for item in detailSplitViewController.splitViewItems.reversed() {
                detailSplitViewController.removeSplitViewItem(item)
            }
            for (index, item) in targetItems.enumerated() {
                detailSplitViewController.insertSplitViewItem(item, at: index)
            }
        }

        appliedPlacement = placement
        guard resetsDefaultDivider else {
            pendingDefaultDetailDividerPlacement = placement
            return
        }

        if forcesDefaultDivider || placementChanged || orderChanged {
            scheduleDefaultDetailDividerPosition(for: placement)
        } else if pendingDefaultDetailDividerPlacement != nil {
            applyPendingDefaultDetailDividerPosition(afterLayingOut: true)
        }
    }

    private func splitItems(_ lhs: [NSSplitViewItem], match rhs: [NSSplitViewItem]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        return zip(lhs, rhs).allSatisfy { $0 === $1 }
    }

    private func scheduleDefaultDetailDividerPosition(for placement: NetworkInspectorPlacement) {
        pendingDefaultDetailDividerPlacement = placement
        applyPendingDefaultDetailDividerPosition(afterLayingOut: true)
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingDefaultDetailDividerPosition(afterLayingOut: true)
        }
    }

    private func applyPendingDefaultDetailDividerPosition(afterLayingOut shouldLayout: Bool = false) {
        if shouldLayout {
            view.layoutSubtreeIfNeeded()
        }

        guard let placement = pendingDefaultDetailDividerPlacement,
              applyDefaultDetailDividerPosition(for: placement) else {
            return
        }

        pendingDefaultDetailDividerPlacement = nil
    }

    @discardableResult
    private func applyDefaultDetailDividerPosition(for placement: NetworkInspectorPlacement) -> Bool {
        let splitView = detailSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let totalLength = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let availableLength = totalLength - splitView.dividerThickness
        guard splitView.subviews.count >= 2,
              hasSettledDetailSplitLayout(),
              availableLength.isFinite,
              availableLength > 0 else {
            return false
        }

        splitView.setPosition((availableLength * Metrics.summaryPaneFraction).rounded(), ofDividerAt: 0)
        return true
    }

    private func hasSettledDetailSplitLayout() -> Bool {
        let detailFrame = detailSplitViewController.view.convert(detailSplitViewController.view.bounds, to: stackView)
        let expectedDetailHeight = stackView.bounds.height - filterBarView.bounds.height
        guard stackView.bounds.width > 0,
              expectedDetailHeight > 0 else {
            return false
        }

        return abs(detailFrame.width - stackView.bounds.width) <= 1 &&
            abs(detailFrame.height - expectedDetailHeight) <= 1
    }

    private func applyTreeRenderChange(
        _ renderChange: PacketInspectorTreeRenderChange,
        inspectionState: PacketInspectionState
    ) {
        switch renderChange {
        case .none:
            return
        case .selection:
            applySelectedNode(preservingExistingSelection: true)
            return
        case .reload:
            break
        }

        if let inspection = inspectionState.currentInspection {
            print("[TCPViewer] \(NetworkInspectorDebugLog.timestamp()) ✅ Inspector View rendering data: packet=#\(inspection.packetNumber), rootNodes=\(viewModel.rootItems.count)")
        }
        let preservedScrollOrigin = outlineScrollOrigin()
        outlineView.reloadData()
        applyExpansionState()
        applySelectedNode(preservingExistingSelection: false, scrollToSelection: false)
        restoreOutlineScrollOrigin(preservedScrollOrigin)
    }

    private func setupFilterBar() {
        filterBarView.translatesAutoresizingMaskIntoConstraints = false
        filterBarView.wantsLayer = true
        filterBarView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        filterSearchField.placeholderString = "Filter key or value"
        filterSearchField.sendsSearchStringImmediately = true
        filterSearchField.sendsWholeSearchString = false
        filterSearchField.delegate = self
        filterSearchField.target = self
        filterSearchField.action = #selector(filterSearchFieldDidChange(_:))
        filterSearchField.translatesAutoresizingMaskIntoConstraints = false

        filterBarView.addSubview(filterSearchField)
        NSLayoutConstraint.activate([
            filterBarView.heightAnchor.constraint(equalToConstant: Metrics.filterBarHeight),
            filterSearchField.leadingAnchor.constraint(equalTo: filterBarView.leadingAnchor, constant: 8),
            filterSearchField.trailingAnchor.constraint(equalTo: filterBarView.trailingAnchor, constant: -8),
            filterSearchField.centerYAnchor.constraint(equalTo: filterBarView.centerYAnchor),
        ])
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
        outlineView.actionHandler = self
        outlineView.menu = makeContextMenu()

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView
    }

    private func setupLayout() {
        outlineViewController.view = scrollView
        let outlineItem = NSSplitViewItem(viewController: outlineViewController)
        outlineItem.minimumThickness = 160
        let hexItem = NSSplitViewItem(viewController: hexViewController)
        hexItem.minimumThickness = Metrics.minimumHexPanelHeight
        self.outlineItem = outlineItem
        self.hexItem = hexItem

        addChild(detailSplitViewController)
        // Keep the split layout slot stable while the empty state hides the inspector content.
        detailContainerView.translatesAutoresizingMaskIntoConstraints = false
        detailContainerView.addSubview(detailSplitViewController.view)
        detailSplitViewController.view.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsetsZero
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(filterBarView)
        stackView.addArrangedSubview(detailContainerView)
        filterBarView.setContentHuggingPriority(.required, for: .vertical)
        filterBarView.setContentCompressionResistancePriority(.required, for: .vertical)
        detailContainerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        detailContainerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        applyPlacement(.trailing, resetsDefaultDivider: false, forcesDefaultDivider: false)

        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            filterBarView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            detailContainerView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            detailContainerView.heightAnchor.constraint(equalTo: stackView.heightAnchor, constant: -Metrics.filterBarHeight),
            detailSplitViewController.view.leadingAnchor.constraint(equalTo: detailContainerView.leadingAnchor),
            detailSplitViewController.view.trailingAnchor.constraint(equalTo: detailContainerView.trailingAnchor),
            detailSplitViewController.view.topAnchor.constraint(equalTo: detailContainerView.topAnchor),
            detailSplitViewController.view.bottomAnchor.constraint(equalTo: detailContainerView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // Swap between the launch empty state and packet-detail controls.
    @discardableResult
    private func updateContentVisibility(for inspectionState: PacketInspectionState) -> Bool {
        let shouldShowEmptyState = inspectionState.selectedPacketID == nil
        let shouldShowPacketDetail = !shouldShowEmptyState
        let didRevealPacketDetail = shouldShowPacketDetail && !isShowingPacketDetail
        isShowingPacketDetail = shouldShowPacketDetail

        detailSplitViewController.view.isHidden = shouldShowEmptyState
        scrollView.isHidden = shouldShowEmptyState
        outlineView.isHidden = shouldShowEmptyState
        hexViewController.view.isHidden = shouldShowEmptyState

        if shouldShowEmptyState {
            showEmptyState(message: inspectionState.statusMessage)
        } else {
            hideEmptyState()
        }

        return didRevealPacketDetail
    }

    // Focus the always-visible filter field without changing the active query.
    private func focusFilterField() {
        view.window?.makeFirstResponder(filterSearchField)
        filterSearchField.currentEditor()?.selectAll(nil)
    }

    private func applyFilterText(to inspectionState: PacketInspectionState) {
        let renderChange = viewModel.render(inspectionState: inspectionState, filterText: filterSearchField.stringValue)
        applyTreeRenderChange(renderChange, inspectionState: inspectionState)
    }

    @objc private func filterSearchFieldDidChange(_ sender: NSSearchField) {
        guard let inspectionState = latestInspectionState else {
            return
        }

        applyFilterText(to: inspectionState)
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
        pinToInspectorContentArea(placeholder)
        emptyStateView = placeholder
        emptyStateMessage = message
    }

    private func pinToInspectorContentArea(_ contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // Restore the outline and hex views once a packet selection exists.
    private func hideEmptyState() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        emptyStateMessage = nil
    }

    // Restore expansion choices without recursively opening every packet-detail field.
    private func applyExpansionState() {
        isApplyingExpansionState = true
        defer { isApplyingExpansionState = false }

        for item in viewModel.rootItems {
            applyExpansionState(to: item, level: 0)
        }
    }

    private func applyExpansionState(to item: PacketInspectorTreeItem, level: Int) {
        guard !item.children.isEmpty else {
            return
        }

        if expansionState.shouldExpand(item: item, level: level) {
            outlineView.expandItem(item)
            applyExpansionStateToChildren(of: item, level: level + 1)
        } else {
            outlineView.collapseItem(item)
        }
    }

    private func applyExpansionStateToChildren(of item: PacketInspectorTreeItem, level: Int) {
        for child in item.children {
            applyExpansionState(to: child, level: level)
        }
    }

    private func outlineScrollOrigin() -> NSPoint {
        scrollView.contentView.bounds.origin
    }

    // Put the outline viewport back where it was, clamped to the new content height.
    private func restoreOutlineScrollOrigin(_ origin: NSPoint) {
        guard let documentView = scrollView.documentView else {
            return
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
    }

    private func applySelectedNode(preservingExistingSelection: Bool, scrollToSelection: Bool = true) {
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
            if scrollToSelection {
                outlineView.scrollRowToVisible(row)
            }
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scrollToSelection {
            outlineView.scrollRowToVisible(row)
        }
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
              item.selectionID != nil else {
            return
        }

        if outlineView.selectedRowIndexes.contains(row) {
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // Collect selected visible outline row IDs in display order for subtree copy formatting.
    private func selectedCopySelectionIDs() -> [String] {
        outlineView.selectedRowIndexes.compactMap { row in
            (outlineView.item(atRow: row) as? PacketInspectorTreeItem)?.selectionID
        }
    }

    // Write inspector copy rows to the system pasteboard as plain text.
    private func copyRowsToPasteboard(_ rows: [PacketInspectorCopyRow]) {
        let text = PacketInspectorCopyFormatter.text(for: rows)
        guard !text.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySelectedRowsToPasteboard() {
        copyRowsToPasteboard(viewModel.copyRows(forSelectionIDs: selectedCopySelectionIDs()))
    }

    private func copyAllRowsToPasteboard() {
        copyRowsToPasteboard(viewModel.copyRowsForAllDetails())
    }

    @objc private func copySelectedRowsFromMenu(_ sender: Any?) {
        copySelectedRowsToPasteboard()
    }

    @objc private func copyAllRowsFromMenu(_ sender: Any?) {
        copyAllRowsToPasteboard()
    }

    @objc private func showFilterFromMenu(_ sender: Any?) {
        focusFilterField()
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

        let isSection = isTopLevelSectionItem(item)
        textField.stringValue = item.displayText
        textField.font = font(for: item.kind, isSection: isSection)
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

    private func font(for kind: PacketInspectorTreeItemKind, isSection: Bool) -> NSFont {
        if isSection {
            return configuration.packetFont(weight: .bold)
        }

        switch kind {
        case .layer:
            return configuration.packetFont(weight: .semibold)
        case .field, .warning, .message:
            return configuration.packetFont()
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

    private func isTopLevelSectionItem(_ item: PacketInspectorTreeItem) -> Bool {
        item.kind == .layer && viewModel.rootItems.contains { $0 === item }
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
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let item = item as? PacketInspectorTreeItem,
              isTopLevelSectionItem(item) else {
            return nil
        }

        return PacketInspectorSectionRowView()
    }

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

        delegate?.packetInspectorViewController(self, didSelectDetailNode: item.selectionID)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? PacketInspectorTreeItem else {
            return false
        }

        return item.selectionID != nil
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingExpansionState,
              let item = notification.userInfo?["NSObject"] as? PacketInspectorTreeItem else {
            return
        }

        expansionState.recordExpanded(item: item)
        let childLevel = outlineView.level(forItem: item) + 1

        isApplyingExpansionState = true
        defer { isApplyingExpansionState = false }
        applyExpansionStateToChildren(of: item, level: childLevel)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingExpansionState,
              let item = notification.userInfo?["NSObject"] as? PacketInspectorTreeItem else {
            return
        }

        expansionState.recordCollapsed(item: item)
    }
}

extension PacketInspectorViewController: PacketInspectorOutlineViewActionHandling {
    fileprivate func packetInspectorOutlineViewDidRequestCopy(_ outlineView: PacketInspectorOutlineView) {
        copySelectedRowsToPasteboard()
    }
}

extension PacketInspectorViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === filterSearchField,
              let inspectionState = latestInspectionState else {
            return
        }

        applyFilterText(to: inspectionState)
    }
}

extension PacketInspectorViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSelectionFromCurrentMenuEvent()

        menu.removeAllItems()
        let hasSelectedRows = !selectedCopySelectionIDs().isEmpty
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(copySelectedRowsFromMenu(_:)),
            keyEquivalent: "c"
        )
        copyItem.target = self
        copyItem.isEnabled = hasSelectedRows
        copyItem.toolTip = "Copy the selected inspector rows."
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        menu.addItem(copyItem)

        let copyAllItem = NSMenuItem(
            title: "Copy All",
            action: #selector(copyAllRowsFromMenu(_:)),
            keyEquivalent: ""
        )
        copyAllItem.target = self
        copyAllItem.isEnabled = viewModel.hasCopyableDetails()
        copyAllItem.toolTip = "Copy all packet detail rows."
        copyAllItem.image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "Copy All")
        menu.addItem(copyAllItem)
        menu.addItem(.separator())

        let filterItem = NSMenuItem(
            title: "Filter",
            action: #selector(showFilterFromMenu(_:)),
            keyEquivalent: ""
        )
        filterItem.target = self
        filterItem.isEnabled = hasSelectedRows
        filterItem.toolTip = "Focus the inspector filter."
        filterItem.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter")
        menu.addItem(filterItem)
    }
}
