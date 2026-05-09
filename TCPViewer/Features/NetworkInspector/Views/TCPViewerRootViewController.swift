//
//  TCPViewerRootViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import PcapPlusPlusCore

protocol TCPViewerRootViewControllerDelegate: AnyObject {
    func tcpviewerRootViewControllerDidChangeToolbarState(_ controller: TCPViewerRootViewController)
    func tcpviewerRootViewController(_ controller: TCPViewerRootViewController, didRequestHelperOnboarding snapshot: TCPViewerNetworkHelperToolSnapshot)
    func tcpviewerRootViewControllerDidRequestPaywall(_ controller: TCPViewerRootViewController)
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
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var appliedInspectorVisibility: Bool?
    private var needsSidebarDividerRefresh = false
    private var hasRenderedHelperOnboarding = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

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
        configureSplitViewObservation()
        applyPersistedSidebarLayout()
        render()
        viewModel.performInitialLoadIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if needsSidebarDividerRefresh, sidebarItem?.isCollapsed == false {
            needsSidebarDividerRefresh = false
            applySidebarDividerPosition()
        }
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
        viewModel.toggleInspector()
    }

    func toggleQuickFilter(_ filterID: PacketQuickFilterID) {
        viewModel.toggleQuickFilter(filterID)
    }

    func resetQuickFilters() {
        viewModel.resetQuickFilters()
    }

    func focusStructuredFilter() {
        viewModel.setStructuredFilterVisible(true)
        workspaceViewController.focusStructuredFilter()
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

    @objc func toggleSidebar(_ sender: Any?) {
        // Mirror AppKit's toggleSidebar action while keeping the split state persisted in our model.
        setSidebarVisible(sidebarItem?.isCollapsed ?? false)
    }

    private func setupChildControllers() {
        // Build the two-level split layout: sidebar | (table | inspector).
        sidebarViewController.delegate = self
        workspaceViewController.delegate = self
        inspectorViewController.delegate = self
        statusStripViewController.delegate = self

        mainSplitViewController.splitView.isVertical = true
        contentSplitViewController.splitView.isVertical = true

        // Keep the table and inspector inside the main container split.
        let workspaceItem = NSSplitViewItem(contentListWithViewController: workspaceViewController)
        contentSplitViewController.addSplitViewItem(workspaceItem)

        let inspectorItem = NSSplitViewItem(viewController: inspectorViewController)
        inspectorItem.canCollapse = true
        inspectorItem.allowsFullHeightLayout = false
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
        sidebarItem.canCollapse = true
        mainSplitViewController.addSplitViewItem(sidebarItem)
        self.sidebarItem = sidebarItem

        let mainContainerItem = NSSplitViewItem(viewController: mainContainerViewController)
        mainContainerItem.allowsFullHeightLayout = false
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
        applyInspectorLayout(snapshot)
        delegate?.tcpviewerRootViewControllerDidChangeToolbarState(self)

        if viewModel.shouldPresentNetworkHelperOnboarding && !hasRenderedHelperOnboarding {
            hasRenderedHelperOnboarding = true
            delegate?.tcpviewerRootViewController(self, didRequestHelperOnboarding: viewModel.networkHelperToolSnapshot)
        }
    }

    // Restore the last sidebar state early so AppKit lays out the window with the expected split.
    private func applyPersistedSidebarLayout() {
        setSidebarVisible(viewModel.prefersSidebarVisibleOnLaunch(), persistPreference: false)
    }

    // Collapse or expand the leading sidebar and restore its last saved width when it reopens.
    private func setSidebarVisible(_ isVisible: Bool, persistPreference: Bool = true) {
        if !isVisible {
            persistCurrentSidebarThicknessIfVisible()
        }

        sidebarItem?.isCollapsed = !isVisible
        if persistPreference {
            viewModel.setSidebarVisible(isVisible)
        }

        if isVisible {
            applySidebarDividerPosition()
        }
    }

    // Reapply the saved leading divider position once the split view has a real width.
    private func applySidebarDividerPosition() {
        let splitView = mainSplitViewController.splitView
        guard splitView.subviews.count == 2 else {
            return
        }

        splitView.layoutSubtreeIfNeeded()
        let totalLength = splitView.bounds.width
        guard totalLength > 0 else {
            needsSidebarDividerRefresh = true
            return
        }

        guard let sidebarThickness = viewModel.preferredSidebarThickness(for: totalLength) else {
            return
        }

        splitView.setPosition(sidebarThickness, ofDividerAt: 0)
    }

    // Keep the inspector in the right-side split item and only update collapse state when needed.
    private func applyInspectorLayout(_ snapshot: NetworkInspectorSnapshot) {
        let visibilityChanged = appliedInspectorVisibility != snapshot.isInspectorVisible

        contentSplitViewController.splitView.isVertical = true
        if visibilityChanged {
            inspectorItem?.isCollapsed = !snapshot.isInspectorVisible
        }

        appliedInspectorVisibility = snapshot.isInspectorVisible
    }

    private func configureSplitViewObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainSplitViewDidResizeSubviews(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: mainSplitViewController.splitView
        )
    }

    @objc private func mainSplitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === mainSplitViewController.splitView else {
            return
        }

        persistCurrentSidebarLayout()
    }

    // Persist the leading split state after manual drags and AppKit-driven collapses.
    private func persistCurrentSidebarLayout() {
        let isVisible = sidebarItem?.isCollapsed == false
        viewModel.setSidebarVisible(isVisible)
        persistCurrentSidebarThicknessIfVisible()
    }

    // Persist only visible sidebar sizes so collapsing the pane never stores a broken zero value.
    private func persistCurrentSidebarThicknessIfVisible() {
        guard let thickness = currentSidebarThickness() else {
            return
        }

        viewModel.rememberSidebarThickness(thickness)
    }

    // Read the live sidebar width from AppKit's leading split item when it is on screen.
    private func currentSidebarThickness() -> CGFloat? {
        guard let sidebarView = sidebarItem?.viewController.view,
              sidebarView.superview != nil,
              sidebarItem?.isCollapsed == false else {
            return nil
        }

        let thickness = sidebarView.frame.width
        guard thickness.isFinite, thickness > 0 else {
            return nil
        }

        return thickness
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

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didUpdateStructuredFilterGroup group: PacketStructuredFilterGroup) {
        viewModel.updateStructuredFilterGroup(group)
    }

    func packetWorkspaceViewControllerDidRequestResetQuickFilters(_ controller: PacketWorkspaceViewController) {
        viewModel.resetQuickFilters()
    }

    func packetWorkspaceViewControllerCanAddStructuredFilter(_ controller: PacketWorkspaceViewController) -> Bool {
        TCPViewerLicenseService.shared.isLicenseAuthorized
    }

    func packetWorkspaceViewControllerDidRequestStructuredFilterPaywall(_ controller: PacketWorkspaceViewController) {
        delegate?.tcpviewerRootViewControllerDidRequestPaywall(self)
    }

    func packetWorkspaceViewControllerDidRequestHideStructuredFilter(_ controller: PacketWorkspaceViewController) {
        viewModel.setStructuredFilterVisible(false)
    }
}

extension TCPViewerRootViewController: PacketInspectorViewControllerDelegate {
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?) {
        viewModel.selectDetailNode(identifier)
    }
}

extension TCPViewerRootViewController: StatusStripViewControllerDelegate {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController) {
        cancelDocumentLoading()
    }

    func statusStripViewControllerDidRequestClearPackets(_ controller: StatusStripViewController) {
        viewModel.clearTablePackets()
    }

    func statusStripViewControllerDidToggleStructuredFilter(_ controller: StatusStripViewController) {
        let shouldShow = !viewModel.snapshot.isStructuredFilterVisible
        viewModel.setStructuredFilterVisible(shouldShow)
        if shouldShow {
            workspaceViewController.focusStructuredFilter()
        }
    }
}
