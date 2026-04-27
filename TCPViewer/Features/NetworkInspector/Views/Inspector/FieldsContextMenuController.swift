import AppKit
import PcapPlusPlusCore

protocol FieldsContextMenuControllerDelegate: AnyObject {
    func fieldsContextMenuRequestsRevealInRaw(forNodeID nodeID: String)
}

final class FieldsContextMenuController: NSObject, NSMenuDelegate {
    weak var delegate: FieldsContextMenuControllerDelegate?
    var rootNodes: [PacketDetailNode] = []

    /// (item, node, allRoots) -> handler builds the item; return nil to skip a separator before it.
    func makeMenu(for node: PacketDetailNode?) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        guard let node else {
            menu.addItem(disabledItem(title: "No selection"))
            return menu
        }

        menu.addItem(item(title: "Copy Value", action: #selector(copyValue(_:)), node: node, enabled: !(node.value ?? "").isEmpty))
        menu.addItem(item(title: "Copy Field Name", action: #selector(copyFieldName(_:)), node: node))
        menu.addItem(item(title: "Copy Field Path", action: #selector(copyFieldPath(_:)), node: node))
        menu.addItem(item(title: "Copy Indented Tree", action: #selector(copyTree(_:)), node: node))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item(title: "Reveal in Raw Bytes", action: #selector(revealInRaw(_:)), node: node, enabled: node.byteRange != nil))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(disabledItem(title: "Copy as Filter", tooltip: "Coming soon"))
        menu.addItem(disabledItem(title: "Follow Stream", tooltip: "Coming soon"))
        menu.addItem(disabledItem(title: "Add as Column", tooltip: "Coming soon"))
        return menu
    }

    private func item(title: String, action: Selector, node: PacketDetailNode, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = node.id
        item.isEnabled = enabled
        return item
    }

    private func disabledItem(title: String, tooltip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = tooltip
        return item
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let node = node(forID: id) else { return }
        copy(text: node.value ?? "")
    }

    @objc private func copyFieldName(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let node = node(forID: id) else { return }
        copy(text: node.name)
    }

    @objc private func copyFieldPath(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        copy(text: id)
    }

    @objc private func copyTree(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let node = node(forID: id) else { return }
        var rows: [PacketDetailCopyRow] = []
        flatten(node, depth: 0, into: &rows)
        copy(text: PacketDetailCopyFormatter.text(for: rows))
    }

    @objc private func revealInRaw(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.fieldsContextMenuRequestsRevealInRaw(forNodeID: id)
    }

    private func node(forID id: String) -> PacketDetailNode? {
        for root in rootNodes {
            if let found = find(in: root, id: id) {
                return found
            }
        }
        return nil
    }

    private func find(in node: PacketDetailNode, id: String) -> PacketDetailNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(in: child, id: id) {
                return found
            }
        }
        return nil
    }

    private func flatten(_ node: PacketDetailNode, depth: Int, into rows: inout [PacketDetailCopyRow]) {
        rows.append(PacketDetailCopyRow(node: node, depth: depth))
        for child in node.children {
            flatten(child, depth: depth + 1, into: &rows)
        }
    }

    private func copy(text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
