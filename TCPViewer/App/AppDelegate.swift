//
//  AppDelegate.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Cocoa
import Sparkle

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    let networkHelperToolManager = TCPViewerNetworkHelperToolManager()
    let appConfiguration = AppConfiguration()

    private var aboutWindowController: TCPViewerAboutWindowController?
    private var settingsWindowController: NSWindowController?
    private var licenseWindowController: TCPViewerLicenseWindowController?
    private var updaterController: SPUStandardUpdaterController?
    private let sparkleUpdaterDelegate = TCPViewerSparkleUpdaterDelegate()
    private weak var checkForUpdatesMenuItem: NSMenuItem?
    private weak var licenseMenuItem: NSMenuItem?
    private var licenseStatusObserver: NSObjectProtocol?
    private var isHandlingTermination = false
    private var isShowingRenewalRequiredAlert = false


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        appConfiguration.applyAppearance()
        observeLicenseStatusChanges()
        wireAboutMenu()
        wirePreferencesMenu()
        wireUpdatesMenu()
        wireFilterMenu()
        verifyLicenseAtLaunch()
        networkHelperToolManager.refreshStatusForLaunch()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        verifyLicenseIfNeededForForeground()
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

    @IBAction func showAbout(_ sender: Any?) {
        // Reuse one About window so repeated menu clicks keep the window stable.
        if let aboutWindowController {
            aboutWindowController.showWindow(sender)
            aboutWindowController.window?.makeKeyAndOrderFront(sender)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = TCPViewerAboutWindowController()
        aboutWindowController = controller
        controller.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
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

    private func wireAboutMenu() {
        // Replace the storyboard standard About panel with the custom SwiftUI About window.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            return
        }

        let standardAboutAction = NSSelectorFromString("orderFrontStandardAboutPanel:")
        guard let item = appMenu.items.first(where: { $0.action == standardAboutAction || $0.title.hasPrefix("About ") }) else {
            return
        }

        item.target = self
        item.action = #selector(showAbout(_:))
        item.title = "About TCP Viewer"
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

    private func wireUpdatesMenu() {
        // Sparkle owns validation and presentation once the update menu item is connected.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            return
        }

        let item = findOrCreateUpdatesMenuItem(in: appMenu)
        checkForUpdatesMenuItem = item

        guard let updaterController = makeUpdaterControllerIfConfigured() else {
            item.target = nil
            item.action = nil
            item.isEnabled = false
            return
        }

        item.target = updaterController
        item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        item.isEnabled = true
    }

    private func findOrCreateUpdatesMenuItem(in appMenu: NSMenu) -> NSMenuItem {
        // Keep the standard Sparkle command near About where macOS users expect it.
        if let existingItem = appMenu.items.first(where: { $0.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)) || $0.title == "Check for Updates…" }) {
            existingItem.title = "Check for Updates…"
            return existingItem
        }

        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        let insertionIndex = appMenu.items.firstIndex { $0.isSeparatorItem } ?? min(1, appMenu.items.count)
        appMenu.insertItem(item, at: insertionIndex)
        return item
    }

    private func makeUpdaterControllerIfConfigured() -> SPUStandardUpdaterController? {
        // Local debug builds can omit Sparkle env values, while release builds must provide them.
        guard isSparkleConfigured() else {
            return nil
        }

        if let updaterController {
            return updaterController
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: sparkleUpdaterDelegate,
            userDriverDelegate: nil
        )
        updaterController = controller
        return controller
    }

    private func isSparkleConfigured() -> Bool {
        // Reject unresolved build-setting placeholders so development builds stay quiet.
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

        return isResolvedSparkleValue(feedURL) && isResolvedSparkleValue(publicKey)
    }

    private func isResolvedSparkleValue(_ value: String?) -> Bool {
        // Sparkle requires both values before it can safely check for updates.
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        return !value.isEmpty && !value.contains("$(")
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

    private func verifyLicenseAtLaunch() {
        TCPViewerLicenseService.shared.verifyAtLaunch { [weak self] status in
            self?.handleLicenseVerificationStatus(status)
        }
    }

    private func verifyLicenseIfNeededForForeground() {
        TCPViewerLicenseService.shared.verifyIfNeeded { [weak self] status in
            self?.handleLicenseVerificationStatus(status)
        }
    }

    private func handleLicenseVerificationStatus(_ status: TCPViewerLicenseStatus) {
        guard case .unauthorized(.renewalRequired) = status else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.showRenewalRequiredAlertIfNeeded()
        }
    }

    private func showRenewalRequiredAlertIfNeeded() {
        guard !isShowingRenewalRequiredAlert else {
            return
        }

        isShowingRenewalRequiredAlert = true
        let alert = NSAlert()
        alert.messageText = "TCP Viewer PRO Was Disabled"
        alert.informativeText = TCPViewerLicenseError.renewalRequired.errorDescription ?? "This TCP Viewer build is not covered by your license."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Renew License")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            TCPViewerLicenseWebsiteService.open(.renewLicense)
        }
        isShowingRenewalRequiredAlert = false
    }
}

private final class TCPViewerSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        var parameters = [
            [
                "key": "platform",
                "value": "macos",
                "displayKey": "Platform",
                "displayValue": "macOS",
            ],
        ]

        if let signature = TCPViewerLicenseService.shared.currentLicense?.signature {
            // Sparkle cannot add custom headers for appcast checks, so pass the receipt signature as a query parameter.
            parameters.append([
                "key": "signature",
                "value": signature,
                "displayKey": "License Receipt",
                "displayValue": "Activated",
            ])
        }

        return parameters
    }
}
