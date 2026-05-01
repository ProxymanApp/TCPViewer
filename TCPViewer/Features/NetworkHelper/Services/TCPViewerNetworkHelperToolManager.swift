//
//  TCPViewerNetworkHelperToolManager.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Darwin
import Foundation
import ServiceManagement

enum TCPViewerNetworkHelperToolStatus: String, Sendable, Equatable {
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

struct TCPViewerNetworkHelperToolSnapshot: Sendable, Equatable {
    let status: TCPViewerNetworkHelperToolStatus
    let authorizationStatus: TCPViewerNetworkHelperAuthorizationStatus
    let lastCheckedAt: Date?
    let message: String

    static let notInstalled = TCPViewerNetworkHelperToolSnapshot(
        status: .notInstalled,
        authorizationStatus: .notRegistered,
        lastCheckedAt: nil,
        message: "TCP Viewer Network Helper Tool is not installed."
    )

    var title: String {
        switch status {
        case .notInstalled:
            "Install TCP Viewer Network Helper Tool"
        case .waitingForApproval:
            "Approve TCP Viewer Network Helper Tool"
        case .installedNeedsRelaunch:
            "Relaunch TCP Viewer"
        case .ready:
            "TCP Viewer Network Helper Tool Ready"
        case .broken:
            "Repair TCP Viewer Network Helper Tool"
        case .unsupported:
            "TCP Viewer Network Helper Tool Unsupported"
        case .installing:
            "Installing TCP Viewer Network Helper Tool"
        }
    }
}

enum TCPViewerNetworkHelperAuthorizationStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)
}

struct TCPViewerNetworkHelperBPFInspection: Sendable, Equatable {
    let groupExists: Bool
    let deviceCount: Int
    let expectedPermissionsReady: Bool
    let currentProcessHasCaptureGroup: Bool
    let currentProcessCanAccessBPF: Bool
    let message: String
}

protocol TCPViewerNetworkHelperServiceControlling {
    var status: TCPViewerNetworkHelperAuthorizationStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

protocol TCPViewerNetworkHelperBPFChecking {
    func inspect() -> TCPViewerNetworkHelperBPFInspection
}

protocol TCPViewerNetworkHelperToolManaging: AnyObject {
    var snapshot: TCPViewerNetworkHelperToolSnapshot { get }

    @discardableResult
    func refreshStatus(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot

    @discardableResult
    func install(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot

    @discardableResult
    func repair(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot

    @discardableResult
    func uninstall(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot

    func openSystemSettings()
}

final class TCPViewerNetworkHelperToolManager: TCPViewerNetworkHelperToolManaging {
    private(set) var snapshot: TCPViewerNetworkHelperToolSnapshot

    private let serviceController: any TCPViewerNetworkHelperServiceControlling
    private let legacyServiceControllers: [any TCPViewerNetworkHelperServiceControlling]
    private let bpfChecker: any TCPViewerNetworkHelperBPFChecking
    private let workerQueue = DispatchQueue(label: "com.proxyman.tcpviewer.NetworkHelperToolManager", qos: .userInitiated)

    convenience init() {
        self.init(
            serviceController: TCPViewerNetworkHelperSMAppServiceController(),
            legacyServiceControllers: TCPViewerNetworkHelperConstants.legacyLaunchDaemonPlistNames.map {
                TCPViewerNetworkHelperSMAppServiceController(plistName: $0)
            },
            bpfChecker: TCPViewerNetworkHelperBPFChecker()
        )
    }

    init(
        serviceController: any TCPViewerNetworkHelperServiceControlling,
        legacyServiceControllers: [any TCPViewerNetworkHelperServiceControlling] = [],
        bpfChecker: any TCPViewerNetworkHelperBPFChecking
    ) {
        self.serviceController = serviceController
        self.legacyServiceControllers = legacyServiceControllers
        self.bpfChecker = bpfChecker
        self.snapshot = .notInstalled
    }

    @discardableResult
    func refreshStatus(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        let currentSnapshot = snapshot
        workerQueue.async {
            let updatedSnapshot = self.makeSnapshot()
            self.publish(updatedSnapshot, completion: completion)
        }
        return currentSnapshot
    }

    @discardableResult
    func install(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        let installingSnapshot = TCPViewerNetworkHelperToolSnapshot(
            status: .installing,
            authorizationStatus: serviceController.status,
            lastCheckedAt: Date(),
            message: "Registering TCP Viewer Network Helper Tool with macOS."
        )
        snapshot = installingSnapshot
        workerQueue.async {
            do {
                try self.serviceController.register()
                self.unregisterLegacyServices()
                let updatedSnapshot = self.makeSnapshot()
                self.publish(updatedSnapshot, completion: completion)
            } catch {
                let refreshedSnapshot = self.makeSnapshot()
                guard refreshedSnapshot.status == .notInstalled else {
                    self.publish(refreshedSnapshot, completion: completion)
                    return
                }

                let failedSnapshot = TCPViewerNetworkHelperToolSnapshot(
                    status: .broken,
                    authorizationStatus: refreshedSnapshot.authorizationStatus,
                    lastCheckedAt: Date(),
                    message: "TCP Viewer could not register the helper: \(error.localizedDescription)"
                )
                self.publish(failedSnapshot, completion: completion)
            }
        }
        return installingSnapshot
    }

    @discardableResult
    func repair(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        install(completion: completion)
    }

    @discardableResult
    func uninstall(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        let currentSnapshot = snapshot
        workerQueue.async {
            var unregisterError: Error?
            do {
                try self.serviceController.unregister()
            } catch {
                unregisterError = error
            }

            self.unregisterLegacyServices()
            let refreshedSnapshot = self.makeSnapshot()
            if let unregisterError, refreshedSnapshot.status != .notInstalled {
                let failedSnapshot = TCPViewerNetworkHelperToolSnapshot(
                    status: .broken,
                    authorizationStatus: refreshedSnapshot.authorizationStatus,
                    lastCheckedAt: Date(),
                    message: "TCP Viewer could not uninstall the helper: \(unregisterError.localizedDescription)"
                )
                self.publish(failedSnapshot, completion: completion)
                return
            }

            self.publish(refreshedSnapshot, completion: completion)
        }
        return currentSnapshot
    }

    func openSystemSettings() {
        serviceController.openSystemSettings()
    }

    private func makeSnapshot() -> TCPViewerNetworkHelperToolSnapshot {
        let authorizationStatus = serviceController.status
        let bpfInspection = bpfChecker.inspect()
        let status: TCPViewerNetworkHelperToolStatus
        let message: String

        switch authorizationStatus {
        case .notRegistered:
            status = .notInstalled
            message = "TCP Viewer Network Helper Tool has not been registered with macOS."
        case .notFound:
            status = .notInstalled
            message = "TCP Viewer could not find the bundled helper plist in this app build."
        case .requiresApproval:
            status = .waitingForApproval
            message = "Approve TCP Viewer in System Settings > General > Login Items, then retry."
        case .enabled:
            if !bpfInspection.groupExists || !bpfInspection.expectedPermissionsReady {
                status = .broken
                message = bpfInspection.message
            } else if !bpfInspection.currentProcessHasCaptureGroup {
                status = .installedNeedsRelaunch
                message = "Relaunch TCP Viewer so macOS refreshes the app's capture-group membership."
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

        return TCPViewerNetworkHelperToolSnapshot(
            status: status,
            authorizationStatus: authorizationStatus,
            lastCheckedAt: Date(),
            message: message
        )
    }

    private func unregisterLegacyServices() {
        for legacyServiceController in legacyServiceControllers {
            try? legacyServiceController.unregister()
        }
    }

    private func publish(
        _ updatedSnapshot: TCPViewerNetworkHelperToolSnapshot,
        completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void
    ) {
        DispatchQueue.main.async {
            self.snapshot = updatedSnapshot
            completion(updatedSnapshot)
        }
    }
}

final class ReadyTCPViewerNetworkHelperToolManager: TCPViewerNetworkHelperToolManaging {
    private(set) var snapshot = TCPViewerNetworkHelperToolSnapshot(
        status: .ready,
        authorizationStatus: .enabled,
        lastCheckedAt: nil,
        message: "TCP Viewer Network Helper Tool is ready."
    )

    func refreshStatus(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func install(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func repair(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func uninstall(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func openSystemSettings() {}
}

struct TCPViewerNetworkHelperSMAppServiceController: TCPViewerNetworkHelperServiceControlling {
    private let plistName: String

    init(plistName: String = TCPViewerNetworkHelperConstants.launchDaemonPlistName) {
        self.plistName = plistName
    }

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    var status: TCPViewerNetworkHelperAuthorizationStatus {
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

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct TCPViewerNetworkHelperBPFChecker: TCPViewerNetworkHelperBPFChecking {
    func inspect() -> TCPViewerNetworkHelperBPFInspection {
        guard let group = getgrnam(TCPViewerNetworkHelperConstants.captureGroupName) else {
            return TCPViewerNetworkHelperBPFInspection(
                groupExists: false,
                deviceCount: 0,
                expectedPermissionsReady: false,
                currentProcessHasCaptureGroup: false,
                currentProcessCanAccessBPF: false,
                message: "TCP Viewer could not find the packet-capture access group."
            )
        }

        let groupID = group.pointee.gr_gid
        let devicePaths = bpfDevicePaths()
        guard !devicePaths.isEmpty else {
            return TCPViewerNetworkHelperBPFInspection(
                groupExists: true,
                deviceCount: 0,
                expectedPermissionsReady: false,
                currentProcessHasCaptureGroup: currentProcessGroupIDs().contains(groupID),
                currentProcessCanAccessBPF: false,
                message: "TCP Viewer could not find any /dev/bpf* capture devices."
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
                permissionBits == TCPViewerNetworkHelperConstants.bpfDeviceMode
        }
        let processGroupIDs = currentProcessGroupIDs()
        let hasCaptureGroup = processGroupIDs.contains(groupID)
        let canAccessBPF = devicePaths.contains { access($0, R_OK | W_OK) == 0 }
        let message = devicesReady && hasCaptureGroup && canAccessBPF
            ? "TCP Viewer can access \(devicePaths.count) packet-capture devices."
            : "TCP Viewer found \(devicePaths.count) packet-capture devices, but access is not ready."

        return TCPViewerNetworkHelperBPFInspection(
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
            atPath: TCPViewerNetworkHelperConstants.bpfDeviceDirectory
        ) else {
            return []
        }

        return names
            .filter { name in
                name.hasPrefix("bpf") && name.dropFirst(3).allSatisfy(\.isNumber)
            }
            .sorted()
            .map { "\(TCPViewerNetworkHelperConstants.bpfDeviceDirectory)/\($0)" }
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
