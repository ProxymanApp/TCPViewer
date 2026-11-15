//
//  TCPViewerSettingsWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import AppKit
import SwiftUI

enum TCPViewerSettingsTab: String {
    case privacy = "Privacy"
    case appearance = "Appearance"
    case helperTool = "Helper Tool"
    case tlsDecryption = "TLS"
    case mcp = "MCP"
    case moreApps = "More Apps"
}

final class TCPViewerSettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "TCPViewer.SettingsWindow"

    private let tabViewController = TCPViewerSettingsTabViewController()
    private var tabChromeHeight: CGFloat = 112

    init(
        configuration: AppConfiguration,
        networkHelperToolManager: any TCPViewerNetworkHelperToolManaging
    ) {
        var resizeForContentChange: (() -> Void)?

        tabViewController.title = "Settings"
        tabViewController.tabStyle = .toolbar
        tabViewController.addTabViewItem(Self.makeTab(
            tab: .privacy,
            systemImage: "person.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerPrivacySettingsView(configuration: configuration))
        ))
        tabViewController.addTabViewItem(Self.makeTab(
            tab: .appearance,
            systemImage: "paintbrush.pointed.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerAppearanceSettingsView(configuration: configuration))
        ))
        tabViewController.addTabViewItem(Self.makeTab(
            tab: .helperTool,
            systemImage: "wrench.and.screwdriver.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerHelperToolSettingsView(manager: networkHelperToolManager))
        ))
        tabViewController.addTabViewItem(Self.makeTab(
            tab: .tlsDecryption,
            systemImage: "lock.open.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerTLSDecryptionSettingsView(
                onPreferredHeightChange: {
                    resizeForContentChange?()
                }
            ))
        ))
        tabViewController.addTabViewItem(Self.makeTab(
            tab: .mcp,
            systemImage: "cpu.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerMCPSettingsView(
                configuration: configuration,
                onPreferredHeightChange: {
                    resizeForContentChange?()
                }
            ))
        ))
        tabViewController.addTabViewItem(Self.makeTab(
            tab: .moreApps,
            systemImage: "square.grid.2x2.fill",
            viewController: Self.makeHostingController(rootView: TCPViewerMoreAppsSettingsView())
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
        resizeForContentChange = { [weak self] in
            self?.resizeWindowToSelectedTab()
        }
        tabViewController.onSelectionChanged = { [weak self] in
            self?.resizeWindowToSelectedTab()
        }
        resizeWindowToSelectedTab()
        TCPViewerUI.restoreWindowFrameOrCenter(window, autosaveName: Self.frameAutosaveName)
        resizeWindowToSelectedTab()
    }

    // Bring a pane forward, e.g. TLS when the user asks to add a key log from a capture window.
    func select(_ tab: TCPViewerSettingsTab) {
        guard let index = tabViewController.tabViewItems.firstIndex(where: { $0.label == tab.rawValue }) else { return }
        tabViewController.selectedTabViewItemIndex = index
    }

    private static func makeHostingController<Content: View>(rootView: Content) -> NSViewController {
        let controller = NSHostingController(rootView: rootView)
        controller.view.frame.size.width = TCPViewerSettingsLayout.windowWidth
        return controller
    }

    // Tabs take their titles from TCPViewerSettingsTab, so select(_:) always finds them.
    private static func makeTab(
        tab: TCPViewerSettingsTab,
        systemImage: String,
        viewController: NSViewController
    ) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: viewController)
        item.label = tab.rawValue
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: tab.rawValue)
        return item
    }

    private func resizeWindowToSelectedTab() {
        guard let window, let selectedView = tabViewController.tabView.selectedTabViewItem?.view else {
            return
        }

        window.title = "Settings"
        tabViewController.view.layoutSubtreeIfNeeded()
        selectedView.layoutSubtreeIfNeeded()
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
