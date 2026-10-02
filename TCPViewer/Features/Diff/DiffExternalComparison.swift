//
//  DiffExternalComparison.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/10/26.
//

import Foundation

final class DiffExternalComparison {
    enum App { case fileMerge, kaleidoscope }
    private let queue = DispatchQueue(label: "com.proxyman.tcpviewer.diff-external")
    private var directories: [URL] = []
    private var processes: [UUID: Process] = [:]

    // Pass paths as separate arguments so packet content and filenames never become shell code.
    static func arguments(left: URL, right: URL) -> [String] { [left.path, right.path] }

    func open(app: App, left: String, right: String, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            var directory: URL?
            do {
                let candidates = app == .fileMerge ? ["/usr/bin/opendiff"] : ["/opt/homebrew/bin/ksdiff", "/usr/local/bin/ksdiff"]
                guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                    throw NSError(domain: "TCPViewer.Diff", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        app == .fileMerge ? "Install Xcode to use FileMerge." : "Install Kaleidoscope and its ksdiff command-line tool."])
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TCPViewer-Diff-\(UUID().uuidString)", isDirectory: true)
                directory = folder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let leftURL = folder.appendingPathComponent("left.txt")
                let rightURL = folder.appendingPathComponent("right.txt")
                try Data(left.utf8).write(to: leftURL, options: .atomic)
                try Data(right.utf8).write(to: rightURL, options: .atomic)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Self.arguments(left: leftURL, right: rightURL)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let processID = UUID()
                process.terminationHandler = { [weak self] finished in
                    guard let self else { return }
                    self.queue.async {
                        self.processes.removeValue(forKey: processID)
                        let error: Error? = finished.terminationStatus == 0 ? nil : NSError(
                            domain: "TCPViewer.Diff", code: Int(finished.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "The comparison command failed. Check that the external application is installed."])
                        if error != nil {
                            try? FileManager.default.removeItem(at: folder)
                            self.directories.removeAll { $0 == folder }
                        }
                        DispatchQueue.main.async { completion(error) }
                    }
                }
                try process.run()
                processes[processID] = process
                directories.append(folder)
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    // Successful comparisons keep their files for external readers until TCPViewer terminates.
    func cleanUp() {
        queue.sync {
            directories.forEach { try? FileManager.default.removeItem(at: $0) }
            directories.removeAll()
        }
    }
}
