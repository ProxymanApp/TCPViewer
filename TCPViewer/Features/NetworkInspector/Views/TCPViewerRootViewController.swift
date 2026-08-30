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

private final class TCPViewerInspectorSplitViewController: NSSplitViewController {
    var didResizeSubviews: ((Notification) -> Void)?

    // Forward AppKit delegate resize events while preserving NSSplitViewController's own delegate behavior.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        didResizeSubviews?(notification)
    }
}

private final class TCPViewerCaptureDropView: NSView {
    var importHandler: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        captureFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = captureFileURLs(from: sender)
        guard !urls.isEmpty else {
            return false
        }

        importHandler?(urls)
        return true
    }

    private func captureFileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let pasteboard = draggingInfo.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL)
    }
}

private struct PendingTCPFollowReveal {
    let target: TCPFollowRevealTarget
    let captureIdentity: TCPFollowCaptureIdentity
}

private protocol TCPViewSessionImportSheetViewControllerDelegate: AnyObject {
    func tcpViewSessionImportSheetDidRequestCancel(_ controller: TCPViewSessionImportSheetViewController)
    func tcpViewSessionImportSheetDidRequestClose(_ controller: TCPViewSessionImportSheetViewController)
}

private final class TCPViewSessionImportSheetViewController: NSViewController {
    weak var delegate: TCPViewSessionImportSheetViewControllerDelegate?

    private let progressIndicator = NSProgressIndicator()
    private let titleLabel = TCPViewerUI.label(
        "Importing TCPViewer Session",
        font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    )
    private let messageLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
        color: .secondaryLabelColor
    )
    private let actionButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var phase: TCPViewSessionImportState.Phase = .idle

    override func loadView() {
        view = TCPViewerDynamicBackgroundView(backgroundColor: .windowBackgroundColor)
        preferredContentSize = NSSize(width: 380, height: 152)
        setupLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        actionButton.target = self
        actionButton.action = #selector(performAction(_:))
    }

    func render(state: TCPViewSessionImportState) {
        phase = state.phase
        messageLabel.stringValue = state.message

        switch state.phase {
        case .idle:
            break
        case .loading:
            titleLabel.stringValue = "Importing TCPViewer Session"
            actionButton.title = "Cancel"
            actionButton.isEnabled = state.canCancel
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        case .cancelling:
            titleLabel.stringValue = "Cancelling Import"
            actionButton.title = "Cancel"
            actionButton.isEnabled = false
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        case .failed:
            titleLabel.stringValue = "Could Not Import Session"
            actionButton.title = "Close"
            actionButton.isEnabled = true
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
        }
    }

    private func setupLayout() {
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular

        let textStack = NSStackView(views: [titleLabel, messageLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [progressIndicator, textStack])
        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [actionButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView(views: [contentStack, buttonRow])
        rootStack.orientation = .vertical
        rootStack.alignment = .trailing
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            progressIndicator.widthAnchor.constraint(equalToConstant: 24),
            progressIndicator.heightAnchor.constraint(equalToConstant: 24),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
    }

    @objc private func performAction(_ sender: Any?) {
        switch phase {
        case .failed:
            delegate?.tcpViewSessionImportSheetDidRequestClose(self)
        case .loading, .cancelling:
            delegate?.tcpViewSessionImportSheetDidRequestCancel(self)
        case .idle:
            break
        }
    }
}

final class TCPViewerRootViewController: NSViewController {
    weak var delegate: TCPViewerRootViewControllerDelegate?

    let viewModel: NetworkInspectorViewModel

    private let mainSplitViewController = NSSplitViewController()
    private let contentSplitViewController = TCPViewerInspectorSplitViewController()
    private let mainContainerViewController = NSViewController()
    private let mainEmptyStateViewController = TCPViewerMainEmptyStateViewController()
    private let sidebarViewController = SidebarViewController()
    private let workspaceViewController: PacketWorkspaceViewController
    private let inspectorViewController: PacketInspectorViewController
    private let statusStripViewController = StatusStripViewController()
    private var sidebarItem: NSSplitViewItem?
    private var workspaceItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var appliedInspectorVisibility: Bool?
    private var appliedInspectorPlacement: NetworkInspectorPlacement?
    private var needsSidebarDividerRefresh = false
    private var needsInspectorDividerRefresh = false
    private var isRestoringInspectorDivider = false
    private var temporaryInspectorRestoreThickness: CGFloat?
    private var hasRenderedHelperOnboarding = false
    private var sessionImportSheetViewController: TCPViewSessionImportSheetViewController?
    private var followStreamWindowControllers: [TCPFollowStreamWindowController] = []
    private var pendingTCPFollowReveal: PendingTCPFollowReveal?
    private var isMainEmptyStateVisible = false
    #if DEBUG
    private var packetSelectionCrashReproducer: TCPViewerPacketSelectionCrashReproducer?
    #endif

    deinit {
        #if DEBUG
        packetSelectionCrashReproducer?.cancel()
        #endif
        NotificationCenter.default.removeObserver(self)
    }

    init(viewModel: NetworkInspectorViewModel, configuration: AppConfiguration) {
        self.viewModel = viewModel
        self.workspaceViewController = PacketWorkspaceViewController(configuration: configuration)
        self.inspectorViewController = PacketInspectorViewController(configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        self.viewModel.delegate = self
        self.contentSplitViewController.didResizeSubviews = { [weak self] notification in
            self?.contentSplitViewDidResizeSubviews(notification)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = TCPViewerCaptureDropView()
        rootView.importHandler = { [weak self] urls in
            self?.importDocuments(at: urls)
        }
        view = rootView
        setupChildControllers()
        setupLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSplitViewObservation()
        applyPersistedSidebarLayout()
        render()
        #if DEBUG
        viewModel.performInitialLoadIfNeeded { [weak self] in
            self?.runPacketSelectionCrashReproducerOnLaunchIfNeeded()
        }
        #else
        viewModel.performInitialLoadIfNeeded()
        #endif
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if needsSidebarDividerRefresh, sidebarItem?.isCollapsed == false {
            needsSidebarDividerRefresh = false
            applySidebarDividerPosition()
        }

        if needsInspectorDividerRefresh, inspectorItem?.isCollapsed == false {
            needsInspectorDividerRefresh = false
            applyInspectorDividerPosition(placement: appliedInspectorPlacement ?? viewModel.snapshot.inspectorPlacement)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        renderSessionImportSheet(viewModel.snapshot.base.sessionImportState)
    }

    func openDocument(at url: URL) {
        guard !TCPViewerCaptureFileImportPolicy.isSessionFileURL(url) else {
            viewModel.openDocument(at: url) { [weak self] in
                self?.sidebarViewController.revealSelectedImportedFileIfNeeded()
                self?.presentSessionImportReportIfNeeded()
            }
            return
        }

        importDocuments(at: [url])
    }

    func importDocuments(at urls: [URL], completion: (() -> Void)? = nil) {
        importDocumentsWithResult(at: urls) { _ in
            completion?()
        }
    }

    func importDocumentsWithResult(
        at urls: [URL],
        completion: @escaping (TCPViewerCaptureImportResult) -> Void
    ) {
        viewModel.importDocumentsWithResult(at: urls) { [weak self] result in
            self?.sidebarViewController.revealSelectedImportedFileIfNeeded()
            self?.presentSessionImportReportIfNeeded()
            completion(result)
        }
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

    func exportTCPViewSession() {
        viewModel.presentTCPViewSessionExportPanel(attachedTo: view.window)
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

    func toggleInspector(placement: NetworkInspectorPlacement) {
        viewModel.toggleInspector(placement: placement)
    }

    func toggleQuickFilter(_ filterID: PacketQuickFilterID) {
        viewModel.toggleQuickFilter(filterID)
    }

    func applyCustomFilter(_ filterID: PacketCustomFilter.ID) {
        viewModel.applyCustomFilter(id: filterID)
    }

    func renameCustomFilter(_ filterID: PacketCustomFilter.ID, name: String) {
        do {
            try viewModel.renameCustomFilter(id: filterID, name: name)
        } catch {
            presentCustomFilterError(error, title: "Could Not Rename Filter")
        }
    }

    func overrideCustomFilter(_ filterID: PacketCustomFilter.ID, group: PacketStructuredFilterGroup) {
        do {
            try viewModel.overrideCustomFilter(id: filterID, group: group)
        } catch {
            presentCustomFilterError(error, title: "Could Not Override Filter")
        }
    }

    func duplicateCustomFilter(_ filterID: PacketCustomFilter.ID) {
        do {
            try viewModel.duplicateCustomFilter(id: filterID)
        } catch {
            presentCustomFilterError(error, title: "Could Not Duplicate Filter")
        }
    }

    func deleteCustomFilter(_ filterID: PacketCustomFilter.ID) {
        do {
            try viewModel.deleteCustomFilter(id: filterID)
        } catch {
            presentCustomFilterError(error, title: "Could Not Delete Filter")
        }
    }

    func resetQuickFilters() {
        viewModel.resetQuickFilters()
    }

    func focusStructuredFilter() {
        viewModel.setStructuredFilterVisible(true)
        workspaceViewController.focusStructuredFilter()
    }

    func focusSidebarFilter() {
        guard sidebarItem?.isCollapsed == true else {
            sidebarViewController.focusFilterField()
            return
        }

        // Reopen the sidebar before focusing because collapsed split items cannot accept focus.
        setSidebarVisible(true)
        DispatchQueue.main.async { [weak self] in
            self?.sidebarViewController.focusFilterField()
        }
    }

    func focusPacketDetailFilter() {
        guard inspectorItem?.isCollapsed == true else {
            inspectorViewController.focusFilterField()
            return
        }

        // Reopen the inspector before focusing because collapsed split items cannot accept focus.
        viewModel.setInspectorVisible(true)
        DispatchQueue.main.async { [weak self] in
            self?.inspectorViewController.focusFilterField()
        }
    }

    func showOpenPanel() {
        viewModel.presentOpenCapturePanel { [weak self] in
            self?.sidebarViewController.revealSelectedImportedFileIfNeeded()
        }
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

    @objc func focusSidebarFilter(_ sender: Any?) {
        focusSidebarFilter()
    }

    private func setupChildControllers() {
        // Build the two-level split layout: sidebar | (workspace + inspector).
        sidebarViewController.delegate = self
        workspaceViewController.delegate = self
        inspectorViewController.delegate = self
        statusStripViewController.delegate = self
        mainEmptyStateViewController.delegate = self

        mainSplitViewController.splitView.isVertical = true
        contentSplitViewController.splitView.isVertical = true

        // Keep the table and inspector inside the main container split.
        let workspaceItem = NSSplitViewItem(contentListWithViewController: workspaceViewController)
        contentSplitViewController.addSplitViewItem(workspaceItem)
        self.workspaceItem = workspaceItem

        let inspectorItem = NSSplitViewItem(viewController: inspectorViewController)
        inspectorItem.canCollapse = true
        inspectorItem.allowsFullHeightLayout = false
        inspectorItem.minimumThickness = NetworkInspectorLayoutMetrics.minimumInspectorThickness
        contentSplitViewController.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem

        mainContainerViewController.view = TCPViewerDynamicBackgroundView(backgroundColor: .controlBackgroundColor)
        mainContainerViewController.addChild(contentSplitViewController)
        mainContainerViewController.addChild(mainEmptyStateViewController)
        mainContainerViewController.addChild(statusStripViewController)

        let mainContainerView = mainContainerViewController.view
        contentSplitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        mainEmptyStateViewController.view.translatesAutoresizingMaskIntoConstraints = false
        statusStripViewController.view.translatesAutoresizingMaskIntoConstraints = false
        mainContainerView.addSubview(contentSplitViewController.view)
        mainContainerView.addSubview(mainEmptyStateViewController.view)
        mainContainerView.addSubview(statusStripViewController.view)
        mainEmptyStateViewController.view.isHidden = true

        NSLayoutConstraint.activate([
            contentSplitViewController.view.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor),
            contentSplitViewController.view.trailingAnchor.constraint(equalTo: mainContainerView.trailingAnchor),
            contentSplitViewController.view.topAnchor.constraint(equalTo: mainContainerView.topAnchor),
            contentSplitViewController.view.bottomAnchor.constraint(equalTo: statusStripViewController.view.topAnchor),

            mainEmptyStateViewController.view.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor),
            mainEmptyStateViewController.view.trailingAnchor.constraint(equalTo: mainContainerView.trailingAnchor),
            mainEmptyStateViewController.view.topAnchor.constraint(equalTo: mainContainerView.topAnchor),
            mainEmptyStateViewController.view.bottomAnchor.constraint(equalTo: statusStripViewController.view.topAnchor),

            statusStripViewController.view.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor),
            statusStripViewController.view.trailingAnchor.constraint(equalTo: mainContainerView.trailingAnchor),
            statusStripViewController.view.bottomAnchor.constraint(equalTo: mainContainerView.bottomAnchor),
        ])

        addChild(mainSplitViewController)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = NetworkInspectorLayoutMetrics.minimumSidebarThickness
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
        applyPendingTCPFollowReveal(snapshot)
        mainEmptyStateViewController.render(snapshot: snapshot)
        statusStripViewController.render(snapshot: snapshot, metrics: viewModel.statusMetricsSnapshot)
        applyMainEmptyStateVisibility(snapshot)
        renderSessionImportSheet(snapshot.base.sessionImportState)
        applyInspectorLayout(snapshot)
        delegate?.tcpviewerRootViewControllerDidChangeToolbarState(self)

        if viewModel.shouldPresentNetworkHelperOnboarding && !hasRenderedHelperOnboarding {
            hasRenderedHelperOnboarding = true
            delegate?.tcpviewerRootViewController(self, didRequestHelperOnboarding: viewModel.networkHelperToolSnapshot)
        }
    }

    // Wait for asynchronous dissection before asking the Hex pane to reveal reassembled bytes.
    private func applyPendingTCPFollowReveal(_ snapshot: NetworkInspectorSnapshot) {
        guard let pendingTCPFollowReveal else {
            return
        }
        guard viewModel.canRevealTCPFollowPacket(
            pendingTCPFollowReveal.target.packetID,
            from: pendingTCPFollowReveal.captureIdentity
        ) else {
            self.pendingTCPFollowReveal = nil
            return
        }
        let inspectionState = snapshot.base.inspectionState
        guard inspectionState.selectedPacketID == pendingTCPFollowReveal.target.packetID else {
            self.pendingTCPFollowReveal = nil
            return
        }
        guard inspectionState.inspection?.packetID == pendingTCPFollowReveal.target.packetID else {
            if !inspectionState.isLoading {
                self.pendingTCPFollowReveal = nil
            }
            return
        }

        inspectorViewController.revealTCPFollowPayload(pendingTCPFollowReveal.target)
        self.pendingTCPFollowReveal = nil
    }

    private func applyMainEmptyStateVisibility(_ snapshot: NetworkInspectorSnapshot) {
        // Swap only the central content region so sidebar and status remain available.
        let shouldShowEmptyState = snapshot.shouldShowMainEmptyState
        guard isMainEmptyStateVisible != shouldShowEmptyState else {
            return
        }

        isMainEmptyStateVisible = shouldShowEmptyState
        contentSplitViewController.view.isHidden = shouldShowEmptyState
        mainEmptyStateViewController.view.isHidden = !shouldShowEmptyState
    }

    private func renderSessionImportSheet(_ state: TCPViewSessionImportState) {
        // Present session imports as a sheet so document title and bottom strip remain unchanged.
        guard state.isPresented else {
            if let sheet = sessionImportSheetViewController {
                dismiss(sheet)
                sessionImportSheetViewController = nil
            }
            return
        }

        guard view.window != nil else {
            return
        }

        let sheet: TCPViewSessionImportSheetViewController
        if let currentSheet = sessionImportSheetViewController {
            sheet = currentSheet
        } else {
            let newSheet = TCPViewSessionImportSheetViewController()
            newSheet.delegate = self
            sessionImportSheetViewController = newSheet
            presentAsSheet(newSheet)
            sheet = newSheet
        }
        sheet.render(state: state)
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

    // Keep inspector placement and collapse state in sync with toolbar/view-model state.
    private func applyInspectorLayout(_ snapshot: NetworkInspectorSnapshot) {
        let placementChanged = appliedInspectorPlacement != snapshot.inspectorPlacement
        let visibilityChanged = appliedInspectorVisibility != snapshot.isInspectorVisible
        let previousPlacement = appliedInspectorPlacement ?? snapshot.inspectorPlacement

        if placementChanged, appliedInspectorVisibility == true {
            persistCurrentInspectorThicknessIfVisible(placement: previousPlacement)
        }

        if placementChanged {
            isRestoringInspectorDivider = true
            configureInspectorPlacement(snapshot.inspectorPlacement)
        }
        inspectorViewController.applyPlacement(snapshot.inspectorPlacement)

        appliedInspectorPlacement = snapshot.inspectorPlacement
        if visibilityChanged {
            if !snapshot.isInspectorVisible {
                persistCurrentInspectorThicknessIfVisible(placement: snapshot.inspectorPlacement)
                inspectorItem?.isCollapsed = true
            } else {
                restoreInspectorDividerAfterOpening(placement: snapshot.inspectorPlacement)
            }
        } else if placementChanged, snapshot.isInspectorVisible {
            restoreInspectorDividerAfterOpening(placement: snapshot.inspectorPlacement)
        } else if placementChanged {
            clearTemporaryInspectorRestoreThickness()
            isRestoringInspectorDivider = false
        }

        appliedInspectorVisibility = snapshot.isInspectorVisible
    }

    private func configureInspectorPlacement(_ placement: NetworkInspectorPlacement) {
        guard let workspaceItem, let inspectorItem else {
            return
        }

        contentSplitViewController.splitView.isVertical = placement == .trailing

        // Keep workspace first; this split view is flipped, so the second item renders at the bottom.
        let targetItems = [workspaceItem, inspectorItem]
        guard !splitItems(contentSplitViewController.splitViewItems, match: targetItems) else {
            return
        }

        for item in contentSplitViewController.splitViewItems.reversed() {
            contentSplitViewController.removeSplitViewItem(item)
        }
        for (index, item) in targetItems.enumerated() {
            contentSplitViewController.insertSplitViewItem(item, at: index)
        }
    }

    private func splitItems(_ lhs: [NSSplitViewItem], match rhs: [NSSplitViewItem]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        return zip(lhs, rhs).allSatisfy { $0 === $1 }
    }

    // Expand the inspector without letting AppKit's intermediate resize overwrite the saved size.
    private func restoreInspectorDividerAfterOpening(placement: NetworkInspectorPlacement) {
        isRestoringInspectorDivider = true
        prepareInspectorItemForExactRestore(placement: placement)
        inspectorItem?.isCollapsed = false
        applyInspectorDividerPosition(placement: placement)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.applyInspectorDividerPosition(placement: placement)
            self.view.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.applyInspectorDividerPosition(placement: placement)
                self.clearTemporaryInspectorRestoreThickness()
                self.view.layoutSubtreeIfNeeded()
                self.applyInspectorDividerPosition(placement: placement)
                self.isRestoringInspectorDivider = false
            }
        }
    }

    // Lock the split item briefly so AppKit's uncollapse animation starts at the saved size.
    private func prepareInspectorItemForExactRestore(placement: NetworkInspectorPlacement) {
        let splitView = contentSplitViewController.splitView
        guard let inspectorThickness = inspectorRestoreThickness(for: splitView, placement: placement) else {
            clearTemporaryInspectorRestoreThickness()
            return
        }

        temporaryInspectorRestoreThickness = inspectorThickness
        inspectorItem?.minimumThickness = inspectorThickness
        inspectorItem?.maximumThickness = inspectorThickness
    }

    private func clearTemporaryInspectorRestoreThickness() {
        guard temporaryInspectorRestoreThickness != nil else {
            return
        }

        temporaryInspectorRestoreThickness = nil
        inspectorItem?.minimumThickness = NetworkInspectorLayoutMetrics.minimumInspectorThickness
        inspectorItem?.maximumThickness = NSSplitViewItem.unspecifiedDimension
    }

    // Reapply the saved divider position once the split view has a real size.
    private func applyInspectorDividerPosition(placement: NetworkInspectorPlacement) {
        let splitView = contentSplitViewController.splitView
        guard splitView.dividerThickness.isFinite else {
            return
        }

        splitView.layoutSubtreeIfNeeded()
        let totalLength = inspectorSplitLength(splitView, placement: placement)
        guard totalLength > 0 else {
            needsInspectorDividerRefresh = true
            return
        }

        guard let inspectorThickness = inspectorRestoreThickness(for: splitView, placement: placement) else {
            return
        }

        let dividerPosition = totalLength - splitView.dividerThickness - inspectorThickness
        guard dividerPosition.isFinite, dividerPosition > 0 else {
            return
        }

        splitView.setPosition(dividerPosition, ofDividerAt: 0)
    }

    private func inspectorRestoreThickness(for splitView: NSSplitView, placement: NetworkInspectorPlacement) -> CGFloat? {
        let availableLength = inspectorSplitLength(splitView, placement: placement) - splitView.dividerThickness
        return viewModel.restoredInspectorThickness(for: availableLength, placement: placement)
    }

    private func inspectorSplitLength(_ splitView: NSSplitView, placement: NetworkInspectorPlacement) -> CGFloat {
        switch placement {
        case .trailing:
            return splitView.bounds.width
        case .bottom:
            return splitView.bounds.height
        }
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

    private func contentSplitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === contentSplitViewController.splitView else {
            return
        }

        guard !isRestoringInspectorDivider else {
            return
        }

        persistCurrentInspectorLayout()
    }

    // Persist the inspector split state after manual drags and AppKit-driven collapses.
    private func persistCurrentInspectorLayout() {
        let isVisible = inspectorItem?.isCollapsed == false
        viewModel.setInspectorVisible(isVisible)
        persistCurrentInspectorThicknessIfVisible()
    }

    // Persist only visible inspector sizes so collapsing the pane never stores a broken zero value.
    private func persistCurrentInspectorThicknessIfVisible(placement: NetworkInspectorPlacement? = nil) {
        let placement = placement ?? appliedInspectorPlacement ?? viewModel.snapshot.inspectorPlacement
        guard let thickness = currentInspectorThickness(placement: placement) else {
            return
        }

        viewModel.rememberInspectorThickness(thickness, placement: placement)
    }

    // Read the live inspector size from AppKit's split item when it is on screen.
    private func currentInspectorThickness(placement: NetworkInspectorPlacement) -> CGFloat? {
        guard let inspectorView = inspectorItem?.viewController.view,
              inspectorView.superview != nil,
              inspectorItem?.isCollapsed == false else {
            return nil
        }

        let thickness: CGFloat
        switch placement {
        case .trailing:
            thickness = inspectorView.frame.width
        case .bottom:
            thickness = inspectorView.frame.height
        }
        guard thickness.isFinite, thickness > 0 else {
            return nil
        }

        return thickness
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

#if DEBUG
private enum TCPViewerPacketSelectionCrashReproducerLaunchConfiguration {
    static let launchArgument = "--tcpviewer-run-selection-crash-reproducer"
    static let enabledEnvironmentKey = "TCPVIEWER_RUN_SELECTION_CRASH_REPRODUCER"
    static let interfaceEnvironmentKey = "TCPVIEWER_SELECTION_CRASH_REPRODUCER_INTERFACE"
    static let defaultInterfaceID = "en1"
    static let startupDelay: TimeInterval = 1
    static let firstRunDuration: TimeInterval = 60
    static let secondRunDuration: TimeInterval = 15
    static let selectionInterval: TimeInterval = 0.5
    private static let enabledValues: Set<String> = ["1", "true", "yes"]

    static var isEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(launchArgument) ||
            isEnabledValue(processInfo.environment[enabledEnvironmentKey]) ||
            hasEnabledLaunchEnvironmentArgument(in: processInfo.arguments)
    }

    static var interfaceID: String {
        let configuredInterfaceID = ProcessInfo.processInfo.environment[interfaceEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuredInterfaceID, !configuredInterfaceID.isEmpty else {
            return defaultInterfaceID
        }
        return configuredInterfaceID
    }

    private static func hasEnabledLaunchEnvironmentArgument(in arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            if argument == enabledEnvironmentKey || argument == "-\(enabledEnvironmentKey)" {
                let nextIndex = arguments.index(after: index)
                return nextIndex < arguments.endIndex ? isEnabledValue(arguments[nextIndex]) : true
            }

            if let value = value(afterEqualsSignIn: argument, key: enabledEnvironmentKey) {
                return isEnabledValue(value)
            }

            if let value = value(afterEqualsSignIn: argument, key: "-\(enabledEnvironmentKey)") {
                return isEnabledValue(value)
            }
        }

        return false
    }

    private static func value(afterEqualsSignIn argument: String, key: String) -> String? {
        guard argument.hasPrefix("\(key)=") else {
            return nil
        }

        return String(argument.dropFirst(key.count + 1))
    }

    private static func isEnabledValue(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return enabledValues.contains(value)
    }
}

private final class TCPViewerPacketSelectionCrashReproducer {
    private weak var rootViewController: TCPViewerRootViewController?
    private let requestedInterfaceID: String
    private let startupDelay: TimeInterval
    private let runDurations: [TimeInterval]
    private let selectionInterval: TimeInterval
    private var currentRunIndex = 0
    private var currentRunSelectionCount = 0
    private var totalSelectionCount = 0
    private var emptyTickCount = 0
    private var startupWorkItem: DispatchWorkItem?
    private var selectionWorkItem: DispatchWorkItem?
    private var stopWorkItem: DispatchWorkItem?
    private var isCancelled = false

    init(
        rootViewController: TCPViewerRootViewController,
        requestedInterfaceID: String,
        startupDelay: TimeInterval,
        firstRunDuration: TimeInterval,
        secondRunDuration: TimeInterval,
        selectionInterval: TimeInterval
    ) {
        self.rootViewController = rootViewController
        self.requestedInterfaceID = requestedInterfaceID
        self.startupDelay = startupDelay
        self.runDurations = [firstRunDuration, secondRunDuration]
        self.selectionInterval = selectionInterval
    }

    // Starts the debug-only flow after a short launch delay so the window can settle.
    func start() {
        log("🧪 Waiting \(formattedSeconds(startupDelay)) after launch before selecting '\(requestedInterfaceID)' and starting capture.")
        let workItem = DispatchWorkItem { [weak self] in
            self?.startCurrentRun()
        }
        startupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay, execute: workItem)
    }

    // Cancels any pending timer tick so the reproducer stops cleanly with the window.
    func cancel() {
        isCancelled = true
        startupWorkItem?.cancel()
        selectionWorkItem?.cancel()
        stopWorkItem?.cancel()
        startupWorkItem = nil
        selectionWorkItem = nil
        stopWorkItem = nil
    }

    // Selects the requested interface and starts capture for the current timed run.
    private func startCurrentRun() {
        guard !isCancelled, let rootViewController else {
            return
        }

        rootViewController.viewModel.selectSourceList(.allPackets)
        guard let interfaceID = resolvedInterfaceID(in: rootViewController) else {
            log("Could not find interface '\(requestedInterfaceID)'. Available interfaces: \(availableInterfaceIDs(in: rootViewController))")
            cancel()
            return
        }

        rootViewController.viewModel.selectInterface(interfaceID)
        rootViewController.viewModel.selectSourceList(.allPackets)
        currentRunSelectionCount = 0
        emptyTickCount = 0

        let duration = currentRunDuration
        log("🧪 Starting run \(currentRunIndex + 1)/\(runDurations.count) on '\(interfaceID)' for \(formattedSeconds(duration)); selecting every \(formattedSeconds(selectionInterval)).")

        if rootViewController.viewModel.snapshot.base.sessionState.canStop {
            captureStartDidFinish()
        } else {
            rootViewController.viewModel.toggleLiveCapture { [weak self] in
                self?.captureStartDidFinish()
            }
        }
    }

    // Verifies capture is active before beginning timed random selection ticks.
    private func captureStartDidFinish() {
        guard !isCancelled, let rootViewController else {
            return
        }

        rootViewController.viewModel.selectSourceList(.allPackets)
        guard rootViewController.viewModel.snapshot.base.sessionState.canStop else {
            let message = rootViewController.viewModel.snapshot.base.sessionState.statusMessage
            log("Capture did not start: \(message)")
            cancel()
            return
        }

        scheduleRunStop()
        scheduleNextSelection()
    }

    // Schedules the stop boundary for the current run duration.
    private func scheduleRunStop() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishCurrentRun()
        }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + currentRunDuration, execute: workItem)
    }

    // Schedules the next selection attempt while the timed run is active.
    private func scheduleNextSelection() {
        guard !isCancelled else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.performSelectionTick()
        }
        selectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + selectionInterval, execute: workItem)
    }

    // Performs one random NSTableView row selection, waiting for packets if the table is empty.
    private func performSelectionTick() {
        guard !isCancelled, let rootViewController else {
            return
        }

        rootViewController.viewModel.selectSourceList(.allPackets)
        if rootViewController.selectRandomPacketRowForCrashReproducerTesting() {
            currentRunSelectionCount += 1
            totalSelectionCount += 1
            emptyTickCount = 0
            log("🎯 Selected random packet row \(currentRunSelectionCount) in run \(currentRunIndex + 1).")
        } else {
            emptyTickCount += 1
            if emptyTickCount == 1 || emptyTickCount.isMultiple(of: 5) {
                log("Waiting for packet rows before selecting. Empty ticks: \(emptyTickCount).")
            }
        }

        scheduleNextSelection()
    }

    // Stops the current capture run and then either clears/restarts or quits the app.
    private func finishCurrentRun() {
        guard !isCancelled, let rootViewController else {
            return
        }

        selectionWorkItem?.cancel()
        selectionWorkItem = nil
        log("🛑 Stopping run \(currentRunIndex + 1)/\(runDurations.count) after \(currentRunSelectionCount) selections.")

        guard rootViewController.viewModel.snapshot.base.sessionState.canStop else {
            finishAllRunsAndQuit()
            return
        }

        rootViewController.viewModel.toggleLiveCapture { [weak self] in
            self?.captureStopDidFinish()
        }
    }

    // Clears packets after the first run, then starts the shorter second run.
    private func captureStopDidFinish() {
        guard !isCancelled, let rootViewController else {
            return
        }

        if currentRunIndex == 0 {
            log("🧹 Clearing packets before the second run.")
            rootViewController.viewModel.clearPackets()
            currentRunIndex += 1
            startCurrentRun()
        } else {
            finishAllRunsAndQuit()
        }
    }

    // Finishes the automated reproduction session and exits the debug app.
    private func finishAllRunsAndQuit() {
        log("✅ Finished automatic selection reproducer after \(totalSelectionCount) total selections. Quitting app.")
        cancel()
        NSApp.terminate(nil)
    }

    private var currentRunDuration: TimeInterval {
        runDurations[min(currentRunIndex, runDurations.count - 1)]
    }

    // Resolves either an interface id or technical name from the current interface inventory.
    private func resolvedInterfaceID(in rootViewController: TCPViewerRootViewController) -> String? {
        let interfaces = rootViewController.viewModel.snapshot.base.sessionState.interfaceInventory
        return interfaces.first { captureInterface in
            captureInterface.id == requestedInterfaceID ||
                captureInterface.technicalName == requestedInterfaceID
        }?.id
    }

    // Builds a concise interface list for debug logs when the requested interface is unavailable.
    private func availableInterfaceIDs(in rootViewController: TCPViewerRootViewController) -> String {
        let values = rootViewController.viewModel.snapshot.base.sessionState.interfaceInventory.map { captureInterface in
            captureInterface.id == captureInterface.technicalName
                ? captureInterface.id
                : "\(captureInterface.id)(\(captureInterface.technicalName))"
        }
        return values.isEmpty ? "none" : values.joined(separator: ", ")
    }

    private func log(_ message: String) {
        print("[TCPViewer] \(NetworkInspectorDebugLog.timestamp()) selection-crash-reproducer: \(message)")
    }

    private func formattedSeconds(_ seconds: TimeInterval) -> String {
        "\(String(format: "%.1f", seconds))s"
    }
}

extension TCPViewerRootViewController {
    // Selects a random packet row while keeping the workspace controller private to the root.
    fileprivate func selectRandomPacketRowForCrashReproducerTesting() -> Bool {
        workspaceViewController.selectRandomPacketRowForTesting()
    }

    // Starts the packet selection crash reproducer when the debug launch flag is present.
    private func runPacketSelectionCrashReproducerOnLaunchIfNeeded() {
        guard TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.isEnabled else {
            return
        }

        print("[TCPViewer] \(NetworkInspectorDebugLog.timestamp()) selection-crash-reproducer: 🧪 Automatic run enabled from launch.")
        runPacketSelectionCrashReproducerForTesting(
            interfaceID: TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.interfaceID,
            startupDelay: TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.startupDelay,
            firstRunDuration: TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.firstRunDuration,
            secondRunDuration: TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.secondRunDuration,
            selectionInterval: TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.selectionInterval
        )
    }

    // Exposes the crash reproducer to debug code without compiling it into Release builds.
    func runPacketSelectionCrashReproducerForTesting(
        interfaceID: String = TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.defaultInterfaceID,
        startupDelay: TimeInterval = TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.startupDelay,
        firstRunDuration: TimeInterval = TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.firstRunDuration,
        secondRunDuration: TimeInterval = TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.secondRunDuration,
        selectionInterval: TimeInterval = TCPViewerPacketSelectionCrashReproducerLaunchConfiguration.selectionInterval
    ) {
        packetSelectionCrashReproducer?.cancel()

        let reproducer = TCPViewerPacketSelectionCrashReproducer(
            rootViewController: self,
            requestedInterfaceID: interfaceID,
            startupDelay: startupDelay,
            firstRunDuration: firstRunDuration,
            secondRunDuration: secondRunDuration,
            selectionInterval: selectionInterval
        )
        packetSelectionCrashReproducer = reproducer
        reproducer.start()
    }
}
#endif

#if DEBUG
extension TCPViewerRootViewController {
    // Expose split geometry to unit tests without depending on nested AppKit view discovery.
    var inspectorSplitViewForTesting: NSSplitView {
        contentSplitViewController.splitView
    }

    var workspaceViewForTesting: NSView? {
        workspaceItem?.viewController.view
    }

    var inspectorViewForTesting: NSView? {
        inspectorItem?.viewController.view
    }

    var isMainEmptyStateVisibleForTesting: Bool {
        isMainEmptyStateVisible
    }

    var isContentSplitViewHiddenForTesting: Bool {
        contentSplitViewController.view.isHidden
    }
}
#endif

extension TCPViewerRootViewController: NetworkInspectorViewModelDelegate {
    func networkInspectorViewModelDidChange(_ viewModel: NetworkInspectorViewModel) {
        render()
    }

    func networkInspectorViewModelDidUpdateStatusMetrics(_ viewModel: NetworkInspectorViewModel) {
        statusStripViewController.render(metrics: viewModel.statusMetricsSnapshot)
    }
}

extension TCPViewerRootViewController: TCPViewerMainEmptyStateViewControllerDelegate {
    func tcpViewerMainEmptyStateViewController(
        _ controller: TCPViewerMainEmptyStateViewController,
        didSelectInterface identifier: String
    ) {
        viewModel.selectInterface(identifier)
    }

    func tcpViewerMainEmptyStateViewControllerDidRequestStartCapture(_ controller: TCPViewerMainEmptyStateViewController) {
        viewModel.toggleLiveCapture()
    }
}

extension TCPViewerRootViewController: SidebarViewControllerDelegate {
    func sidebarViewController(_ controller: SidebarViewController, didSelect selection: PacketSourceListSelection?) {
        viewModel.selectSourceList(selection)
    }

    func sidebarViewController(_ controller: SidebarViewController, didUpdateFilterText text: String) {
        viewModel.updateSourceListFilterText(text)
    }

    func sidebarViewController(_ controller: SidebarViewController, didRequestPin targets: [PacketSourceListPinTarget]) {
        guard canUsePinFeature() else {
            delegate?.tcpviewerRootViewControllerDidRequestPaywall(self)
            return
        }

        viewModel.pinSourceListItems(targets)
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
        didRequestPinPackets identifiers: [PacketSummary.ID]
    ) {
        guard canUsePinFeature() else {
            delegate?.tcpviewerRootViewControllerDidRequestPaywall(self)
            return
        }

        viewModel.pinAppPackets(identifiers)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestSavePackets identifiers: [PacketSummary.ID]) {
        viewModel.savePackets(identifiers)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestFollowTCPStream packetID: PacketSummary.ID) {
        presentFollowTCPStreamWindow(packetID: packetID)
    }

    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestSetComment comment: String,
        onPackets identifiers: [PacketSummary.ID]
    ) {
        viewModel.setPacketComment(comment, onPackets: identifiers)
    }

    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestApplyTextStyle mutation: PacketTextStyleMutation,
        toPackets identifiers: [PacketSummary.ID]
    ) {
        viewModel.applyTextStyleMutation(mutation, toPackets: identifiers)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestExportPackets identifiers: [PacketSummary.ID], format: CaptureFileFormat) {
        viewModel.presentPacketExportPanel(identifiers: identifiers, format: format, attachedTo: view.window)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didRequestDeletePackets identifiers: [PacketSummary.ID]) {
        viewModel.deletePackets(identifiers)
    }

    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        inspectPacket identifier: PacketSummary.ID,
        completion: @escaping TCPViewerCompletion<PacketInspection>
    ) {
        viewModel.inspectPacket(identifier, completion: completion)
    }

    func packetWorkspaceViewController(_ controller: PacketWorkspaceViewController, didUpdateStructuredFilterGroup group: PacketStructuredFilterGroup) {
        viewModel.updateStructuredFilterGroup(group)
    }

    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestSaveCustomFilterNamed name: String,
        group: PacketStructuredFilterGroup
    ) {
        do {
            try viewModel.saveCustomFilter(name: name, group: group)
        } catch {
            presentCustomFilterError(error, title: "Could Not Save Filter")
        }
    }

    func packetWorkspaceViewController(
        _ controller: PacketWorkspaceViewController,
        didRequestOverrideCustomFilter filterID: PacketCustomFilter.ID,
        group: PacketStructuredFilterGroup
    ) {
        overrideCustomFilter(filterID, group: group)
    }

    func packetWorkspaceViewControllerDidRequestResetQuickFilters(_ controller: PacketWorkspaceViewController) {
        viewModel.resetQuickFilters()
    }

    func packetWorkspaceViewControllerCanAddStructuredFilter(_ controller: PacketWorkspaceViewController) -> Bool {
        TCPViewerLicenseService.shared.isLicenseAuthorized
    }

    func packetWorkspaceViewControllerCanSaveCustomFilter(_ controller: PacketWorkspaceViewController) -> Bool {
        TCPViewerLicenseService.shared.isLicenseAuthorized
    }

    func packetWorkspaceViewControllerDidRequestStructuredFilterPaywall(_ controller: PacketWorkspaceViewController) {
        delegate?.tcpviewerRootViewControllerDidRequestPaywall(self)
    }

    func packetWorkspaceViewControllerDidRequestHideStructuredFilter(_ controller: PacketWorkspaceViewController) {
        viewModel.setStructuredFilterVisible(false)
    }

    fileprivate func canUsePinFeature() -> Bool {
        TCPViewerLicenseService.shared.isLicenseAuthorized
    }

    // Present persistence failures at the root so child controllers stay model-driven.
    private func presentCustomFilterError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentInspectorFilterError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Apply Filter"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentSessionImportReportIfNeeded() {
        guard let report = viewModel.consumeSessionImportReportWithFailures() else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Session Imported with Skipped Flows"
        let reason = report.failedFlowCount == 1 ? "it was malformed" : "they were malformed"
        alert.informativeText = "Imported \(Self.flowCountText(report.importedFlowCount)). Skipped \(Self.flowCountText(report.failedFlowCount)) because \(reason)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func flowCountText(_ count: Int) -> String {
        "\(count) flow\(count == 1 ? "" : "s")"
    }
}

private extension TCPViewerRootViewController {
    // Open a dedicated native workspace and keep its bounded background operation cancellable.
    func presentFollowTCPStreamWindow(packetID: PacketSummary.ID) {
        let captureIdentity = viewModel.tcpFollowCaptureIdentity
        guard let navigation = viewModel.tcpFollowStreamNavigation(containing: packetID) else {
            return
        }
        let controller = TCPFollowStreamWindowController(navigation: navigation)
        followStreamWindowControllers.append(controller)
        controller.closeHandler = { [weak self, weak controller] in
            guard let controller else {
                return
            }
            self?.followStreamWindowControllers.removeAll { $0 === controller }
        }
        controller.revealPacket = { [weak self] target in
            guard let self,
                  self.viewModel.canRevealTCPFollowPacket(target.packetID, from: captureIdentity) else {
                return
            }
            self.pendingTCPFollowReveal = PendingTCPFollowReveal(
                target: target,
                captureIdentity: captureIdentity
            )
            self.viewModel.selectPacket(target.packetID)
            self.viewModel.setInspectorVisible(true)
            self.workspaceViewController.scrollPacketToVisible(target.packetID)
            self.view.window?.makeKeyAndOrderFront(nil)
        }
        controller.streamSelectionHandler = { [weak self, weak controller] entry in
            guard let self, let controller else {
                return
            }
            guard self.viewModel.canRevealTCPFollowPacket(entry.packetID, from: captureIdentity) else {
                controller.show(error: TCPViewerCoreError(
                    code: .offlineFileOpenFailed,
                    message: "The capture changed, so this TCP stream is no longer available."
                ))
                return
            }
            self.loadFollowTCPStream(containing: entry.packetID, into: controller)
        }
        controller.present()
        loadFollowTCPStream(containing: packetID, into: controller)
    }

    // Reuse the same bounded callback-based reassembly path for initial and stepped streams.
    func loadFollowTCPStream(
        containing packetID: PacketSummary.ID,
        into controller: TCPFollowStreamWindowController
    ) {
        viewModel.followTCPStream(
            containing: packetID,
            progress: { [weak controller] progress in
                DispatchQueue.main.async {
                    controller?.updateProgress(progress)
                }
            },
            shouldCancel: { [weak controller] in
                controller?.cancellationFlag.isCancelled ?? true
            }
        ) { [weak controller] result in
            DispatchQueue.main.async {
                guard let controller else {
                    return
                }
                switch result {
                case .success(let stream):
                    controller.show(stream: stream)
                case .failure(let error):
                    controller.show(error: error)
                }
            }
        }
    }
}

extension TCPViewerRootViewController: PacketInspectorViewControllerDelegate {
    func packetInspectorViewController(_ controller: PacketInspectorViewController, didSelectDetailNode identifier: String?) {
        viewModel.selectDetailNode(identifier)
    }

    func packetInspectorViewController(
        _ controller: PacketInspectorViewController,
        didRequestCreateCustomColumn request: PacketCustomColumnRequest
    ) {
        workspaceViewController.createCustomColumn(from: request)
    }

    func packetInspectorViewController(
        _ controller: PacketInspectorViewController,
        didRequestApplyFilter request: PacketInspectorFilterRequest
    ) {
        viewModel.applyInspectorFilter(request) { [weak self] didApply, failureMessage in
            guard didApply else {
                if let failureMessage {
                    self?.presentInspectorFilterError(failureMessage)
                }
                return
            }
            self?.workspaceViewController.focusStructuredFilter()
        }
    }
}

extension TCPViewerRootViewController: StatusStripViewControllerDelegate {
    func statusStripViewControllerDidRequestCancelLoad(_ controller: StatusStripViewController) {
        cancelDocumentLoading()
    }

    func statusStripViewControllerDidRequestClearPackets(_ controller: StatusStripViewController) {
        viewModel.clearTablePackets()
    }

    func statusStripViewControllerDidRequestToggleFilter(_ controller: StatusStripViewController) {
        let showsFilter = !viewModel.snapshot.isStructuredFilterVisible
        viewModel.setStructuredFilterVisible(showsFilter)
        if showsFilter {
            workspaceViewController.focusStructuredFilter()
        }
    }
}

extension TCPViewerRootViewController: TCPViewSessionImportSheetViewControllerDelegate {
    fileprivate func tcpViewSessionImportSheetDidRequestCancel(_ controller: TCPViewSessionImportSheetViewController) {
        viewModel.cancelSessionImport()
    }

    fileprivate func tcpViewSessionImportSheetDidRequestClose(_ controller: TCPViewSessionImportSheetViewController) {
        viewModel.dismissSessionImport()
    }
}
