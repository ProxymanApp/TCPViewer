//
//  TCPViewerUIWindowPositioningTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import AppKit
import Testing
@testable import TCPViewer

@MainActor
struct TCPViewerUIWindowPositioningTests {
    @Test func centersWindowWhenNoSavedFrameExists() {
        let window = WindowPositioningSpy(restoresSavedFrame: false)

        TCPViewerUI.restoreWindowFrameOrCenter(window, autosaveName: "Test.Window")

        #expect(window.restoredFrameName == "Test.Window")
        #expect(window.forcedFrameRestore)
        #expect(window.centerCallCount == 1)
        #expect(window.registeredAutosaveName == "Test.Window")
    }

    @Test func keepsRestoredPositionWhenSavedFrameExists() {
        let window = WindowPositioningSpy(restoresSavedFrame: true)

        TCPViewerUI.restoreWindowFrameOrCenter(window, autosaveName: "Test.Window")

        #expect(window.restoredFrameName == "Test.Window")
        #expect(window.forcedFrameRestore)
        #expect(window.centerCallCount == 0)
        #expect(window.registeredAutosaveName == "Test.Window")
    }
}

@MainActor
private final class WindowPositioningSpy: NSWindow {
    private let restoresSavedFrame: Bool

    private(set) var restoredFrameName: String?
    private(set) var forcedFrameRestore = false
    private(set) var centerCallCount = 0
    private(set) var registeredAutosaveName: String?

    init(restoresSavedFrame: Bool) {
        self.restoresSavedFrame = restoresSavedFrame
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName, force: Bool) -> Bool {
        restoredFrameName = name
        forcedFrameRestore = force
        return restoresSavedFrame
    }

    override func center() {
        centerCallCount += 1
    }

    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        registeredAutosaveName = name
        return true
    }
}
