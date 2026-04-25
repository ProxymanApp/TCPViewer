import Darwin
import Foundation
import SystemConfiguration

enum TCPViewerNetworkHelperConstants {
    static let displayName = "TCP Viewer Network Helper Tool"
    static let serviceLabel = "com.proxyman.tcpviewer.helpertool"
    static let launchDaemonPlistName = "\(serviceLabel).plist"
    static let captureGroupName = "tcpviewer_capture"
    static let captureGroupFullName = "TCP Viewer Capture Access"
    static let bpfDeviceDirectory = "/dev"
    static let bpfDeviceMode: mode_t = 0o660
}

enum TCPViewerNetworkHelperExitCode: Int32, Sendable, Equatable {
    case success = 0
    case noConsoleUser = 64
    case notAdmin = 65
    case groupFailure = 66
    case bpfPermissionFailure = 67
}

struct TCPViewerNetworkHelperRunResult: Sendable, Equatable {
    let exitCode: TCPViewerNetworkHelperExitCode
    let message: String
}

protocol TCPViewerNetworkHelperSystem {
    func captureGroupExists() throws -> Bool
    func createCaptureGroup() throws
    func currentConsoleUser() -> String?
    func userIsAdmin(_ username: String) throws -> Bool
    func addUserToCaptureGroup(_ username: String) throws
    func bpfDevicePaths() throws -> [String]
    func applyCapturePermissions(toDeviceAt path: String) throws
}

struct TCPViewerNetworkHelperCore {
    let system: any TCPViewerNetworkHelperSystem

    init(system: any TCPViewerNetworkHelperSystem) {
        self.system = system
    }

    // Prepare the capture group, enrolling the active admin user when available.
    func run() -> TCPViewerNetworkHelperRunResult {
        do {
            let groupAlreadyExists = try system.captureGroupExists()
            if !groupAlreadyExists {
                try system.createCaptureGroup()
            }

            if let username = system.currentConsoleUser() {
                guard try system.userIsAdmin(username) else {
                    return TCPViewerNetworkHelperRunResult(
                        exitCode: .notAdmin,
                        message: "\(username) is not an admin user."
                    )
                }

                try system.addUserToCaptureGroup(username)
            } else if !groupAlreadyExists {
                return TCPViewerNetworkHelperRunResult(
                    exitCode: .noConsoleUser,
                    message: "No active console user was available to enroll for capture access."
                )
            }

            let bpfDevicePaths = try system.bpfDevicePaths()
            guard !bpfDevicePaths.isEmpty else {
                return TCPViewerNetworkHelperRunResult(
                    exitCode: .bpfPermissionFailure,
                    message: "No /dev/bpf* devices were found."
                )
            }

            for path in bpfDevicePaths {
                try system.applyCapturePermissions(toDeviceAt: path)
            }

            return TCPViewerNetworkHelperRunResult(
                exitCode: .success,
                message: "Prepared \(bpfDevicePaths.count) capture devices."
            )
        } catch let error as TCPViewerNetworkHelperSystemError {
            return TCPViewerNetworkHelperRunResult(exitCode: error.exitCode, message: error.message)
        } catch {
            return TCPViewerNetworkHelperRunResult(
                exitCode: .bpfPermissionFailure,
                message: error.localizedDescription
            )
        }
    }
}

struct TCPViewerNetworkHelperSystemError: Error, Sendable, Equatable {
    let exitCode: TCPViewerNetworkHelperExitCode
    let message: String
}

struct TCPViewerNetworkHelperCommandResult {
    let terminationStatus: Int32
    let output: String
}

protocol TCPViewerNetworkHelperCommandRunning {
    func run(_ executablePath: String, arguments: [String]) throws -> TCPViewerNetworkHelperCommandResult
}

struct TCPViewerNetworkHelperCommandRunner: TCPViewerNetworkHelperCommandRunning {
    func run(_ executablePath: String, arguments: [String]) throws -> TCPViewerNetworkHelperCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return TCPViewerNetworkHelperCommandResult(
            terminationStatus: process.terminationStatus,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct TCPViewerNetworkHelperPOSIXSystem: TCPViewerNetworkHelperSystem {
    private let commandRunner: any TCPViewerNetworkHelperCommandRunning

    init(commandRunner: any TCPViewerNetworkHelperCommandRunning = TCPViewerNetworkHelperCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func captureGroupExists() throws -> Bool {
        let result = try commandRunner.run(
            "/usr/bin/dscl",
            arguments: [".", "-read", "/Groups/\(TCPViewerNetworkHelperConstants.captureGroupName)"]
        )
        return result.terminationStatus == 0
    }

    func createCaptureGroup() throws {
        let result = try commandRunner.run(
            "/usr/sbin/dseditgroup",
            arguments: [
                "-o", "create",
                "-r", TCPViewerNetworkHelperConstants.captureGroupFullName,
                TCPViewerNetworkHelperConstants.captureGroupName,
            ]
        )
        guard result.terminationStatus == 0 else {
            throw TCPViewerNetworkHelperSystemError(
                exitCode: .groupFailure,
                message: result.output.nilIfEmpty ?? "Could not create the TCP Viewer capture group."
            )
        }
    }

    func currentConsoleUser() -> String? {
        var uid = uid_t()
        var gid = gid_t()
        guard let value = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? else {
            return nil
        }

        let ignoredUsers = ["", "root", "loginwindow", "_mbsetupuser"]
        return ignoredUsers.contains(value) ? nil : value
    }

    func userIsAdmin(_ username: String) throws -> Bool {
        let result = try commandRunner.run(
            "/usr/sbin/dseditgroup",
            arguments: ["-o", "checkmember", "-m", username, "admin"]
        )
        return result.terminationStatus == 0
    }

    func addUserToCaptureGroup(_ username: String) throws {
        let result = try commandRunner.run(
            "/usr/sbin/dseditgroup",
            arguments: [
                "-o", "edit",
                "-a", username,
                "-t", "user",
                TCPViewerNetworkHelperConstants.captureGroupName,
            ]
        )
        guard result.terminationStatus == 0 else {
            throw TCPViewerNetworkHelperSystemError(
                exitCode: .groupFailure,
                message: result.output.nilIfEmpty ?? "Could not add \(username) to the TCP Viewer capture group."
            )
        }
    }

    func bpfDevicePaths() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: TCPViewerNetworkHelperConstants.bpfDeviceDirectory)
        return names
            .filter { name in
                name.hasPrefix("bpf") && name.dropFirst(3).allSatisfy(\.isNumber)
            }
            .sorted()
            .map { "\(TCPViewerNetworkHelperConstants.bpfDeviceDirectory)/\($0)" }
    }

    func applyCapturePermissions(toDeviceAt path: String) throws {
        guard let group = getgrnam(TCPViewerNetworkHelperConstants.captureGroupName) else {
            throw TCPViewerNetworkHelperSystemError(
                exitCode: .groupFailure,
                message: "The TCP Viewer capture group does not exist."
            )
        }

        if chown(path, 0, group.pointee.gr_gid) != 0 {
            throw TCPViewerNetworkHelperSystemError(
                exitCode: .bpfPermissionFailure,
                message: "Could not update ownership for \(path): \(Self.posixErrorMessage())."
            )
        }

        if chmod(path, TCPViewerNetworkHelperConstants.bpfDeviceMode) != 0 {
            throw TCPViewerNetworkHelperSystemError(
                exitCode: .bpfPermissionFailure,
                message: "Could not update permissions for \(path): \(Self.posixErrorMessage())."
            )
        }
    }

    private static func posixErrorMessage() -> String {
        String(cString: strerror(errno))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
