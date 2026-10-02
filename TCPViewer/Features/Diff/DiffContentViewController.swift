//
//  DiffContentViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit

final class DiffContentViewController: NSViewController, NSUserInterfaceValidations {
    @IBOutlet weak var diffContainerView: NSView!
    @IBOutlet weak var diffModeBtn: NSPopUpButton!
    @IBOutlet weak var emptyLbl: NSTextField!
    @IBOutlet weak var helpLbl: NSStackView!
    @IBOutlet weak var toolbarBoxView: NSBox!
    @IBOutlet weak var backgroundBox: NSBox!
    @IBOutlet weak var sideBySideModeMenuItem: NSMenuItem!
    @IBOutlet weak var unifiedModeMenuItem: NSMenuItem!
    @IBOutlet weak var shareBtn: NSPopUpButton!
    @IBOutlet weak var fileMergeMenuItem: NSMenuItem!
    @IBOutlet weak var ksdiffMenuItem: NSMenuItem!

    private var model: DiffPoolModel!
    private let editor = DiffMonacoEditorViewController()
    var externalComparison: DiffExternalComparison?

    func configure(model: DiffPoolModel, configuration: AppConfiguration) {
        self.model = model
        _ = view
        backgroundBox.fillColor = .controlBackgroundColor
        toolbarBoxView.fillColor = .controlBackgroundColor
        emptyLbl.maximumNumberOfLines = 0
        emptyLbl.lineBreakMode = .byWordWrapping
        emptyLbl.alignment = .center
        emptyLbl.widthAnchor.constraint(lessThanOrEqualTo: diffContainerView.widthAnchor, constant: -40).isActive = true
        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        diffContainerView.addSubview(editor.view)
        NSLayoutConstraint.activate([
            editor.view.leadingAnchor.constraint(equalTo: diffContainerView.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: diffContainerView.trailingAnchor),
            editor.view.topAnchor.constraint(equalTo: diffContainerView.topAnchor),
            editor.view.bottomAnchor.constraint(equalTo: diffContainerView.bottomAnchor)
        ])
        editor.configure(configuration)
    }

    // Loading and failures replace the previous comparison so stale packet text is never shown.
    func render() {
        diffModeBtn.select(model.displayMode == .sideBySide ? sideBySideModeMenuItem : unifiedModeMenuItem)
        let entries = [model.left, model.right].compactMap { $0 }
        let errors = entries.compactMap(\.errorMessage)
        let pending = entries.contains { $0.text == nil && $0.errorMessage == nil }
        let ready = !entries.isEmpty && errors.isEmpty && !pending
        emptyLbl.isHidden = ready
        helpLbl.isHidden = !entries.isEmpty
        editor.view.isHidden = !ready
        emptyLbl.stringValue = entries.isEmpty ? "No Item Selection" : pending ? "Loading packet details…" : "Could not load packet details.\n\(errors.joined(separator: "\n"))"
        editor.render(left: ready ? model.left?.text ?? "" : "", right: ready ? model.right?.text ?? "" : "", mode: model.displayMode)
    }

    @IBAction func diffModeBtnOnChange(_ sender: NSMenuItem) {
        model.setDisplayMode(sender === sideBySideModeMenuItem ? .sideBySide : .unified)
    }

    @IBAction func helpBtnOnClick(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Compare Packet Details"
        alert.informativeText = "Select packets in the main table, then press ⌘Y or right-click → Diff. Use the Left and Right checkboxes to choose the comparison.\n\nEvery packet-detail row is included, with tabs showing its hierarchy. Side By Side displays two panes; Unified displays an inline diff.\n\n⌘[ and ⌘] assign the selected row to a side. Delete removes entries from the Diff pool."
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    @IBAction func openWithFileMergeBtnOnClick(_ sender: Any?) { openExternal(.fileMerge) }
    @IBAction func openWithDsdiffBtnOnClick(_ sender: Any?) { openExternal(.kaleidoscope) }

    private func openExternal(_ app: DiffExternalComparison.App) {
        guard let left = model.left?.text, let right = model.right?.text else { return }
        externalComparison?.open(app: app, left: left, right: right) { [weak self] error in
            guard let self, let error, let window = self.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Could not open comparison"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(openWithFileMergeBtnOnClick(_:)) || item.action == #selector(openWithDsdiffBtnOnClick(_:)) {
            return model.left?.text != nil && model.right?.text != nil
        }
        return true
    }

    func showSearchBar() { editor.showSearchBar() }
    func closeEditor() { editor.closeEditor() }
}
