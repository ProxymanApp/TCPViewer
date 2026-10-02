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
    @IBOutlet weak var contentKindBtn: NSPopUpButton!
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
    private var binaryFont: NSFont!
    private var binary: DiffBinaryViewController?
    var externalComparison: DiffExternalComparison?

    func configure(model: DiffPoolModel, configuration: AppConfiguration) {
        self.model = model
        binaryFont = configuration.packetFont(sizeDelta: -1)
        _ = view
        backgroundBox.fillColor = .controlBackgroundColor
        toolbarBoxView.fillColor = .controlBackgroundColor
        emptyLbl.maximumNumberOfLines = 0
        emptyLbl.lineBreakMode = .byWordWrapping
        emptyLbl.alignment = .center
        emptyLbl.widthAnchor.constraint(lessThanOrEqualTo: diffContainerView.widthAnchor, constant: -40).isActive = true
        embed(editor)
        editor.configure(configuration)
    }

    private func embed(_ controller: NSViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        diffContainerView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: diffContainerView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: diffContainerView.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: diffContainerView.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: diffContainerView.bottomAnchor)
        ])
    }

    // Loading and failures replace the previous comparison so stale packet text is never shown.
    func render() {
        let isBinary = model.contentKind == .packetBytes
        contentKindBtn.selectItem(at: isBinary ? 1 : 0)
        diffModeBtn.select(isBinary || model.displayMode == .sideBySide ? sideBySideModeMenuItem : unifiedModeMenuItem)
        diffModeBtn.isEnabled = !isBinary
        diffModeBtn.toolTip = isBinary ? "Packet Bytes uses two hex panes. Unified is available for Packet Details." : nil
        shareBtn.isHidden = isBinary
        let entries = [model.left, model.right].compactMap { $0 }
        let errors = entries.compactMap(\.errorMessage)
        let pending = entries.contains { $0.text == nil && $0.errorMessage == nil }
        let ready = !entries.isEmpty && errors.isEmpty && !pending
        emptyLbl.isHidden = ready
        helpLbl.isHidden = !entries.isEmpty
        editor.view.isHidden = !ready || isBinary
        emptyLbl.stringValue = entries.isEmpty ? "No Item Selection" : pending ? "Loading packet…" : "Could not load packet.\n\(errors.joined(separator: "\n"))"
        editor.render(left: ready && !isBinary ? model.left?.text ?? "" : "", right: ready && !isBinary ? model.right?.text ?? "" : "", mode: model.displayMode)
        if isBinary && ready {
            if binary == nil {
                let controller = DiffBinaryViewController(font: binaryFont)
                embed(controller)
                binary = controller
            }
            binary?.view.isHidden = false
            binary?.render(left: model.left, right: model.right)
        } else {
            binary?.view.isHidden = true
            binary?.suspend()
        }
    }

    @IBAction func contentKindBtnOnChange(_ sender: NSPopUpButton) {
        model.setContentKind(sender.indexOfSelectedItem == 1 ? .packetBytes : .packetDetails)
    }

    @IBAction func diffModeBtnOnChange(_ sender: NSMenuItem) {
        guard model.contentKind == .packetDetails else { return }
        model.setDisplayMode(sender === sideBySideModeMenuItem ? .sideBySide : .unified)
    }

    @IBAction func helpBtnOnClick(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Compare Packets"
        alert.informativeText = "Select packets in the main table, then press ⌘Y or right-click → Diff. Use the Left and Right checkboxes to choose the comparison.\n\nPacket Details includes every detail row. Side By Side displays two panes; Unified displays an inline diff.\n\nPacket Bytes compares captured frame bytes in read-only hex and ASCII panes. Highlighted bytes differ. Use Previous/Next (⇧F7/F7) to jump between differences, and ⌘F to find hex bytes. A truncated capture includes only the bytes it captured.\n\n⌘[ and ⌘] assign the selected row to a side. Delete removes entries from the Diff pool."
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    @IBAction func openWithFileMergeBtnOnClick(_ sender: Any?) { openExternal(.fileMerge) }
    @IBAction func openWithDsdiffBtnOnClick(_ sender: Any?) { openExternal(.kaleidoscope) }

    private func openExternal(_ app: DiffExternalComparison.App) {
        guard model.contentKind == .packetDetails, let left = model.left?.text, let right = model.right?.text else { return }
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
            return model.contentKind == .packetDetails && model.left?.text != nil && model.right?.text != nil
        }
        return true
    }

    func showSearchBar() {
        if model.contentKind == .packetBytes { binary?.showSearchBar() }
        else { editor.showSearchBar() }
    }

    func navigateByteDifference(backwards: Bool) -> Bool {
        guard model.contentKind == .packetBytes else { return false }
        if backwards { binary?.previousChange(nil) } else { binary?.nextChange(nil) }
        return true
    }

    func closeEditor() {
        binary?.suspend()
        editor.closeEditor()
    }
}
