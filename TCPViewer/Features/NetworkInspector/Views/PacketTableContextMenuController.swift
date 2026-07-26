//
//  PacketTableContextMenuController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/4/26.
//

import AppKit
import PcapPlusPlusCore

@objc protocol PacketTableContextMenuActionHandling: AnyObject {
    func copyRowsFromMenu(_ sender: Any?)
    func copyRowsAsPlainTextFromMenu(_ sender: Any?)
    func copyRowsAsJSONFromMenu(_ sender: Any?)
    func copyRowsAsMarkdownTableFromMenu(_ sender: Any?)
    func copyRowsAsCSVFromMenu(_ sender: Any?)
    func copyRowsAsCSVWithHeaderFromMenu(_ sender: Any?)
    func copyCellFromMenu(_ sender: Any?)
    func pinRowsFromMenu(_ sender: Any?)
    func saveRowsFromMenu(_ sender: Any?)
    func setPacketHighlightColorFromMenu(_ sender: Any?)
    func togglePacketStrikethroughFromMenu(_ sender: Any?)
    func resetPacketTextStyleFromMenu(_ sender: Any?)
    func exportRowsAsPcapFromMenu(_ sender: Any?)
    func exportRowsAsPcapngFromMenu(_ sender: Any?)
    func deleteRowsFromMenu(_ sender: Any?)
}

protocol PacketTableContextMenuStateProviding: AnyObject {
    func packetTableContextMenuWillOpen()
    func packetTableContextMenuState() -> PacketTableMenuState
}

final class PacketTableContextMenuController: NSObject {
    weak var actionHandler: PacketTableContextMenuActionHandling?
    weak var stateProvider: PacketTableContextMenuStateProviding?

    // Build the AppKit menu once and update its items each time it opens.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    // Rebuild menu items from the current packet-table click and selection state.
    private func update(menu: NSMenu, state: PacketTableMenuState) {
        menu.removeAllItems()
        menu.addItem(item(
            title: "Copy",
            action: #selector(PacketTableContextMenuActionHandling.copyRowsFromMenu(_:)),
            keyEquivalent: "c",
            isEnabled: state.copyRowEnabled,
            toolTip: "Copy the selected packet rows with separators.",
            systemSymbolName: "doc.on.doc"
        ))
        menu.addItem(item(
            title: "Copy Cell Value",
            action: #selector(PacketTableContextMenuActionHandling.copyCellFromMenu(_:)),
            isEnabled: state.copyCellEnabled,
            toolTip: "Copy values from the clicked column for the selected rows."
        ))
        menu.addItem(copyRowsAsMenuItem(state: state))

        menu.addItem(.separator())
        menu.addItem(item(
            title: "Pin",
            action: #selector(PacketTableContextMenuActionHandling.pinRowsFromMenu(_:)),
            isEnabled: state.pinEnabled,
            toolTip: "Pin the selected app or apps for quick access.",
            systemSymbolName: "pin"
        ))
        menu.addItem(item(
            title: "Save",
            action: #selector(PacketTableContextMenuActionHandling.saveRowsFromMenu(_:)),
            isEnabled: state.saveEnabled,
            toolTip: "Save the selected packets to the packet workspace."
        ))
        menu.addItem(highlightMenuItem(state: state))

        menu.addItem(.separator())
        menu.addItem(exportMenuItem(state: state))

        menu.addItem(.separator())
        menu.addItem(item(
            title: "Delete",
            action: #selector(PacketTableContextMenuActionHandling.deleteRowsFromMenu(_:)),
            keyEquivalent: "\u{8}",
            isEnabled: state.deleteEnabled,
            toolTip: "Delete the selected packets.",
            systemSymbolName: "trash"
        ))
    }

    // Create the ordered highlight palette and its keyboard shortcuts.
    private func highlightMenuItem(state: PacketTableMenuState) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Highlight")
        submenu.autoenablesItems = false

        for (index, color) in PacketHighlightColor.allCases.enumerated() {
            let shortcut = index < 9 ? String(index + 1) : ""
            let colorItem = item(
                title: color.menuTitle,
                action: #selector(PacketTableContextMenuActionHandling.setPacketHighlightColorFromMenu(_:)),
                keyEquivalent: shortcut,
                isEnabled: state.styleEnabled,
                toolTip: "Highlight the targeted packet rows in \(color.menuTitle.lowercased())."
            )
            colorItem.representedObject = color.rawValue
            colorItem.image = color.menuImage
            if !shortcut.isEmpty {
                colorItem.keyEquivalentModifierMask = .command
            }
            submenu.addItem(colorItem)
        }

        submenu.addItem(.separator())
        let strikethroughItem = item(
            title: "Strikethrough",
            action: #selector(PacketTableContextMenuActionHandling.togglePacketStrikethroughFromMenu(_:)),
            keyEquivalent: "/",
            isEnabled: state.styleEnabled,
            toolTip: "Toggle strikethrough on the targeted packet rows."
        )
        strikethroughItem.keyEquivalentModifierMask = .command
        submenu.addItem(strikethroughItem)

        submenu.addItem(.separator())
        let resetItem = item(
            title: "Reset",
            action: #selector(PacketTableContextMenuActionHandling.resetPacketTextStyleFromMenu(_:)),
            keyEquivalent: "0",
            isEnabled: state.styleEnabled,
            toolTip: "Remove all highlighting and text effects from the targeted packet rows."
        )
        resetItem.keyEquivalentModifierMask = .command
        submenu.addItem(resetItem)

        menuItem.submenu = submenu
        menuItem.isEnabled = state.styleEnabled
        menuItem.toolTip = "Choose a color or text effect for the targeted packet rows."
        return menuItem
    }

    // Create the copy-format submenu for the targeted packet rows.
    private func copyRowsAsMenuItem(state: PacketTableMenuState) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Copy Rows As", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Copy Rows As")
        submenu.autoenablesItems = false

        submenu.addItem(item(
            title: "Plain text",
            action: #selector(PacketTableContextMenuActionHandling.copyRowsAsPlainTextFromMenu(_:)),
            isEnabled: state.copyRowEnabled,
            toolTip: "Copy the selected packet rows as tab-separated plain text."
        ))
        submenu.addItem(item(
            title: "JSON",
            action: #selector(PacketTableContextMenuActionHandling.copyRowsAsJSONFromMenu(_:)),
            isEnabled: state.copyRowEnabled,
            toolTip: "Copy the selected packet rows as a JSON array."
        ))

        submenu.addItem(.separator())
        submenu.addItem(item(
            title: "Markdown Table",
            action: #selector(PacketTableContextMenuActionHandling.copyRowsAsMarkdownTableFromMenu(_:)),
            isEnabled: state.copyRowEnabled,
            toolTip: "Copy the selected packet rows as a Markdown table."
        ))

        submenu.addItem(.separator())
        submenu.addItem(item(
            title: "CSV",
            action: #selector(PacketTableContextMenuActionHandling.copyRowsAsCSVFromMenu(_:)),
            isEnabled: state.copyRowEnabled,
            toolTip: "Copy the selected packet rows as CSV without headers."
        ))
        submenu.addItem(item(
            title: "CSV with Header",
            action: #selector(PacketTableContextMenuActionHandling.copyRowsAsCSVWithHeaderFromMenu(_:)),
            isEnabled: state.copyRowEnabled,
            toolTip: "Copy the selected packet rows as CSV with a header row."
        ))

        menuItem.submenu = submenu
        menuItem.isEnabled = state.copyRowEnabled
        menuItem.toolTip = "Choose a text format for copying the selected packet rows."
        return menuItem
    }

    // Create the export submenu for writing the targeted packets to capture files.
    private func exportMenuItem(state: PacketTableMenuState) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Export")
        submenu.autoenablesItems = false

        submenu.addItem(item(
            title: "as pcap...",
            action: #selector(PacketTableContextMenuActionHandling.exportRowsAsPcapFromMenu(_:)),
            isEnabled: state.exportEnabled,
            toolTip: "Export the targeted packets to a pcap file."
        ))
        submenu.addItem(item(
            title: "as pcapng...",
            action: #selector(PacketTableContextMenuActionHandling.exportRowsAsPcapngFromMenu(_:)),
            isEnabled: state.exportEnabled,
            toolTip: "Export the targeted packets to a pcapng file."
        ))

        menuItem.submenu = submenu
        menuItem.isEnabled = state.exportEnabled
        menuItem.toolTip = "Export the targeted packets to a capture file."
        menuItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        return menuItem
    }

    // Configure one command item with shared target, enablement, tooltip, and optional symbol.
    private func item(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        isEnabled: Bool,
        toolTip: String,
        systemSymbolName: String? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.target = actionHandler
        menuItem.isEnabled = isEnabled
        menuItem.toolTip = toolTip
        if let systemSymbolName {
            menuItem.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: title)
        }
        return menuItem
    }
}

extension PacketHighlightColor {
    var menuTitle: String {
        rawValue.capitalized
    }

    var appKitColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }

    var menuImage: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            self.appKitColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension PacketTableContextMenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        stateProvider?.packetTableContextMenuWillOpen()
        update(menu: menu, state: stateProvider?.packetTableContextMenuState() ?? .empty)
    }
}
