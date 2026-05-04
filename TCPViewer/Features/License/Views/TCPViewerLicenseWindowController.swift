//
//  TCPViewerLicenseWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import AppKit
import SwiftUI

final class TCPViewerLicenseWindowController: NSWindowController {
    init(licenseService: TCPViewerLicenseService = .shared) {
        let contentView = TCPViewerLicenseView(licenseService: licenseService)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TCP Viewer License"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 900, height: 660))
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
