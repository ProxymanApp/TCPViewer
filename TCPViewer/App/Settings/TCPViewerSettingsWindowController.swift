import AppKit
import SwiftUI

final class TCPViewerSettingsWindowController: NSWindowController {
    init(
        configuration: AppConfiguration,
        networkHelperToolManager: any TCPViewerNetworkHelperToolManaging
    ) {
        let rootView = TCPViewerSettingsView(
            configuration: configuration,
            networkHelperToolManager: networkHelperToolManager
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 500))
        window.contentMinSize = NSSize(width: 700, height: 440)
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .expanded
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
