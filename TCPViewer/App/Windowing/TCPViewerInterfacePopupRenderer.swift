//
//  TCPViewerInterfacePopupRenderer.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/6/26.
//

import AppKit
import PcapPlusPlusCore

enum TCPViewerInterfacePopupMetrics {
    static let minimumWidth: CGFloat = 76
    static let maximumWidth: CGFloat = 260
    static let titlePadding: CGFloat = 48
    static let imageTitleSpacing: CGFloat = 8
    static let controlHeight: CGFloat = 30
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

struct TCPViewerInterfacePopupState {
    let interfaces: [CaptureInterfaceSummary]
    let selectedInterfaceID: String?
    let lastUsedInterfaceIDs: [String]
    let activeInterfaceID: String?
    let isCaptureLocked: Bool

    func isActiveInterface(_ interface: CaptureInterfaceSummary) -> Bool {
        // Match either the stable interface id or BSD name reported by the active-route resolver.
        guard let activeInterfaceID else {
            return false
        }

        return interface.id.caseInsensitiveCompare(activeInterfaceID) == .orderedSame ||
            interface.technicalName.caseInsensitiveCompare(activeInterfaceID) == .orderedSame
    }
}

enum TCPViewerInterfacePopupRenderer {
    static func configure(_ popup: NSPopUpButton) {
        // Keep every interface popup visually aligned with the toolbar control.
        popup.controlSize = .regular
        popup.menu?.autoenablesItems = false
    }

    static func render(
        _ popup: NSPopUpButton,
        state: TCPViewerInterfacePopupState,
        widthConstraint: NSLayoutConstraint?,
        maximumWidth: CGFloat? = TCPViewerInterfacePopupMetrics.maximumWidth
    ) {
        // Rebuild the menu from snapshot state so toolbar and empty state stay identical.
        popup.removeAllItems()
        popup.menu?.autoenablesItems = false
        if state.interfaces.isEmpty {
            popup.addItem(withTitle: "No Interfaces")
            popup.isEnabled = false
            updateWidth(of: popup, widthConstraint: widthConstraint, maximumWidth: maximumWidth)
            return
        }

        let recentInterfaces = state.lastUsedInterfaceIDs.compactMap { identifier in
            state.interfaces.first { $0.id == identifier }
        }
        let recentInterfaceIDs = Set(recentInterfaces.map(\.id))
        let preferredInterfaces = state.interfaces.filter { interface in
            !recentInterfaceIDs.contains(interface.id) &&
                isPreferredTopLevelInterface(interface, state: state)
        }
        let preferredInterfaceIDs = Set(preferredInterfaces.map(\.id))
        let otherInterfaces = state.interfaces.filter { interface in
            !recentInterfaceIDs.contains(interface.id) &&
                !preferredInterfaceIDs.contains(interface.id)
        }

        if !recentInterfaces.isEmpty {
            addInterfaceGroupHeader("Last used", to: popup)
            recentInterfaces.forEach { addInterfaceItem($0, state: state, to: popup) }
            if !preferredInterfaces.isEmpty || !otherInterfaces.isEmpty {
                popup.menu?.addItem(.separator())
            }
        }

        preferredInterfaces.forEach { addInterfaceItem($0, state: state, to: popup) }
        if !preferredInterfaces.isEmpty && !otherInterfaces.isEmpty {
            popup.menu?.addItem(.separator())
        }
        addOtherInterfaces(otherInterfaces, state: state, to: popup)
        if !selectInterfaceItem(
            with: state.selectedInterfaceID,
            in: popup,
            widthConstraint: widthConstraint,
            maximumWidth: maximumWidth
        ) {
            selectFirstInterfaceItem(in: popup, widthConstraint: widthConstraint, maximumWidth: maximumWidth)
        }
        popup.isEnabled = !state.isCaptureLocked
        updateWidth(of: popup, widthConstraint: widthConstraint, maximumWidth: maximumWidth)
    }

    @discardableResult
    static func selectInterfaceItem(
        with identifier: String?,
        in popup: NSPopUpButton,
        widthConstraint: NSLayoutConstraint?,
        maximumWidth: CGFloat? = TCPViewerInterfacePopupMetrics.maximumWidth
    ) -> Bool {
        // Select by represented identifier because recent grouping changes visible row order.
        guard let identifier, let menu = popup.menu else {
            return false
        }

        for (index, item) in menu.items.enumerated() where item.representedObject as? String == identifier {
            popup.selectItem(at: index)
            updateWidth(of: popup, widthConstraint: widthConstraint, maximumWidth: maximumWidth)
            return true
        }

        return false
    }

    static func selectFirstInterfaceItem(
        in popup: NSPopUpButton,
        widthConstraint: NSLayoutConstraint?,
        maximumWidth: CGFloat? = TCPViewerInterfacePopupMetrics.maximumWidth
    ) {
        // Avoid leaving the disabled group header as the visible popup title when no selection exists.
        guard let menu = popup.menu else {
            return
        }

        for (index, item) in menu.items.enumerated() where item.representedObject is String {
            popup.selectItem(at: index)
            updateWidth(of: popup, widthConstraint: widthConstraint, maximumWidth: maximumWidth)
            return
        }
    }

    static func selectedInterfaceIdentifier(from sender: Any) -> String? {
        // Submenu rows send themselves, while normal popup rows update the popup selection.
        if let menuItem = sender as? NSMenuItem {
            return menuItem.representedObject as? String
        }

        if let popup = sender as? NSPopUpButton {
            return popup.selectedItem?.representedObject as? String
        }

        return nil
    }

    static func updateWidth(
        of popup: NSPopUpButton,
        widthConstraint: NSLayoutConstraint?,
        maximumWidth: CGFloat? = TCPViewerInterfacePopupMetrics.maximumWidth
    ) {
        // Measure the selected content; callers can cap width where the surrounding UI needs it.
        let selectedItem = popup.selectedItem
        let title = selectedItem?.title ?? popup.title
        let font = popup.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let imageWidth = selectedItem?.image.map { $0.size.width + TCPViewerInterfacePopupMetrics.imageTitleSpacing } ?? 0
        let measuredWidth = title.size(withAttributes: [.font: font]).width +
            imageWidth +
            TCPViewerInterfacePopupMetrics.titlePadding
        let width = ceil(resolvedWidth(for: measuredWidth, maximumWidth: maximumWidth))
        widthConstraint?.constant = width
        popup.setFrameSize(NSSize(width: width, height: TCPViewerInterfacePopupMetrics.controlHeight))
        popup.superview?.layoutSubtreeIfNeeded()
    }

    private static func resolvedWidth(for measuredWidth: CGFloat, maximumWidth: CGFloat?) -> CGFloat {
        let naturalWidth = max(TCPViewerInterfacePopupMetrics.minimumWidth, measuredWidth)
        guard let maximumWidth else {
            return naturalWidth
        }

        return min(maximumWidth, naturalWidth)
    }

    private static func isPreferredTopLevelInterface(
        _ interface: CaptureInterfaceSummary,
        state: TCPViewerInterfacePopupState
    ) -> Bool {
        // Keep the current/active choice visible even when macOS reports it as an unusual interface.
        if interface.id == state.selectedInterfaceID || state.isActiveInterface(interface) {
            return true
        }

        switch TCPViewerInterfaceMenuGroup(interface: interface) {
        case .aggregate:
            return true
        case .wifi:
            return isUserFacingWiFiInterface(interface)
        case .ethernet:
            return isUserFacingEthernetInterface(interface)
        case .thunderbolt, .loopback, .tunnels, .bridges, .other:
            return false
        }
    }

    private static func isUserFacingWiFiInterface(_ interface: CaptureInterfaceSummary) -> Bool {
        let displayName = normalizedDisplayText(for: interface)
        return displayName.contains("wi-fi") || displayName.contains("wifi")
    }

    private static func isUserFacingEthernetInterface(_ interface: CaptureInterfaceSummary) -> Bool {
        let technicalName = interface.technicalName.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let displayName = normalizedDisplayText(for: interface)
        guard !technicalName.hasPrefix("anpi"), !technicalName.hasPrefix("ap") else {
            return false
        }

        return technicalName.hasPrefix("en") || displayName.contains("ethernet")
    }

    private static func normalizedDisplayText(for interface: CaptureInterfaceSummary) -> String {
        [interface.friendlyName, interface.displayName, interface.interfaceDescription]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase }
            .joined(separator: " ")
    }

    private static func addOtherInterfaces(
        _ interfaces: [CaptureInterfaceSummary],
        state: TCPViewerInterfacePopupState,
        to popup: NSPopUpButton
    ) {
        guard !interfaces.isEmpty else {
            return
        }

        let otherItem = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Other")
        submenu.autoenablesItems = false
        addInterfaceSections(
            TCPViewerInterfaceMenuGrouper.sections(for: interfaces),
            state: state,
            to: submenu,
            actionTarget: popup.target,
            action: popup.action
        )
        otherItem.submenu = submenu
        popup.menu?.addItem(otherItem)
    }

    private static func addInterfaceSections(
        _ sections: [TCPViewerInterfaceMenuSection],
        state: TCPViewerInterfacePopupState,
        to menu: NSMenu,
        actionTarget: AnyObject? = nil,
        action: Selector? = nil
    ) {
        // Avoid a redundant section header when all interfaces belong to one group.
        guard sections.count > 1 else {
            sections.first?.interfaces.forEach {
                addInterfaceItem($0, state: state, to: menu, actionTarget: actionTarget, action: action)
            }
            return
        }

        for (index, section) in sections.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }

            addInterfaceGroupHeader(section.title, to: menu)
            section.interfaces.forEach {
                addInterfaceItem($0, state: state, to: menu, actionTarget: actionTarget, action: action)
            }
        }
    }

    private static func addInterfaceGroupHeader(_ title: String, to popup: NSPopUpButton) {
        guard let menu = popup.menu else {
            return
        }

        addInterfaceGroupHeader(title, to: menu)
    }

    private static func addInterfaceGroupHeader(_ title: String, to menu: NSMenu) {
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
        menu.addItem(item)
    }

    private static func addInterfaceItem(
        _ interface: CaptureInterfaceSummary,
        state: TCPViewerInterfacePopupState,
        to popup: NSPopUpButton
    ) {
        guard let menu = popup.menu else {
            return
        }

        addInterfaceItem(interface, state: state, to: menu)
    }

    private static func addInterfaceItem(
        _ interface: CaptureInterfaceSummary,
        state: TCPViewerInterfacePopupState,
        to menu: NSMenu,
        actionTarget: AnyObject? = nil,
        action: Selector? = nil
    ) {
        // Keep each menu item self-identifying so selection does not depend on grouped menu indexes.
        let item = NSMenuItem(title: interface.friendlyName ?? interface.displayName, action: nil, keyEquivalent: "")
        item.representedObject = interface.id
        item.isEnabled = interface.isSelectable && !state.isCaptureLocked
        item.target = actionTarget
        item.action = action
        if state.isActiveInterface(interface) {
            item.image = activeInterfaceMenuIcon()
            item.toolTip = "Active network interface"
        }
        menu.addItem(item)
    }

    private static func activeInterfaceMenuIcon() -> NSImage? {
        // Mark the macOS primary route with a compact icon without changing interface names.
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = TCPViewerUI.image("location.fill")?.withSymbolConfiguration(configuration)?.copy() as? NSImage
        image?.isTemplate = true
        return image
    }
}
