import Darwin
import Combine
import Foundation
import ServiceManagement

enum PacketryNetworkHelperToolStatus: String, Sendable, Equatable {
    case notInstalled
    case waitingForApproval
    case installedNeedsRelaunch
    case ready
    case broken
    case unsupported
    case installing

    var allowsLiveCapture: Bool {
        self == .ready
    }
}

struct PacketryNetworkHelperToolSnapshot: Sendable, Equatable {
    let status: PacketryNetworkHelperToolStatus
    let authorizationStatus: PacketryNetworkHelperAuthorizationStatus
    let lastCheckedAt: Date?
    let message: String

    static let notInstalled = PacketryNetworkHelperToolSnapshot(
        status: .notInstalled,
        authorizationStatus: .notRegistered,
        lastCheckedAt: nil,
        message: "Packetry Network Helper Tool is not installed."
    )

    var title: String {
        switch status {
        case .notInstalled:
            "Install Packetry Network Helper Tool"
        case .waitingForApproval:
            "Approve Packetry Network Helper Tool"
        case .installedNeedsRelaunch:
            "Relaunch Packetry"
        case .ready:
            "Packetry Network Helper Tool Ready"
        case .broken:
            "Repair Packetry Network Helper Tool"
        case .unsupported:
            "Packetry Network Helper Tool Unsupported"
        case .installing:
            "Installing Packetry Network Helper Tool"
        }
    }
}

enum PacketryNetworkHelperAuthorizationStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)
}

struct PacketryNetworkHelperBPFInspection: Sendable, Equatable {
    let groupExists: Bool
    let deviceCount: Int
    let expectedPermissionsReady: Bool
    let currentProcessHasCaptureGroup: Bool
    let currentProcessCanAccessBPF: Bool
    let message: String
}

protocol PacketryNetworkHelperServiceControlling {
    var status: PacketryNetworkHelperAuthorizationStatus { get }
    func register() throws
    func openSystemSettings()
}

protocol PacketryNetworkHelperBPFChecking {
    func inspect() -> PacketryNetworkHelperBPFInspection
}

@MainActor
protocol PacketryNetworkHelperToolManaging: AnyObject {
    var snapshot: PacketryNetworkHelperToolSnapshot { get }

    @discardableResult
    func refreshStatus() async -> PacketryNetworkHelperToolSnapshot

    @discardableResult
    func install() async -> PacketryNetworkHelperToolSnapshot

    @discardableResult
    func repair() async -> PacketryNetworkHelperToolSnapshot

    func openSystemSettings()
}

@MainActor
final class PacketryNetworkHelperToolManager: ObservableObject, PacketryNetworkHelperToolManaging {
    @Published private(set) var snapshot: PacketryNetworkHelperToolSnapshot

    private let serviceController: any PacketryNetworkHelperServiceControlling
    private let bpfChecker: any PacketryNetworkHelperBPFChecking

    convenience init() {
        self.init(
            serviceController: PacketryNetworkHelperSMAppServiceController(),
            bpfChecker: PacketryNetworkHelperBPFChecker()
        )
    }

    init(
        serviceController: any PacketryNetworkHelperServiceControlling,
        bpfChecker: any PacketryNetworkHelperBPFChecking
    ) {
        self.serviceController = serviceController
        self.bpfChecker = bpfChecker
        self.snapshot = .notInstalled
    }

    @discardableResult
    func refreshStatus() async -> PacketryNetworkHelperToolSnapshot {
        let updatedSnapshot = makeSnapshot()
        snapshot = updatedSnapshot
        return updatedSnapshot
    }

    @discardableResult
    func install() async -> PacketryNetworkHelperToolSnapshot {
        snapshot = PacketryNetworkHelperToolSnapshot(
            status: .installing,
            authorizationStatus: serviceController.status,
            lastCheckedAt: Date(),
            message: "Registering Packetry Network Helper Tool with macOS."
        )

        do {
            try serviceController.register()
            return await refreshStatus()
        } catch {
            let refreshedSnapshot = await refreshStatus()
            guard refreshedSnapshot.status == .notInstalled else {
                return refreshedSnapshot
            }

            let failedSnapshot = PacketryNetworkHelperToolSnapshot(
                status: .broken,
                authorizationStatus: refreshedSnapshot.authorizationStatus,
                lastCheckedAt: Date(),
                message: "Packetry could not register the helper: \(error.localizedDescription)"
            )
            snapshot = failedSnapshot
            return failedSnapshot
        }
    }

    @discardableResult
    func repair() async -> PacketryNetworkHelperToolSnapshot {
        await install()
    }

    func openSystemSettings() {
        serviceController.openSystemSettings()
    }

    private func makeSnapshot() -> PacketryNetworkHelperToolSnapshot {
        let authorizationStatus = serviceController.status
        let bpfInspection = bpfChecker.inspect()
        let status: PacketryNetworkHelperToolStatus
        let message: String

        switch authorizationStatus {
        case .notRegistered:
            status = .notInstalled
            message = "Packetry Network Helper Tool has not been registered with macOS."
        case .notFound:
            status = .notInstalled
            message = "Packetry could not find the bundled helper plist in this app build."
        case .requiresApproval:
            status = .waitingForApproval
            message = "Approve Packetry in System Settings > General > Login Items, then retry."
        case .enabled:
            if !bpfInspection.groupExists || !bpfInspection.expectedPermissionsReady {
                status = .broken
                message = bpfInspection.message
            } else if !bpfInspection.currentProcessHasCaptureGroup {
                status = .installedNeedsRelaunch
                message = "Relaunch Packetry so macOS refreshes the app's capture-group membership."
            } else if !bpfInspection.currentProcessCanAccessBPF {
                status = .broken
                message = bpfInspection.message
            } else {
                status = .ready
                message = bpfInspection.message
            }
        case .unknown(let rawValue):
            status = .unsupported
            message = "macOS reported an unknown helper status: \(rawValue)."
        }

        return PacketryNetworkHelperToolSnapshot(
            status: status,
            authorizationStatus: authorizationStatus,
            lastCheckedAt: Date(),
            message: message
        )
    }
}

@MainActor
final class ReadyPacketryNetworkHelperToolManager: PacketryNetworkHelperToolManaging {
    private(set) var snapshot = PacketryNetworkHelperToolSnapshot(
        status: .ready,
        authorizationStatus: .enabled,
        lastCheckedAt: nil,
        message: "Packetry Network Helper Tool is ready."
    )

    func refreshStatus() async -> PacketryNetworkHelperToolSnapshot {
        snapshot
    }

    func install() async -> PacketryNetworkHelperToolSnapshot {
        snapshot
    }

    func repair() async -> PacketryNetworkHelperToolSnapshot {
        snapshot
    }

    func openSystemSettings() {}
}

struct PacketryNetworkHelperSMAppServiceController: PacketryNetworkHelperServiceControlling {
    private let service = SMAppService.daemon(plistName: PacketryNetworkHelperConstants.launchDaemonPlistName)

    var status: PacketryNetworkHelperAuthorizationStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .unknown(service.status.rawValue)
        }
    }

    func register() throws {
        try service.register()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct PacketryNetworkHelperBPFChecker: PacketryNetworkHelperBPFChecking {
    func inspect() -> PacketryNetworkHelperBPFInspection {
        guard let group = getgrnam(PacketryNetworkHelperConstants.captureGroupName) else {
            return PacketryNetworkHelperBPFInspection(
                groupExists: false,
                deviceCount: 0,
                expectedPermissionsReady: false,
                currentProcessHasCaptureGroup: false,
                currentProcessCanAccessBPF: false,
                message: "Packetry could not find the packet-capture access group."
            )
        }

        let groupID = group.pointee.gr_gid
        let devicePaths = bpfDevicePaths()
        guard !devicePaths.isEmpty else {
            return PacketryNetworkHelperBPFInspection(
                groupExists: true,
                deviceCount: 0,
                expectedPermissionsReady: false,
                currentProcessHasCaptureGroup: currentProcessGroupIDs().contains(groupID),
                currentProcessCanAccessBPF: false,
                message: "Packetry could not find any /dev/bpf* capture devices."
            )
        }

        let devicesReady = devicePaths.allSatisfy { path in
            var info = stat()
            guard lstat(path, &info) == 0 else {
                return false
            }

            let permissionBits = info.st_mode & mode_t(0o777)
            return info.st_uid == 0 &&
                info.st_gid == groupID &&
                permissionBits == PacketryNetworkHelperConstants.bpfDeviceMode
        }
        let processGroupIDs = currentProcessGroupIDs()
        let hasCaptureGroup = processGroupIDs.contains(groupID)
        let canAccessBPF = devicePaths.contains { access($0, R_OK | W_OK) == 0 }
        let message = devicesReady && hasCaptureGroup && canAccessBPF
            ? "Packetry can access \(devicePaths.count) packet-capture devices."
            : "Packetry found \(devicePaths.count) packet-capture devices, but access is not ready."

        return PacketryNetworkHelperBPFInspection(
            groupExists: true,
            deviceCount: devicePaths.count,
            expectedPermissionsReady: devicesReady,
            currentProcessHasCaptureGroup: hasCaptureGroup,
            currentProcessCanAccessBPF: canAccessBPF,
            message: message
        )
    }

    private func bpfDevicePaths() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: PacketryNetworkHelperConstants.bpfDeviceDirectory
        ) else {
            return []
        }

        return names
            .filter { name in
                name.hasPrefix("bpf") && name.dropFirst(3).allSatisfy(\.isNumber)
            }
            .sorted()
            .map { "\(PacketryNetworkHelperConstants.bpfDeviceDirectory)/\($0)" }
    }

    private func currentProcessGroupIDs() -> Set<gid_t> {
        let groupCount = getgroups(0, nil)
        guard groupCount >= 0 else {
            return [getgid(), getegid()]
        }

        var groups = [gid_t](repeating: 0, count: Int(groupCount))
        let resolvedCount = groups.withUnsafeMutableBufferPointer { buffer in
            getgroups(groupCount, buffer.baseAddress)
        }
        let resolvedGroups = resolvedCount > 0 ? groups.prefix(Int(resolvedCount)) : []
        return Set(resolvedGroups + [getgid(), getegid()])
    }
}
