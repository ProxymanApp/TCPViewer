//
//  TCPViewerAppRelauncher.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/11/26.
//

import Foundation

// Reopens TCP Viewer after this process exits, so macOS starts a fresh process with refreshed group membership.
enum TCPViewerAppRelauncher {
    // LaunchServices only re-activates a running app, so the waiter polls until the PID is gone (max ~30 s) before reopening.
    static let waitScript = """
    i=0
    while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 300 ]; do /bin/sleep 0.1; i=$((i + 1)); done
    /usr/bin/open "$2"
    """

    // The PID and bundle path are positional arguments, so the path is never parsed as shell code.
    static func makeWaiterProcess(processIdentifier: Int32, bundleURL: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", waitScript, "tcpviewer-relaunch", String(processIdentifier), bundleURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    // Spawns the detached waiter for the current process; it outlives TCP Viewer and reopens the bundle once it quits.
    @discardableResult
    static func relaunchAfterCurrentProcessExits(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let process = makeWaiterProcess(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleURL: bundleURL
        )
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
