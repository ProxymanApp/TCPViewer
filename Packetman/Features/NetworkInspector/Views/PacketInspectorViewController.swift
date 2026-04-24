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
        inspectorTab: .overview,
        isInspectorVisible: true,
        displayFilterText: "",
        packetTableContent: .empty
    ))

    // Extract inspector-only state so the controller can render without touching root state.
    func render(snapshot: NetworkInspectorSnapshot) {
        state = PacketInspectorRenderState(snapshot: snapshot)
    }
}

final class PacketInspectorViewController: NSViewController {
    weak var delegate: PacketInspectorViewControllerDelegate?

    private let viewModel = PacketInspectorPanelViewModel()
    private let tabControl = NSSegmentedControl(labels: PacketInspectorTab.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let contentContainer = NSView()
    private var currentContentView: NSView?
    private var hexView: PacketHexFiendView?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupHeader()
        setupContentContainer()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        viewModel.render(snapshot: snapshot)
        let state = viewModel.state
        tabControl.selectedSegment = PacketInspectorTab.allCases.firstIndex(of: state.inspectorTab) ?? 0
        renderContent(state: state)
    }

    private func setupHeader() {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        tabControl.segmentStyle = .rounded
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(tabControl)

        let separator = PacketmanUI.separator()
        header.addSubview(separator)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            tabControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            tabControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            tabControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
    }

    private func setupContentContainer() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 44),
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

    private func renderContent(state: PacketInspectorRenderState) {
        switch state.inspectorTab {
        case .overview:
            replaceContent(makeOverviewView(state: state))
        case .layers:
            replaceContent(makeLayersView(state: state))
        case .hex:
            replaceContent(makeHexView(state: state))
        case .stream:
            replaceContent(makeStreamView(state: state))
        case .notes:
            replaceContent(makeNotesView(state: state))
        }
    }

    private func replaceContent(_ newView: NSView) {
        currentContentView?.removeFromSuperview()
        currentContentView = newView
        PacketmanUI.pin(newView, to: contentContainer)
    }

    private func makeOverviewView(state: PacketInspectorRenderState) -> NSView {
        guard let packet = state.selectedPacket else {
            return PacketmanUI.placeholder(
                title: "No Packet Selected",
                imageName: "sidebar.trailing",
                message: state.statusMessage,
                placement: .top
            )
        }

        return scrollView(for: sectionStack([
            section("Summary", rows: [
                keyValue("Packet", "\(packet.packetNumber)"),
                keyValue("Length", NetworkInspectorFormatters.byteCount(packet.capturedLength)),
                keyValue("Protocol", NetworkInspectorFormatters.protocolLabel(for: packet)),
                keyValue("Status", NetworkInspectorFormatters.severity(for: packet).label),
            ]),
            section("Source", rows: [
                keyValue("Endpoint", NetworkInspectorFormatters.endpointLabel(packet.endpoints.source)),
                keyValue("Interface", packet.captureMetadata.interfaceName ?? packet.interfaceID ?? "-"),
            ]),
            section("Destination", rows: [
                keyValue("Endpoint", NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination)),
            ]),
            section("Timing", rows: [
                keyValue("Captured", NetworkInspectorFormatters.packetTime.string(from: packet.timestamp)),
            ]),
        ]))
    }

    private func makeLayersView(state: PacketInspectorRenderState) -> NSView {
        if state.isLoading {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.startAnimation(nil)
            let label = PacketmanUI.label("Decoding packet...", font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
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

        guard let inspection = state.inspection else {
            return PacketmanUI.placeholder(
                title: "Layers",
                imageName: "point.3.connected.trianglepath.dotted",
                message: state.statusMessage,
                placement: .top
            )
        }

        let rows = inspection.detailNodes.map { detailRow($0, depth: 0, selectedNodeID: state.selectedDetailNodeID) }
        return scrollView(for: sectionStack(rows, spacing: 2, edgeInsets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)))
    }

    private func makeHexView(state: PacketInspectorRenderState) -> NSView {
        guard let inspection = state.inspection else {
            hexView = nil
            return PacketmanUI.placeholder(
                title: "Hex",
                imageName: "binary",
                message: "Select a packet to inspect raw bytes.",
                placement: .top
            )
        }

        let hexView = self.hexView ?? PacketHexFiendView()
        self.hexView = hexView
        hexView.render(data: inspection.rawBytes, highlightedByteRange: state.highlightedByteRange)
        return hexView
    }

    private func makeStreamView(state: PacketInspectorRenderState) -> NSView {
        guard let packet = state.selectedPacket else {
            return PacketmanUI.placeholder(
                title: "Stream",
                imageName: "arrow.left.arrow.right",
                message: "Select a packet to inspect stream context.",
                placement: .top
            )
        }

        return scrollView(for: sectionStack([
            section("Stream", rows: [
                keyValue("Stream ID", packet.streamID.map(String.init) ?? "-"),
                keyValue("Protocol", NetworkInspectorFormatters.protocolLabel(for: packet)),
            ]),
            note("Follow-stream workflows are prepared for a future pass."),
        ]))
    }

    private func makeNotesView(state: PacketInspectorRenderState) -> NSView {
        guard let packet = state.selectedPacket else {
            return PacketmanUI.placeholder(
                title: "Notes",
                imageName: "note.text",
                message: "Select a packet to view capture comments.",
                placement: .top
            )
        }

        return scrollView(for: sectionStack([
            section("Notes", rows: [
                keyValue("Packet Comment", packet.captureMetadata.packetComment ?? "-"),
                keyValue("Decode Reason", packet.decodeStatus.reason ?? "-"),
            ]),
            note("Editable packet notes are prepared for a future session/profile pass."),
        ]))
    }

    private func scrollView(for documentView: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
        ])
        return scrollView
    }

    private func sectionStack(_ views: [NSView], spacing: CGFloat = 18, edgeInsets: NSEdgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = edgeInsets
        return stack
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let titleLabel = PacketmanUI.label(title.uppercased(), font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
        let rowsStack = NSStackView(views: rows)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        let stack = NSStackView(views: [titleLabel, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func keyValue(_ key: String, _ value: String) -> NSView {
        let keyLabel = PacketmanUI.label(key, font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
        let valueLabel = PacketmanUI.label(value, font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
        valueLabel.maximumNumberOfLines = 2
        valueLabel.isSelectable = true

        let row = NSStackView(views: [keyLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        keyLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true
        return row
    }

    private func note(_ text: String) -> NSView {
        let label = PacketmanUI.label(text, font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
        label.maximumNumberOfLines = 3
        return label
    }

    private func detailRow(_ node: PacketDetailNode, depth: Int, selectedNodeID: String?) -> NSView {
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier(node.id)
        button.isBordered = false
        button.target = self
        button.action = #selector(detailNodeSelected(_:))
        button.contentTintColor = node.kind == .warning ? .systemOrange : .labelColor

        let icon = NSImageView(image: PacketmanUI.image(node.children.isEmpty ? (node.kind == .warning ? "exclamationmark.triangle.fill" : "circle.fill") : "chevron.down") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: node.children.isEmpty ? 7 : 11, weight: .regular)
        icon.contentTintColor = node.kind == .warning ? .systemOrange : .secondaryLabelColor

        let nameLabel = PacketmanUI.label(node.name, font: .systemFont(ofSize: NSFont.systemFontSize, weight: node.kind == .layer ? .semibold : .regular), color: node.kind == .warning ? .systemOrange : .labelColor)
        let valueLabel = PacketmanUI.label(node.value ?? "", font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), color: .secondaryLabelColor)

        let rowContent = NSStackView(views: [icon, nameLabel, NSView(), valueLabel])
        rowContent.orientation = .horizontal
        rowContent.alignment = .centerY
        rowContent.spacing = 8
        rowContent.edgeInsets = NSEdgeInsets(top: 5, left: CGFloat(depth) * 16 + 8, bottom: 5, right: 8)
        rowContent.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true

        button.addSubview(rowContent)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = selectedNodeID == node.id ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
        NSLayoutConstraint.activate([
            rowContent.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            rowContent.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            rowContent.topAnchor.constraint(equalTo: button.topAnchor),
            rowContent.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        let childRows = node.children.map { detailRow($0, depth: depth + 1, selectedNodeID: selectedNodeID) }
        guard !childRows.isEmpty else {
            return button
        }

        let stack = NSStackView(views: [button] + childRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }
}
