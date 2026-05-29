//
//  PacketClientIconPathResolverTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/4/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct PacketClientIconPathResolverTests {

    @Test func chromeHelperExecutableUsesOuterAppIconPath() {
        let executablePath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/123.0.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

        let iconFilePath = PacketClientIconPathResolver.iconFilePath(
            bundlePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/123.0.0/Helpers/Google Chrome Helper.app",
            executablePath: executablePath
        )

        #expect(iconFilePath == "/Applications/Google Chrome.app")
    }

    @Test func normalAppExecutableUsesAppBundlePath() {
        let iconFilePath = PacketClientIconPathResolver.iconFilePath(
            bundlePath: "/Applications/Example.app",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )

        #expect(iconFilePath == "/Applications/Example.app")
    }

    @Test func nestedHelperBundleWithoutExecutableUsesOuterAppPath() {
        let iconFilePath = PacketClientIconPathResolver.iconFilePath(
            bundlePath: "/Applications/Example.app/Contents/Helpers/Example Helper.app",
            executablePath: nil
        )

        #expect(iconFilePath == "/Applications/Example.app")
    }

    @Test func standaloneBinaryFallsBackToExecutablePath() {
        let iconFilePath = PacketClientIconPathResolver.iconFilePath(
            bundlePath: nil,
            executablePath: "/usr/local/bin/example"
        )

        #expect(iconFilePath == "/usr/local/bin/example")
    }

    @Test func emptyPathsAreIgnored() {
        #expect(PacketClientIconPathResolver.iconFilePath(bundlePath: "  ", executablePath: "\n\t") == nil)
        #expect(PacketClientIconPathResolver.iconFilePath(bundlePath: " /Applications/Example.app ", executablePath: " ") == "/Applications/Example.app")
    }

    @Test func iconCacheRejectsCorruptAndNonAbsolutePaths() {
        #expect(PacketClientIconCache.normalizedIconPath(String(repeating: "\0", count: 23)) == nil)
        #expect(PacketClientIconCache.normalizedIconPath("relative/example.app") == nil)
        #expect(PacketClientIconCache.normalizedIconPath(" /Applications/Example.app ") == "/Applications/Example.app")
    }

    @Test func packetClientCellCopyKeepsConfiguredSwiftState() throws {
        let suiteName = "PacketClientCellCopy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = AppConfiguration(defaults: defaults)
        let cell = PacketClientCell()

        cell.configure(
            displayName: "Example",
            iconFilePath: "/Applications/Example.app",
            configuration: configuration
        )
        let copiedCell = try #require(cell.copy() as? PacketClientCell)

        #expect(copiedCell.stringValue == "Example")
    }

    @Test func clientConvenienceUsesPacketClientPaths() {
        let client = PacketClient(
            pid: 123,
            name: "Example Helper",
            displayName: "Example Helper",
            executablePath: "/Applications/Example.app/Contents/Helpers/Example Helper.app/Contents/MacOS/Example Helper",
            bundleIdentifier: "com.example.helper",
            bundlePath: "/Applications/Example.app/Contents/Helpers/Example Helper.app"
        )

        #expect(PacketClientIconPathResolver.iconFilePath(for: client) == "/Applications/Example.app")
    }
}
