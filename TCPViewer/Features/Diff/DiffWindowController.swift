//
//  DiffWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit

final class DiffWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = windowController as? DiffWindowController, controller.handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class DiffWindowController: NSWindowController, NSWindowDelegate, DiffPoolModelDelegate, NSMenuItemValidation {
    private var poolController: DiffPoolViewController!
    private var contentController: DiffContentViewController!
    private var model: DiffPoolModel!
    var closeHandler: (() -> Void)?

    // The storyboard and sizing originate from Proxyman's Cocoa Diff window.
    override func windowDidLoad() {
        super.windowDidLoad()
        window?.setContentSize(NSSize(width: 1400, height: 900))
        window?.minSize = NSSize(width: 650, height: 450)
        if let window { TCPViewerUI.restoreWindowFrameOrCenter(window, autosaveName: "TCPViewer.Diff.Window") }
    }

    func configure(model: DiffPoolModel, configuration: AppConfiguration, layout: PacketTableColumnLayout?) {
        self.model = model
        guard let split = contentViewController as? DiffSplitViewController else { return }
        poolController = split.splitViewItems[0].viewController as? DiffPoolViewController
        contentController = split.splitViewItems[1].viewController as? DiffContentViewController
        poolController.configure(model: model, configuration: configuration, layout: layout)
        contentController.configure(model: model, configuration: configuration)
        model.delegate = self
        diffPoolModelDidChange(model)
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func diffPoolModelDidChange(_ model: DiffPoolModel) {
        poolController.render()
        contentController.render()
    }

    @IBAction func selectDiffLeft(_ sender: Any?) { poolController.toggleSide(.left) }
    @IBAction func selectDiffRight(_ sender: Any?) { poolController.toggleSide(.right) }
    @IBAction func focusStructuredFilter(_ sender: Any?) { contentController.showSearchBar() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectDiffLeft(_:)) || item.action == #selector(selectDiffRight(_:)) {
            let side: DiffSide = item.action == #selector(selectDiffLeft(_:)) ? .left : .right
            item.state = poolController.selectedEntry?.side == side ? .on : .off
            return window?.attachedSheet == nil && poolController.selectedEntry != nil
        }
        return true
    }

    // Brackets belong to the focused Diff window rather than the main window's tab history.
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard window?.attachedSheet == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 98, flags.isEmpty || flags == [.shift] {
            return contentController.navigateByteDifference(backwards: flags == [.shift])
        }
        if flags == [.command, .shift], event.keyCode == 51 || event.keyCode == 117,
           window?.firstResponder === poolController.tableView {
            model.removeAll()
            return true
        }
        guard flags == [.command] else { return false }
        switch event.charactersIgnoringModifiers {
        case "[": selectDiffLeft(nil); return true
        case "]": selectDiffRight(nil); return true
        case "f": contentController.showSearchBar(); return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.delegate = nil
        contentController.closeEditor()
        closeHandler?()
    }
}

final class DiffSplitViewController: NSSplitViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.autosaveName = "TCPViewer.Diff.Split"
    }
}
