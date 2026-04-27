import Foundation
import PcapPlusPlusCore

struct PacketDetailCopyRow: Equatable {
    let depth: Int
    let name: String
    let value: String?

    init(depth: Int, name: String, value: String?) {
        self.depth = depth
        self.name = name
        self.value = value
    }

    init(node: PacketDetailNode, depth: Int) {
        self.init(depth: depth, name: node.name, value: node.value)
    }
}

enum PacketDetailCopyFormatter {
    static func text(for rows: [PacketDetailCopyRow]) -> String {
        rows.map { row in
            let indentation = String(repeating: "    ", count: max(row.depth, 0))
            guard let value = row.value, !value.isEmpty else {
                return "\(indentation)\(row.name)"
            }
            return "\(indentation)\(row.name): \(value)"
        }
        .joined(separator: "\n")
    }
}
