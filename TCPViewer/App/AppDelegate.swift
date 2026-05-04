//
//  AppDelegate.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let networkHelperToolManager = TCPViewerNetworkHelperToolManager()
    let appConfiguration = AppConfiguration()

    private var settingsWindowController: NSWindowController?
    private var licenseWindowController: NSWindowController?
    private weak var licenseMenuItem: NSMenuItem?
    private var licenseStatusObserver: NSObjectProtocol?
    private var isHandlingTermination = false


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        appConfiguration.applyAppearance()
        observeLicenseStatusChanges()
        wirePreferencesMenu()
        TCPViewerLicenseService.shared.verifyAtLaunch()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isHandlingTermination else {
            return .terminateLater
        }

        isHandlingTermination = true
        TCPViewerWorkspaceController.prepareAllForApplicationTermination { [weak self] shouldTerminate in
            self?.isHandlingTermination = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }

        return .terminateLater
    }

    @IBAction func showSettings(_ sender: Any?) {
        if let settingsWindowController {
            settingsWindowController.showWindow(sender)
            settingsWindowController.window?.makeKeyAndOrderFront(sender)
            return
        }

        let controller = TCPViewerSettingsWindowController(
            configuration: appConfiguration,
            networkHelperToolManager: networkHelperToolManager
        )
        settingsWindowController = controller
        controller.showWindow(sender)
    }

    @IBAction func showLicense(_ sender: Any?) {
        if let licenseWindowController {
            licenseWindowController.showWindow(sender)
            licenseWindowController.window?.makeKeyAndOrderFront(sender)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = TCPViewerLicenseWindowController()
        licenseWindowController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func wirePreferencesMenu() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            return
        }

        for item in appMenu.items where item.keyEquivalent == "," || item.title == "Preferences…" || item.title == "Settings…" {
            item.target = self
            item.action = #selector(showSettings(_:))
            item.title = "Settings…"
        }

        addLicenseMenuItemIfNeeded(to: appMenu)
    }

    private func addLicenseMenuItemIfNeeded(to appMenu: NSMenu) {
        if let existingItem = appMenu.items.first(where: { $0.action == #selector(showLicense(_:)) }) {
            licenseMenuItem = existingItem
            updateLicenseMenuItemTitle()
            return
        }

        let item = NSMenuItem(title: "", action: #selector(showLicense(_:)), keyEquivalent: "")
        item.target = self

        let insertionIndex = appMenu.items.firstIndex { $0.action == #selector(showSettings(_:)) }
            .map { $0 + 1 }
            ?? max(0, appMenu.items.count - 1)
        appMenu.insertItem(NSMenuItem.separator(), at: insertionIndex)
        appMenu.insertItem(item, at: insertionIndex + 1)
        licenseMenuItem = item
        updateLicenseMenuItemTitle()
    }

    private func observeLicenseStatusChanges() {
        licenseStatusObserver = NotificationCenter.default.addObserver(
            forName: TCPViewerLicenseService.statusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateLicenseMenuItemTitle()
        }
    }

    private func updateLicenseMenuItemTitle() {
        licenseMenuItem?.title = TCPViewerLicenseService.shared.isLicenseAuthorized
            ? "TCP Viewer License…"
            : "Buy TCP Viewer License…"
    }
}
