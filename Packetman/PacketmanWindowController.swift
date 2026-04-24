import AppKit
import PcapPlusPlusCore
import SwiftUI

final class PacketmanWindowController: NSWindowController {
    let rootViewController: PacketmanRootViewController

    private let toolbarDataSource = PacketmanToolbarDataSource()
    private var helperSheetController: NSHostingController<PacketryNetworkHelperOnboardingSheet>?
    private var helperSheetWindow: NSWindow?

    init(services: PacketryServiceRegistry, initialURL: URL? = nil) {
        let viewModel = NetworkInspectorViewModel(services: services)
        self.rootViewController = PacketmanRootViewController(viewModel: viewModel)
        let window = NSWindow(contentViewController: rootViewController)
        window.title = initialURL?.lastPathComponent ?? "Packetman"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 1180, height: 760)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.rootViewController.delegate = self
        setupToolbar()

        if let initialURL {
            rootViewController.openDocument(at: initialURL)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    private func setupToolbar() {
        toolbarDataSource.delegate = self
        window?.toolbar = toolbarDataSource.toolbar
        window?.toolbarStyle = .unified
    }

    private func renderToolbar() {
        let snapshot = rootViewController.viewModel.snapshot
        toolbarDataSource.render(snapshot: snapshot, inspectorViewModel: rootViewController.viewModel)
        window?.title = snapshot.base.documentState.fileURL?.lastPathComponent ?? "Packetman"
    }

    private func presentHelperOnboarding(snapshot: PacketryNetworkHelperToolSnapshot) {
        guard helperSheetController == nil, let window else {
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

        if rootViewController.viewModel.shouldPresentNetworkHelperOnboarding {
            helperSheetController.rootView = makeHelperOnboardingView(snapshot: rootViewController.viewModel.networkHelperToolSnapshot)
        } else {
            dismissHelperOnboarding()
        }
    }

    private func dismissHelperOnboarding() {
        guard helperSheetController != nil, let sheet = helperSheetWindow else {
            self.helperSheetController = nil
            helperSheetWindow = nil
            return
        }

        window?.endSheet(sheet)
        self.helperSheetController = nil
        helperSheetWindow = nil
    }

    private func makeHelperOnboardingView(snapshot: PacketryNetworkHelperToolSnapshot) -> PacketryNetworkHelperOnboardingSheet {
        PacketryNetworkHelperOnboardingSheet(
            snapshot: snapshot,
            onInstall: { [weak self] in self?.rootViewController.installNetworkHelperTool() },
            onRepair: { [weak self] in self?.rootViewController.repairNetworkHelperTool() },
            onRetry: { [weak self] in self?.rootViewController.retryNetworkHelperToolStatus() },
            onOpenSystemSettings: { [weak self] in self?.rootViewController.openNetworkHelperSystemSettings() },
            onRelaunch: { [weak self] in self?.rootViewController.relaunchPacketman() },
            onContinueOffline: { [weak self] in
                self?.rootViewController.dismissNetworkHelperOnboarding()
                self?.dismissHelperOnboarding()
            }
        )
    }
}

extension PacketmanWindowController: PacketmanRootViewControllerDelegate {
    func packetmanRootViewControllerDidChangeToolbarState(_ controller: PacketmanRootViewController) {
        renderToolbar()
        updateHelperOnboardingSheet()
    }

    func packetmanRootViewController(_ controller: PacketmanRootViewController, didRequestHelperOnboarding snapshot: PacketryNetworkHelperToolSnapshot) {
        presentHelperOnboarding(snapshot: snapshot)
    }
}

extension PacketmanWindowController: PacketmanToolbarDataSourceDelegate {
    func packetmanToolbarDataSource(_ dataSource: PacketmanToolbarDataSource, didSelectInterface identifier: String) {
        rootViewController.selectInterface(identifier)
    }

    func packetmanToolbarDataSourceDidToggleCapture(_ dataSource: PacketmanToolbarDataSource) {
        rootViewController.toggleLiveCapture()
    }

    func packetmanToolbarDataSourceDidRequestSave(_ dataSource: PacketmanToolbarDataSource) {
        rootViewController.saveDocument()
    }

    func packetmanToolbarDataSource(_ dataSource: PacketmanToolbarDataSource, didRequestExport format: CaptureFileFormat) {
        rootViewController.exportDocument(format: format)
    }

    func packetmanToolbarDataSourceDidToggleInspector(_ dataSource: PacketmanToolbarDataSource) {
        rootViewController.toggleInspector()
    }
}
