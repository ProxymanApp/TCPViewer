//
//  PacketClientIconPathResolver.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/4/26.
//

import Foundation
import PcapPlusPlusCore

enum PacketClientIconPathResolver {
    // Choose a display-only app icon path without changing the captured process identity.
    static func iconFilePath(for client: PacketClient?) -> String? {
        guard let client else {
            return nil
        }

        return iconFilePath(bundlePath: client.bundlePath, executablePath: client.executablePath)
    }

    // Prefer the outer app bundle for nested helper processes, then fall back to known paths.
    static func iconFilePath(bundlePath: String?, executablePath: String?) -> String? {
        let trimmedBundlePath = trimmed(bundlePath)
        let trimmedExecutablePath = trimmed(executablePath)

        if let executableAppPath = outermostAppBundlePath(in: trimmedExecutablePath) {
            return executableAppPath
        }

        if let bundleAppPath = outermostAppBundlePath(in: trimmedBundlePath) {
            return bundleAppPath
        }

        return trimmedBundlePath ?? trimmedExecutablePath
    }

    private static func outermostAppBundlePath(in path: String?) -> String? {
        guard let path else {
            return nil
        }

        let components = (path as NSString).pathComponents
        guard let appIndex = components.firstIndex(where: { component in
            (component as NSString).pathExtension.lowercased() == "app"
        }) else {
            return nil
        }

        return NSString.path(withComponents: Array(components[...appIndex]))
    }

    private static func trimmed(_ path: String?) -> String? {
        guard let value = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }
}
