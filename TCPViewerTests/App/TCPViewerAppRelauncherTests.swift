//
//  TCPViewerAppRelauncherTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/11/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerAppRelauncherTests {
    @Test func waiterPassesPIDAndBundlePathAsPositionalArguments() {
        let bundleURL = URL(fileURLWithPath: "/Applications/TCP Viewer \"$(touch x)\".app")

        let process = TCPViewerAppRelauncher.makeWaiterProcess(processIdentifier: 4242, bundleURL: bundleURL)

        #expect(process.executableURL?.path == "/bin/sh")
        #expect(process.arguments == [
            "-c",
            TCPViewerAppRelauncher.waitScript,
            "tcpviewer-relaunch",
            "4242",
            bundleURL.path,
        ])
        #expect(!TCPViewerAppRelauncher.waitScript.contains(bundleURL.path))
    }

    // Runs the real script against a short-lived process; a missing bundle path makes `open` fail without launching anything.
    @Test func waiterWaitsForProcessToExitBeforeReopening() throws {
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/bin/sleep")
        target.arguments = ["0.5"]
        try target.run()

        let missingBundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcpviewer-relaunch-\(UUID().uuidString).app")
        let waiter = TCPViewerAppRelauncher.makeWaiterProcess(
            processIdentifier: target.processIdentifier,
            bundleURL: missingBundleURL
        )
        try waiter.run()
        waiter.waitUntilExit()

        #expect(!target.isRunning)
        target.waitUntilExit()
    }
}
