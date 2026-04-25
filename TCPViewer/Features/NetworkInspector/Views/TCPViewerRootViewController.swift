import AppKit
import PcapPlusPlusCore

protocol TCPViewerRootViewControllerDelegate: AnyObject {
    func tcpviewerRootViewControllerDidChangeToolbarState(_ controller: TCPViewerRootViewController)
    func tcpviewerRootViewController(_ controller: TCPViewerRootViewController, didRequestHelperOnboarding snapshot: TCPViewerNetworkHelperToolSnapshot)
}

final class TCPViewerRootViewController: NSViewController {
    weak var delegate: TCPViewerRootViewControllerDelegate?

    let viewModel: NetworkInspectorViewModel

    private let outerSplitViewController = NSSplitViewController()
    private let innerSplitViewController = NSSplitViewController()
    private let rightPaneViewController = NSViewController()
    private let sidebarViewController = SidebarViewController()
    private let workspaceViewController = PacketWorkspaceViewController()
    private let inspectorViewController = PacketInspectorViewController()
    private let statusStripViewController = StatusStripViewController()
    private var inspectorItem: NSSplitViewItem?
    private var hasRenderedHelperOnboarding = false

    init(viewModel: NetworkInspectorViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        self.viewModel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        setupChildControllers()
        setupLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        viewModel.performInitialLoadIfNeeded()
    }

    func openDocument(at url: URL) {
        viewModel.openDocument(at: url)
    }

    func toggleLiveCapture() {
        viewModel.toggleLiveCapture()
    }

    func saveDocument() {
        viewModel.saveDocument()
    }

    func exportDocument(format: CaptureFileFormat) {
        viewModel.presentSaveCapturePanel(format: format)
    }

    func cancelDocumentLoading() {
        viewModel.cancelDocumentLoading()
    }

    func selectInterface(_ identifier: String) {
        viewModel.selectInterface(identifier)
    }

    func toggleInspector() {
        innerSplitViewController.toggleInspector(nil)
        if let inspectorItem {
            viewModel.setInspectorVisible(!inspectorItem.isCollapsed)
        } else {
            viewModel.toggleInspector()
        }
    }

    func showOpenPanel() {
        viewModel.presentOpenCapturePanel()
    }

    func installNetworkHelperTool() {
        viewModel.installNetworkHelperTool()
    }

    func repairNetworkHelperTool() {
        viewModel.repairNetworkHelperTool()
    }

    func retryNetworkHelperToolStatus() {
        viewModel.retryNetworkHelperToolStatus()
    }

    func openNetworkHelperSystemSettings() {
        viewModel.openNetworkHelperSystemSettings()
    }

    func relaunchTCPViewer() {
        viewModel.relaunchTCPViewer()
    }

    func dismissNetworkHelperOnboarding() {
        hasRenderedHelperOnboarding = true
        viewModel.dismissNetworkHelperOnboarding()
    }

    private func setupChildControllers() {
        sidebarViewController.delegate = self
        workspaceViewController.delegate = self
        inspectorViewController.delegate = self
        statusStripViewController.delegate = self

        // Inner split (workspace | inspector) lives inside the right pane so the
        // bottom status strip only spans content + inspector, not the sidebar.
        let workspaceItem = NSSplitViewItem(viewController: workspaceViewController)
        workspaceItem.minimumThickness = 620
        innerSplitViewController.addSplitViewItem(workspaceItem)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorViewController)
        inspectorItem.minimumThickness = 320
        inspectorItem.maximumThickness = 460
        inspectorItem.canCollapse = true
        innerSplitViewController.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem

        rightPaneViewController.view = NSView()
        rightPaneViewController.addChild(innerSplitViewController)
        rightPaneViewController.addChild(statusStripViewController)

        let rightPane = rightPaneViewController.view
        innerSplitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        statusStripViewController.view.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(innerSplitViewController.view)
        rightPane.addSubview(statusStripViewController.view)

        NSLayoutConstraint.activate([
            innerSplitViewController.view.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            innerSplitViewController.view.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            innerSplitViewController.view.topAnchor.constraint(equalTo: rightPane.topAnchor),
            innerSplitViewController.view.bottomAnchor.constraint(equalTo: statusStripViewController.view.topAnchor),

            statusStripViewController.view.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            statusStripViewController.view.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            statusStripViewController.view.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        addChild(outerSplitViewController)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        outerSplitViewController.addSplitViewItem(sidebarItem)

        let rightPaneItem = NSSplitViewItem(viewController: rightPaneViewController)
        rightPaneItem.minimumThickness = 620
        outerSplitViewController.addSplitViewItem(rightPaneItem)
    }

    private func setupLayout() {
        outerSplitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outerSplitViewController.view)

        NSLayoutConstraint.activate([
            outerSplitViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outerSplitViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outerSplitViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            outerSplitViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func render() {
        let snapshot = viewModel.snapshot
        sidebarViewController.render(snapshot: snapshot)
        workspaceViewController.render(snapshot: snapshot)
        inspectorViewController.render(snapshot: snapshot)
        statusStripViewController.render(snapshot: snapshot)
        inspectorItem?.isCollapsed = !snapshot.isInspectorVisible
        delegate?.tcpviewerRootViewControllerDidChangeToolbarState(self)

        if viewModel.shouldPresentNetworkHelperOnboarding && !hasRenderedHelperOnboarding {
            hasRenderedHelperOnboarding = true
            delegate?.tcpviewerRootViewController(self, didRequestHelperOnboarding: viewModel.networkHelperToolSnapshot)
        }
    }
}

extension TCPViewerRootViewController: NetworkInspectorViewModelDelegate {
    func networkInspectorViewModelDidChange(_ viewModel: NetworkInspectorViewModel) {
        render()
    }
}

extension TCPViewerRootViewController: SidebarViewControllerDelegate {
    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?) {
        viewModel.selectSourceList(selection)
    }

    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String) {
        viewModel.updateSourceListFilterText(text)
    }
}

extension TCPViewerRootViewController: PacketWorkspaceViewControllerDelegate {
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didSelectPacket identifier: PacketSummary.ID?) {
        viewModel.selectPacket(identifier)
    }
}

extension TCPViewerRootViewController: PacketInspectorViewControllerDelegate {
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelect tab: PacketInspectorTab) {
        viewModel.selectInspectorTab(tab)
    }

    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?) {
        viewModel.selectDetailNode(identifier)
    }
}

extension TCPViewerRootViewController: StatusStripViewControllerDelegate {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController) {
        cancelDocumentLoading()
    }

    func statusStripViewControllerDidRequestClearPackets(_ controller: StatusStripViewController) {
        viewModel.clearPackets()
    }
}
