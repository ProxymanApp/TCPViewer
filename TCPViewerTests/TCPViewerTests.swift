//
//  TCPViewerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Testing
import Foundation
import PcapPlusPlusCore
@testable import TCPViewer

@MainActor
struct TCPViewerTests {
    @Test func windowControllerNotifiesDelegateOnStateChange() {
        let userDefaults = Self.makeUserDefaults()
        let controller = TCPViewerWorkspaceController(
            services: TCPViewerServiceRegistry(core: UnconfiguredTCPViewerCore()),
            userDefaults: userDefaults
        )
        let delegate = WindowControllerDelegateSpy()
        controller.delegate = delegate

        controller.updateCaptureFilterText("tcp port 443")

        #expect(delegate.changeCount > 0)
        #expect(controller.snapshot.filterState.captureFilterText == "tcp port 443")
    }

    @Test func inspectorViewModelNotifiesDelegateOnLocalRenderChange() {
        let userDefaults = Self.makeUserDefaults()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: UnconfiguredTCPViewerCore()),
            userDefaults: userDefaults
        )
        let delegate = InspectorViewModelDelegateSpy()
        viewModel.delegate = delegate

        viewModel.updateDisplayFilterText("protocol:tcp")

        #expect(delegate.changeCount > 0)
        #expect(viewModel.snapshot.displayFilterText == "protocol:tcp")
    }

    private static func makeUserDefaults() -> UserDefaults {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class WindowControllerDelegateSpy: TCPViewerWorkspaceControllerDelegate {
    private(set) var changeCount = 0

    func tcpViewerWorkspaceControllerDidChange(_ controller: TCPViewerWorkspaceController) {
        changeCount += 1
    }
}

private final class InspectorViewModelDelegateSpy: NetworkInspectorViewModelDelegate {
    private(set) var changeCount = 0

    func networkInspectorViewModelDidChange(_ viewModel: NetworkInspectorViewModel) {
        changeCount += 1
    }
}
