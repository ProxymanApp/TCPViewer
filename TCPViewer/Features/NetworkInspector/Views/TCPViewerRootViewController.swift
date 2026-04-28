import AppKit
import PcapPlusPlusCore

protocol TCPViewerRootViewControllerDelegate: AnyObject {
    func tcpviewerRootViewControllerDidChangeToolbarState(_ controller: TCPViewerRootViewController)
    func tcpviewerRootViewController(_ controller: TCPViewerRootViewController, didRequestHelperOnboarding snapshot: TCPViewerNetworkHelperToolSnapshot)
}

final class TCPViewerRootViewController: NSViewController {
    weak var delegate: TCPViewerRootViewControllerDelegate?

    let viewModel: NetworkInspectorViewModel

    private let mainSplitViewController = NSSplitViewController()
    private let contentSplitViewController = NSSplitViewController()
    private let mainContainerViewController = NSViewController()
    private let sidebarViewController = SidebarViewController()
    private let workspaceViewController: PacketWorkspaceViewController
    private let inspectorViewController: PacketInspectorViewController
    private let statusStripViewController = StatusStripViewController()
    private var inspectorItem: NSSplitViewItem?
    private var hasRenderedHelperOnboarding = false

    init(viewModel: NetworkInspectorViewModel, configuration: AppConfiguration) {
        self.viewModel = viewModel
        self.workspaceViewController = PacketWorkspaceViewController(configuration: configuration)
        self.inspectorViewController = PacketInspectorViewController(configuration: configuration)
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

    func clearAllPackets() {
        viewModel.clearPackets()
    }

    func saveDocument() {
        viewModel.saveDocument()
    }

    func exportDocument(format: CaptureFileFormat) {
        viewModel.presentSaveCapturePanel(format: format)
    }

    func exportSession(format: CaptureFileFormat) {
        viewModel.presentSessionExportPanel(format: format, attachedTo: view.window)
    }

    func cancelDocumentLoading() {
        viewModel.cancelDocumentLoading()
    }

    func selectInterface(_ identifier: String) {
        viewModel.selectInterface(identifier)
    }

    func toggleInspector() {
        contentSplitViewController.toggleInspector(nil)
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
        // Build the two-level split layout: sidebar | (table | inspector).
        sidebarViewController.delegate = self
        workspaceViewController.delegate = self
        statusStripViewController.delegate = self

        mainSplitViewController.splitView.isVertical = true
        contentSplitViewController.splitView.isVertical = true

        // Keep the table and inspector inside the main container split.
        let workspaceItem = NSSplitViewItem(viewController: workspaceViewController)
        workspaceItem.minimumThickness = 620
        contentSplitViewController.addSplitViewItem(workspaceItem)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorViewController)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 720
        inspectorItem.canCollapse = true
        contentSplitViewController.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem

        mainContainerViewController.view = NSView()
        mainContainerViewController.addChild(contentSplitViewController)
        mainContainerViewController.addChild(statusStripViewController)

        let mainContainerView = mainContainerViewController.view
        contentSplitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        statusStripViewController.view.translatesAutoresizingMaskIntoConstraints = false
        mainContainerView.addSubview(contentSplitViewController.view)
        mainContainerView.addSubview(statusStripViewController.view)

        NSLayoutConstraint.activate([
            contentSplitViewController.view.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor),
            contentSplitViewController.view.trailingAnchor.constraint(equalTo: mainContainerView.trailingAnchor),
            contentSplitViewController.view.topAnchor.constraint(equalTo: mainContainerView.topAnchor),
            contentSplitViewController.view.bottomAnchor.constraint(equalTo: statusStripViewController.view.topAnchor),

            statusStripViewController.view.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor),
            statusStripViewController.view.trailingAnchor.constraint(equalTo: mainContainerView.trailingAnchor),
            statusStripViewController.view.bottomAnchor.constraint(equalTo: mainContainerView.bottomAnchor),
        ])

        addChild(mainSplitViewController)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        mainSplitViewController.addSplitViewItem(sidebarItem)

        let mainContainerItem = NSSplitViewItem(viewController: mainContainerViewController)
        mainContainerItem.minimumThickness = 620
        mainSplitViewController.addSplitViewItem(mainContainerItem)
    }

    private func setupLayout() {
        // Pin the main split controller to the root view.
        mainSplitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainSplitViewController.view)

        NSLayoutConstraint.activate([
            mainSplitViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainSplitViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainSplitViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            mainSplitViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

    func sidebarViewController(_ controller: SidebarViewController, didRequestDelete action: PacketSourceListDeletionAction) {
        viewModel.deleteSourceListItem(action)
    }

    func sidebarViewController(_ controller: SidebarViewController, didRequestExport selection: PacketSourceListSelection, format: CaptureFileFormat) {
        viewModel.presentSourceListExportPanel(selection: selection, format: format, attachedTo: view.window)
    }
}

extension TCPViewerRootViewController: PacketWorkspaceViewControllerDelegate {
    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didSelectPacket identifier: PacketSummary.ID?) {
        viewModel.selectPacket(identifier)
    }

    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestPin kind: PacketPinCreationKind,
        packetID: PacketSummary.ID,
        clickedColumn: PacketTableColumnRole
    ) {
        viewModel.pinPacket(packetID, kind: kind, clickedColumn: clickedColumn)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestSavePackets identifiers: [PacketSummary.ID]) {
        viewModel.savePackets(identifiers)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat) {
        viewModel.presentPacketExportPanel(identifiers: identifiers, format: format, attachedTo: view.window)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestDeletePackets identifiers: [PacketSummary.ID]) {
        viewModel.deletePackets(identifiers)
    }
}

extension TCPViewerRootViewController: StatusStripViewControllerDelegate {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController) {
        cancelDocumentLoading()
    }

    func statusStripViewControllerDidRequestClearPackets(_ controller: StatusStripViewController) {
        viewModel.clearTablePackets()
    }
}
