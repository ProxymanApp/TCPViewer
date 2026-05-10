//
//  TCPViewerAboutWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/5/26.
//

import AppKit
import SwiftUI

final class TCPViewerAboutWindowController: NSWindowController {
    init(info: TCPViewerAboutInfo = .current) {
        let hostingController = NSHostingController(rootView: TCPViewerAboutView(info: info))
        let window = NSWindow(contentViewController: hostingController)
        let contentSize = TCPViewerAboutView.preferredWindowContentSize
        window.title = info.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.toolbar = nil
        window.setContentSize(contentSize)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.closeButton)?.isEnabled = true

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
