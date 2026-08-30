//
//  AppDelegateTerminationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/6/26.
//

import AppKit
import Testing
@testable import TCPViewer

@MainActor
struct AppDelegateTerminationTests {
    @Test func factoryResetTerminationBypassesCancellableQuitPreparation() {
        let delegate = AppDelegate()

        delegate.prepareForFactoryResetTermination()
        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(reply == .terminateNow)
    }

    @Test func fileOpenMenuRoutesToAppDelegateCaptureImport() throws {
        let storyboard = try mainStoryboardText()

        #expect(storyboard.contains(#"<customObject id="Voe-Tx-rLC" customClass="AppDelegate""#))
        #expect(storyboard.contains(#"<action selector="openDocument:" target="Voe-Tx-rLC""#))
        #expect(!storyboard.contains(#"<action selector="openDocument:" target="Ady-hI-5gd""#))
    }

    @Test func packetDetailFilterShortcutRoutesThroughMainWindowResponderChain() throws {
        let storyboard = try mainStoryboardText()
        let menuItemStart = try #require(storyboard.range(
            of: #"<menuItem title="Focus Packet Detail Filter" keyEquivalent="f""#
        ))
        let menuItemTail = storyboard[menuItemStart.lowerBound...]
        let menuItemEnd = try #require(menuItemTail.range(of: "</menuItem>"))
        let menuItem = String(menuItemTail[..<menuItemEnd.upperBound])

        #expect(menuItem.contains(#"option="YES" command="YES""#))
        #expect(menuItem.contains(#"<action selector="focusPacketDetailFilter:" target="Ady-hI-5gd""#))
    }

    @Test func packetFilterShortcutsRemoveStandardFindConflicts() {
        let delegate = AppDelegate()
        let editMenu = NSMenu(title: "Edit")
        let findSubmenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findSubmenuItem.submenu = findMenu
        editMenu.addItem(findSubmenuItem)

        let standardFind = findMenu.addItem(
            withTitle: "Find…",
            action: NSSelectorFromString("performFindPanelAction:"),
            keyEquivalent: "f"
        )
        standardFind.keyEquivalentModifierMask = [.command]
        let findAndReplace = findMenu.addItem(
            withTitle: "Find and Replace…",
            action: NSSelectorFromString("performFindPanelAction:"),
            keyEquivalent: "f"
        )
        findAndReplace.keyEquivalentModifierMask = [.command, .option]
        let unrelatedShortcut = findMenu.addItem(
            withTitle: "Custom Find",
            action: NSSelectorFromString("performFindPanelAction:"),
            keyEquivalent: "f"
        )
        unrelatedShortcut.keyEquivalentModifierMask = [.command, .shift]

        delegate.removeFilterShortcutConflicts(in: editMenu)

        #expect(standardFind.keyEquivalent.isEmpty)
        #expect(standardFind.keyEquivalentModifierMask.isEmpty)
        #expect(findAndReplace.keyEquivalent.isEmpty)
        #expect(findAndReplace.keyEquivalentModifierMask.isEmpty)
        #expect(unrelatedShortcut.keyEquivalent == "f")
        #expect(unrelatedShortcut.keyEquivalentModifierMask == [.command, .shift])
    }

    private func mainStoryboardText() throws -> String {
        let storyboardURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TCPViewer")
            .appendingPathComponent("Base.lproj")
            .appendingPathComponent("Main.storyboard")
        return try String(contentsOf: storyboardURL, encoding: .utf8)
    }
}
