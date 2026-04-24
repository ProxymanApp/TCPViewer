import AppKit
import PcapPlusPlusCore

protocol PacketmanRootViewControllerDelegate: AnyObject {
    func packetmanRootViewControllerDidChangeToolbarState(_ controller: PacketmanRootViewController)
    func packetmanRootViewController(_ controller: PacketmanRootViewController, didRequestHelperOnboarding snapshot: PacketryNetworkHelperToolSnapshot)
}

final class PacketmanRootViewController: NSViewController {
    weak var delegate: PacketmanRootViewControllerDelegate?

    let viewModel: NetworkInspectorViewModel

    private let splitViewController = NSSplitViewController()
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
        splitViewController.toggleInspector(nil)
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

    func relaunchPacketman() {
        viewModel.relaunchPacketry()
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

        addChild(splitViewController)
        addChild(statusStripViewController)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        let workspaceItem = NSSplitViewItem(viewController: workspaceViewController)
        workspaceItem.minimumThickness = 620
        splitViewController.addSplitViewItem(workspaceItem)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorViewController)
        inspectorItem.minimumThickness = 320
        inspectorItem.maximumThickness = 460
        inspectorItem.canCollapse = true
        splitViewController.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem
    }

    private func setupLayout() {
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        statusStripViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitViewController.view)
        view.addSubview(statusStripViewController.view)

        NSLayoutConstraint.activate([
            splitViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitViewController.view.bottomAnchor.constraint(equalTo: statusStripViewController.view.topAnchor),

            statusStripViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusStripViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusStripViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func render() {
        let snapshot = viewModel.snapshot
        sidebarViewController.render(snapshot: snapshot)
        workspaceViewController.render(snapshot: snapshot)
        inspectorViewController.render(snapshot: snapshot)
        statusStripViewController.render(snapshot: snapshot)
        inspectorItem?.isCollapsed = !snapshot.isInspectorVisible
        delegate?.packetmanRootViewControllerDidChangeToolbarState(self)

        if viewModel.shouldPresentNetworkHelperOnboarding && !hasRenderedHelperOnboarding {
            hasRenderedHelperOnboarding = true
            delegate?.packetmanRootViewController(self, didRequestHelperOnboarding: viewModel.networkHelperToolSnapshot)
        }
    }
}

extension PacketmanRootViewController: NetworkInspectorViewModelDelegate {
    func networkInspectorViewModelDidChange(_ viewModel: NetworkInspectorViewModel) {
        render()
    }
}

extension PacketmanRootViewController: SidebarViewControllerDelegate {
    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?) {
        viewModel.selectSourceList(selection)
    }

    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String) {
        viewModel.updateSourceListFilterText(text)
    }
}

extension PacketmanRootViewController: PacketWorkspaceViewControllerDelegate {
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didSelectPacket identifier: PacketSummary.ID?) {
        viewModel.selectPacket(identifier)
    }
}

extension PacketmanRootViewController: PacketInspectorViewControllerDelegate {
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelect tab: PacketInspectorTab) {
        viewModel.selectInspectorTab(tab)
    }

    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?) {
        viewModel.selectDetailNode(identifier)
    }
}

extension PacketmanRootViewController: StatusStripViewControllerDelegate {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController) {
        cancelDocumentLoading()
    }
}
