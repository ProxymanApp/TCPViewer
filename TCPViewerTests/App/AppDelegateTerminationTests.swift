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
        let storyboardURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TCPViewer")
            .appendingPathComponent("Base.lproj")
            .appendingPathComponent("Main.storyboard")
        let storyboard = try String(contentsOf: storyboardURL, encoding: .utf8)

        #expect(storyboard.contains(#"<customObject id="Voe-Tx-rLC" customClass="AppDelegate""#))
        #expect(storyboard.contains(#"<action selector="openDocument:" target="Voe-Tx-rLC""#))
        #expect(!storyboard.contains(#"<action selector="openDocument:" target="Ady-hI-5gd""#))
    }
}
