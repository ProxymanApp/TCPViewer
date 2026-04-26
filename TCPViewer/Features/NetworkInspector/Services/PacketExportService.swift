import AppKit
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

struct PacketExportDestination {
    let url: URL
    let format: CaptureFileFormat
}

final class PacketExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        return cancelled
    }
}

final class PacketExportProgressSheetController: NSViewController {
    private let fileName: String
    private let cancelHandler: () -> Void
    private let titleLabel = NSTextField(labelWithString: "Exporting Packets")
    private let detailLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let progressIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var sheetWindow: NSWindow?

    init(fileName: String, cancelHandler: @escaping () -> Void) {
        self.fileName = fileName
        self.cancelHandler = cancelHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        detailLabel.stringValue = "Preparing \(fileName)..."
        detailLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .regular

        cancelButton.target = self
        cancelButton.action = #selector(cancelExport(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let progressRow = NSStackView(views: [progressIndicator, percentLabel])
        progressRow.orientation = .horizontal
        progressRow.spacing = 12
        progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        percentLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let buttonRow = NSStackView(views: [cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .trailing
        buttonRow.distribution = .gravityAreas

        let stackView = NSStackView(views: [titleLabel, detailLabel, progressRow, buttonRow])
        stackView.orientation = .vertical
        stackView.spacing = 14
        stackView.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        view = stackView
    }

    func show(attachedTo parentWindow: NSWindow?) {
        let window = NSWindow(contentViewController: self)
        window.styleMask = [.titled]
        window.title = "Export"
        window.isReleasedWhenClosed = false
        sheetWindow = window

        if let parentWindow {
            parentWindow.beginSheet(window)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func update(_ progress: PacketExportProgress) {
        progressIndicator.doubleValue = progress.fractionCompleted
        let percent = Int((progress.fractionCompleted * 100).rounded())
        percentLabel.stringValue = "\(percent)%"
        detailLabel.stringValue = "Exported \(progress.exportedPacketCount) of \(progress.totalPacketCount) packets to \(fileName)."
    }

    func dismiss() {
        guard let sheetWindow else {
            return
        }

        if let parentWindow = sheetWindow.sheetParent {
            parentWindow.endSheet(sheetWindow)
        } else {
            sheetWindow.close()
        }
        self.sheetWindow = nil
    }

    @objc private func cancelExport(_ sender: Any?) {
        cancelButton.isEnabled = false
        detailLabel.stringValue = "Cancelling export..."
        cancelHandler()
    }
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

    func showProgressSheet(attachedTo window: NSWindow?, fileName: String, cancelHandler: @escaping () -> Void) -> PacketExportProgressSheetController {
        let controller = PacketExportProgressSheetController(fileName: fileName, cancelHandler: cancelHandler)
        controller.show(attachedTo: window)
        return controller
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
