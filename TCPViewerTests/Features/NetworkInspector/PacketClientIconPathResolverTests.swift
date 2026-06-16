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

    @Test func iconCacheLoadsImageSidecarsAsTheirBitmapContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let iconURL = directory.appendingPathComponent("client-icon.png")
        try Self.redPNGData().write(to: iconURL)
        let image = try #require(PacketClientIconCache().image(forPath: iconURL.path))
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        let sampledColor = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))

        #expect(sampledColor.redComponent > 0.8)
        #expect(sampledColor.greenComponent < 0.2)
        #expect(sampledColor.blueComponent < 0.2)
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

    private static func redPNGData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))

        for y in 0..<2 {
            for x in 0..<2 {
                bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }

        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
