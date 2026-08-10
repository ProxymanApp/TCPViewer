//
//  TCPFollowStreamWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import AppKit
import PcapPlusPlusCore
import UniformTypeIdentifiers

final class TCPFollowCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    // Mark the background operation for cooperative cancellation.
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    // Read cancellation safely from the follow queue.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class TCPFollowStreamWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private enum ToolbarItem {
        static let direction = NSToolbarItem.Identifier("TCPFollowStream.direction")
        static let representation = NSToolbarItem.Identifier("TCPFollowStream.representation")
        static let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
        static let save = NSToolbarItem.Identifier("TCPFollowStream.save")
    }

    let cancellationFlag = TCPFollowCancellationFlag()
    var closeHandler: (() -> Void)?
    var revealPacket: ((PacketSummary.ID) -> Void)?

    private let streamViewController = TCPFollowStreamViewController()
    private let directionControl = NSSegmentedControl(labels: ["Both", "Client → Server", "Server → Client"], trackingMode: .selectOne, target: nil, action: nil)
    private let representationControl = NSSegmentedControl(labels: ["Text", "Hex"], trackingMode: .selectOne, target: nil, action: nil)
    private let saveMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let exportQueue = DispatchQueue(label: "com.proxyman.tcpviewer.TCPFollowStream.export", qos: .userInitiated)

    init(packetID: PacketSummary.ID) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Follow TCP Stream · Packet \(packetID)"
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = streamViewController
        configureToolbar()
        streamViewController.revealPacket = { [weak self] packetID in
            self?.revealPacket?(packetID)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Bring up the independent stream workspace immediately in its loading state.
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // Forward bounded core progress onto the native progress bar.
    func updateProgress(_ progress: TCPFollowProgress) {
        streamViewController.updateProgress(progress)
    }

    // Finish loading and enable transcript/raw export actions.
    func show(stream: TCPFollowStream) {
        streamViewController.show(stream: stream)
        saveMenuButton.isEnabled = true
    }

    // Show a non-destructive error inside the same window.
    func show(error: Error) {
        streamViewController.show(error: error)
        saveMenuButton.isEnabled = false
    }

    // Cooperatively cancel reassembly when the user closes the workspace.
    func windowWillClose(_ notification: Notification) {
        cancellationFlag.cancel()
        closeHandler?()
    }

    // Advertise the small fixed toolbar layout.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarItem.direction, ToolbarItem.representation, ToolbarItem.flexibleSpace, ToolbarItem.save]
    }

    // Keep the direction, representation, and export controls visible by default.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    // Build native segmented and pull-down toolbar items.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case ToolbarItem.direction:
            item.label = "Direction"
            item.paletteLabel = "Direction"
            item.view = directionControl
        case ToolbarItem.representation:
            item.label = "Format"
            item.paletteLabel = "Format"
            item.view = representationControl
        case ToolbarItem.save:
            item.label = "Save"
            item.paletteLabel = "Save"
            item.view = saveMenuButton
        default:
            return nil
        }
        return item
    }

    private func configureToolbar() {
        directionControl.selectedSegment = TCPFollowDirectionFilter.both.rawValue
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))
        directionControl.setAccessibilityLabel("Stream direction")

        representationControl.selectedSegment = TCPFollowRepresentation.text.rawValue
        representationControl.target = self
        representationControl.action = #selector(representationChanged(_:))
        representationControl.setAccessibilityLabel("Payload representation")

        saveMenuButton.addItem(withTitle: "Save…")
        saveMenuButton.menu?.addItem(withTitle: "Save Transcript…", action: #selector(saveTranscript(_:)), keyEquivalent: "")
        saveMenuButton.menu?.addItem(.separator())
        saveMenuButton.menu?.addItem(withTitle: "Export Client Bytes…", action: #selector(exportClientBytes(_:)), keyEquivalent: "")
        saveMenuButton.menu?.addItem(withTitle: "Export Server Bytes…", action: #selector(exportServerBytes(_:)), keyEquivalent: "")
        saveMenuButton.menu?.items.forEach { $0.target = self }
        saveMenuButton.setAccessibilityLabel("Save stream")
        saveMenuButton.isEnabled = false

        let toolbar = NSToolbar(identifier: "TCPFollowStream.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbarStyle = .unified
        window?.toolbar = toolbar
    }

    @objc private func directionChanged(_ sender: NSSegmentedControl) {
        guard let filter = TCPFollowDirectionFilter(rawValue: sender.selectedSegment) else {
            return
        }
        streamViewController.setDirectionFilter(filter)
    }

    @objc private func representationChanged(_ sender: NSSegmentedControl) {
        guard let representation = TCPFollowRepresentation(rawValue: sender.selectedSegment) else {
            return
        }
        streamViewController.setRepresentation(representation)
    }

    @objc private func saveTranscript(_ sender: Any?) {
        let data = Data(streamViewController.renderedContent.plainText.utf8)
        presentSavePanel(suggestedName: "tcp-stream.txt", contentType: .plainText, data: data)
    }

    @objc private func exportClientBytes(_ sender: Any?) {
        presentRawSavePanel(
            suggestedName: "tcp-stream-client.bin",
            contentType: .data,
            direction: .clientToServer
        )
    }

    @objc private func exportServerBytes(_ sender: Any?) {
        presentRawSavePanel(
            suggestedName: "tcp-stream-server.bin",
            contentType: .data,
            direction: .serverToClient
        )
    }

    // Build and write a potentially large raw side of the stream away from the main queue.
    private func presentRawSavePanel(suggestedName: String, contentType: UTType, direction: TCPFollowDirection) {
        guard let window, let stream = streamViewController.stream else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            self.exportQueue.async { [weak self] in
                do {
                    let data = TCPFollowStreamViewModel.rawData(in: stream, for: direction)
                    try data.write(to: url, options: .atomic)
                } catch {
                    DispatchQueue.main.async {
                        self?.presentSaveError(error)
                    }
                }
            }
        }
    }

    // Save only after explicit user confirmation and surface filesystem errors as a sheet.
    private func presentSavePanel(suggestedName: String, contentType: UTType, data: Data) {
        guard let window else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self?.presentSaveError(error)
            }
        }
    }

    private func presentSaveError(_ error: Error) {
        guard let window else {
            return
        }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
