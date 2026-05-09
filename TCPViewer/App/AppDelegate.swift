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
    private var licenseWindowController: TCPViewerLicenseWindowController?
    private weak var licenseMenuItem: NSMenuItem?
    private var licenseStatusObserver: NSObjectProtocol?
    private var isHandlingTermination = false


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        appConfiguration.applyAppearance()
        observeLicenseStatusChanges()
        wirePreferencesMenu()
        wireFilterMenu()
        TCPViewerLicenseService.shared.verifyAtLaunch()
        networkHelperToolManager.refreshStatusForLaunch()
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
        presentLicenseSheet(presentationMode: .license, sender: sender)
    }

    @IBAction func showPaywall(_ sender: Any?) {
        presentLicenseSheet(presentationMode: .paywall, sender: sender)
    }

    private func presentLicenseSheet(presentationMode: TCPViewerLicensePresentationMode, sender: Any?) {
        // Reuse one sheet owner while allowing Trial and menu actions to open different license modes.
        guard let parentWindow = licenseSheetParentWindow() ?? createLicenseSheetParentWindow() else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let controller = licenseWindowController, controller.presentationMode != presentationMode {
            dismissLicenseSheet()
        }

        if let sheetWindow = licenseWindowController?.window {
            if let sheetParent = sheetWindow.sheetParent {
                sheetParent.makeKeyAndOrderFront(sender)
            } else {
                parentWindow.beginSheet(sheetWindow)
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = TCPViewerLicenseWindowController(presentationMode: presentationMode) { [weak self] in
            self?.dismissLicenseSheet()
        }
        licenseWindowController = controller
        if let sheetWindow = controller.window {
            parentWindow.beginSheet(sheetWindow)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func licenseSheetParentWindow() -> NSWindow? {
        // Prefer attaching the license sheet to a normal TCP Viewer document window.
        let mainAppWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            + NSApp.windows.filter { $0.windowController is TCPViewerWindowController }

        return mainAppWindows.first(where: isValidLicenseSheetParent)
            ?? NSApp.windows.first(where: isValidLicenseSheetParent)
    }

    private func createLicenseSheetParentWindow() -> NSWindow? {
        // A sheet needs a parent, so create the default document window when none is open.
        _ = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        return licenseSheetParentWindow()
    }

    private func isValidLicenseSheetParent(_ window: NSWindow) -> Bool {
        // Avoid attaching to another sheet or to the license sheet itself.
        window.isVisible
            && window.sheetParent == nil
            && !(window.windowController is TCPViewerLicenseWindowController)
    }

    private func dismissLicenseSheet() {
        // End the sheet attachment when possible, with a close fallback for defensive cleanup.
        guard let sheetWindow = licenseWindowController?.window else {
            licenseWindowController = nil
            return
        }

        if let parentWindow = sheetWindow.sheetParent {
            parentWindow.endSheet(sheetWindow)
        } else {
            sheetWindow.close()
        }
        licenseWindowController = nil
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

    private func wireFilterMenu() {
        guard let editMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else {
            return
        }

        // Cmd-F belongs to the packet filter, so remove the storyboard Find conflict.
        removeFindShortcutConflict(in: editMenu)

        if let existingItem = editMenu.items.first(where: { $0.action == #selector(TCPViewerWindowController.focusStructuredFilter(_:)) }) {
            configureFilterMenuItem(existingItem)
            return
        }

        let item = NSMenuItem(
            title: "Filter",
            action: #selector(TCPViewerWindowController.focusStructuredFilter(_:)),
            keyEquivalent: "f"
        )
        configureFilterMenuItem(item)

        let insertionIndex = editMenu.items.firstIndex { $0.title == "Find" } ?? editMenu.items.count
        editMenu.insertItem(item, at: insertionIndex)
    }

    private func configureFilterMenuItem(_ item: NSMenuItem) {
        item.title = "Filter"
        item.target = nil
        item.action = #selector(TCPViewerWindowController.focusStructuredFilter(_:))
        item.keyEquivalent = "f"
        item.keyEquivalentModifierMask = [.command]
    }

    private func removeFindShortcutConflict(in menu: NSMenu) {
        let findPanelAction = NSSelectorFromString("performFindPanelAction:")

        for item in menu.items {
            if item.action == findPanelAction,
               item.keyEquivalent.lowercased() == "f",
               item.keyEquivalentModifierMask.intersection([.option, .control, .shift]).isEmpty {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }

            if let submenu = item.submenu {
                removeFindShortcutConflict(in: submenu)
            }
        }
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
