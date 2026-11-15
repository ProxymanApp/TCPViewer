//
//  DiffMonacoEditorViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit

// The Diff window's side-by-side or unified comparison of two packets' details.
final class DiffMonacoEditorViewController: MonacoPageViewController {
    override class var page: MonacoPage { .diff }

    // Retain only the latest requested comparison while the page or a previous render is loading.
    func render(left: String, right: String, mode: DiffDisplayMode) {
        send(content: ["left": left, "right": right, "sideBySide": mode == .sideBySide])
    }

    // Keep F7 navigation available even while focus is in the native packet pool.
    func navigateDifference(backwards: Bool) {
        callBridge("navigate(backwards)", arguments: ["backwards": backwards])
    }
}
