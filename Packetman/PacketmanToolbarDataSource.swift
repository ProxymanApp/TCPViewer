import AppKit
import PcapPlusPlusCore

private enum PacketmanToolbarItemMetadata: String, CaseIterable {
    case captureSource = "CaptureSource"
    case captureToggle = "CaptureToggle"
    case status = "Status"
    case share = "Share"
    case inspector = "Inspector"
    case flexibleSpace

    var identifier: NSToolbarItem.Identifier {
        switch self {
        case .flexibleSpace:
            .flexibleSpace
        default:
            NSToolbarItem.Identifier("Packetman.\(rawValue)")
        }
    }
}

protocol PacketmanToolbarDataSourceDelegate: AnyObject {
    func packetmanToolbarDataSource(_ dataSource: PacketmanToolbarDataSource, didSelectInterface identifier: String)
    func packetmanToolbarDataSourceDidToggleCapture(_ dataSource: PacketmanToolbarDataSource)
    func packetmanToolbarDataSourceDidRequestSave(_ dataSource: PacketmanToolbarDataSource)
    func packetmanToolbarDataSource(_ dataSource: PacketmanToolbarDataSource, didRequestExport format: CaptureFileFormat)
    func packetmanToolbarDataSourceDidToggleInspector(_ dataSource: PacketmanToolbarDataSource)
}

final class PacketmanToolbarDataSource: NSObject {
    let toolbar: NSToolbar
    weak var delegate: PacketmanToolbarDataSourceDelegate?

    private let viewModel = PacketmanToolbarViewModel()
    private let interfacePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 30), pullsDown: false)
    private let captureButton = NSButton(frame: NSRect(x: 0, y: 0, width: 86, height: 30))
    private let statusView = PacketmanToolbarStatusView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
    private let sharePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 98, height: 30), pullsDown: true)
    private let inspectorButton = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))

    private var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        PacketmanToolbarItemMetadata.allCases.map(\.identifier)
    }

    private var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        [
            PacketmanToolbarItemMetadata.captureSource.identifier,
            PacketmanToolbarItemMetadata.captureToggle.identifier,
            PacketmanToolbarItemMetadata.flexibleSpace.identifier,
            PacketmanToolbarItemMetadata.status.identifier,
            PacketmanToolbarItemMetadata.flexibleSpace.identifier,
            PacketmanToolbarItemMetadata.share.identifier,
            PacketmanToolbarItemMetadata.inspector.identifier,
        ]
    }

    override init() {
        self.toolbar = NSToolbar(identifier: "Packetman.MainToolbar")
        super.init()
        configureToolbar()
        configureToolbarViews()
    }

    // Apply root state to the toolbar controls without leaking toolbar view ownership to the window.
    func render(snapshot: NetworkInspectorSnapshot, inspectorViewModel: NetworkInspectorViewModel) {
        viewModel.render(snapshot: snapshot, viewModel: inspectorViewModel)
        renderInterfacePopup()
        renderCaptureButton()
        renderSharePopup()
        renderInspectorButton()
        statusView.render(viewModel: viewModel)
    }

    private func configureToolbar() {
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .default
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        if #available(macOS 13.0, *) {
            toolbar.centeredItemIdentifiers = Set([PacketmanToolbarItemMetadata.status.identifier])
        } else {
            toolbar.centeredItemIdentifier = PacketmanToolbarItemMetadata.status.identifier
        }
    }

    private func configureToolbarViews() {
        constrainToolbarView(interfacePopup, width: 150, height: 30)
        constrainToolbarView(captureButton, width: 86, height: 30)
        constrainToolbarView(statusView, width: 360, height: 28)
        constrainToolbarView(sharePopup, width: 98, height: 30)
        constrainToolbarView(inspectorButton, width: 34, height: 30)

        interfacePopup.target = self
        interfacePopup.action = #selector(interfaceChanged(_:))
        interfacePopup.controlSize = .regular

        captureButton.target = self
        captureButton.action = #selector(captureButtonPressed(_:))
        captureButton.bezelStyle = .texturedRounded
        captureButton.controlSize = .regular
        captureButton.imagePosition = .imageLeading
        captureButton.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

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

    private func constrainToolbarView(_ view: NSView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    private func renderInterfacePopup() {
        interfacePopup.removeAllItems()
        if viewModel.interfaces.isEmpty {
            interfacePopup.addItem(withTitle: "No Interfaces")
            interfacePopup.isEnabled = false
            return
        }

        for interface in viewModel.interfaces {
            let title = interface.friendlyName ?? interface.displayName
            interfacePopup.addItem(withTitle: title)
            interfacePopup.lastItem?.representedObject = interface.id
            interfacePopup.lastItem?.isEnabled = interface.isSelectable && !viewModel.isCaptureLocked
        }

        if let selectedID = viewModel.selectedInterfaceID,
           let index = viewModel.interfaces.firstIndex(where: { $0.id == selectedID }) {
            interfacePopup.selectItem(at: index)
        }

        interfacePopup.isEnabled = !viewModel.isCaptureLocked
    }

    private func renderCaptureButton() {
        captureButton.image = PacketmanUI.image(viewModel.captureButtonImageName)
        captureButton.title = viewModel.captureButtonTitle
        captureButton.contentTintColor = viewModel.captureButtonTint
        captureButton.toolTip = viewModel.captureButtonTitle
        captureButton.isEnabled = viewModel.canUseCaptureButton
        captureButton.alphaValue = viewModel.canUseCaptureButton ? 1 : 0.45
    }

    private func renderSharePopup() {
        sharePopup.item(at: 1)?.isEnabled = viewModel.canSave
        sharePopup.item(at: 2)?.isEnabled = viewModel.canSaveAs
        sharePopup.item(at: 3)?.isEnabled = viewModel.canSaveAs
        sharePopup.selectItem(at: 0)
    }

    private func renderInspectorButton() {
        inspectorButton.state = viewModel.isInspectorVisible ? .on : .off
    }

    @objc private func interfaceChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else {
            return
        }

        delegate?.packetmanToolbarDataSource(self, didSelectInterface: identifier)
    }

    @objc private func captureButtonPressed(_ sender: NSButton) {
        delegate?.packetmanToolbarDataSourceDidToggleCapture(self)
    }

    @objc private func shareActionSelected(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            delegate?.packetmanToolbarDataSourceDidRequestSave(self)
        case 2:
            delegate?.packetmanToolbarDataSource(self, didRequestExport: .pcap)
        case 3:
            delegate?.packetmanToolbarDataSource(self, didRequestExport: .pcapng)
        default:
            break
        }

        sender.selectItem(at: 0)
    }

    @objc private func inspectorButtonPressed(_ sender: NSButton) {
        delegate?.packetmanToolbarDataSourceDidToggleInspector(self)
    }
}

extension PacketmanToolbarDataSource: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        allowedItemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultItemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case PacketmanToolbarItemMetadata.captureSource.identifier:
            item.label = "Interface"
            item.paletteLabel = "Interface"
            item.view = interfacePopup
            item.visibilityPriority = .high
        case PacketmanToolbarItemMetadata.captureToggle.identifier:
            item.label = "Capture"
            item.paletteLabel = "Capture"
            item.view = captureButton
            item.visibilityPriority = .high
        case PacketmanToolbarItemMetadata.status.identifier:
            item.label = "Status"
            item.paletteLabel = "Status"
            item.view = statusView
            item.visibilityPriority = .high
        case PacketmanToolbarItemMetadata.share.identifier:
            item.label = "Share"
            item.paletteLabel = "Share"
            item.view = sharePopup
            item.visibilityPriority = .high
        case PacketmanToolbarItemMetadata.inspector.identifier:
            item.label = "Inspector"
            item.paletteLabel = "Inspector"
            item.view = inspectorButton
            item.visibilityPriority = .high
        default:
            return nil
        }

        return item
    }
}

private final class PacketmanToolbarViewModel {
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

private final class PacketmanToolbarStatusView: NSView {
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
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emphasizedLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let stack = NSStackView(views: [dot, statusLabel, emphasizedLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            heightAnchor.constraint(equalToConstant: 28),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
