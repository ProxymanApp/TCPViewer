import Testing
import Foundation
import PcapPlusPlusCore
@testable import Packetman

@MainActor
struct PacketmanTests {
    @Test func windowControllerNotifiesDelegateOnStateChange() {
        let userDefaults = Self.makeUserDefaults()
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: UnconfiguredPacketryCore()),
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
            services: PacketryServiceRegistry(core: UnconfiguredPacketryCore()),
            userDefaults: userDefaults
        )
        let delegate = InspectorViewModelDelegateSpy()
        viewModel.delegate = delegate

        viewModel.updateDisplayFilterText("protocol:tcp")

        #expect(delegate.changeCount > 0)
        #expect(viewModel.snapshot.displayFilterText == "protocol:tcp")
    }

    private static func makeUserDefaults() -> UserDefaults {
        let suiteName = "PacketmanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class WindowControllerDelegateSpy: PacketryWindowControllerDelegate {
    private(set) var changeCount = 0

    func packetryWindowControllerDidChange(_ controller: PacketryWindowController) {
        changeCount += 1
    }
}

private final class InspectorViewModelDelegateSpy: NetworkInspectorViewModelDelegate {
    private(set) var changeCount = 0

    func networkInspectorViewModelDidChange(_ viewModel: NetworkInspectorViewModel) {
        changeCount += 1
    }
}
