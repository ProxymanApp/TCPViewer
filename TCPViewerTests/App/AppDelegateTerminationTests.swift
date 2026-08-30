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
