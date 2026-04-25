import AppKit
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

struct PacketExportDestination {
    let url: URL
    let format: CaptureFileFormat
}

final class PacketExportService {
    private enum Key {
        static let lastDirectoryPath = "TCPViewer.packetExport.lastDirectoryPath"
    }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    // Build a stable default name with a timestamp suffix for every export action.
    func defaultFileName(scopeName: String, format: CaptureFileFormat) -> String {
        "\(sanitizedScopeName(scopeName))-\(Self.timestampFormatter.string(from: now())).\(format.rawValue)"
    }

    func lastDirectoryURL() -> URL? {
        guard let path = defaults.string(forKey: Key.lastDirectoryPath),
              !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func rememberDestination(_ url: URL) {
        defaults.set(url.deletingLastPathComponent().path, forKey: Key.lastDirectoryPath)
    }

    func chooseDestination(scopeName: String, format: CaptureFileFormat) -> PacketExportDestination? {
        let panel = NSSavePanel()
        panel.title = "Export Packets"
        panel.nameFieldStringValue = defaultFileName(scopeName: scopeName, format: format)
        panel.directoryURL = lastDirectoryURL()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue)].compactMap { $0 }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return PacketExportDestination(url: url, format: format)
    }

    func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export Failed"
        if let tcpviewerError = error as? TCPViewerCoreError {
            alert.informativeText = tcpviewerError.message
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func sanitizedScopeName(_ scopeName: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = scopeName.unicodeScalars.map { scalar -> String in
            allowedCharacters.contains(scalar) ? String(scalar) : "-"
        }
        let sanitized = scalars.joined()
            .split(separator: "-")
            .joined(separator: "-")
        return sanitized.isEmpty ? "TCPViewer-Session" : sanitized
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
