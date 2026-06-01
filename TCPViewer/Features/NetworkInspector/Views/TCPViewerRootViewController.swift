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

    fileprivate func canUsePinFeature() -> Bool {
        TCPViewerLicenseService.shared.isLicenseAuthorized
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
