//
//  TCPViewerWorkspaceTabContentController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import AppKit

/// A tab owns its pane here so a future split can add a second pane without changing window routing.
final class TCPViewerWorkspaceTabContentController: NSViewController {
    private(set) var focusedPane: TCPViewerRootViewController?

    init(pane: TCPViewerRootViewController) {
        focusedPane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(pane:)") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        guard let pane = focusedPane else { return }
        addChild(pane)
        pane.view.frame = view.bounds
        pane.view.autoresizingMask = [.width, .height]
        view.addSubview(pane.view)
    }

    // Detach before releasing the pane so AppKit cannot keep it in the responder chain.
    func close() {
        focusedPane?.close()
        focusedPane = nil
        if isViewLoaded { view.removeFromSuperview() }
        removeFromParent()
    }
}
