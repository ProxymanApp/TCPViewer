//
//  TCPViewerWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import PcapPlusPlusCore
import SwiftUI
import Carbon

final class TCPViewerWindowController: NSWindowController {
    let workspaceViewController = TCPViewerWorkspaceViewController()
    private(set) var tabs: [TCPViewerWorkspaceTab] = []
    private(set) var selectedTabID: UUID?
    var selectedTab: TCPViewerWorkspaceTab? { tabs.first { $0.id == selectedTabID } }
    var rootViewController: TCPViewerRootViewController { selectedTab!.pane! }
    let liveWorkspace: TCPViewerCaptureWorkspace
    private let services: TCPViewerServiceRegistry
    private let configuration: AppConfiguration
    private var history = TCPViewerWorkspaceTabHistory()
    private var isClosingWorkspace = false
    private var isReadyToClose = false
    var closeHandler: (() -> Void)?
    private lazy var importer = TCPViewerWorkspaceImporter(windowController: self)
    private lazy var automationSource = TCPViewerWorkspaceAutomationSource(windowController: self)

    private let toolbarDataSource: TCPViewerToolbarDataSource
    private let filterController = PacketQuickFilterViewController()
    private var helperSheetController: NSHostingController<TCPViewerNetworkHelperOnboardingSheet>?
    private var helperSheetWindow: NSWindow?
    private var isHelperOnboardingManuallyPresented = false
    private var licenseStatusObserver: NSObjectProtocol?

    init(services: TCPViewerServiceRegistry, configuration: AppConfiguration, initialURL: URL? = nil,
         startsWithLiveTab: Bool = true) {
        self.services = services
        self.configuration = configuration
        self.toolbarDataSource = TCPViewerToolbarDataSource(userDefaults: configuration.userDefaults)
        self.liveWorkspace = TCPViewerCaptureWorkspace(services: services, userDefaults: configuration.userDefaults,
                                                      interfaceHistoryStore: configuration.interfaceSelectionHistory)
        let window = TCPViewerWorkspaceWindow(contentViewController: workspaceViewController)
        window.title = initialURL?.lastPathComponent ?? "TCP Viewer"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .automatic
        }
        window.setContentSize(Self.defaultContentSize(for: window))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.delegate = self
        window.shortcutHandler = { [weak self] in self?.handleTabShortcut($0) ?? false }
        window.focusHandler = { [weak self] in self?.focusPane(containing: $0) }
        configureTabs()
        if startsWithLiveTab && initialURL == nil { newWorkspaceTab(nil) }
        TCPViewerMCPServiceProvider.shared.register(source: automationSource, window: window)
        setupToolbar()
        setupQuickFilters()
        observeLicenseStatusChanges()
        // Persist size and position across launches. If a saved frame exists
        // for this name, it overrides the default size/center set above.
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // File-only windows still need capture interfaces for CLI and MCP commands.
        liveWorkspace.controller.performInitialLoadIfNeeded()
        if let initialURL {
            importCaptureURLs([initialURL], automaticNewTab: true)
        }
    }

    // Tab creation allocates metadata first; selecting it is the only pane factory call.
    @IBAction func newWorkspaceTab(_ sender: Any?) {
        guard !isClosingWorkspace else { return }
        let tab = TCPViewerWorkspaceTab(source: liveWorkspace)
        tabs.append(tab)
        selectTab(tab.id)
    }

    func selectTab(_ id: UUID, recordsHistory: Bool = true) {
        guard let next = tabs.first(where: { $0.id == id }), !isClosingWorkspace else { return }
        if selectedTabID == id { return }
        if let previous = selectedTab {
            previous.sidebarNavigation = workspaceViewController.sidebar.saveNavigationState()
            _ = previous.displayTitle
            previous.deactivate()
        }
        selectedTabID = id
        if recordsHistory { history.visit(id) }
        workspaceViewController.sidebar.restoreNavigationState(next.sidebarNavigation)
        guard let pane = next.openPane(using: { source in
            self.makePane(source: source)
        }) else { return }
        guard let content = next.contentController else { return }
        workspaceViewController.show(content, tabCount: tabs.count)
        next.activate()
        updateTabBar()
        renderToolbar()
        window?.makeFirstResponder(pane.view)
    }

    private func makePane(
        source: TCPViewerCaptureWorkspace,
        paneState: NetworkInspectorPaneState? = nil
    ) -> TCPViewerRootViewController {
        let model = NetworkInspectorViewModel(
            services: source.controller.services,
            captureWorkspace: source,
            freshPane: paneState == nil && source.kind == .live,
            userDefaults: configuration.userDefaults,
            interfaceHistoryStore: configuration.interfaceSelectionHistory,
            paneState: paneState
        )
        let pane = TCPViewerRootViewController(
            viewModel: model,
            configuration: configuration,
            sharedSidebar: workspaceViewController.sidebar
        )
        pane.delegate = self
        pane.importHandler = { [weak self] urls, completion in
            guard let self else {
                completion(TCPViewerCaptureImportResult(
                    importedURLs: [],
                    error: TCPViewerWorkspaceImporter.cancelledError
                ))
                return
            }
            self.importCaptureURLs(urls, completion: completion)
        }
        pane.sidebarVisibilityHandler = { [weak self, weak model] visible in
            guard let self, let model else { return }
            self.workspaceViewController.setSidebarVisible(visible, viewModel: model)
        }
        return pane
    }

    @IBAction func toggleSplitView(_ sender: Any?) {
        guard let selectedTab else { return }
        if selectedTab.isSplitViewVisible {
            selectedTab.closeSplitView()
            if let firstPane = selectedTab.firstPane {
                window?.makeFirstResponder(firstPane.view)
            }
        } else if let pane = selectedTab.openSecondPane(using: { source, state in
            self.makePane(source: source, paneState: state)
        }) {
            window?.makeFirstResponder(pane.view)
        }
        renderToolbar()
    }

    private func openInSplitView(
        from controller: TCPViewerRootViewController,
        selection: PacketSourceListSelection,
        preserving originalSelection: PacketSourceListSelection
    ) {
        guard let selectedTab, let firstPane = selectedTab.firstPane else { return }
        if controller === firstPane {
            firstPane.selectSourceListWhenAvailable(originalSelection)
        }
        let pane = selectedTab.openSecondPane { source, state in
            self.makePane(source: source, paneState: state)
        }
        guard let pane else { return }
        pane.selectSourceListWhenAvailable(selection)
        selectedTab.focus(pane)
        window?.makeFirstResponder(pane.view)
        renderToolbar()
    }

    private func focusPane(containing responder: NSResponder?) {
        guard let content = selectedTab?.contentController,
              let pane = content.pane(containing: responder),
              content.focusedPane !== pane else { return }
        content.focus(pane)
        renderToolbar()
    }

    @IBAction func closeSelectedTab(_ sender: Any?) { if let id = selectedTabID { closeTab(id) } }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 { window?.performClose(nil); return }
        let selection = TCPViewerWorkspaceTabOrder.selectionAfterClosing(id, selectedID: selectedTabID, ids: tabs.map(\.id))
        let tab = tabs.remove(at: index)
        history.remove(id)
        tab.close()
        if selectedTabID == id { selectedTabID = nil; if let selection { selectTab(selection) } }
        updateTabBar()
    }

    func closeOtherTabs(keeping id: UUID) {
        selectTab(id)
        TCPViewerWorkspaceTabOrder.tabsToClose(except: id, ids: tabs.map(\.id)).forEach(closeTab)
    }

    func closeTabsToRight(of id: UUID) {
        let ids = TCPViewerWorkspaceTabOrder.tabsToClose(toRightOf: id, ids: tabs.map(\.id))
        if let selectedTabID, ids.contains(selectedTabID) { selectTab(id) }
        ids.forEach(closeTab)
    }

    func importCaptureURLs(_ urls: [URL], automaticNewTab: Bool = false,
                           completion: @escaping (TCPViewerCaptureImportResult) -> Void = { _ in }) {
        importer.open(urls, automaticNewTab: automaticNewTab, completion: completion)
    }

    func makeOfflineWorkspace() -> TCPViewerCaptureWorkspace {
        let offlineServices = TCPViewerServiceRegistry(core: services.core, networkHelperTool: services.networkHelperTool)
        return TCPViewerCaptureWorkspace(services: offlineServices, kind: .offline, userDefaults: configuration.userDefaults)
    }

    // Placement commits only after import succeeds; replacement retains the destination's position.
    func placeImportedWorkspace(_ source: TCPViewerCaptureWorkspace, title: String, replacing id: UUID?) -> Bool {
        guard !isClosingWorkspace else { return false }
        let tab = TCPViewerWorkspaceTab(id: id ?? UUID(), source: source, title: title)
        if let id {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
            let previous = tabs[index]
            tabs[index] = tab
            previous.close()
            if selectedTabID == id { selectedTabID = nil }
        } else { tabs.append(tab) }
        selectTab(tab.id)
        return true
    }

    @IBAction func exportSessionAsPcap(_ sender: Any?) { rootViewController.exportSession(format: .pcap) }
    @IBAction func exportSessionAsPcapng(_ sender: Any?) { rootViewController.exportSession(format: .pcapng) }
    @IBAction func exportSessionToFile(_ sender: Any?) { rootViewController.exportTCPViewSession() }

    private func configureTabs() {
        let bar = workspaceViewController.tabBar
        bar.onAdd = { [weak self] in self?.newWorkspaceTab(nil) }
        bar.onSelect = { [weak self] in self?.selectTab($0) }
        bar.onClose = { [weak self] in self?.closeTab($0) }
        bar.onCloseOthers = { [weak self] in self?.closeOtherTabs(keeping: $0) }
        bar.onCloseToRight = { [weak self] in self?.closeTabsToRight(of: $0) }
        bar.onBack = { [weak self] in self?.navigateHistory(forward: false) }
        bar.onForward = { [weak self] in self?.navigateHistory(forward: true) }
        bar.onMove = { [weak self] id, insertion in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            let destination = TCPViewerWorkspaceTabOrder.destinationIndex(from: index, insertionIndex: insertion, count: self.tabs.count)
            self.tabs.insert(self.tabs.remove(at: index), at: destination)
            self.updateTabBar()
        }
        workspaceViewController.importHandler = { [weak self] in self?.importCaptureURLs($0) }
    }

    private func updateTabBar() {
        let validIDs = Set(tabs.map(\.id))
        workspaceViewController.setTabCount(tabs.count)
        workspaceViewController.tabBar.update(items: tabs.map { .init(id: $0.id, title: $0.displayTitle, isSnapshot: $0.isOffline) },
                                             selectedID: selectedTabID, canGoBack: history.canGoBack(validIDs: validIDs),
                                             canGoForward: history.canGoForward(validIDs: validIDs))
    }

    private func navigateHistory(forward: Bool) {
        let validIDs = Set(tabs.map(\.id))
        let id = forward ? history.goForward(validIDs: validIDs) : history.goBack(validIDs: validIDs)
        if let id { selectTab(id, recordsHistory: false) }
    }

    @IBAction func navigateBackInTabHistory(_ sender: Any?) {
        navigateHistory(forward: false)
    }

    @IBAction func navigateForwardInTabHistory(_ sender: Any?) {
        navigateHistory(forward: true)
    }

    private func selectAdjacentTab(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs.count > 1 else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    // Handle tab keys in this window only, leaving sheets and auxiliary windows untouched.
    func handleTabShortcut(_ event: NSEvent) -> Bool {
        guard window?.attachedSheet == nil, !isClosingWorkspace else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if flags == [.command] {
            if event.keyCode == kVK_ANSI_T { newWorkspaceTab(nil); return true }
            if event.keyCode == kVK_ANSI_W { closeSelectedTab(nil); return true }
            if event.keyCode == kVK_ANSI_LeftBracket { navigateBackInTabHistory(nil); return true }
            if event.keyCode == kVK_ANSI_RightBracket { navigateForwardInTabHistory(nil); return true }
        }
        if event.keyCode == kVK_Tab && (flags == [.control] || flags == [.control, .shift]) {
            selectAdjacentTab(flags.contains(.shift) ? -1 : 1); return true
        }
        if flags == [.command, .shift] {
            if event.keyCode == kVK_ANSI_LeftBracket { selectAdjacentTab(-1); return true }
            if event.keyCode == kVK_ANSI_RightBracket { selectAdjacentTab(1); return true }
            let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            if let index = keys.firstIndex(of: Int(event.keyCode)), tabs.indices.contains(index) { selectTab(tabs[index].id); return true }
        }
        return false
    }

    private static let frameAutosaveName = "TCPViewer.MainWindow"
    private static let defaultScreenRatio: CGFloat = 0.85

    // Choose a display-sized launch frame without imposing an app-level resizing minimum.
    private static func defaultContentSize(for window: NSWindow) -> NSSize {
        let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSSize(width: visibleFrame.width * defaultScreenRatio, height: visibleFrame.height * defaultScreenRatio)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let licenseStatusObserver {
            NotificationCenter.default.removeObserver(licenseStatusObserver)
        }
    }

    @IBAction func openDocumentPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        TCPViewerCaptureFileImportPolicy.configureOpenPanel(panel)
        if panel.runModal() == .OK { importCaptureURLs(panel.urls) }
    }

    @IBAction func saveDocument(_ sender: Any?) {
        rootViewController.saveDocument()
    }

    @IBAction func saveDocumentAs(_ sender: Any?) {
        rootViewController.exportDocument(format: .pcapng)
    }

    @IBAction func toggleInspector(_ sender: Any?) {
        rootViewController.toggleInspector()
    }

    @IBAction func focusStructuredFilter(_ sender: Any?) {
        rootViewController.focusStructuredFilter()
    }

    @IBAction func focusSidebarFilter(_ sender: Any?) {
        rootViewController.focusSidebarFilter()
    }

    @IBAction func focusPacketDetailFilter(_ sender: Any?) {
        rootViewController.focusPacketDetailFilter()
    }

    @IBAction func clearAllPackets(_ sender: Any?) {
        rootViewController.clearAllPackets()
    }

    // Route the Tools action through the same root controller used by the packet context menu.
    @IBAction func followSelectedStream(_ sender: Any?) {
        rootViewController.followSelectedStream()
    }

    @IBAction func showEndpointStatistics(_ sender: Any?) {
        rootViewController.showEndpointStatistics()
    }

    private func setupToolbar() {
        toolbarDataSource.delegate = self
        window?.toolbar = toolbarDataSource.toolbar
        window?.toolbarStyle = .unified
        toolbarDataSource.installSplitViewItemIfNeeded()
        toolbarDataSource.setAvailableUpdateCount((NSApp.delegate as? AppDelegate)?.currentAvailableUpdateCount() ?? 0)
    }

    // Update the independent release badge without rebuilding the capture toolbar state.
    func updateAvailableBuildCount(_ count: Int) {
        toolbarDataSource.setAvailableUpdateCount(count)
    }

    private func setupQuickFilters() {
        filterController.delegate = self
        if let pane = selectedTab?.pane { filterController.render(snapshot: pane.viewModel.snapshot) }
        window?.addTitlebarAccessoryViewController(filterController)
    }

    private func renderToolbar() {
        guard selectedTab?.pane != nil else { return }
        updateTabBar()
        let snapshot = rootViewController.viewModel.snapshot
        toolbarDataSource.render(
            snapshot: snapshot,
            inspectorViewModel: rootViewController.viewModel,
            isLicenseAuthorized: TCPViewerLicenseService.shared.isLicenseAuthorized,
            isSplitViewVisible: selectedTab?.isSplitViewVisible == true
        )
        filterController.render(snapshot: snapshot)
        window?.title = selectedTab?.displayTitle ?? "TCP Viewer"
    }

    private func observeLicenseStatusChanges() {
        licenseStatusObserver = NotificationCenter.default.addObserver(
            forName: TCPViewerLicenseService.statusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.renderToolbar()
        }
    }

    private func presentHelperOnboarding(
        snapshot: TCPViewerNetworkHelperToolSnapshot,
        isManuallyPresented: Bool = false
    ) {
        if isManuallyPresented {
            isHelperOnboardingManuallyPresented = true
        }

        if let helperSheetController {
            helperSheetController.rootView = makeHelperOnboardingView(snapshot: snapshot)
            return
        }

        guard let window else {
            return
        }

        let controller = NSHostingController(rootView: makeHelperOnboardingView(snapshot: snapshot))
        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.styleMask = [.titled, .closable]
        helperSheetController = controller
        helperSheetWindow = sheetWindow
        window.beginSheet(sheetWindow)
    }

    private func updateHelperOnboardingSheet() {
        guard let helperSheetController else {
            return
        }

        if shouldKeepHelperOnboardingSheetVisible {
            helperSheetController.rootView = makeHelperOnboardingView(snapshot: rootViewController.viewModel.networkHelperToolSnapshot)
        } else {
            dismissHelperOnboarding()
        }
    }

    private var shouldKeepHelperOnboardingSheetVisible: Bool {
        if isHelperOnboardingManuallyPresented {
            return rootViewController.viewModel.networkHelperToolSnapshot.status != .ready
        }

        return rootViewController.viewModel.shouldPresentNetworkHelperOnboarding
    }

    private func dismissHelperOnboarding() {
        isHelperOnboardingManuallyPresented = false
        guard helperSheetController != nil, let sheet = helperSheetWindow else {
            self.helperSheetController = nil
            helperSheetWindow = nil
            return
        }

        window?.endSheet(sheet)
        self.helperSheetController = nil
        helperSheetWindow = nil
    }

    private func makeHelperOnboardingView(snapshot: TCPViewerNetworkHelperToolSnapshot) -> TCPViewerNetworkHelperOnboardingSheet {
        TCPViewerNetworkHelperOnboardingSheet(
            snapshot: snapshot,
            onInstall: { [weak self] in self?.rootViewController.installNetworkHelperTool() },
            onRepair: { [weak self] in self?.rootViewController.repairNetworkHelperTool() },
            onOpenSystemSettings: { [weak self] in self?.rootViewController.openNetworkHelperSystemSettings() },
            onRelaunch: { [weak self] in self?.rootViewController.relaunchTCPViewer() },
            onContinueOffline: { [weak self] in
                self?.rootViewController.dismissNetworkHelperOnboarding()
                self?.dismissHelperOnboarding()
            }
        )
    }
}

extension TCPViewerWindowController: TCPViewerRootViewControllerDelegate {
    // Auxiliary windows must reattach their original pane before changing its selection.
    func tcpviewerRootViewControllerDidRequestActivation(_ controller: TCPViewerRootViewController) {
        guard let tab = tabs.first(where: { $0.contains(controller) }) else { return }
        if selectedTabID != tab.id { selectTab(tab.id) }
        tab.focus(controller)
        renderToolbar()
    }

    func tcpviewerRootViewControllerDidChangeToolbarState(_ controller: TCPViewerRootViewController) {
        guard controller === selectedTab?.pane else { return }
        renderToolbar()
        updateHelperOnboardingSheet()
    }

    func tcpviewerRootViewController(
        _ controller: TCPViewerRootViewController,
        didRequestOpenInNewTab selection: PacketSourceListSelection
    ) {
        guard tabs.first(where: { $0.contains(controller) })?.source === liveWorkspace else {
            return
        }

        newWorkspaceTab(nil)
        rootViewController.selectSourceListWhenAvailable(selection)
    }

    func tcpviewerRootViewController(
        _ controller: TCPViewerRootViewController,
        didRequestOpenInSplitView selection: PacketSourceListSelection,
        preserving originalSelection: PacketSourceListSelection
    ) {
        guard selectedTab?.contains(controller) == true else { return }
        openInSplitView(from: controller, selection: selection, preserving: originalSelection)
    }

    func tcpviewerRootViewController(_ controller: TCPViewerRootViewController, didRequestHelperOnboarding snapshot: TCPViewerNetworkHelperToolSnapshot) {
        presentHelperOnboarding(snapshot: snapshot)
    }

    func tcpviewerRootViewControllerDidRequestPaywall(_ controller: TCPViewerRootViewController) {
        (NSApp.delegate as? AppDelegate)?.showPaywall(self)
    }
}

extension TCPViewerWindowController: TCPViewerToolbarDataSourceDelegate {
    func tcpviewerToolbarDataSource(_ dataSource: TCPViewerToolbarDataSource, didSelectInterface identifier: String) {
        rootViewController.selectInterface(identifier)
    }

    func tcpviewerToolbarDataSourceDidToggleCapture(_ dataSource: TCPViewerToolbarDataSource) {
        rootViewController.toggleLiveCapture()
    }

    func tcpviewerToolbarDataSourceDidRequestClearAllPackets(_ dataSource: TCPViewerToolbarDataSource) {
        clearAllPackets(dataSource)
    }

    func tcpviewerToolbarDataSourceDidRequestExportSession(_ dataSource: TCPViewerToolbarDataSource) {
        // Reuse the root export flow so panel, progress, and error handling stay in one place.
        rootViewController.exportTCPViewSession()
    }

    func tcpviewerToolbarDataSource(_ dataSource: TCPViewerToolbarDataSource, didRequestExport format: CaptureFileFormat) {
        rootViewController.exportSession(format: format)
    }

    func tcpviewerToolbarDataSourceDidToggleInspector(_ dataSource: TCPViewerToolbarDataSource) {
        rootViewController.toggleInspector(placement: .trailing)
    }

    func tcpviewerToolbarDataSourceDidToggleBottomInspector(_ dataSource: TCPViewerToolbarDataSource) {
        rootViewController.toggleInspector(placement: .bottom)
    }

    func tcpviewerToolbarDataSourceDidToggleSplitView(_ dataSource: TCPViewerToolbarDataSource) {
        toggleSplitView(dataSource)
    }

    func tcpviewerToolbarDataSourceDidRequestHelperToolScreen(_ dataSource: TCPViewerToolbarDataSource) {
        presentHelperOnboarding(
            snapshot: rootViewController.viewModel.networkHelperToolSnapshot,
            isManuallyPresented: true
        )
    }

    func tcpviewerToolbarDataSourceDidRequestPaywall(_ dataSource: TCPViewerToolbarDataSource) {
        (NSApp.delegate as? AppDelegate)?.showPaywall(self)
    }

    func tcpviewerToolbarDataSourceDidRequestCheckForUpdates(_ dataSource: TCPViewerToolbarDataSource) {
        (NSApp.delegate as? AppDelegate)?.checkForUpdatesFromToolbar()
    }
}

extension TCPViewerWindowController: PacketQuickFilterViewControllerDelegate {
    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didToggle filterID: PacketQuickFilterID) {
        rootViewController.toggleQuickFilter(filterID)
    }

    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didApplyCustomFilter filterID: PacketCustomFilter.ID) {
        rootViewController.applyCustomFilter(filterID)
    }

    func packetQuickFilterViewController(
        _ controller: PacketQuickFilterViewController,
        didRenameCustomFilter filterID: PacketCustomFilter.ID,
        name: String
    ) {
        rootViewController.renameCustomFilter(filterID, name: name)
    }

    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didDuplicateCustomFilter filterID: PacketCustomFilter.ID) {
        rootViewController.duplicateCustomFilter(filterID)
    }

    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didDeleteCustomFilter filterID: PacketCustomFilter.ID) {
        rootViewController.deleteCustomFilter(filterID)
    }

    func packetQuickFilterViewControllerDidRequestReset(_ controller: PacketQuickFilterViewController) {
        rootViewController.resetQuickFilters()
    }
}

extension TCPViewerWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newWorkspaceTab(_:)) { return !isClosingWorkspace }
        guard selectedTab?.pane != nil, !isClosingWorkspace else { return false }
        if menuItem.action == #selector(toggleSplitView(_:)) {
            menuItem.state = selectedTab?.isSplitViewVisible == true ? .on : .off
            return true
        }
        if menuItem.action == #selector(navigateBackInTabHistory(_:)) {
            return window?.attachedSheet == nil && history.canGoBack(validIDs: Set(tabs.map(\.id)))
        }
        if menuItem.action == #selector(navigateForwardInTabHistory(_:)) {
            return window?.attachedSheet == nil && history.canGoForward(validIDs: Set(tabs.map(\.id)))
        }
        if [#selector(exportSessionAsPcap(_:)), #selector(exportSessionAsPcapng(_:)), #selector(exportSessionToFile(_:))].contains(menuItem.action) {
            return rootViewController.viewModel.snapshot.totalPacketCount > 0 && !rootViewController.viewModel.snapshot.base.loadState.canCancel
        }
        if menuItem.action == #selector(followSelectedStream(_:)) {
            let row = rootViewController.selectedFollowRow
            menuItem.title = (row?.followStreamProtocol ?? .tcp).menuTitle
            return row != nil
        }
        guard menuItem.action == #selector(clearAllPackets(_:)) else {
            return true
        }

        // Keep the keyboard command disabled whenever the toolbar clear button is disabled.
        let snapshot = rootViewController.viewModel.snapshot
        return snapshot.totalPacketCount > 0 && !snapshot.base.loadState.canCancel
    }
}

private final class TCPViewerWorkspaceWindow: NSWindow {
    var shortcutHandler: ((NSEvent) -> Bool)?
    var focusHandler: ((NSResponder?) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           let contentView,
           let hitView = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) {
            focusHandler?(hitView)
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let didChange = super.makeFirstResponder(responder)
        if didChange { focusHandler?(responder) }
        return didChange
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if shortcutHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

extension TCPViewerWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isReadyToClose { return true }
        guard !isClosingWorkspace else { return false }
        isClosingWorkspace = true
        importer.cancelAll()
        liveWorkspace.close { [weak self] succeeded in
            guard let self else { return }
            guard succeeded else { self.isClosingWorkspace = false; return }
            self.isReadyToClose = true
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosingWorkspace = true
        liveWorkspace.close { [liveWorkspace] _ in _ = liveWorkspace }
        importer.cancelAll()
        tabs.forEach { $0.close() }
        tabs.removeAll()
        selectedTabID = nil
        history = TCPViewerWorkspaceTabHistory()
        updateTabBar()
        dismissHelperOnboarding()
        TCPViewerMCPServiceProvider.shared.unregister(source: automationSource)
        window?.toolbar = nil
        closeHandler?()
        closeHandler = nil
    }
}
