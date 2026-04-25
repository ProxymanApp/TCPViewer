//
//  AppDelegate.swift
//  TCPViewer
//
//  Created by nghiatran on 24/4/26.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let networkHelperToolManager = TCPViewerNetworkHelperToolManager()
    let appConfiguration = AppConfiguration()

    private var settingsWindowController: NSWindowController?
    private var isHandlingTermination = false


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        appConfiguration.applyAppearance()
        wirePreferencesMenu()
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

    private func wirePreferencesMenu() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            return
        }

        for item in appMenu.items where item.keyEquivalent == "," || item.title == "Preferences…" || item.title == "Settings…" {
            item.target = self
            item.action = #selector(showSettings(_:))
            item.title = "Settings…"
        }
    }
}
