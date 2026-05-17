//
//  TCPViewerToolbarDataSource.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import PcapPlusPlusCore

private enum TCPViewerToolbarItemMetadata: String, CaseIterable {
    case captureSource = "CaptureSource"
    case captureToggle = "CaptureToggle"
    case clearAll = "ClearAll"
    case status = "Status"
    case trial = "Trial"
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

private enum TCPViewerToolbarLayout {
    static let interfacePopupMinimumWidth: CGFloat = 76
    static let interfacePopupMaximumWidth: CGFloat = 260
    static let interfacePopupTitlePadding: CGFloat = 48
    static let toolbarControlHeight: CGFloat = 30
    static let trialButtonWidth: CGFloat = 132
}

struct TCPViewerInterfaceMenuSection {
    let title: String
    let interfaces: [CaptureInterfaceSummary]
}

enum TCPViewerInterfaceMenuGrouper {
    static func sections(for interfaces: [CaptureInterfaceSummary]) -> [TCPViewerInterfaceMenuSection] {
        // Preserve inventory order for sections while merging matching families that appear apart.
        var orderedGroups: [TCPViewerInterfaceMenuGroup] = []
        var groupedInterfaces: [TCPViewerInterfaceMenuGroup: [CaptureInterfaceSummary]] = [:]

        for interface in interfaces {
            let group = TCPViewerInterfaceMenuGroup(interface: interface)
            if groupedInterfaces[group] == nil {
                orderedGroups.append(group)
            }
            groupedInterfaces[group, default: []].append(interface)
        }

        return orderedGroups.compactMap { group in
            guard let interfaces = groupedInterfaces[group], !interfaces.isEmpty else {
                return nil
            }

            return TCPViewerInterfaceMenuSection(title: group.title, interfaces: interfaces)
        }
    }
}

private enum TCPViewerInterfaceMenuGroup: Hashable {
    case aggregate
    case ethernet
    case wifi
    case thunderbolt
    case loopback
    case tunnels
    case bridges
    case other

    init(interface: CaptureInterfaceSummary) {
        let technicalName = interface.technicalName.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let displayName = [interface.friendlyName, interface.displayName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase }
            .joined(separator: " ")

        if technicalName == "any" || technicalName.hasPrefix("pktap") || displayName.contains("all interfaces") {
            self = .aggregate
        } else if interface.isLoopback || technicalName.hasPrefix("lo") || displayName.contains("loopback") {
            self = .loopback
        } else if displayName.contains("wi-fi") || technicalName.hasPrefix("awdl") || technicalName.hasPrefix("llw") {
            self = .wifi
        } else if displayName.contains("thunderbolt") {
            self = .thunderbolt
        } else if technicalName.hasPrefix("utun") || technicalName.hasPrefix("ipsec") ||
                    technicalName.hasPrefix("gif") || technicalName.hasPrefix("stf") ||
                    displayName.contains("tunnel") {
            self = .tunnels
        } else if technicalName.hasPrefix("bridge") || displayName.contains("bridge") {
            self = .bridges
        } else if displayName.contains("ethernet") ||
                    technicalName.hasPrefix("en") || technicalName.hasPrefix("ap") ||
                    technicalName.hasPrefix("anpi") {
            self = .ethernet
        } else {
            self = .other
        }
    }

    var title: String {
        switch self {
        case .aggregate:
            "All Interfaces"
        case .ethernet:
            "Ethernet"
        case .wifi:
            "Wi-Fi"
        case .thunderbolt:
            "Thunderbolt"
        case .loopback:
            "Loopback"
        case .tunnels:
            "Tunnels"
        case .bridges:
            "Bridges"
        case .other:
            "Other Interfaces"
        }
    }
}

protocol TCPViewerToolbarDataSourceDelegate: AnyObject {
    func tcpviewerToolbarDataSource(_ dataSource: TCPViewerToolbarDataSource, didSelectInterface identifier: String)
    func tcpviewerToolbarDataSourceDidToggleCapture(_ dataSource: TCPViewerToolbarDataSource)
    func tcpviewerToolbarDataSourceDidRequestClearAllPackets(_ dataSource: TCPViewerToolbarDataSource)
    func tcpviewerToolbarDataSource(_ dataSource: TCPViewerToolbarDataSource, didRequestExport format: CaptureFileFormat)
    func tcpviewerToolbarDataSourceDidToggleInspector(_ dataSource: TCPViewerToolbarDataSource)
    func tcpviewerToolbarDataSourceDidRequestHelperToolScreen(_ dataSource: TCPViewerToolbarDataSource)
    func tcpviewerToolbarDataSourceDidRequestPaywall(_ dataSource: TCPViewerToolbarDataSource)
}

final class TCPViewerToolbarDataSource: NSObject {
    let toolbar: NSToolbar
    weak var delegate: TCPViewerToolbarDataSourceDelegate?

    private let viewModel = TCPViewerToolbarViewModel()
    private let interfacePopup = NSPopUpButton(
        frame: NSRect(
            x: 0,
            y: 0,
            width: TCPViewerToolbarLayout.interfacePopupMinimumWidth,
            height: TCPViewerToolbarLayout.toolbarControlHeight
        ),
        pullsDown: false
    )
    private let captureButton = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))
    private let clearAllButton = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))
    private let statusView = TCPViewerToolbarStatusView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
    private let trialButton = NSButton(
        frame: NSRect(x: 0, y: 0, width: TCPViewerToolbarLayout.trialButtonWidth, height: 30)
    )
    private let sharePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 42, height: 30), pullsDown: true)
    private let inspectorButton = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 30))
    private var interfacePopupWidthConstraint: NSLayoutConstraint?
    private var isTrialButtonRequired = !TCPViewerLicenseService.shared.isLicenseAuthorized

    private var allowedItemIdentifiers: [NSToolbarItem.Identifier] {
        var identifiers = TCPViewerToolbarItemMetadata.allCases
            .filter { isTrialButtonRequired || $0 != .trial }
            .map(\.identifier)
        identifiers += [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .space,
        ]
        return identifiers
    }

    private var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            TCPViewerToolbarItemMetadata.captureSource.identifier,
            TCPViewerToolbarItemMetadata.captureToggle.identifier,
            .space,
            TCPViewerToolbarItemMetadata.clearAll.identifier,
            TCPViewerToolbarItemMetadata.flexibleSpace.identifier,
            TCPViewerToolbarItemMetadata.status.identifier,
        ]

        if isTrialButtonRequired {
            identifiers.append(TCPViewerToolbarItemMetadata.trial.identifier)
        }

        identifiers += [
            TCPViewerToolbarItemMetadata.flexibleSpace.identifier,
            TCPViewerToolbarItemMetadata.share.identifier,
            TCPViewerToolbarItemMetadata.inspector.identifier,
        ]

        return identifiers
    }

    override init() {
        self.toolbar = NSToolbar(identifier: "TCPViewer.MainToolbar.v4")
        super.init()
        configureToolbar()
        configureToolbarViews()
    }

    // Apply root state to the toolbar controls without leaking toolbar view ownership to the window.
    func render(snapshot: NetworkInspectorSnapshot, inspectorViewModel: NetworkInspectorViewModel, isLicenseAuthorized: Bool) {
        viewModel.render(snapshot: snapshot, viewModel: inspectorViewModel, isLicenseAuthorized: isLicenseAuthorized)
        isTrialButtonRequired = viewModel.showsTrialButton
        renderInterfacePopup()
        renderCaptureButton()
        renderClearAllButton()
        renderTrialButton()
        renderSharePopup()
        renderInspectorButton()
        statusView.render(viewModel: viewModel)
        syncTrialToolbarItem()
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
        constrainDynamicInterfacePopup()
        constrainToolbarView(captureButton, width: 34, height: 30)
        constrainToolbarView(clearAllButton, width: 34, height: 30)
        constrainToolbarView(statusView, width: 360, height: 28)
        constrainToolbarView(trialButton, width: TCPViewerToolbarLayout.trialButtonWidth, height: 30)
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

        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllButtonPressed(_:))
        clearAllButton.bezelStyle = .texturedRounded
        clearAllButton.controlSize = .regular
        clearAllButton.image = TCPViewerUI.image("trash")
        clearAllButton.imagePosition = .imageOnly
        clearAllButton.toolTip = "Clear All Packets"

        trialButton.target = self
        trialButton.action = #selector(trialButtonPressed(_:))
        trialButton.bezelStyle = .regularSquare
        trialButton.isBordered = false
        trialButton.wantsLayer = true
        trialButton.layer?.backgroundColor = NSColor.systemYellow.cgColor
        trialButton.layer?.cornerRadius = 15
        trialButton.layer?.masksToBounds = true
        trialButton.font = .systemFont(ofSize: 15, weight: .bold)
        trialButton.image = TCPViewerUI.image("exclamationmark.circle.fill")
        trialButton.imagePosition = .imageLeading
        trialButton.imageHugsTitle = true
        trialButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        trialButton.contentTintColor = .black
        trialButton.toolTip = "Upgrade to TCP Viewer PRO"

        sharePopup.controlSize = .regular
        sharePopup.addItem(withTitle: "")
        sharePopup.item(at: 0)?.image = TCPViewerUI.image("square.and.arrow.up")
        sharePopup.addItem(withTitle: "Export as pcap")
        sharePopup.addItem(withTitle: "Export as pcapng")
        sharePopup.imagePosition = .imageOnly
        sharePopup.target = self
        sharePopup.action = #selector(shareActionSelected(_:))
        sharePopup.toolTip = "Share"

        inspectorButton.target = self
        inspectorButton.action = #selector(inspectorButtonPressed(_:))
        inspectorButton.setButtonType(.toggle)
        inspectorButton.bezelStyle = .texturedRounded
        inspectorButton.controlSize = .regular
        inspectorButton.image = TCPViewerUI.image("sidebar.trailing")
        inspectorButton.imagePosition = .imageOnly
        inspectorButton.title = ""
        inspectorButton.toolTip = "Toggle Inspector"

        statusView.onOpenHelperToolScreen = { [weak self] in
            guard let self else {
                return
            }

            delegate?.tcpviewerToolbarDataSourceDidRequestHelperToolScreen(self)
        }
    }

    private func constrainToolbarView(_ view: NSView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    private func constrainDynamicInterfacePopup() {
        interfacePopup.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = interfacePopup.widthAnchor.constraint(
            equalToConstant: TCPViewerToolbarLayout.interfacePopupMinimumWidth
        )
        NSLayoutConstraint.activate([
            widthConstraint,
            interfacePopup.heightAnchor.constraint(equalToConstant: TCPViewerToolbarLayout.toolbarControlHeight),
        ])
        interfacePopupWidthConstraint = widthConstraint
    }

    private func renderInterfacePopup() {
        interfacePopup.removeAllItems()
        interfacePopup.menu?.autoenablesItems = false
        if viewModel.interfaces.isEmpty {
            interfacePopup.addItem(withTitle: "No Interfaces")
            interfacePopup.isEnabled = false
            updateInterfacePopupWidth()
            return
        }

        let recentInterfaces = viewModel.lastUsedInterfaceIDs.compactMap { identifier in
            viewModel.interfaces.first { $0.id == identifier }
        }

        if !recentInterfaces.isEmpty {
            addInterfaceGroupHeader("Last used")
            recentInterfaces.forEach(addInterfaceItem)
            if !viewModel.interfaces.isEmpty {
                interfacePopup.menu?.addItem(.separator())
            }
        }

        addInterfaceSections(TCPViewerInterfaceMenuGrouper.sections(for: viewModel.interfaces))
        if !selectInterfaceItem(with: viewModel.selectedInterfaceID) {
            selectFirstInterfaceItem()
        }
        interfacePopup.isEnabled = !viewModel.isCaptureLocked
        updateInterfacePopupWidth()
    }

    private func addInterfaceSections(_ sections: [TCPViewerInterfaceMenuSection]) {
        guard sections.count > 1 else {
            sections.first?.interfaces.forEach(addInterfaceItem)
            return
        }

        for (index, section) in sections.enumerated() {
            if index > 0 {
                interfacePopup.menu?.addItem(.separator())
            }

            addInterfaceGroupHeader(section.title)
            section.interfaces.forEach(addInterfaceItem)
        }
    }

    private func addInterfaceGroupHeader(_ title: String) {
        // Add a disabled group label so each dropdown section reads as a menu group.
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
        if viewModel.isActiveInterface(interface) {
            item.image = activeInterfaceMenuIcon()
            item.toolTip = "Active network interface"
        }
        interfacePopup.menu?.addItem(item)
    }

    private func activeInterfaceMenuIcon() -> NSImage? {
        // Mark the macOS primary route with a compact icon without changing interface names.
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = TCPViewerUI.image("location.fill")?.withSymbolConfiguration(configuration)?.copy() as? NSImage
        image?.isTemplate = true
        return image
    }

    @discardableResult
    private func selectInterfaceItem(with identifier: String?) -> Bool {
        // Select by represented identifier because recent grouping changes visible row order.
        guard let identifier, let menu = interfacePopup.menu else {
            return false
        }

        for (index, item) in menu.items.enumerated() where item.representedObject as? String == identifier {
            interfacePopup.selectItem(at: index)
            updateInterfacePopupWidth()
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
            updateInterfacePopupWidth()
            return
        }
    }

    private func updateInterfacePopupWidth() {
        let title = interfacePopup.selectedItem?.title ?? interfacePopup.title
        let font = interfacePopup.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let measuredWidth = title.size(withAttributes: [.font: font]).width + TCPViewerToolbarLayout.interfacePopupTitlePadding
        let width = ceil(min(
            TCPViewerToolbarLayout.interfacePopupMaximumWidth,
            max(TCPViewerToolbarLayout.interfacePopupMinimumWidth, measuredWidth)
        ))
        interfacePopupWidthConstraint?.constant = width
        interfacePopup.setFrameSize(NSSize(width: width, height: TCPViewerToolbarLayout.toolbarControlHeight))
        interfacePopup.superview?.layoutSubtreeIfNeeded()
    }

    private func renderCaptureButton() {
        captureButton.image = TCPViewerUI.image(viewModel.captureButtonImageName)
        captureButton.contentTintColor = viewModel.captureButtonTint
        captureButton.toolTip = viewModel.captureButtonTitle
        captureButton.isEnabled = viewModel.canUseCaptureButton
        captureButton.alphaValue = viewModel.canUseCaptureButton ? 1 : 0.45
    }

    private func renderClearAllButton() {
        clearAllButton.isEnabled = viewModel.canClearAllPackets
        clearAllButton.alphaValue = viewModel.canClearAllPackets ? 1 : 0.45
    }

    private func renderTrialButton() {
        trialButton.title = "TRIAL VERSION"
        trialButton.isHidden = !viewModel.showsTrialButton
    }

    private func renderSharePopup() {
        sharePopup.item(at: 1)?.isEnabled = viewModel.canExport
        sharePopup.item(at: 2)?.isEnabled = viewModel.canExport
        sharePopup.selectItem(at: 0)
    }

    private func renderInspectorButton() {
        inspectorButton.state = viewModel.isInspectorVisible ? .on : .off
    }

    private func syncTrialToolbarItem() {
        let trialIdentifier = TCPViewerToolbarItemMetadata.trial.identifier
        let trialItemIndexes = toolbar.items.enumerated()
            .filter { $0.element.itemIdentifier == trialIdentifier }
            .map(\.offset)

        if viewModel.showsTrialButton {
            guard trialItemIndexes.isEmpty else {
                return
            }

            let statusIndex = toolbar.items.firstIndex {
                $0.itemIdentifier == TCPViewerToolbarItemMetadata.status.identifier
            }
            let insertionIndex = statusIndex.map { min($0 + 1, toolbar.items.count) } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: trialIdentifier, at: insertionIndex)
        } else {
            for index in trialItemIndexes.reversed() {
                toolbar.removeItem(at: index)
            }
        }
    }

    @objc private func interfaceChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else {
            if !selectInterfaceItem(with: viewModel.selectedInterfaceID) {
                selectFirstInterfaceItem()
            }
            updateInterfacePopupWidth()
            return
        }

        updateInterfacePopupWidth()
        delegate?.tcpviewerToolbarDataSource(self, didSelectInterface: identifier)
    }

    @objc private func captureButtonPressed(_ sender: NSButton) {
        delegate?.tcpviewerToolbarDataSourceDidToggleCapture(self)
    }

    @objc private func clearAllButtonPressed(_ sender: NSButton) {
        delegate?.tcpviewerToolbarDataSourceDidRequestClearAllPackets(self)
    }

    @objc private func trialButtonPressed(_ sender: NSButton) {
        delegate?.tcpviewerToolbarDataSourceDidRequestPaywall(self)
    }

    @objc private func shareActionSelected(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            delegate?.tcpviewerToolbarDataSource(self, didRequestExport: .pcap)
        case 2:
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

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        isTrialButtonRequired ? [TCPViewerToolbarItemMetadata.trial.identifier] : []
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemIdentifier: NSToolbarItem.Identifier,
        canBeInsertedAt index: Int
    ) -> Bool {
        guard itemIdentifier == TCPViewerToolbarItemMetadata.trial.identifier else {
            return true
        }

        return isTrialButtonRequired && index != NSNotFound
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
        case TCPViewerToolbarItemMetadata.clearAll.identifier:
            item.label = "Clear All"
            item.paletteLabel = "Clear All Packets"
            item.view = clearAllButton
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.status.identifier:
            item.label = "Status"
            item.paletteLabel = "Status"
            item.view = statusView
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.trial.identifier:
            guard isTrialButtonRequired else {
                return nil
            }

            item.label = "Trial"
            item.paletteLabel = "Trial Version"
            item.view = trialButton
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.share.identifier:
            item.label = "Share"
            item.paletteLabel = "Share"
            item.view = sharePopup
            item.visibilityPriority = .high
        case TCPViewerToolbarItemMetadata.inspector.identifier:
            item.label = "Inspector"
            item.paletteLabel = "Toggle Inspector"
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
    private(set) var activeInterfaceID: String?
    private(set) var isCaptureLocked = false
    private(set) var captureButtonTitle = "Start"
    private(set) var captureButtonImageName = "play.fill"
    private(set) var captureButtonTint = NSColor.systemGreen
    private(set) var canUseCaptureButton = false
    private(set) var canClearAllPackets = false
    private(set) var canSave = false
    private(set) var canSaveAs = false
    private(set) var canExport = false
    private(set) var isInspectorVisible = true
    private(set) var statusText = "TCP Viewer | Idle"
    private(set) var emphasizedText: String?
    private(set) var statusTint = NSColor.secondaryLabelColor
    private(set) var helpText = ""
    private(set) var helperError: TCPViewerToolbarHelperError?
    private(set) var isShowingHelperError = false
    private(set) var showsTrialButton = false

    // Build toolbar-only presentation state from the root inspector snapshot.
    func render(snapshot: NetworkInspectorSnapshot, viewModel: NetworkInspectorViewModel, isLicenseAuthorized: Bool) {
        interfaces = snapshot.base.sessionState.interfaceInventory
        selectedInterfaceID = snapshot.base.sessionState.selectedInterfaceID
        lastUsedInterfaceIDs = snapshot.base.sessionState.lastUsedInterfaceIDs
        activeInterfaceID = snapshot.base.sessionState.activeInterfaceID
        selectedInterfaceTitle = viewModel.selectedInterfaceTitle()
        isCaptureLocked = snapshot.isCaptureLocked
        captureButtonTitle = viewModel.captureButtonTitle()
        captureButtonImageName = viewModel.captureButtonSystemImage()
        captureButtonTint = snapshot.base.sessionState.canStop ? .systemRed : .systemGreen
        canUseCaptureButton = snapshot.base.sessionState.canStart || snapshot.base.sessionState.canStop
        canClearAllPackets = snapshot.totalPacketCount > 0 && !snapshot.base.loadState.canCancel
        canSave = snapshot.base.documentState.canSave
        canSaveAs = snapshot.base.documentState.canSaveAs
        canExport = snapshot.totalPacketCount > 0 && snapshot.base.loadState.progress.phase != .loading
        isInspectorVisible = snapshot.isInspectorVisible
        helperError = Self.helperError(for: viewModel.networkHelperToolSnapshot)
        isShowingHelperError = helperError != nil
        if let helperError {
            statusText = helperError.title
            emphasizedText = nil
            statusTint = .systemRed
        } else {
            statusText = Self.statusText(for: snapshot)
            emphasizedText = Self.emphasizedText(for: snapshot)
            statusTint = Self.tint(for: snapshot)
        }
        showsTrialButton = !isLicenseAuthorized
        helpText = [
            snapshot.base.sessionState.statusMessage,
            "\(snapshot.totalPacketCount) packets",
            "\(snapshot.droppedPacketCount) dropped",
            "\(snapshot.malformedPacketCount) malformed",
        ].joined(separator: " | ")
    }

    func isActiveInterface(_ interface: CaptureInterfaceSummary) -> Bool {
        guard let activeInterfaceID else {
            return false
        }

        return interface.id.caseInsensitiveCompare(activeInterfaceID) == .orderedSame ||
            interface.technicalName.caseInsensitiveCompare(activeInterfaceID) == .orderedSame
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
        switch snapshot.base.sessionState.phase {
        case .running:
            return "TCP Viewer | Capturing on"
        case .paused:
            return "TCP Viewer | Paused on"
        case .starting:
            return "TCP Viewer | Starting Capture"
        case .stopping:
            return "TCP Viewer | Stopping Capture"
        case .idle, .ready, .stopped, .failed:
            break
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

        switch snapshot.base.sessionState.phase {
        case .ready:
            return "TCP Viewer | Ready"
        case .stopped:
            return "TCP Viewer | Stopped"
        case .idle, .starting, .running, .paused, .stopping, .failed:
            return "TCP Viewer | \(snapshot.base.sessionState.phase.rawValue.capitalized)"
        }
    }

    private static func emphasizedText(for snapshot: NetworkInspectorSnapshot) -> String? {
        if [.starting, .running, .paused, .stopping].contains(snapshot.base.sessionState.phase) {
            guard let interface = snapshot.base.sessionState.selectedInterface else {
                return "selected interface"
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

    private static func helperError(for snapshot: TCPViewerNetworkHelperToolSnapshot) -> TCPViewerToolbarHelperError? {
        let title: String
        switch snapshot.status {
        case .notInstalled:
            title = "Helper Tool Not Installed"
        case .waitingForApproval:
            title = "Helper Tool Needs Approval"
        case .installedNeedsRelaunch:
            title = "Helper Tool Needs Relaunch"
        case .broken:
            title = "Helper Tool Unavailable"
        case .unsupported:
            title = "Helper Tool Unsupported"
        case .ready, .installing:
            return nil
        }

        return TCPViewerToolbarHelperError(
            title: title,
            message: snapshot.message
        )
    }
}

private struct TCPViewerToolbarHelperError {
    let title: String
    let message: String
}

private final class TCPViewerToolbarStatusView: NSView {
    var onOpenHelperToolScreen: (() -> Void)?

    private let dot = NSView()
    private let statusLabel = TCPViewerUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), color: .secondaryLabelColor)
    private let emphasizedLabel = TCPViewerUI.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))
    private let helperErrorButton = NSButton(title: "Error", target: nil, action: nil)
    private var helperError: TCPViewerToolbarHelperError?

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
        statusLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: viewModel.isShowingHelperError ? .semibold : .medium
        )
        statusLabel.textColor = viewModel.isShowingHelperError ? .systemRed : .secondaryLabelColor
        emphasizedLabel.stringValue = viewModel.emphasizedText ?? ""
        emphasizedLabel.isHidden = viewModel.isShowingHelperError || viewModel.emphasizedText == nil
        helperError = viewModel.helperError
        helperErrorButton.isHidden = viewModel.helperError == nil
        helperErrorButton.toolTip = viewModel.helperError.map { "\($0.title): \($0.message)" }
        toolTip = viewModel.helpText
    }

    private func setupLayout() {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emphasizedLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        configureHelperErrorButton()

        let stack = NSStackView(views: [dot, statusLabel, emphasizedLabel, helperErrorButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(10, after: dot)
        stack.setCustomSpacing(4, after: statusLabel)
        stack.setCustomSpacing(12, after: emphasizedLabel)
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

    private func configureHelperErrorButton() {
        helperErrorButton.target = self
        helperErrorButton.action = #selector(helperErrorButtonPressed(_:))
        helperErrorButton.bezelStyle = .rounded
        helperErrorButton.controlSize = .small
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        helperErrorButton.font = font
        helperErrorButton.attributedTitle = NSAttributedString(
            string: "Error",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.systemRed,
            ]
        )
        let errorImage = TCPViewerUI.image("exclamationmark.circle.fill")
        errorImage?.isTemplate = true
        helperErrorButton.image = errorImage
        helperErrorButton.imagePosition = .imageLeading
        helperErrorButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        helperErrorButton.contentTintColor = .systemRed
        helperErrorButton.isHidden = true
        helperErrorButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @objc private func helperErrorButtonPressed(_ sender: NSButton) {
        guard helperError != nil else {
            return
        }

        onOpenHelperToolScreen?()
    }
}
