import AppKit
import PcapPlusPlusCore

private enum TCPViewerToolbarItemMetadata: String, CaseIterable {
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
            NSToolbarItem.Identifier("TCPViewer.\(rawValue)")
        }
    }
}

protocol TCPViewerToolbarDataSourceDelegate: AnyObject {
    func tcpviewerToolbarDataSource(_ dataSource: TCPViewerToolbarDataSource, didSelectInterface identifier: String)
    func tcpviewerToolbarDataSourceDidToggleCapture(_ dataSource: TCPViewerToolbarDataSource)
    func tcpviewerToolbarDataSourceDidRequestSave(_ dataSource: TCPViewerToolbarDataSource)
    func tcpviewerToolbarDataSource(_ dataSource: TCPViewerToolbarDataSource, didRequestExport format: CaptureFileFormat)
    func tcpviewerToolbarDataSourceDidToggleInspector(_ dataSource: TCPViewerToolbarDataSource)
}

final class TCPViewerToolbarDataSource: NSObject {
    let toolbar: NSToolbar
    weak var delegate: TCPViewerToolbarDataSourceDelegate?

    private let viewModel = TCPViewerToolbarViewModel()
    private let interfacePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 60, height: 30), pullsDown: false)
    private let captureButton = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))
    private let statusView = TCPViewerToolbarStatusView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
    private let sharePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 42, height: 30), pullsDown: true)
    private let inspectorButton = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))

    private var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        TCPViewerToolbarItemMetadata.allCases.map(\.identifier) + [
            .toggleSidebar,
            .sidebarTrackingSeparator,
        ]
    }

    private var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            TCPViewerToolbarItemMetadata.captureSource.identifier,
            TCPViewerToolbarItemMetadata.captureToggle.identifier,
            TCPViewerToolbarItemMetadata.flexibleSpace.identifier,
            TCPViewerToolbarItemMetadata.status.identifier,
            TCPViewerToolbarItemMetadata.flexibleSpace.identifier,
            TCPViewerToolbarItemMetadata.share.identifier,
            TCPViewerToolbarItemMetadata.inspector.identifier,
        ]
    }

    override init() {
        self.toolbar = NSToolbar(identifier: "TCPViewer.MainToolbar.v2")
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
            toolbar.centeredItemIdentifiers = Set([TCPViewerToolbarItemMetadata.status.identifier])
        } else {
            toolbar.centeredItemIdentifier = TCPViewerToolbarItemMetadata.status.identifier
        }
    }

    private func configureToolbarViews() {
        constrainToolbarView(interfacePopup, width: 60, height: 30)
        constrainToolbarView(captureButton, width: 34, height: 30)
        constrainToolbarView(statusView, width: 360, height: 28)
        constrainToolbarView(sharePopup, width: 42, height: 30)
        constrainToolbarView(inspectorButton, width: 34, height: 30)

        interfacePopup.target = self
        interfacePopup.action = #selector(interfaceChanged(_:))
        interfacePopup.controlSize = .regular
        interfacePopup.menu?.autoenablesItems = false

        captureButton.target = self
        captureButton.action = #selector(captureButtonPressed(_:))
        captureButton.bezelStyle = .texturedRounded
        captureButton.controlSize = .regular
        captureButton.imagePosition = .imageOnly
        captureButton.title = ""
        captureButton.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        sharePopup.controlSize = .regular
        sharePopup.addItem(withTitle: "")
        sharePopup.item(at: 0)?.image = TCPViewerUI.image("square.and.arrow.up")
        sharePopup.addItem(withTitle: "Save")
        sharePopup.addItem(withTitle: "Export as pcap")
        sharePopup.addItem(withTitle: "Export as pcapng")
        sharePopup.imagePosition = .imageOnly
        sharePopup.target = self
        sharePopup.action = #selector(shareActionSelected(_:))
        sharePopup.toolTip = "Share"

        inspectorButton.target = self
        inspectorButton.action = #selector(inspectorButtonPressed(_:))
        inspectorButton.bezelStyle = .texturedRounded
        inspectorButton.image = TCPViewerUI.image("sidebar.trailing")
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
        interfacePopup.menu?.autoenablesItems = false
        if viewModel.interfaces.isEmpty {
            interfacePopup.addItem(withTitle: "No Interfaces")
            interfacePopup.isEnabled = false
            return
        }

        let recentInterfaces = viewModel.lastUsedInterfaceIDs.compactMap { identifier in
            viewModel.interfaces.first { $0.id == identifier }
        }
        let recentInterfaceIDs = Set(recentInterfaces.map(\.id))
        let remainingInterfaces = viewModel.interfaces.filter { !recentInterfaceIDs.contains($0.id) }

        if !recentInterfaces.isEmpty {
            addInterfaceGroupHeader("Last used")
            recentInterfaces.forEach(addInterfaceItem)
            if !remainingInterfaces.isEmpty {
                interfacePopup.menu?.addItem(.separator())
            }
        }

        remainingInterfaces.forEach(addInterfaceItem)
        if !selectInterfaceItem(with: viewModel.selectedInterfaceID) {
            selectFirstInterfaceItem()
        }
        interfacePopup.isEnabled = !viewModel.isCaptureLocked
    }

    private func addInterfaceGroupHeader(_ title: String) {
        // Add a disabled group label so recent interfaces read separately from the full inventory.
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.disabledControlTextColor,
            ]
        )
        item.isEnabled = false
        interfacePopup.menu?.addItem(item)
    }

    private func addInterfaceItem(_ interface: CaptureInterfaceSummary) {
        // Keep each menu item self-identifying so selection does not depend on grouped menu indexes.
        let item = NSMenuItem(title: interface.friendlyName ?? interface.displayName, action: nil, keyEquivalent: "")
        item.representedObject = interface.id
        item.isEnabled = interface.isSelectable && !viewModel.isCaptureLocked
        interfacePopup.menu?.addItem(item)
    }

    @discardableResult
    private func selectInterfaceItem(with identifier: String?) -> Bool {
        // Select by represented identifier because recent grouping changes visible row order.
        guard let identifier, let menu = interfacePopup.menu else {
            return false
        }

        for (index, item) in menu.items.enumerated() where item.representedObject as? String == identifier {
            interfacePopup.selectItem(at: index)
            return true
        }

        return false
    }

    private func selectFirstInterfaceItem() {
        // Avoid leaving the disabled group header as the visible popup title when no selection exists.
        guard let menu = interfacePopup.menu else {
            return
        }

        for (index, item) in menu.items.enumerated() where item.representedObject is String {
            interfacePopup.selectItem(at: index)
            return
        }
    }

    private func renderCaptureButton() {
        captureButton.image = TCPViewerUI.image(viewModel.captureButtonImageName)
        captureButton.contentTintColor = viewModel.captureButtonTint
        captureButton.toolTip = viewModel.captureButtonTitle
        captureButton.isEnabled = viewModel.canUseCaptureButton
        captureButton.alphaValue = viewModel.canUseCaptureButton ? 1 : 0.45
    }

    private func renderSharePopup() {
        sharePopup.item(at: 1)?.isEnabled = viewModel.canSave
        sharePopup.item(at: 2)?.isEnabled = viewModel.canExport
        sharePopup.item(at: 3)?.isEnabled = viewModel.canExport
        sharePopup.selectItem(at: 0)
    }

    private func renderInspectorButton() {
        inspectorButton.state = viewModel.isInspectorVisible ? .on : .off
    }

    @objc private func interfaceChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else {
            if !selectInterfaceItem(with: viewModel.selectedInterfaceID) {
                selectFirstInterfaceItem()
            }
            return
        }

        delegate?.tcpviewerToolbarDataSource(self, didSelectInterface: identifier)
    }

    @objc private func captureButtonPressed(_ sender: NSButton) {
        delegate?.tcpviewerToolbarDataSourceDidToggleCapture(self)
    }

    @objc private func shareActionSelected(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            delegate?.tcpviewerToolbarDataSourceDidRequestSave(self)
        case 2:
            delegate?.tcpviewerToolbarDataSource(self, didRequestExport: .pcap)
        case 3:
            delegate?.tcpviewerToolbarDataSource(self, didRequestExport: .pcapng)
        default:
            break
        }

        sender.selectItem(at: 0)
    }

    @objc private func inspectorButtonPressed(_ sender: NSButton) {
        delegate?.tcpviewerToolbarDataSourceDidToggleInspector(self)
    }
}

extension TCPViewerToolbarDataSource: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        allowedItemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultItemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case TCPViewerToolbarItemMetadata.captureSource.identifier:
            item.label = "Interface"
            item.paletteLabel = "Interface"
            item.view = interfacePopup
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.captureToggle.identifier:
            item.label = "Capture"
            item.paletteLabel = "Capture"
            item.view = captureButton
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.status.identifier:
            item.label = "Status"
            item.paletteLabel = "Status"
            item.view = statusView
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.share.identifier:
            item.label = "Share"
            item.paletteLabel = "Share"
            item.view = sharePopup
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.inspector.identifier:
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

private final class TCPViewerToolbarViewModel {
    private(set) var selectedInterfaceTitle = "Interface"
    private(set) var interfaces: [CaptureInterfaceSummary] = []
    private(set) var selectedInterfaceID: String?
    private(set) var lastUsedInterfaceIDs: [String] = []
    private(set) var isCaptureLocked = false
    private(set) var captureButtonTitle = "Start"
    private(set) var captureButtonImageName = "play.fill"
    private(set) var captureButtonTint = NSColor.systemGreen
    private(set) var canUseCaptureButton = false
    private(set) var canSave = false
    private(set) var canSaveAs = false
    private(set) var canExport = false
    private(set) var isInspectorVisible = true
    private(set) var statusText = "TCP Viewer | Idle"
    private(set) var emphasizedText: String?
    private(set) var statusTint = NSColor.secondaryLabelColor
    private(set) var helpText = ""

    // Build toolbar-only presentation state from the root inspector snapshot.
    func render(snapshot: NetworkInspectorSnapshot, viewModel: NetworkInspectorViewModel) {
        interfaces = snapshot.base.sessionState.interfaceInventory
        selectedInterfaceID = snapshot.base.sessionState.selectedInterfaceID
        lastUsedInterfaceIDs = snapshot.base.sessionState.lastUsedInterfaceIDs
        selectedInterfaceTitle = viewModel.selectedInterfaceTitle()
        isCaptureLocked = snapshot.isCaptureLocked
        captureButtonTitle = viewModel.captureButtonTitle()
        captureButtonImageName = viewModel.captureButtonSystemImage()
        captureButtonTint = snapshot.base.sessionState.canStop ? .systemRed : .systemGreen
        canUseCaptureButton = snapshot.base.sessionState.canStart || snapshot.base.sessionState.canStop
        canSave = snapshot.base.documentState.canSave
        canSaveAs = snapshot.base.documentState.canSaveAs
        canExport = snapshot.totalPacketCount > 0 && snapshot.base.loadState.progress.phase != .loading
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
            return "TCP Viewer | Listening on"
        }

        if snapshot.base.loadState.progress.phase == .loading {
            return "TCP Viewer | Loading"
        }

        if snapshot.base.documentState.phase == .loaded || snapshot.base.documentState.phase == .saved {
            return "TCP Viewer | Viewing"
        }

        if snapshot.base.sessionState.phase == .failed || snapshot.base.documentState.phase == .failed {
            return "TCP Viewer | Attention"
        }

        return "TCP Viewer | \(snapshot.base.sessionState.phase.rawValue.capitalized)"
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

private final class TCPViewerToolbarStatusView: NSView {
    private let dot = NSView()
    private let statusLabel = TCPViewerUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), color: .secondaryLabelColor)
    private let emphasizedLabel = TCPViewerUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(viewModel: TCPViewerToolbarViewModel) {
        dot.layer?.backgroundColor = viewModel.statusTint.cgColor
        statusLabel.stringValue = viewModel.statusText
        emphasizedLabel.stringValue = viewModel.emphasizedText ?? ""
        emphasizedLabel.isHidden = viewModel.emphasizedText == nil
        toolTip = viewModel.helpText
    }

    private func setupLayout() {
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
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
