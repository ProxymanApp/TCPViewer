import Darwin
import Foundation
import SystemConfiguration

enum PacketryNetworkHelperConstants {
    static let displayName = "Packetry Network Helper Tool"
    static let serviceLabel = "com.proxyman.Packetry.NetworkHelper"
    static let launchDaemonPlistName = "\(serviceLabel).plist"
    static let captureGroupName = "packetry_capture"
    static let captureGroupFullName = "Packetry Capture Access"
    static let bpfDeviceDirectory = "/dev"
    static let bpfDeviceMode: mode_t = 0o660
}

enum PacketryNetworkHelperExitCode: Int32, Sendable, Equatable {
    case success = 0
    case noConsoleUser = 64
    case notAdmin = 65
    case groupFailure = 66
    case bpfPermissionFailure = 67
}

struct PacketryNetworkHelperRunResult: Sendable, Equatable {
    let exitCode: PacketryNetworkHelperExitCode
    let message: String
}

protocol PacketryNetworkHelperSystem {
    func captureGroupExists() throws -> Bool
    func createCaptureGroup() throws
    func currentConsoleUser() -> String?
    func userIsAdmin(_ username: String) throws -> Bool
    func addUserToCaptureGroup(_ username: String) throws
    func bpfDevicePaths() throws -> [String]
    func applyCapturePermissions(toDeviceAt path: String) throws
}

struct PacketryNetworkHelperCore {
    let system: any PacketryNetworkHelperSystem

    init(system: any PacketryNetworkHelperSystem) {
        self.system = system
    }

    // Prepare the capture group, enrolling the active admin user when available.
    func run() -> PacketryNetworkHelperRunResult {
        do {
            let groupAlreadyExists = try system.captureGroupExists()
            if !groupAlreadyExists {
                try system.createCaptureGroup()
            }

            if let username = system.currentConsoleUser() {
                guard try system.userIsAdmin(username) else {
                    return PacketryNetworkHelperRunResult(
                        exitCode: .notAdmin,
                        message: "\(username) is not an admin user."
                    )
                }

                try system.addUserToCaptureGroup(username)
            } else if !groupAlreadyExists {
                return PacketryNetworkHelperRunResult(
                    exitCode: .noConsoleUser,
                    message: "No active console user was available to enroll for capture access."
                )
            }

            let bpfDevicePaths = try system.bpfDevicePaths()
            guard !bpfDevicePaths.isEmpty else {
                return PacketryNetworkHelperRunResult(
                    exitCode: .bpfPermissionFailure,
                    message: "No /dev/bpf* devices were found."
                )
            }

            for path in bpfDevicePaths {
                try system.applyCapturePermissions(toDeviceAt: path)
            }

            return PacketryNetworkHelperRunResult(
                exitCode: .success,
                message: "Prepared \(bpfDevicePaths.count) capture devices."
            )
        } catch let error as PacketryNetworkHelperSystemError {
            return PacketryNetworkHelperRunResult(exitCode: error.exitCode, message: error.message)
        } catch {
            return PacketryNetworkHelperRunResult(
                exitCode: .bpfPermissionFailure,
                message: error.localizedDescription
            )
        }
    }
}

struct PacketryNetworkHelperSystemError: Error, Sendable, Equatable {
    let exitCode: PacketryNetworkHelperExitCode
    let message: String
}

struct PacketryNetworkHelperCommandResult {
    let terminationStatus: Int32
    let output: String
}

protocol PacketryNetworkHelperCommandRunning {
    func run(_ executablePath: String, arguments: [String]) throws -> PacketryNetworkHelperCommandResult
}

struct PacketryNetworkHelperCommandRunner: PacketryNetworkHelperCommandRunning {
    func run(_ executablePath: String, arguments: [String]) throws -> PacketryNetworkHelperCommandResult {
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
        return PacketryNetworkHelperCommandResult(
            terminationStatus: process.terminationStatus,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct PacketryNetworkHelperPOSIXSystem: PacketryNetworkHelperSystem {
    private let commandRunner: any PacketryNetworkHelperCommandRunning

    init(commandRunner: any PacketryNetworkHelperCommandRunning = PacketryNetworkHelperCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func captureGroupExists() throws -> Bool {
        let result = try commandRunner.run(
            "/usr/bin/dscl",
            arguments: [".", "-read", "/Groups/\(PacketryNetworkHelperConstants.captureGroupName)"]
        )
        return result.terminationStatus == 0
    }

    func createCaptureGroup() throws {
        let result = try commandRunner.run(
            "/usr/sbin/dseditgroup",
            arguments: [
                "-o", "create",
                "-r", PacketryNetworkHelperConstants.captureGroupFullName,
                PacketryNetworkHelperConstants.captureGroupName,
            ]
        )
        guard result.terminationStatus == 0 else {
            throw PacketryNetworkHelperSystemError(
                exitCode: .groupFailure,
                message: result.output.nilIfEmpty ?? "Could not create the Packetry capture group."
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
                PacketryNetworkHelperConstants.captureGroupName,
            ]
        )
        guard result.terminationStatus == 0 else {
            throw PacketryNetworkHelperSystemError(
                exitCode: .groupFailure,
                message: result.output.nilIfEmpty ?? "Could not add \(username) to the Packetry capture group."
            )
        }
    }

    func bpfDevicePaths() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: PacketryNetworkHelperConstants.bpfDeviceDirectory)
        return names
            .filter { name in
                name.hasPrefix("bpf") && name.dropFirst(3).allSatisfy(\.isNumber)
            }
            .sorted()
            .map { "\(PacketryNetworkHelperConstants.bpfDeviceDirectory)/\($0)" }
    }

    func applyCapturePermissions(toDeviceAt path: String) throws {
        guard let group = getgrnam(PacketryNetworkHelperConstants.captureGroupName) else {
            throw PacketryNetworkHelperSystemError(
                exitCode: .groupFailure,
                message: "The Packetry capture group does not exist."
            )
        }

        if chown(path, 0, group.pointee.gr_gid) != 0 {
            throw PacketryNetworkHelperSystemError(
                exitCode: .bpfPermissionFailure,
                message: "Could not update ownership for \(path): \(Self.posixErrorMessage())."
            )
        }

        if chmod(path, PacketryNetworkHelperConstants.bpfDeviceMode) != 0 {
            throw PacketryNetworkHelperSystemError(
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
