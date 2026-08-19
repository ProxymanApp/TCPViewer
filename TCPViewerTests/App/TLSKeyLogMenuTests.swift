//
//  TLSKeyLogMenuTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import AppKit
import Testing
@testable import TCPViewer

@MainActor
struct TLSKeyLogMenuTests {
    @Test func toolsMenuIsInsertedBeforeWindowAndWiredOnlyOnce() throws {
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu()
        for title in ["TCP Viewer", "File", "Edit", "Window", "Help"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            menu.addItem(item)
        }
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }
        let delegate = AppDelegate()

        delegate.wireToolsMenu()
        delegate.wireToolsMenu()

        let toolsItems = menu.items.filter { $0.title == "Tools" }
        let toolsItem = try #require(toolsItems.first)
        #expect(toolsItems.count == 1)
        #expect(menu.index(of: toolsItem) < menu.items.firstIndex(where: { $0.title == "Window" })!)
        #expect(toolsItem.submenu?.items.count == 1)
        #expect(toolsItem.submenu?.items.first?.title == "TLS Key Log…")
        #expect(toolsItem.submenu?.items.first?.target === delegate)
    }
}
