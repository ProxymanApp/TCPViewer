import AppKit
import PcapPlusPlusCore

protocol PacketInspectorViewControllerDelegate: AnyObject {
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelect tab: PacketInspectorTab)
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?)
}

final class PacketInspectorViewController: NSViewController {
    weak var delegate: PacketInspectorViewControllerDelegate?

    private let configuration: AppConfiguration
    private let viewModel = PacketInspectorPanelViewModel()

    private let header: InspectorHeaderView
    private let protocolStack: InspectorProtocolStackView
    private let tabBar = InspectorTabBar()
    private let contentContainer = NSView()
    private let placeholderContainer = NSView()

    private let overviewTab: OverviewTabViewController
    private let fieldsTab: FieldsTabViewController
    private let rawTab: RawTabViewController

    private var currentTabVC: NSViewController?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.header = InspectorHeaderView(configuration: configuration)
        self.protocolStack = InspectorProtocolStackView(configuration: configuration)
        self.overviewTab = OverviewTabViewController(configuration: configuration)
        self.fieldsTab = FieldsTabViewController(configuration: configuration)
        self.rawTab = RawTabViewController(configuration: configuration)
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
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = InspectorTheme.Palette.panelBackground.cgColor

        header.translatesAutoresizingMaskIntoConstraints = false
        protocolStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        placeholderContainer.translatesAutoresizingMaskIntoConstraints = false

        protocolStack.delegate = self
        tabBar.delegate = self
        fieldsTab.delegate = self

        root.addSubview(header)
        root.addSubview(protocolStack)
        root.addSubview(tabBar)
        root.addSubview(contentContainer)
        root.addSubview(placeholderContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            protocolStack.topAnchor.constraint(equalTo: header.bottomAnchor),
            protocolStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            protocolStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            tabBar.topAnchor.constraint(equalTo: protocolStack.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            placeholderContainer.topAnchor.constraint(equalTo: header.topAnchor),
            placeholderContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            placeholderContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            placeholderContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        let didChange = viewModel.render(snapshot: snapshot)
        guard didChange || currentTabVC == nil else { return }

        let state = viewModel.state
        renderTopChrome(state: state)
        renderContent(state: state)
    }

    // MARK: - Top chrome

    private func renderTopChrome(state: PacketInspectorRenderState) {
        let hasPacket = state.selectedPacket != nil
        header.isHidden = !hasPacket
        protocolStack.isHidden = !hasPacket
        tabBar.isHidden = !hasPacket
        contentContainer.isHidden = !hasPacket

        if hasPacket {
            header.applyConfiguration(configuration)
            header.render(packet: state.selectedPacket, inspection: state.inspection)
            protocolStack.applyConfiguration(configuration)
            let layerNodes = state.inspection?.detailNodes ?? []
            protocolStack.render(layerNodes: layerNodes, selectedLayerNodeID: selectedLayerID(state: state, layerNodes: layerNodes))
            tabBar.setSelected(state.inspectorTab)
            placeholderContainer.subviews.forEach { $0.removeFromSuperview() }
            placeholderContainer.isHidden = true
        } else {
            placeholderContainer.subviews.forEach { $0.removeFromSuperview() }
            placeholderContainer.isHidden = false
            let placeholder = TCPViewerUI.placeholder(
                title: "No Packet Selected",
                imageName: "sidebar.trailing",
                message: state.statusMessage,
                placement: .center
            )
            TCPViewerUI.pin(placeholder, to: placeholderContainer)
        }
    }

    private func selectedLayerID(state: PacketInspectorRenderState, layerNodes: [PacketDetailNode]) -> String? {
        guard let selected = state.selectedDetailNodeID else { return nil }
        // Walk roots to find which layer's subtree contains the selected node id.
        for layer in layerNodes where layer.kind == .layer {
            if contains(node: layer, id: selected) {
                return layer.id
            }
        }
        return nil
    }

    private func contains(node: PacketDetailNode, id: String) -> Bool {
        if node.id == id { return true }
        for child in node.children {
            if contains(node: child, id: id) { return true }
        }
        return false
    }

    // MARK: - Content

    private func renderContent(state: PacketInspectorRenderState) {
        guard state.selectedPacket != nil else {
            removeCurrentTab()
            return
        }

        let nextTab: NSViewController
        switch state.inspectorTab {
        case .overview:
            overviewTab.applyConfiguration(configuration)
            overviewTab.render(state: state)
            nextTab = overviewTab
        case .fields:
            fieldsTab.applyConfiguration(configuration)
            fieldsTab.render(state: state)
            nextTab = fieldsTab
        case .raw:
            rawTab.applyConfiguration(configuration)
            rawTab.render(state: state)
            nextTab = rawTab
        }

        if currentTabVC !== nextTab {
            removeCurrentTab()
            addChild(nextTab)
            nextTab.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(nextTab.view)
            NSLayoutConstraint.activate([
                nextTab.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                nextTab.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                nextTab.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                nextTab.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            ])
            currentTabVC = nextTab
        }
    }

    private func removeCurrentTab() {
        guard let current = currentTabVC else { return }
        current.view.removeFromSuperview()
        current.removeFromParent()
        currentTabVC = nil
    }

    @objc private func appConfigurationDidChange(_ notification: Notification) {
        guard isViewLoaded else { return }
        renderContent(state: viewModel.state)
        renderTopChrome(state: viewModel.state)
    }
}

// MARK: - Child delegates

extension PacketInspectorViewController: InspectorTabBarDelegate {
    func inspectorTabBar(_ bar: InspectorTabBar, didSelect tab: PacketInspectorTab) {
        delegate?.packetInspectorViewController(self, didSelect: tab)
    }
}

extension PacketInspectorViewController: InspectorProtocolStackViewDelegate {
    func protocolStackView(_ view: InspectorProtocolStackView, didSelectLayerNodeID identifier: String) {
        // Switch to Fields tab so the user sees what they clicked.
        if viewModel.state.inspectorTab != .fields {
            delegate?.packetInspectorViewController(self, didSelect: .fields)
        }
        delegate?.packetInspectorViewController(self, didSelectDetailNode: identifier)
    }
}

extension PacketInspectorViewController: FieldsTabViewControllerDelegate {
    func fieldsTab(_ controller: FieldsTabViewController, didSelectNodeID nodeID: String?) {
        delegate?.packetInspectorViewController(self, didSelectDetailNode: nodeID)
    }

    func fieldsTabRequestsReveal(_ controller: FieldsTabViewController, nodeID: String) {
        delegate?.packetInspectorViewController(self, didSelectDetailNode: nodeID)
        delegate?.packetInspectorViewController(self, didSelect: .raw)
    }
}
