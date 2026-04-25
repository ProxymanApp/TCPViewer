import AppKit
import SwiftUI

final class TCPViewerSettingsWindowController: NSWindowController {
    private let tabViewController = TCPViewerSettingsTabViewController()
    private var tabChromeHeight: CGFloat = 112

    init(
        configuration: AppConfiguration,
        networkHelperToolManager: any TCPViewerNetworkHelperToolManaging
    ) {
        tabViewController.title = "Settings"
        tabViewController.tabStyle = .toolbar
        tabViewController.addTabViewItem(Self.makeTab(
            title: "Privacy",
            systemImage: "person.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerPrivacySettingsView(configuration: configuration))
        ))
        tabViewController.addTabViewItem(Self.makeTab(
            title: "Appearance",
            systemImage: "paintbrush.pointed.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerAppearanceSettingsView(configuration: configuration))
        ))
        tabViewController.addTabViewItem(Self.makeTab(
            title: "Helper Tool",
            systemImage: "wrench.and.screwdriver.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerHelperToolSettingsView(manager: networkHelperToolManager))
        ))

        let window = NSWindow(contentViewController: tabViewController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: TCPViewerSettingsLayout.windowWidth, height: 500))
        window.contentMinSize = NSSize(width: TCPViewerSettingsLayout.windowWidth, height: 1)
        window.contentMaxSize = NSSize(width: TCPViewerSettingsLayout.windowWidth, height: CGFloat.greatestFiniteMagnitude)
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }

        super.init(window: window)
        tabViewController.onSelectionChanged = { [weak self] in
            self?.resizeWindowToSelectedTab()
        }
        resizeWindowToSelectedTab()
    }

    private static func makeHostingController<Content: View>(rootView: Content) -> NSViewController {
        let controller = NSHostingController(rootView: rootView)
        controller.view.frame.size.width = TCPViewerSettingsLayout.windowWidth
        return controller
    }

    private static func makeTab(
        title: String,
        systemImage: String,
        viewController: NSViewController
    ) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: viewController)
        item.label = title
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        return item
    }

    private func resizeWindowToSelectedTab() {
        guard let window, let selectedView = tabViewController.tabView.selectedTabViewItem?.view else {
            return
        }

        window.title = "Settings"
        tabViewController.view.layoutSubtreeIfNeeded()
        if selectedView.frame.height > 0 {
            tabChromeHeight = max(0, tabViewController.view.bounds.height - selectedView.frame.height)
        }

        let selectedHeight = selectedView.fittingSize.height
        let targetContentHeight = ceil(selectedHeight + tabChromeHeight)
        var targetFrame = window.frameRect(forContentRect: NSRect(
            origin: .zero,
            size: NSSize(width: TCPViewerSettingsLayout.windowWidth, height: targetContentHeight)
        ))
        targetFrame.origin.x = window.frame.origin.x
        targetFrame.origin.y = window.frame.maxY - targetFrame.height

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.setFrame(targetFrame, display: true, animate: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TCPViewerSettingsTabViewController: NSTabViewController {
    var onSelectionChanged: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelectionChanged?()
    }
}
