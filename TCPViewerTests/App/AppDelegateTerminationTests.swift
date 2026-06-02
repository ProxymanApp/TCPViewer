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
}
