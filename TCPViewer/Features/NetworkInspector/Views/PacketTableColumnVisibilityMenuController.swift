import AppKit

@objc protocol PacketTableColumnVisibilityMenuActionHandling: AnyObject {
    func togglePacketTableColumnVisibilityFromMenu(_ sender: Any?)
    func resetPacketTableColumnsFromMenu(_ sender: Any?)
}

final class PacketTableColumnVisibilityMenuController: NSObject {
    private enum Layout {
        static let itemWidth: CGFloat = 220
        static let itemHeight: CGFloat = 20
    }

    weak var actionHandler: PacketTableColumnVisibilityMenuActionHandling?

    private let columnService: PacketTableColumnService

    init(columnService: PacketTableColumnService) {
        self.columnService = columnService
    }

    // Build the header menu once, then refresh column checks whenever it opens.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Columns")
        menu.autoenablesItems = false
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
        let menuItem = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        menuItem.representedObject = entry.identifier
        menuItem.state = entry.isVisible ? .on : .off
        menuItem.isEnabled = entry.isEnabled
        menuItem.toolTip = "Show or hide the \(entry.title) column."

        let button = NSButton(
            checkboxWithTitle: entry.title,
            target: actionHandler,
            action: #selector(PacketTableColumnVisibilityMenuActionHandling.togglePacketTableColumnVisibilityFromMenu(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(entry.identifier)
        button.controlSize = .small
        button.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        button.state = entry.isVisible ? .on : .off
        button.isEnabled = entry.isEnabled
        button.toolTip = menuItem.toolTip
        button.frame = NSRect(x: 0, y: 0, width: Layout.itemWidth, height: Layout.itemHeight)
        menuItem.view = button
        return menuItem
    }

    // Create the bottom reset command for restoring default visibility.
    private func resetItem() -> NSMenuItem {
        let title = "Reset All Columns"
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.toolTip = "Restore the default packet table columns."

        let button = NSButton(
            title: title,
            target: actionHandler,
            action: #selector(PacketTableColumnVisibilityMenuActionHandling.resetPacketTableColumnsFromMenu(_:))
        )
        button.controlSize = .small
        button.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        button.isBordered = false
        button.alignment = .left
        button.toolTip = menuItem.toolTip
        button.frame = NSRect(x: 0, y: 0, width: Layout.itemWidth, height: Layout.itemHeight)
        menuItem.view = button
        return menuItem
    }
}

extension PacketTableColumnVisibilityMenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        update(menu: menu)
    }
}
