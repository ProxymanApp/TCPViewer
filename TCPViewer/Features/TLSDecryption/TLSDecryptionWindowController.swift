//
//  TLSDecryptionWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import AppKit

final class TLSDecryptionWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "TCPViewer.TLSDecryptionWindow"

    var closeHandler: (() -> Void)?
    let viewController = TLSDecryptionViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TLS Decryption"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 480, height: 380))
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func render(snapshot: TLSDecryptionSnapshot) {
        viewController.render(snapshot: snapshot)
    }

    func windowWillClose(_ notification: Notification) {
        closeHandler?()
    }
}
