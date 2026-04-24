import AppKit
import PcapPlusPlusCore
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let captureSource = NSToolbarItem.Identifier("Packetman.CaptureSource")
    static let captureToggle = NSToolbarItem.Identifier("Packetman.CaptureToggle")
    static let status = NSToolbarItem.Identifier("Packetman.Status")
    static let share = NSToolbarItem.Identifier("Packetman.Share")
    static let inspector = NSToolbarItem.Identifier("Packetman.Inspector")
}

final class PacketmanToolbarViewModel {
    private(set) var selectedInterfaceTitle = "Interface"
    private(set) var interfaces: [CaptureInterfaceSummary] = []
    private(set) var selectedInterfaceID: String?
    private(set) var isCaptureLocked = false
    private(set) var captureButtonTitle = "Start"
    private(set) var captureButtonImageName = "play.fill"
    private(set) var captureButtonTint = NSColor.systemGreen
    private(set) var canUseCaptureButton = false
    private(set) var canSave = false
    private(set) var canSaveAs = false
    private(set) var isInspectorVisible = true
    private(set) var statusText = "Packetman | Idle"
    private(set) var emphasizedText: String?
    private(set) var statusTint = NSColor.secondaryLabelColor
    private(set) var helpText = ""

    // Build toolbar-only presentation state from the root inspector snapshot.
    func render(snapshot: NetworkInspectorSnapshot, viewModel: NetworkInspectorViewModel) {
        interfaces = snapshot.base.sessionState.interfaceInventory
        selectedInterfaceID = snapshot.base.sessionState.selectedInterfaceID
        selectedInterfaceTitle = viewModel.selectedInterfaceTitle()
        isCaptureLocked = snapshot.isCaptureLocked
        captureButtonTitle = viewModel.captureButtonTitle()
        captureButtonImageName = viewModel.captureButtonSystemImage()
        captureButtonTint = snapshot.base.sessionState.canStop ? .systemRed : .systemGreen
        canUseCaptureButton = snapshot.base.sessionState.canStart || snapshot.base.sessionState.canStop
        canSave = snapshot.base.documentState.canSave
        canSaveAs = snapshot.base.documentState.canSaveAs
        isInspectorVisible = snapshot.isInspectorVisible
        statusTint = Self.tint(for: snapshot)
        statusText = Self.statusText(for: snapshot)
        emphasizedText = Self.emphasizedText(for: snapshot)
        helpText = [
            snapshot.base.sessionState.statusMessage,
            "\(snapshot.totalPacketCount) packets",
            "\(snapshot.droppedPacketCount) dropped",
            "\(snapshot.malformedPacketCount) malformed",
        ].joined(separator: " | ")
    }

    private static func tint(for snapshot: NetworkInspectorSnapshot) -> NSColor {
        if snapshot.base.sessionState.phase == .failed || snapshot.base.documentState.phase == .failed {
            return .systemRed
        }

        if snapshot.base.documentState.isPartialResult || snapshot.droppedPacketCount > 0 || snapshot.malformedPacketCount > 0 {
            return .systemOrange
        }

        if [.starting, .running, .paused, .stopping].contains(snapshot.base.sessionState.phase) ||
            [.opening, .loaded, .saving, .saved, .reopening].contains(snapshot.base.documentState.phase) {
            return .systemGreen
        }

        return .secondaryLabelColor
    }

    private static func statusText(for snapshot: NetworkInspectorSnapshot) -> String {
        if snapshot.base.sessionState.phase == .running {
            return "Packetman | Listening on"
        }

        if snapshot.base.loadState.progress.phase == .loading {
            return "Packetman | Loading"
        }

        if snapshot.base.documentState.phase == .loaded || snapshot.base.documentState.phase == .saved {
            return "Packetman | Viewing"
        }

        if snapshot.base.sessionState.phase == .failed || snapshot.base.documentState.phase == .failed {
            return "Packetman | Attention"
        }

        return "Packetman | \(snapshot.base.sessionState.phase.rawValue.capitalized)"
    }

    private static func emphasizedText(for snapshot: NetworkInspectorSnapshot) -> String? {
        if snapshot.base.sessionState.phase == .running {
            guard let interface = snapshot.base.sessionState.selectedInterface else {
                return "selected interface"
            }

            if let ipv4Address = interface.addresses.first(where: { $0.family == .ipv4 })?.value {
                return ipv4Address
            }

            return interface.friendlyName ?? interface.displayName
        }

        if snapshot.base.loadState.progress.phase == .loading {
            return snapshot.base.loadState.progress.message
        }

        if snapshot.base.documentState.phase == .loaded || snapshot.base.documentState.phase == .saved {
            return snapshot.base.documentState.fileURL?.lastPathComponent ?? "\(snapshot.totalPacketCount) packets"
        }

        if let error = snapshot.base.sessionState.lastError ?? snapshot.base.documentState.lastError {
            return error.message
        }

        return snapshot.base.sessionState.selectedInterface.map { $0.friendlyName ?? $0.displayName }
    }
}

final class PacketmanWindowController: NSWindowController {
    let rootViewController: PacketmanRootViewController

    private let toolbarViewModel = PacketmanToolbarViewModel()
    private let interfacePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 30), pullsDown: false)
    private let captureButton = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    private let statusView = PacketmanToolbarStatusView(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
    private let sharePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 98, height: 30), pullsDown: true)
    private let inspectorButton = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))
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
        let toolbar = NSToolbar(identifier: "Packetman.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        configureToolbarViews()
    }

    private func configureToolbarViews() {
        interfacePopup.target = self
        interfacePopup.action = #selector(interfaceChanged(_:))
        interfacePopup.controlSize = .regular

        captureButton.target = self
        captureButton.action = #selector(captureButtonPressed(_:))
        captureButton.bezelStyle = .circular
        captureButton.isBordered = false

        sharePopup.controlSize = .regular
        sharePopup.addItem(withTitle: "Share")
        sharePopup.addItem(withTitle: "Save")
        sharePopup.addItem(withTitle: "Export as pcap")
        sharePopup.addItem(withTitle: "Export as pcapng")
        sharePopup.target = self
        sharePopup.action = #selector(shareActionSelected(_:))

        inspectorButton.target = self
        inspectorButton.action = #selector(inspectorButtonPressed(_:))
        inspectorButton.bezelStyle = .texturedRounded
        inspectorButton.image = PacketmanUI.image("sidebar.trailing")
        inspectorButton.imagePosition = .imageOnly
        inspectorButton.toolTip = "Toggle Inspector View"
    }

    private func renderToolbar() {
        let snapshot = rootViewController.viewModel.snapshot
        toolbarViewModel.render(snapshot: snapshot, viewModel: rootViewController.viewModel)
        renderInterfacePopup()
        renderCaptureButton()
        renderSharePopup()
        renderInspectorButton()
        statusView.render(viewModel: toolbarViewModel)
        window?.title = snapshot.base.documentState.fileURL?.lastPathComponent ?? "Packetman"
    }

    private func renderInterfacePopup() {
        interfacePopup.removeAllItems()
        if toolbarViewModel.interfaces.isEmpty {
            interfacePopup.addItem(withTitle: "No Interfaces")
            interfacePopup.isEnabled = false
            return
        }

        for interface in toolbarViewModel.interfaces {
            let title = interface.friendlyName ?? interface.displayName
            interfacePopup.addItem(withTitle: title)
            interfacePopup.lastItem?.representedObject = interface.id
            interfacePopup.lastItem?.isEnabled = interface.isSelectable && !toolbarViewModel.isCaptureLocked
        }

        if let selectedID = toolbarViewModel.selectedInterfaceID,
           let index = toolbarViewModel.interfaces.firstIndex(where: { $0.id == selectedID }) {
            interfacePopup.selectItem(at: index)
        }

        interfacePopup.isEnabled = !toolbarViewModel.isCaptureLocked
    }

    private func renderCaptureButton() {
        captureButton.image = PacketmanUI.image(toolbarViewModel.captureButtonImageName)
        captureButton.contentTintColor = .white
        captureButton.toolTip = toolbarViewModel.captureButtonTitle
        captureButton.isEnabled = toolbarViewModel.canUseCaptureButton
        captureButton.alphaValue = toolbarViewModel.canUseCaptureButton ? 1 : 0.45
        captureButton.wantsLayer = true
        captureButton.layer?.cornerRadius = 16
        captureButton.layer?.backgroundColor = toolbarViewModel.captureButtonTint.cgColor
    }

    private func renderSharePopup() {
        sharePopup.item(at: 1)?.isEnabled = toolbarViewModel.canSave
        sharePopup.item(at: 2)?.isEnabled = toolbarViewModel.canSaveAs
        sharePopup.item(at: 3)?.isEnabled = toolbarViewModel.canSaveAs
        sharePopup.selectItem(at: 0)
    }

    private func renderInspectorButton() {
        inspectorButton.state = toolbarViewModel.isInspectorVisible ? .on : .off
    }

    @objc private func interfaceChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else {
            return
        }

        rootViewController.selectInterface(identifier)
    }

    @objc private func captureButtonPressed(_ sender: NSButton) {
        rootViewController.toggleLiveCapture()
    }

    @objc private func shareActionSelected(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            rootViewController.saveDocument()
        case 2:
            rootViewController.exportDocument(format: .pcap)
        case 3:
            rootViewController.exportDocument(format: .pcapng)
        default:
            break
        }

        sender.selectItem(at: 0)
    }

    @objc private func inspectorButtonPressed(_ sender: NSButton) {
        rootViewController.toggleInspector()
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

extension PacketmanWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.captureSource, .captureToggle, .flexibleSpace, .status, .share, .inspector]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.captureSource, .captureToggle, .flexibleSpace, .status, .flexibleSpace, .share, .inspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .captureSource:
            item.label = "Interface"
            item.view = interfacePopup
        case .captureToggle:
            item.label = "Capture"
            item.view = captureButton
        case .status:
            item.label = "Status"
            item.view = statusView
        case .share:
            item.label = "Share"
            item.view = sharePopup
        case .inspector:
            item.label = "Inspector"
            item.view = inspectorButton
        default:
            return nil
        }

        return item
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

final class PacketmanToolbarStatusView: NSView {
    private let dot = NSView()
    private let statusLabel = PacketmanUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), color: .secondaryLabelColor)
    private let emphasizedLabel = PacketmanUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(viewModel: PacketmanToolbarViewModel) {
        dot.layer?.backgroundColor = viewModel.statusTint.cgColor
        statusLabel.stringValue = viewModel.statusText
        emphasizedLabel.stringValue = viewModel.emphasizedText ?? ""
        emphasizedLabel.isHidden = viewModel.emphasizedText == nil
        toolTip = viewModel.helpText
    }

    private func setupLayout() {
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [dot, statusLabel, emphasizedLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            heightAnchor.constraint(equalToConstant: 26),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
