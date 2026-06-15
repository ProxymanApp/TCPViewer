//
//  TCPViewerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Testing
import Foundation
import AppKit
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

    @Test func dynamicBackgroundViewUpdatesLayerColorForAppearanceChanges() throws {
        let dynamicColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
        }
        let view = TCPViewerDynamicBackgroundView(backgroundColor: dynamicColor)

        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        let lightBackground = try #require(view.layer?.backgroundColor)

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        let darkBackground = try #require(view.layer?.backgroundColor)

        #expect(try brightness(of: lightBackground) > brightness(of: darkBackground))
    }

    private static func makeUserDefaults() -> UserDefaults {
        let suiteName = "TCPViewerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func brightness(of color: CGColor) throws -> CGFloat {
        let nsColor = try #require(NSColor(cgColor: color)?.usingColorSpace(.deviceRGB))
        return nsColor.redComponent + nsColor.greenComponent + nsColor.blueComponent
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
