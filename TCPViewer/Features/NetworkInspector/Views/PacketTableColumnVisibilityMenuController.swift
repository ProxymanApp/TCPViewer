//
//  PacketTableColumnVisibilityMenuController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/4/26.
//

import AppKit

@objc protocol PacketTableColumnVisibilityMenuActionHandling: AnyObject {
    func togglePacketTableColumnVisibilityFromMenu(_ sender: Any?)
    func resetPacketTableColumnsFromMenu(_ sender: Any?)
}

final class PacketTableColumnVisibilityMenuController: NSObject {
    weak var actionHandler: PacketTableColumnVisibilityMenuActionHandling?

    private let columnService: PacketTableColumnService

    init(columnService: PacketTableColumnService) {
        self.columnService = columnService
    }

    // Build the header menu once, then refresh column checks whenever it opens.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Columns")
        menu.autoenablesItems = false
        menu.showsStateColumn = true
        menu.delegate = self
        return menu
    }

    // Rebuild menu rows from the latest column visibility state.
    private func update(menu: NSMenu) {
        menu.removeAllItems()
        columnService.menuEntries.forEach { entry in
            menu.addItem(columnItem(entry))
        }

        menu.addItem(.separator())
        menu.addItem(resetItem())
    }

    // Create a small checkbox row so the menu can fit more columns vertically.
    private func columnItem(_ entry: PacketTableColumnMenuEntry) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: entry.title,
            action: #selector(PacketTableColumnVisibilityMenuActionHandling.togglePacketTableColumnVisibilityFromMenu(_:)),
            keyEquivalent: ""
        )
        menuItem.target = actionHandler
        menuItem.representedObject = entry.identifier
        menuItem.state = entry.isVisible ? .on : .off
        menuItem.isEnabled = entry.isEnabled
        menuItem.toolTip = "Show or hide the \(entry.title) column."
        return menuItem
    }

    // Create the bottom reset command for restoring default visibility.
    private func resetItem() -> NSMenuItem {
        let title = "Reset All Columns"
        let menuItem = NSMenuItem(
            title: title,
            action: #selector(PacketTableColumnVisibilityMenuActionHandling.resetPacketTableColumnsFromMenu(_:)),
            keyEquivalent: ""
        )
        menuItem.target = actionHandler
        menuItem.toolTip = "Restore the default packet table columns."
        return menuItem
    }
}

extension PacketTableColumnVisibilityMenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        update(menu: menu)
    }
}
