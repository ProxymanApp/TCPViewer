//
//  PacketClientIconCache.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/4/26.
//

import AppKit
import PcapPlusPlusCore

final class PacketClientIconCache {
    private var imagesByKey: [String: NSImage] = [:]

    // Return one shared icon instance per app path so repeated packet rows stay cheap.
    func image(for client: PacketClient?) -> NSImage? {
        image(forPath: PacketClientIconPathResolver.iconFilePath(for: client))
    }

    func image(forPath path: String?) -> NSImage? {
        guard let path = Self.normalizedIconPath(path) else {
            return nil
        }

        if let image = imagesByKey[path] {
            return image
        }

        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        imagesByKey[path] = image
        return image
    }

    static func normalizedIconPath(_ path: String?) -> String? {
        guard let path else {
            return nil
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }

        return String(decoding: trimmed.utf8, as: UTF8.self)
    }
}
