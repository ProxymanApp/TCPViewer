import AppKit
import PcapPlusPlusCore

final class PacketClientIconCache {
    private var imagesByKey: [String: NSImage] = [:]

    // Return one shared icon instance per app path so repeated packet rows stay cheap.
    func image(for client: PacketClient?) -> NSImage? {
        guard let path = PacketClientIconPathResolver.iconFilePath(for: client) else {
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
}
