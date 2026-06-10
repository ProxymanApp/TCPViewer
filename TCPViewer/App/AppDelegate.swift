//
//  AppDelegate.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Cocoa
import PcapPlusPlusCore
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
    private lazy var sentryService = TCPViewerSentryService(configuration: appConfiguration)
    private lazy var factoryResetService = TCPViewerFactoryResetService(helperToolManager: networkHelperToolManager)
    private var isHandlingTermination = false
    private var skipsNextQuitConfirmation = false
    private var isShowingRenewalRequiredAlert = false
    private var isVerifyingLicenseAtLaunch = false
    private var didCheckForUpdatesAtLaunch = false
    private var isTerminatingAfterFactoryReset = false
    #if DEBUG
    private var shouldOpenUntitledDocumentAfterIgnoringDebugLaunchFiles = false
    #endif


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        sentryService.start()
        appConfiguration.applyAppearance()
        observeLicenseStatusChanges()
        wireAboutMenu()
        wirePreferencesMenu()
        wireUpdatesMenu()
        wireFilterMenu()
        wireHelpMenu()
        verifyLicenseAtLaunch()
        networkHelperToolManager.refreshStatusForLaunch()
        #if DEBUG
        openUntitledDocumentAfterIgnoringDebugLaunchFilesIfNeeded()
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        verifyLicenseIfNeededForForeground()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        #if DEBUG
        let filteredFilenames = TCPViewerDebugLaunchArgumentFilter.filteredDocumentFilenames(filenames)
        guard filteredFilenames.count != filenames.count else {
            importCaptureFiles(filenames, sender: sender)
            return
        }

        if filteredFilenames.isEmpty {
            shouldOpenUntitledDocumentAfterIgnoringDebugLaunchFiles = true
            sender.reply(toOpenOrPrint: .success)
            openUntitledDocumentAfterIgnoringDebugLaunchFilesIfNeeded()
        } else {
            importCaptureFiles(filteredFilenames, sender: sender)
        }
        #else
        importCaptureFiles(filenames, sender: sender)
        #endif
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingAfterFactoryReset else {
            return .terminateNow
        }

        guard !isHandlingTermination else {
            return .terminateLater
        }

        guard shouldContinueAfterQuitConfirmation() else {
            return .terminateCancel
        }

        return prepareForTermination(sender)
    }

    @IBAction func openDocument(_ sender: Any?) {
        presentCaptureOpenPanel()
    }

    private func prepareForTermination(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isHandlingTermination = true
        TCPViewerWorkspaceController.prepareAllForApplicationTermination { [weak self] shouldTerminate in
            self?.isHandlingTermination = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }

        return .terminateLater
    }

    private func importCaptureFiles(_ filenames: [String], sender: NSApplication) {
        guard !filenames.isEmpty else {
            sender.reply(toOpenOrPrint: .success)
            return
        }

        let urls = filenames
            .map { URL(fileURLWithPath: $0) }
            .filter(TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL)

        guard !urls.isEmpty else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        importCaptureURLs(urls) { success in
            sender.reply(toOpenOrPrint: success ? .success : .failure)
        }
    }

    // Presents the shared capture importer from the app-level File > Open action.
    private func presentCaptureOpenPanel() {
        let panel = NSOpenPanel()
        TCPViewerCaptureFileImportPolicy.configureOpenPanel(panel)
        guard panel.runModal() == .OK else {
            return
        }

        importCaptureURLs(panel.urls)
    }

    // Imports captures into the current TCP Viewer window, creating one only when needed.
    private func importCaptureURLs(_ urls: [URL], completion: ((Bool) -> Void)? = nil) {
        let supportedURLs = urls.filter(TCPViewerCaptureFileImportPolicy.isSupportedCaptureFileURL)
        guard !supportedURLs.isEmpty else {
            completion?(false)
            return
        }

        do {
            let windowController = try frontmostOrNewTCPViewerWindowController()
            focusWindowController(windowController)
            windowController.rootViewController.importDocuments(at: supportedURLs) {
                completion?(true)
            }
        } catch {
            NSDocumentController.shared.presentError(error)
            completion?(false)
        }
    }

    private func frontmostOrNewTCPViewerWindowController() throws -> TCPViewerWindowController {
        if let controller = frontmostTCPViewerWindowController() {
            return controller
        }

        let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        guard let controller = document.windowControllers.compactMap({ $0 as? TCPViewerWindowController }).first else {
            throw TCPViewerCoreError(code: .offlineFileOpenFailed, message: "TCP Viewer could not create a window for imported capture files.")
        }
        return controller
    }

    // Finds an existing TCP Viewer document window before falling back to a new one.
    private func frontmostTCPViewerWindowController() -> TCPViewerWindowController? {
        if let controller = NSApp.orderedWindows.compactMap({ $0.windowController as? TCPViewerWindowController }).first {
            return controller
        }

        for document in NSDocumentController.shared.documents {
            if let controller = document.windowControllers.compactMap({ $0 as? TCPViewerWindowController }).first {
                return controller
            }
        }

        return NSApp.windows.compactMap { $0.windowController as? TCPViewerWindowController }.first
    }

    // Brings the import target window forward so newly imported files are immediately visible.
    private func focusWindowController(_ controller: TCPViewerWindowController) {
        controller.showWindow(nil)
        if controller.window?.isMiniaturized == true {
            controller.window?.deminiaturize(nil)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    private func openUntitledDocumentAfterIgnoringDebugLaunchFilesIfNeeded() {
        guard shouldOpenUntitledDocumentAfterIgnoringDebugLaunchFiles else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.shouldOpenUntitledDocumentAfterIgnoringDebugLaunchFiles else {
                return
            }

            self.shouldOpenUntitledDocumentAfterIgnoringDebugLaunchFiles = false
            guard NSApp.windows.contains(where: { $0.windowController is TCPViewerWindowController }) == false else {
                return
            }

            do {
                _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            } catch {
                NSDocumentController.shared.presentError(error)
            }
        }
    }
    #endif

    private func shouldContinueAfterQuitConfirmation() -> Bool {
        guard !skipsNextQuitConfirmation else {
            skipsNextQuitConfirmation = false
            return true
        }

        guard appConfiguration.confirmsBeforeQuitting else {
            return true
        }

        return presentQuitConfirmationAlert()
    }

    private func presentQuitConfirmationAlert() -> Bool {
        let doNotAskAgainCheckbox = NSButton(
            checkboxWithTitle: "Do not ask again",
            target: nil,
            action: nil
        )
        doNotAskAgainCheckbox.state = .off

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit TCP Viewer?"
        alert.informativeText = "All captured data in the current session will be lost."
        alert.accessoryView = doNotAskAgainCheckbox
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        if doNotAskAgainCheckbox.state == .on {
            appConfiguration.confirmsBeforeQuitting = false
        }
        return true
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

    @IBAction func factoryReset(_ sender: Any?) {
        presentFactoryResetConfirmation()
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
        checkForUpdatesAtLaunchIfNeeded(using: updaterController)
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

    private func checkForUpdatesAtLaunchIfNeeded(using updaterController: SPUStandardUpdaterController) {
        // Ask Sparkle once per launch so any available update shows its standard release-notes prompt.
        guard !didCheckForUpdatesAtLaunch else {
            return
        }

        didCheckForUpdatesAtLaunch = true
        let updater = updaterController.updater
        guard updater.automaticallyChecksForUpdates else {
            return
        }

        updater.checkForUpdatesInBackground()
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

    private func wireHelpMenu() {
        guard let helpMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Help" })?.submenu else {
            return
        }

        let advancedItem = findOrCreateAdvancedMenuItem(in: helpMenu)
        let advancedMenu = advancedItem.submenu ?? NSMenu(title: "Advanced")
        advancedItem.submenu = advancedMenu

        if let existingItem = advancedMenu.items.first(where: { $0.action == #selector(factoryReset(_:)) }) {
            configureFactoryResetMenuItem(existingItem)
            return
        }

        let item = NSMenuItem(title: "Factory Reset…", action: #selector(factoryReset(_:)), keyEquivalent: "")
        configureFactoryResetMenuItem(item)
        advancedMenu.addItem(item)
    }

    private func findOrCreateAdvancedMenuItem(in helpMenu: NSMenu) -> NSMenuItem {
        if let existingItem = helpMenu.items.first(where: { $0.title == "Advanced" }) {
            return existingItem
        }

        let item = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "Advanced")

        if !helpMenu.items.isEmpty, helpMenu.items.last?.isSeparatorItem == false {
            helpMenu.addItem(NSMenuItem.separator())
        }
        helpMenu.addItem(item)
        return item
    }

    private func configureFactoryResetMenuItem(_ item: NSMenuItem) {
        item.title = "Factory Reset…"
        item.target = self
        item.action = #selector(factoryReset(_:))
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
    }

    private func presentFactoryResetConfirmation() {
        let uninstallHelperCheckbox = NSButton(
            checkboxWithTitle: "Also uninstall the Helper Tool",
            target: nil,
            action: nil
        )
        uninstallHelperCheckbox.state = .off

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Factory Reset TCP Viewer?"
        alert.informativeText = "This will remove TCP Viewer app data, user defaults, saved windows, caches, and local state. This cannot be undone."
        alert.accessoryView = uninstallHelperCheckbox
        alert.addButton(withTitle: "Yes, Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        performFactoryReset(uninstallHelperTool: uninstallHelperCheckbox.state == .on)
    }

    private func performFactoryReset(uninstallHelperTool: Bool) {
        disableAutosavedWindowStateForFactoryReset()
        factoryResetService.reset(uninstallHelperTool: uninstallHelperTool) { [weak self] result in
            self?.handleFactoryResetResult(result, uninstallHelperTool: uninstallHelperTool)
        }
    }

    private func handleFactoryResetResult(
        _ result: Result<TCPViewerFactoryResetResult, Error>,
        uninstallHelperTool: Bool
    ) {
        switch result {
        case .success(let resetResult):
            disableAutosavedWindowStateForFactoryReset()
            NSDocumentController.shared.clearRecentDocuments(nil)
            showFactoryResetCompletionAlert(resetResult, uninstallHelperTool: uninstallHelperTool)
            prepareForFactoryResetTermination()
            NSApp.terminate(nil)
        case .failure(let error):
            showFactoryResetFailureAlert(error)
        }
    }

    func prepareForFactoryResetTermination() {
        // Factory Reset already deleted app state, so the next termination must not be cancellable.
        isTerminatingAfterFactoryReset = true
        skipsNextQuitConfirmation = true
    }

    private func showFactoryResetCompletionAlert(
        _ result: TCPViewerFactoryResetResult,
        uninstallHelperTool: Bool
    ) {
        let helperDidNotUninstall = uninstallHelperTool && result.helperToolSnapshot?.status != .notInstalled
        let alert = NSAlert()
        alert.alertStyle = helperDidNotUninstall ? .warning : .informational
        alert.messageText = helperDidNotUninstall ? "Factory Reset Finished With a Helper Tool Warning" : "Factory Reset Complete"
        alert.informativeText = helperDidNotUninstall
            ? "TCP Viewer removed local data, but macOS still reports that the Helper Tool is not fully uninstalled. TCP Viewer will quit now so it can reopen with a clean state."
            : "TCP Viewer removed local data and will quit now. Reopen it to start fresh."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    private func showFactoryResetFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Factory Reset Failed"
        alert.informativeText = "TCP Viewer could not remove its local data: \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func disableAutosavedWindowStateForFactoryReset() {
        for window in NSApp.windows {
            window.isRestorable = false
            window.disableSnapshotRestoration()
            window.toolbar?.autosavesConfiguration = false
            _ = window.setFrameAutosaveName("")
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
        isVerifyingLicenseAtLaunch = true
        TCPViewerLicenseService.shared.verifyAtLaunch { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isVerifyingLicenseAtLaunch = false
                self.handleLicenseVerificationStatus(status)
            }
        }
    }

    private func verifyLicenseIfNeededForForeground() {
        guard !isVerifyingLicenseAtLaunch else {
            return
        }

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

#if DEBUG
private enum TCPViewerDebugLaunchArgumentFilter {
    private static let reproducerLaunchArgument = "--tcpviewer-run-selection-crash-reproducer"
    private static let reproducerEnvironmentKey = "TCPVIEWER_RUN_SELECTION_CRASH_REPRODUCER"
    private static let ignoredDocumentValues: Set<String> = ["1", "true", "yes"]

    static func filteredDocumentFilenames(_ filenames: [String]) -> [String] {
        guard shouldIgnoreReproducerDocumentArguments else {
            return filenames
        }

        return filenames.filter { filename in
            let value = URL(fileURLWithPath: filename).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !ignoredDocumentValues.contains(value)
        }
    }

    private static var shouldIgnoreReproducerDocumentArguments: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(reproducerLaunchArgument) ||
            isTruthy(processInfo.environment[reproducerEnvironmentKey]) ||
            hasTruthyLaunchArgumentValue(in: processInfo.arguments)
    }

    private static func hasTruthyLaunchArgumentValue(in arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            if argument == reproducerEnvironmentKey || argument == "-\(reproducerEnvironmentKey)" {
                let nextIndex = arguments.index(after: index)
                return nextIndex < arguments.endIndex ? isTruthy(arguments[nextIndex]) : true
            }

            if let value = value(afterEqualsSignIn: argument, key: reproducerEnvironmentKey) {
                return isTruthy(value)
            }

            if let value = value(afterEqualsSignIn: argument, key: "-\(reproducerEnvironmentKey)") {
                return isTruthy(value)
            }
        }

        return false
    }

    private static func value(afterEqualsSignIn argument: String, key: String) -> String? {
        guard argument.hasPrefix("\(key)=") else {
            return nil
        }

        return String(argument.dropFirst(key.count + 1))
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ignoredDocumentValues.contains(value)
    }
}
#endif

private final class TCPViewerSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        [
            [
                "key": "platform",
                "value": "macos",
                "displayKey": "Platform",
                "displayValue": "macOS",
            ],
        ]
    }
}
