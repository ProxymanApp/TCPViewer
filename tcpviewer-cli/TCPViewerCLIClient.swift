//
//  TCPViewerCLIClient.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import AppKit
import Foundation

protocol TCPViewerCLIRequestRunning {
    func run(
        command: TCPViewerCLICommand,
        params: [String: TCPViewerCLIValue],
        timeout: TimeInterval,
        launchIfNeeded: Bool
    ) throws -> TCPViewerCLIResponse
}

enum TCPViewerCLIClientError: Error, LocalizedError {
    case appNotFound
    case launchFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .appNotFound:
            return "TCP Viewer.app could not be found."
        case .launchFailed(let message):
            return "TCP Viewer could not be launched: \(message)"
        case .timeout:
            return "TCP Viewer did not respond before the timeout."
        }
    }
}

struct TCPViewerCLIRequestFailure: Error, LocalizedError {
    let requestID: String
    let code: String
    let message: String

    var errorDescription: String? { message }
}

protocol TCPViewerCLIAppLaunching {
    var isRunning: Bool { get }
    func launchQuietly(completion: @escaping (Result<Void, Error>) -> Void) throws
}

final class TCPViewerCLIClient: TCPViewerCLIRequestRunning {
    private let fileStore: TCPViewerCLIFileStore
    private let notifications: any TCPViewerCLINotificationCentering
    private let appLauncher: any TCPViewerCLIAppLaunching

    init(
        fileStore: TCPViewerCLIFileStore = TCPViewerCLIFileStore(),
        notifications: any TCPViewerCLINotificationCentering = TCPViewerCLIDarwinNotificationCenter.shared,
        appLauncher: any TCPViewerCLIAppLaunching = TCPViewerCLIWorkspaceLauncher()
    ) {
        self.fileStore = fileStore
        self.notifications = notifications
        self.appLauncher = appLauncher
    }

    func run(
        command: TCPViewerCLICommand,
        params: [String: TCPViewerCLIValue],
        timeout: TimeInterval,
        launchIfNeeded: Bool
    ) throws -> TCPViewerCLIResponse {
        let appWasRunning = appLauncher.isRunning
        if command == .appStatus && !appWasRunning {
            return .success(
                requestID: UUID().uuidString.lowercased(),
                command: command,
                data: [
                    "running": .bool(false),
                    "app": .string("TCP Viewer"),
                    "version": .string(TCPViewerCLIVersion.version),
                    "build": .string(TCPViewerCLIVersion.build),
                    "cli_version": .string(TCPViewerCLIVersion.version),
                    "cli_build": .string(TCPViewerCLIVersion.build),
                    "license_state": .string("unavailable_while_closed"),
                    "active_document": .null,
                    "capture_phase": .string("unavailable"),
                    "packet_count": .int(0),
                ]
            )
        }
        guard appWasRunning || launchIfNeeded else {
            throw TCPViewerCLIClientError.timeout
        }

        fileStore.cleanupOrphans()
        let request = TCPViewerCLIRequest(
            command: command,
            params: params,
            expiresAt: Date().addingTimeInterval(timeout)
        )
        let responseSignal = DispatchSemaphore(value: 0)
        let observer = notifications.observe(TCPViewerCLINotificationName.response) {
            responseSignal.signal()
        }
        defer { withExtendedLifetime(observer) {} }
        do {
            try fileStore.writeRequest(request)
        } catch {
            throw TCPViewerCLIRequestFailure(
                requestID: request.requestID,
                code: "transport_error",
                message: error.localizedDescription
            )
        }

        let launchError = LockedError()
        if appWasRunning {
            notifications.post(TCPViewerCLINotificationName.request)
        } else {
            do {
                try appLauncher.launchQuietly { result in
                    if case .failure(let error) = result {
                        launchError.set(error)
                        responseSignal.signal()
                    }
                }
            } catch {
                fileStore.removeRequest(requestID: request.requestID)
                throw TCPViewerCLIRequestFailure(
                    requestID: request.requestID,
                    code: error is TCPViewerCLIClientError ? TCPViewerCLIErrorCode.code(for: error) : "launch_failed",
                    message: error.localizedDescription
                )
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try? fileStore.readResponse(requestID: request.requestID) {
                fileStore.removeResponse(requestID: request.requestID)
                return response
            }
            if let error = launchError.value() {
                fileStore.removeRequest(requestID: request.requestID)
                throw TCPViewerCLIRequestFailure(
                    requestID: request.requestID,
                    code: "launch_failed",
                    message: TCPViewerCLIClientError.launchFailed(error.localizedDescription).localizedDescription
                )
            }
            let remaining = max(deadline.timeIntervalSinceNow, 0)
            _ = responseSignal.wait(timeout: .now() + min(remaining, 0.1))
        }

        fileStore.removeRequest(requestID: request.requestID)
        throw TCPViewerCLIRequestFailure(
            requestID: request.requestID,
            code: "timeout",
            message: TCPViewerCLIClientError.timeout.localizedDescription
        )
    }
}

private final class LockedError {
    private let lock = NSLock()
    private var storedError: Error?

    func set(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func value() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

final class TCPViewerCLIWorkspaceLauncher: TCPViewerCLIAppLaunching {
    private static let bundleIdentifier = "com.proxyman.tcpviewer"

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    func launchQuietly(completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard let appURL = installedApplicationURL() else {
            throw TCPViewerCLIClientError.appNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    private func installedApplicationURL() -> URL? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if candidate.pathExtension == "app",
           Bundle(url: candidate)?.bundleIdentifier == Self.bundleIdentifier {
            return candidate
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }
}
