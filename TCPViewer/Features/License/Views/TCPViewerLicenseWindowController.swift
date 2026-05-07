//
//  TCPViewerLicenseWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import AppKit
import SwiftUI

final class TCPViewerLicenseWindowController: NSWindowController {
    let presentationMode: TCPViewerLicensePresentationMode

    init(
        licenseService: TCPViewerLicenseService = .shared,
        presentationMode: TCPViewerLicensePresentationMode = .license,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.presentationMode = presentationMode
        let contentView = TCPViewerLicenseView(
            licenseService: licenseService,
            presentationMode: presentationMode,
            onDismiss: onDismiss
        )
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .fullSizeContentView]
        window.setContentSize(NSSize(width: 980, height: 780))
        window.contentMinSize = NSSize(width: 900, height: 720)
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
