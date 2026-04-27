import AppKit
import PcapPlusPlusCore

protocol PacketInspectorViewControllerDelegate: AnyObject {
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelect tab: PacketInspectorTab)
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?)
}

struct PacketInspectorRenderState: Equatable {
    let inspectorTab: PacketInspectorTab
    let selectedPacket: PacketSummary?
    let selectedPacketID: PacketSummary.ID?
    let inspection: PacketInspection?
    let selectedDetailNodeID: String?
    let highlightedByteRange: PacketByteRange?
    let isLoading: Bool
    let statusMessage: String

    init(snapshot: NetworkInspectorSnapshot) {
        self.inspectorTab = snapshot.inspectorTab
        self.selectedPacket = snapshot.selectedPacket
        self.selectedPacketID = snapshot.selectedPacketID
        self.inspection = snapshot.base.inspectionState.inspection
        self.selectedDetailNodeID = snapshot.base.inspectionState.selectedDetailNodeID
        self.highlightedByteRange = snapshot.base.inspectionState.highlightedByteRange
        self.isLoading = snapshot.base.inspectionState.isLoading
        self.statusMessage = snapshot.base.inspectionState.statusMessage
    }
}

final class PacketInspectorPanelViewModel {
    private(set) var state = PacketInspectorRenderState(snapshot: .make(
        base: .foundation,
        selectedSidebar: .liveCapture,
        selectedSourceListSelection: .allPackets,
        sourceListSnapshot: .empty,
        sourceListFilterText: "",
        workspaceMode: .packets,
        inspectorTab: .summary,
        isInspectorVisible: true,
        displayFilterText: "",
        packetTableContent: .empty
    ))

    // Extract inspector-only state and report whether the inspector actually changed.
    @discardableResult
    func render(snapshot: NetworkInspectorSnapshot) -> Bool {
        let nextState = PacketInspectorRenderState(snapshot: snapshot)
        guard !shouldDeferPendingInspection(nextState) else {
            return false
        }

        guard nextState != state else {
            return false
        }

        state = nextState
        return true
    }

    private func shouldDeferPendingInspection(_ state: PacketInspectorRenderState) -> Bool {
        guard let selectedPacketID = state.selectedPacketID else {
            return false
        }

        if state.isLoading {
            return true
        }

        if let inspection = state.inspection, inspection.packetID != selectedPacketID {
            return true
        }

        return false
    }
}

final class PacketInspectorViewController: NSViewController {
    weak var delegate: PacketInspectorViewControllerDelegate?

    private let configuration: AppConfiguration
    private let viewModel = PacketInspectorPanelViewModel()
    private let tabControl = NSSegmentedControl(labels: PacketInspectorTab.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let contentContainer = NSView()
    private var currentContentView: NSView?
    private var hexView: PacketHexFiendView?
    private var rawOutlineView: PacketRawOutlineView?
    private var renderLogCount = 0

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appConfigurationDidChange(_:)),
            name: AppConfiguration.didChangeNotification,
            object: configuration
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = InspectorTheme.Palette.panelBackground.cgColor
        setupHeader()
        setupContentContainer()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        let didChange = viewModel.render(snapshot: snapshot)
        guard didChange || currentContentView == nil else {
            return
        }

        let state = viewModel.state
        logSelectedPacketRender(state: state)
        tabControl.selectedSegment = PacketInspectorTab.allCases.firstIndex(of: state.inspectorTab) ?? 0
        renderContent(state: state)
    }

    // Log every inspector render so row-selection reload behavior is easy to count in Console.
    private func logSelectedPacketRender(state: PacketInspectorRenderState) {
        renderLogCount += 1
        let selectedID = state.selectedPacketID.map(String.init) ?? "nil"
        let packetNumber = state.selectedPacket.map { "#\($0.packetNumber)" } ?? "none"
        let inspectionID = state.inspection?.packetID.description ?? "nil"
        print("[TCPViewer] 🧪 Inspector render \(renderLogCount): selectedPacketID=\(selectedID), packet=\(packetNumber), tab=\(state.inspectorTab.title), loading=\(state.isLoading), inspectionPacketID=\(inspectionID)")
    }

    private func setupHeader() {
        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .followsWindowActiveState
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        tabControl.segmentStyle = .rounded
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(tabControl)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),

            tabControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            tabControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            tabControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
    }

    private func setupContentContainer() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 38),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard PacketInspectorTab.allCases.indices.contains(index) else {
            return
        }

        delegate?.packetInspectorViewController(self, didSelect: PacketInspectorTab.allCases[index])
    }

    @objc private func detailNodeSelected(_ sender: NSButton) {
        delegate?.packetInspectorViewController(self, didSelectDetailNode: sender.identifier?.rawValue)
    }

    @objc private func appConfigurationDidChange(_ notification: Notification) {
        guard isViewLoaded else {
            return
        }

        renderContent(state: viewModel.state)
    }

    private func renderContent(state: PacketInspectorRenderState) {
        switch state.inspectorTab {
        case .summary:
            replaceContent(makeSummaryView(state: state))
        case .detail:
            replaceContent(makeDetailView(state: state))
        case .raw:
            replaceContent(makeRawView(state: state))
        case .hex:
            replaceContent(makeHexView(state: state))
        }
    }

    private func replaceContent(_ newView: NSView) {
        currentContentView?.removeFromSuperview()
        currentContentView = newView
        TCPViewerUI.pin(newView, to: contentContainer)
    }

    private func makeSummaryView(state: PacketInspectorRenderState) -> NSView {
        guard let packet = state.selectedPacket else {
            return TCPViewerUI.placeholder(
                title: "No Packet Selected",
                imageName: "sidebar.trailing",
                message: state.statusMessage,
                placement: .top
            )
        }

        let hero = makeHero(packet: packet, inspection: state.inspection)

        let summaryCard = sectionCard(symbol: "doc.text.magnifyingglass", title: "Summary", rows: [
            InspectorTheme.keyValueRow(label: "Packet", value: "#\(packet.packetNumber)", configuration: configuration),
            InspectorTheme.keyValueRow(label: "Length", value: NetworkInspectorFormatters.byteCount(packet.capturedLength), configuration: configuration),
            InspectorTheme.keyValueRow(label: "On Wire", value: NetworkInspectorFormatters.byteCount(packet.originalLength), configuration: configuration),
            InspectorTheme.keyValueRow(label: "Protocol", value: NetworkInspectorFormatters.protocolLabel(for: packet), configuration: configuration),
            InspectorTheme.keyValueRow(label: "Status", value: NetworkInspectorFormatters.severity(for: packet).label, configuration: configuration),
            InspectorTheme.keyValueRow(label: "Info", value: packet.infoSummary, configuration: configuration),
        ])

        let sourceCard = sectionCard(symbol: "arrow.up.right.circle", title: "Source", rows: [
            InspectorTheme.keyValueRow(label: "Endpoint", value: NetworkInspectorFormatters.endpointLabel(packet.endpoints.source), configuration: configuration),
            InspectorTheme.keyValueRow(label: "Interface", value: packet.captureMetadata.interfaceName ?? packet.interfaceID ?? "—", configuration: configuration),
        ])

        let destinationCard = sectionCard(symbol: "arrow.down.left.circle", title: "Destination", rows: [
            InspectorTheme.keyValueRow(label: "Endpoint", value: NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination), configuration: configuration),
        ])

        let timingCard = sectionCard(symbol: "clock", title: "Timing", rows: [
            InspectorTheme.keyValueRow(label: "Captured", value: NetworkInspectorFormatters.packetTime.string(from: packet.timestamp), configuration: configuration),
        ])

        return scrollView(for: sectionStack([hero, summaryCard, sourceCard, destinationCard, timingCard]))
    }

    private func makeHero(packet: PacketSummary, inspection: PacketInspection?) -> NSView {
        let title = TCPViewerUI.label(
            "Packet #\(packet.packetNumber)",
            font: InspectorTheme.heroTitleFont(configuration)
        )
        title.maximumNumberOfLines = 1

        let subtitle = TCPViewerUI.label(
            heroSubtitle(for: packet),
            font: InspectorTheme.heroSubtitleFont(configuration),
            color: .secondaryLabelColor
        )
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byTruncatingMiddle

        let layerNames = packet.layers.map(\.name)
        let stackView = layerNames.isEmpty
            ? NSView()
            : InspectorTheme.protocolStack(layers: layerNames, configuration: configuration)

        let statusChips = makeStatusChips(packet: packet, inspection: inspection)
        let chipRow = NSStackView()
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = InspectorTheme.Spacing.chipSpacing
        chipRow.addArrangedSubview(stackView)
        for chip in statusChips {
            chipRow.addArrangedSubview(chip)
        }

        let stack = NSStackView(views: [title, subtitle, chipRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(InspectorTheme.Spacing.heroSpacing, after: subtitle)
        return stack
    }

    private func heroSubtitle(for packet: PacketSummary) -> String {
        let source = NetworkInspectorFormatters.endpointLabel(packet.endpoints.source)
        let destination = NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination)
        let length = NetworkInspectorFormatters.byteCount(packet.capturedLength)
        return "\(source) → \(destination) · \(length)"
    }

    private func makeStatusChips(packet: PacketSummary, inspection: PacketInspection?) -> [NSView] {
        var chips: [NSView] = []
        let severity = NetworkInspectorFormatters.severity(for: packet)
        if severity != .normal {
            chips.append(InspectorTheme.chip(text: severity.label, tint: .systemOrange, configuration: configuration))
        }
        if packet.captureMetadata.isTruncated {
            chips.append(InspectorTheme.chip(text: "Truncated", tint: .systemYellow, configuration: configuration))
        }
        if let status = inspection?.decodeStatus, status.kind != .complete, let reason = status.reason, !reason.isEmpty {
            chips.append(InspectorTheme.chip(text: reason, tint: .systemOrange, configuration: configuration))
        }
        return chips
    }

    private func makeDetailView(state: PacketInspectorRenderState) -> NSView {
        if state.isLoading {
            return loadingView(message: "Decoding packet...")
        }

        guard let inspection = state.inspection else {
            return TCPViewerUI.placeholder(
                title: "Detail",
                imageName: "point.3.connected.trianglepath.dotted",
                message: state.statusMessage,
                placement: .top
            )
        }

        let sections = inspection.detailNodes.map { node in
            sectionCard(
                symbol: layerSymbol(for: node.name),
                title: node.name,
                rows: detailRows(for: node.children, depth: 0, selectedNodeID: state.selectedDetailNodeID)
            )
        }
        return scrollView(for: sectionStack(sections))
    }

    private func makeRawView(state: PacketInspectorRenderState) -> NSView {
        if state.isLoading {
            return loadingView(message: "Decoding packet...")
        }

        guard let inspection = state.inspection else {
            rawOutlineView = nil
            return TCPViewerUI.placeholder(
                title: "Raw",
                imageName: "list.bullet.indent",
                message: state.statusMessage,
                placement: .top
            )
        }

        let rawOutlineView = self.rawOutlineView ?? PacketRawOutlineView(configuration: configuration)
        self.rawOutlineView = rawOutlineView
        rawOutlineView.delegate = self
        rawOutlineView.applyConfiguration(configuration)
        rawOutlineView.render(nodes: inspection.detailNodes, selectedNodeID: state.selectedDetailNodeID)
        return rawOutlineView
    }

    private func makeHexView(state: PacketInspectorRenderState) -> NSView {
        guard let inspection = state.inspection else {
            hexView = nil
            return TCPViewerUI.placeholder(
                title: "Hex",
                imageName: "binary",
                message: "Select a packet to inspect raw bytes.",
                placement: .top
            )
        }

        let hexView = self.hexView ?? PacketHexFiendView(configuration: configuration)
        self.hexView = hexView
        hexView.applyConfiguration(configuration)
        hexView.render(data: inspection.rawBytes, highlightedByteRange: state.highlightedByteRange)
        return hexView
    }

    private func scrollView(for documentView: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.documentView = documentView
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
        ])
        return scrollView
    }

    private func loadingView(message: String) -> NSView {
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.startAnimation(nil)
        let label = TCPViewerUI.label(message, font: configuration.packetFont(weight: .regular), color: .secondaryLabelColor)
        let stack = NSStackView(views: [progress, label], orientation: .vertical, spacing: 10)
        stack.alignment = .centerX
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func sectionStack(_ views: [NSView]) -> NSView {
        let container = NSView()
        let pad = InspectorTheme.Spacing.outerPadding
        var previous: NSView?
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad).isActive = true
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad).isActive = true
            if let previous {
                view.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: InspectorTheme.Spacing.cardSpacing).isActive = true
            } else {
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: pad).isActive = true
            }
            previous = view
        }
        if let last = previous {
            last.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad).isActive = true
        }
        return container
    }

    private func sectionCard(symbol: String, title: String, rows: [NSView]) -> NSView {
        let header = InspectorTheme.sectionHeader(symbol: symbol, title: title, configuration: configuration)
        header.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])

        var previous: NSView = header
        var firstRowSpacing: CGFloat = 10
        for (index, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: index == 0 ? firstRowSpacing : InspectorTheme.Spacing.rowSpacing),
            ])
            previous = row
            firstRowSpacing = InspectorTheme.Spacing.rowSpacing

            if index < rows.count - 1 {
                let divider = InspectorTheme.rowDivider()
                content.addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    divider.topAnchor.constraint(equalTo: row.bottomAnchor, constant: InspectorTheme.Spacing.rowSpacing),
                ])
                previous = divider
            }
        }

        previous.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
        return InspectorTheme.card(content: content)
    }

    private func layerSymbol(for layerName: String) -> String {
        switch layerName.uppercased() {
        case let name where name.hasPrefix("ETH"): return "cable.connector"
        case let name where name.hasPrefix("IP"): return "globe"
        case "TCP": return "arrow.left.arrow.right"
        case "UDP": return "bolt.horizontal"
        case "HTTP", "HTTPS": return "network"
        case let name where name.hasPrefix("TLS") || name.hasPrefix("SSL"): return "lock.shield"
        case "DNS": return "magnifyingglass"
        case "ICMP", "ICMPV6": return "exclamationmark.triangle"
        case "ARP": return "link"
        default: return "rectangle.stack"
        }
    }

    private func detailRows(for nodes: [PacketDetailNode], depth: Int, selectedNodeID: String?) -> [NSView] {
        nodes.flatMap { node -> [NSView] in
            [detailFieldRow(node, depth: depth, selectedNodeID: selectedNodeID)] +
                detailRows(for: node.children, depth: depth + 1, selectedNodeID: selectedNodeID)
        }
    }

    private func detailFieldRow(_ node: PacketDetailNode, depth: Int, selectedNodeID: String?) -> NSView {
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier(node.id)
        button.isBordered = false
        button.target = self
        button.action = #selector(detailNodeSelected(_:))
        button.contentTintColor = node.kind == .warning ? .systemOrange : .labelColor

        let icon = NSImageView(image: TCPViewerUI.image(node.children.isEmpty ? (node.kind == .warning ? "exclamationmark.triangle.fill" : "circle.fill") : "chevron.down") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: node.children.isEmpty ? 7 : 11, weight: .regular)
        icon.contentTintColor = node.kind == .warning ? .systemOrange : .secondaryLabelColor

        let nameLabel = TCPViewerUI.label(node.name, font: configuration.packetFont(weight: node.kind == .layer ? .semibold : .regular), color: node.kind == .warning ? .systemOrange : .labelColor)
        let valueLabel = TCPViewerUI.label(node.value ?? "", font: configuration.packetFont(sizeDelta: -1, weight: .regular), color: .secondaryLabelColor)
        valueLabel.maximumNumberOfLines = 2

        let rowContent = NSStackView(views: [icon, nameLabel, NSView(), valueLabel])
        rowContent.orientation = .horizontal
        rowContent.alignment = .centerY
        rowContent.spacing = 8
        rowContent.edgeInsets = NSEdgeInsets(top: 4, left: CGFloat(depth) * 16 + 2, bottom: 4, right: 8)
        rowContent.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true

        button.addSubview(rowContent)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = selectedNodeID == node.id ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        NSLayoutConstraint.activate([
            rowContent.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            rowContent.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            rowContent.topAnchor.constraint(equalTo: button.topAnchor),
            rowContent.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: max(28, configuration.packetRowHeight)),
        ])

        return button
    }

}

extension PacketInspectorViewController: PacketRawOutlineViewDelegate {
    func packetRawOutlineView(_ view: PacketRawOutlineView, didSelectDetailNode identifier: String?) {
        delegate?.packetInspectorViewController(self, didSelectDetailNode: identifier)
    }
}

struct PacketDetailCopyRow: Equatable {
    let depth: Int
    let name: String
    let value: String?

    init(depth: Int, name: String, value: String?) {
        self.depth = depth
        self.name = name
        self.value = value
    }

    init(node: PacketDetailNode, depth: Int) {
        self.init(depth: depth, name: node.name, value: node.value)
    }
}

enum PacketDetailCopyFormatter {
    static func text(for rows: [PacketDetailCopyRow]) -> String {
        rows.map { row in
            let indentation = String(repeating: "    ", count: max(row.depth, 0))
            guard let value = row.value, !value.isEmpty else {
                return "\(indentation)\(row.name)"
            }
            return "\(indentation)\(row.name): \(value)"
        }
        .joined(separator: "\n")
    }
}

protocol PacketRawOutlineViewDelegate: AnyObject {
    func packetRawOutlineView(_ view: PacketRawOutlineView, didSelectDetailNode identifier: String?)
}

private final class PacketRawOutlineItem: NSObject {
    let node: PacketDetailNode
    let children: [PacketRawOutlineItem]

    init(node: PacketDetailNode) {
        self.node = node
        self.children = node.children.map(PacketRawOutlineItem.init)
    }
}

private protocol PacketRawOutlineCopyHandling: AnyObject {
    func copySelectedRows()
}

private final class PacketRawOutlineTableView: NSOutlineView {
    weak var copyHandler: PacketRawOutlineCopyHandling?

    @objc func copy(_ sender: Any?) {
        copyHandler?.copySelectedRows()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return
        }

        super.keyDown(with: event)
    }
}

final class PacketRawOutlineView: NSView {
    weak var delegate: PacketRawOutlineViewDelegate?

    private var configuration: AppConfiguration
    private let outlineView = PacketRawOutlineTableView()
    private let scrollView = NSScrollView()
    private var roots: [PacketRawOutlineItem] = []
    private var currentNodes: [PacketDetailNode] = []
    private var itemByID: [String: PacketRawOutlineItem] = [:]
    private var isSyncingSelection = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupOutlineView()
        setupLayout()
    }

    override init(frame frameRect: NSRect) {
        self.configuration = AppConfiguration()
        super.init(frame: frameRect)
        setupOutlineView()
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyConfiguration(_ configuration: AppConfiguration) {
        self.configuration = configuration
        outlineView.rowHeight = configuration.packetRowHeight
        outlineView.reloadData()
    }

    // Render the decode tree and keep the selected decoded field visible.
    func render(nodes: [PacketDetailNode], selectedNodeID: String?) {
        if nodes != currentNodes {
            currentNodes = nodes
            roots = nodes.map(PacketRawOutlineItem.init)
            rebuildLookup()
            outlineView.reloadData()
            expandAll()
        }

        syncSelection(selectedNodeID: selectedNodeID)
    }

    private func setupOutlineView() {
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Field"
        nameColumn.width = 260
        nameColumn.minWidth = 160
        nameColumn.resizingMask = .userResizingMask

        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = "Value"
        valueColumn.width = 260
        valueColumn.minWidth = 120
        valueColumn.resizingMask = .autoresizingMask

        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(valueColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.headerView = nil
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.copyHandler = self
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = true
        outlineView.rowHeight = configuration.packetRowHeight
        outlineView.indentationPerLevel = 16
        outlineView.indentationMarkerFollowsCell = true
        outlineView.style = .fullWidth
        outlineView.focusRingType = .none
        outlineView.menu = makeContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
    }

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copySelectedRowsFromMenu(_:)), keyEquivalent: ""))
        menu.items.first?.target = self
        return menu
    }

    private func rebuildLookup() {
        itemByID = [:]
        for root in roots {
            register(root)
        }
    }

    private func register(_ item: PacketRawOutlineItem) {
        itemByID[item.node.id] = item
        for child in item.children {
            register(child)
        }
    }

    private func expandAll() {
        for root in roots {
            outlineView.expandItem(root, expandChildren: true)
        }
    }

    private func syncSelection(selectedNodeID: String?) {
        guard let selectedNodeID,
              let item = itemByID[selectedNodeID] else {
            if !outlineView.selectedRowIndexes.isEmpty {
                isSyncingSelection = true
                outlineView.deselectAll(nil)
                isSyncingSelection = false
            }
            return
        }

        let row = outlineView.row(forItem: item)
        guard row >= 0, !outlineView.selectedRowIndexes.contains(row) else {
            return
        }

        isSyncingSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        isSyncingSelection = false
    }

    @objc private func copySelectedRowsFromMenu(_ sender: Any?) {
        copySelectedRows()
    }

    private func item(for item: Any?) -> PacketRawOutlineItem? {
        item as? PacketRawOutlineItem
    }
}

extension PacketRawOutlineView: PacketRawOutlineCopyHandling {
    func copySelectedRows() {
        let rows = outlineView.selectedRowIndexes.compactMap { row -> PacketDetailCopyRow? in
            guard let item = outlineView.item(atRow: row) as? PacketRawOutlineItem else {
                return nil
            }
            return PacketDetailCopyRow(node: item.node, depth: outlineView.level(forRow: row))
        }

        let copyText = PacketDetailCopyFormatter.text(for: rows)
        guard !copyText.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }
}

extension PacketRawOutlineView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        self.item(for: item)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = self.item(for: item)?.children ?? roots
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        self.item(for: item)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let outlineItem = item as? PacketRawOutlineItem else {
            return nil
        }

        let identifier = tableColumn?.identifier.rawValue == "value"
            ? PacketRawOutlineTextCell.valueReuseIdentifier
            : PacketRawOutlineTextCell.nameReuseIdentifier
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? PacketRawOutlineTextCell ??
            PacketRawOutlineTextCell(frame: .zero)
        cell.identifier = identifier
        cell.render(
            text: tableColumn?.identifier.rawValue == "value" ? (outlineItem.node.value ?? "") : outlineItem.node.name,
            kind: outlineItem.node.kind,
            isValue: tableColumn?.identifier.rawValue == "value",
            configuration: configuration
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else {
            return
        }

        let firstSelectedRow = outlineView.selectedRowIndexes.first
        let selectedItem = firstSelectedRow.flatMap { outlineView.item(atRow: $0) as? PacketRawOutlineItem }
        delegate?.packetRawOutlineView(self, didSelectDetailNode: selectedItem?.node.id)
    }
}

private final class PacketRawOutlineTextCell: NSTableCellView {
    static let nameReuseIdentifier = NSUserInterfaceItemIdentifier("PacketRawOutlineNameCell")
    static let valueReuseIdentifier = NSUserInterfaceItemIdentifier("PacketRawOutlineValueCell")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(text: String, kind: PacketDetailNodeKind, isValue: Bool, configuration: AppConfiguration) {
        label.stringValue = text
        label.font = isValue
            ? configuration.packetFont(sizeDelta: -1, weight: .regular)
            : configuration.packetFont(weight: kind == .layer ? .semibold : .regular)
        label.textColor = kind == .warning ? .systemOrange : (isValue ? .secondaryLabelColor : .labelColor)
    }

    private func setupLayout() {
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
