//
//  TLSDecryptionMenu.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit

extension AppDelegate {
    // Tools › TLS Decryption… opens its Settings pane; Add TLS Key Log File… goes straight to the file picker.
    func wireTLSDecryptionMenu() {
        guard let toolsMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Tools" })?.submenu,
              !toolsMenu.items.contains(where: { $0.action == #selector(showTLSDecryptionSettings(_:)) }) else { return }
        toolsMenu.addItem(.separator())
        let settings = NSMenuItem(title: "TLS Decryption…", action: #selector(showTLSDecryptionSettings(_:)), keyEquivalent: "k")
        settings.keyEquivalentModifierMask = [.command, .shift]
        settings.target = self
        toolsMenu.addItem(settings)
        let add = NSMenuItem(title: "Add TLS Key Log File…", action: #selector(addTLSKeyLogFile(_:)), keyEquivalent: "")
        add.target = self
        toolsMenu.addItem(add)
    }

    @IBAction func addTLSKeyLogFile(_ sender: Any?) {
        TLSKeyLogFilePicker.chooseAndUseFile(for: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    @IBAction func decryptOpenCapturesAgain(_ sender: Any?) {
        TLSDecryptionStore.shared.decryptOpenCapturesAgain()
    }
}
