//
//  TLSKeyLogFilePicker.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit

// Choosing and adding a key log from anywhere in the app: Settings, the inspector, the menu or a drop.
enum TLSKeyLogFilePicker {
    static let proxymanGuideURL = URL(string: "https://proxyman.com/docs/advanced-features/tls-key-logging")

    // Show an open panel; key logs are plain text with any extension (.txt, .log, .keys or none).
    static func chooseFile(for window: NSWindow?, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose a TLS Key Log File"
        panel.message = "Choose the key log file that Proxyman, your browser or curl writes (SSLKEYLOGFILE)."
        panel.prompt = "Use Key Log"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        if let currentURL = TLSDecryptionStore.shared.keyLogFileURL {
            panel.directoryURL = currentURL.deletingLastPathComponent()
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // Choose a file and use it, explaining in an alert when the file is not a key log.
    static func chooseAndUseFile(for window: NSWindow?, store: TLSDecryptionStore = .shared) {
        chooseFile(for: window) { url in
            use(url, for: window, store: store)
        }
    }

    static func use(_ url: URL, for window: NSWindow?, store: TLSDecryptionStore = .shared) {
        store.useKeyLogFile(at: url) { result in
            guard case .failure(let error) = result else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "TCP Viewer Can't Use This File"
            alert.informativeText = error.localizedDescription
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    static func openProxymanGuide() {
        guard let proxymanGuideURL else { return }
        NSWorkspace.shared.open(proxymanGuideURL)
    }
}
