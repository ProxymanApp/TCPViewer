//
//  TCPViewerWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import PcapPlusPlusCore
import SwiftUI

final class TCPViewerWindowController: NSWindowController {
    let rootViewController: TCPViewerRootViewController

    private let toolbarDataSource = TCPViewerToolbarDataSource()
    private let filterController = PacketQuickFilterViewController()
    private var helperSheetController: NSHostingController<TCPViewerNetworkHelperOnboardingSheet>?
    private var helperSheetWindow: NSWindow?
    private var isHelperOnboardingManuallyPresented = false
    private var licenseStatusObserver: NSObjectProtocol?

    init(services: TCPViewerServiceRegistry, configuration: AppConfiguration, initialURL: URL? = nil) {
        let viewModel = NetworkInspectorViewModel(
            services: services,
            interfaceHistoryStore: configuration.interfaceSelectionHistory
        )
        self.rootViewController = TCPViewerRootViewController(viewModel: viewModel, configuration: configuration)
        let window = NSWindow(contentViewController: rootViewController)
        window.title = initialURL?.lastPathComponent ?? "TCP Viewer"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .automatic
        }
        window.contentMinSize = Self.contentMinSize
        window.setContentSize(Self.defaultContentSize(for: window))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.rootViewController.delegate = self
        setupToolbar()
        setupQuickFilters()
        observeLicenseStatusChanges()
        // Persist size and position across launches. If a saved frame exists
        // for this name, it overrides the default size/center set above.
        window.setFrameAutosaveName(Self.frameAutosaveName)

        if let initialURL {
            rootViewController.openDocument(at: initialURL)
        }
    }

    private static let frameAutosaveName = "TCPViewer.MainWindow"
    private static let contentMinSize = NSSize(width: 1_180, height: 600)
    private static let defaultScreenRatio: CGFloat = 0.85

    private static func defaultContentSize(for window: NSWindow) -> NSSize {
        let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = max(contentMinSize.width, visibleFrame.width * defaultScreenRatio)
        let height = max(contentMinSize.height, visibleFrame.height * defaultScreenRatio)
        return NSSize(width: width, height: height)
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
        rootViewController.showOpenPanel()
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

    private func setupToolbar() {
        toolbarDataSource.delegate = self
        window?.toolbar = toolbarDataSource.toolbar
        window?.toolbarStyle = .unified
    }

    private func setupQuickFilters() {
        filterController.delegate = self
        filterController.render(snapshot: rootViewController.viewModel.snapshot)
        window?.addTitlebarAccessoryViewController(filterController)
    }

    private func renderToolbar() {
        let snapshot = rootViewController.viewModel.snapshot
        toolbarDataSource.render(
            snapshot: snapshot,
            inspectorViewModel: rootViewController.viewModel,
            isLicenseAuthorized: TCPViewerLicenseService.shared.isLicenseAuthorized
        )
        filterController.render(snapshot: snapshot)
        window?.title = snapshot.base.documentState.fileURL?.lastPathComponent ?? "TCP Viewer"
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
    func tcpviewerRootViewControllerDidChangeToolbarState(_ controller: TCPViewerRootViewController) {
        renderToolbar()
        updateHelperOnboardingSheet()
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
        rootViewController.clearAllPackets()
    }

    func tcpviewerToolbarDataSource(_ dataSource: TCPViewerToolbarDataSource, didRequestExport format: CaptureFileFormat) {
        rootViewController.exportSession(format: format)
    }

    func tcpviewerToolbarDataSourceDidToggleInspector(_ dataSource: TCPViewerToolbarDataSource) {
        rootViewController.toggleInspector()
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

    func packetQuickFilterViewController(_ controller: PacketQuickFilterViewController, didDeleteCustomFilter filterID: PacketCustomFilter.ID) {
        rootViewController.deleteCustomFilter(filterID)
    }

    func packetQuickFilterViewControllerDidRequestReset(_ controller: PacketQuickFilterViewController) {
        rootViewController.resetQuickFilters()
    }
}
