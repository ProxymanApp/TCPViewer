//
//  TLSDecryptionMenu.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import AppKit

extension AppDelegate {
    func wireTLSDecryptionMenu() {
        guard let toolsMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Tools" })?.submenu,
              !toolsMenu.items.contains(where: { $0.action == #selector(showTLSDecryption(_:)) }) else { return }
        let item = NSMenuItem(title: "TLS Decryption…", action: #selector(showTLSDecryption(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.shift, .command]
        item.target = self
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item)
    }

    // Load the persisted key logs and keep loaded captures in step with later key changes.
    func startTLSDecryption() {
        // Unit tests are hosted in this app; a developer's own key logs must not leak into them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        tlsDecryptionStore.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveCaptureDidStop(_:)),
            name: TCPViewerWorkspaceController.liveCaptureDidStopNotification,
            object: nil
        )
        tlsDecryptionStore.reload()
    }

    // Report in-place re-dissections of this window's captures in the TLS Decryption window.
    func observeRedissection(in controller: TCPViewerWindowController) {
        controller.redissectionHandler = { [weak self] captureTitle, result in
            self?.tlsDecryptionStore.reportRedissection(captureTitle: captureTitle, result: result)
        }
    }

    @IBAction func showTLSDecryption(_ sender: Any?) {
        if tlsDecryptionWindowController == nil {
            let controller = TLSDecryptionWindowController()
            controller.viewController.delegate = self
            controller.closeHandler = { [weak self] in self?.tlsDecryptionWindowController = nil }
            tlsDecryptionWindowController = controller
        }
        tlsDecryptionWindowController?.render(snapshot: tlsDecryptionStore.snapshot)
        tlsDecryptionWindowController?.present()
        // Session counts are not updated on every appended line, so refresh them when the user looks.
        tlsDecryptionStore.reload()
    }

    // Keys often reach the log a moment after their handshake was captured, so read the files again
    // and let the stopped capture pick them up.
    @objc private func liveCaptureDidStop(_ notification: Notification) {
        tlsDecryptionStore.reload { [weak self] in
            self?.mainWindowController?.redissectSelectedWorkspaceIfStale()
        }
    }
}

extension AppDelegate: TLSDecryptionStoreDelegate {
    func tlsDecryptionStoreDidChange(_ store: TLSDecryptionStore) {
        tlsDecryptionWindowController?.render(snapshot: store.snapshot)
    }

    func tlsDecryptionStoreDidApplyKeyLog(_ store: TLSDecryptionStore) {
        mainWindowController?.dissectionInputsDidChange()
    }
}

extension AppDelegate: TLSDecryptionViewControllerDelegate {
    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didSetDecryptionEnabled isEnabled: Bool) {
        tlsDecryptionStore.setEnabled(isEnabled)
    }

    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didAddFilesAt urls: [URL]) {
        tlsDecryptionStore.addFiles(at: urls)
    }

    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didRemoveFilesWithIDs ids: Set<String>) {
        tlsDecryptionStore.removeFiles(withIDs: ids)
    }

    func tlsDecryptionViewController(_ controller: TLSDecryptionViewController, didSetFileWithID id: String, enabled isEnabled: Bool) {
        tlsDecryptionStore.setFile(withID: id, enabled: isEnabled)
    }
}
