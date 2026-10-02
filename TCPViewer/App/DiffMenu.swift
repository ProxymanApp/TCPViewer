//
//  DiffMenu.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import AppKit
import PcapPlusPlusCore

extension AppDelegate {
    func wireDiffMenu() {
        guard let mainMenu = NSApp.mainMenu, !mainMenu.items.contains(where: { $0.title == "Diff" }) else { return }
        let parent = NSMenuItem(title: "Diff", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Diff")
        menu.delegate = self
        menu.autoenablesItems = false
        parent.submenu = menu
        let open = NSMenuItem(title: "Open Diff View…", action: #selector(openDiffView(_:)), keyEquivalent: "y")
        open.keyEquivalentModifierMask = [.option, .command]
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add selected items to Diff Pool…", action: #selector(TCPViewerWindowController.addSelectedPacketsToDiff(_:)), keyEquivalent: "y")
        menu.addItem(add)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Left Side", action: #selector(DiffWindowController.selectDiffLeft(_:)), keyEquivalent: "["))
        menu.addItem(NSMenuItem(title: "Right Side", action: #selector(DiffWindowController.selectDiffRight(_:)), keyEquivalent: "]"))
        let index = mainMenu.items.firstIndex(where: { $0.title == "Window" }) ?? mainMenu.items.count
        mainMenu.insertItem(parent, at: index)
    }

    // Menu targets follow the key window; a Diff shortcut must never navigate an inactive capture.
    func updateDiffMenu(_ menu: NSMenu, window: NSWindow?) {
        guard menu.title == "Diff" else { return }
        for item in menu.items {
            if item.action == #selector(TCPViewerWindowController.addSelectedPacketsToDiff(_:)) {
                let controller = window?.windowController as? TCPViewerWindowController
                item.target = controller
                item.isEnabled = controller?.validateMenuItem(item) ?? false
            } else if item.action == #selector(DiffWindowController.selectDiffLeft(_:)) || item.action == #selector(DiffWindowController.selectDiffRight(_:)) {
                let controller = window?.windowController as? DiffWindowController
                item.target = controller
                item.isEnabled = controller?.validateMenuItem(item) ?? false
                if controller == nil { item.state = .off }
            }
        }
    }
}
