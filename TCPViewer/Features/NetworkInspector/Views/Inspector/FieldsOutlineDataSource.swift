import AppKit
import PcapPlusPlusCore

final class FieldsOutlineItem: NSObject {
    let node: PacketDetailNode
    let depth: Int
    fileprivate(set) var children: [FieldsOutlineItem]

    init(node: PacketDetailNode, depth: Int, children: [FieldsOutlineItem]) {
        self.node = node
        self.depth = depth
        self.children = children
    }
}

enum FieldsOutlineTreeBuilder {
    static func build(nodes: [PacketDetailNode], filter: String) -> ([FieldsOutlineItem], [String: FieldsOutlineItem]) {
        var lookup: [String: FieldsOutlineItem] = [:]
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let items = nodes.compactMap { build(node: $0, depth: 0, filter: trimmed, into: &lookup) }
        return (items, lookup)
    }

    private static func build(
        node: PacketDetailNode,
        depth: Int,
        filter: String,
        into lookup: inout [String: FieldsOutlineItem]
    ) -> FieldsOutlineItem? {
        let childItems = node.children.compactMap { build(node: $0, depth: depth + 1, filter: filter, into: &lookup) }
        let selfMatches = filter.isEmpty || matches(node, filter: filter)
        guard selfMatches || !childItems.isEmpty else {
            return nil
        }

        let item = FieldsOutlineItem(node: node, depth: depth, children: childItems)
        lookup[node.id] = item
        return item
    }

    private static func matches(_ node: PacketDetailNode, filter: String) -> Bool {
        if node.name.lowercased().contains(filter) {
            return true
        }
        if let value = node.value?.lowercased(), value.contains(filter) {
            return true
        }
        return false
    }
}

protocol FieldsOutlineCopyHandling: AnyObject {
    func copySelectedRows()
    func copySelectedTree()
}

final class FieldsOutlineTableView: NSOutlineView {
    weak var copyHandler: FieldsOutlineCopyHandling?

    @objc func copy(_ sender: Any?) {
        copyHandler?.copySelectedRows()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == [.command], key == "c" {
            copyHandler?.copySelectedRows()
            return
        }
        if mods == [.command, .option], key == "c" {
            copyHandler?.copySelectedTree()
            return
        }
        super.keyDown(with: event)
    }
}
