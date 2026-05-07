//
//  TCPViewerNetworkHelperToolManager.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Darwin
import Foundation
import Security
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
            serviceController: TCPViewerNetworkHelperSMJobBlessController(),
            legacyServiceControllers: TCPViewerNetworkHelperConstants.legacyServiceLabels.map {
                TCPViewerNetworkHelperSMJobBlessController(serviceLabel: $0)
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
            message = "TCP Viewer could not find the bundled helper payload in this app build."
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

struct TCPViewerNetworkHelperSMJobBlessController: TCPViewerNetworkHelperServiceControlling {
    private let serviceLabel: String
    private let launchDaemonPlistName: String
    private let bundleURL: URL
    private let privilegedHelperToolsDirectoryURL: URL
    private let launchDaemonsDirectoryURL: URL
    private let fileManager: FileManager

    init(
        serviceLabel: String = TCPViewerNetworkHelperConstants.serviceLabel,
        bundleURL: URL = Bundle.main.bundleURL,
        privilegedHelperToolsDirectoryURL: URL = URL(fileURLWithPath: TCPViewerNetworkHelperConstants.privilegedHelperToolsDirectoryPath),
        launchDaemonsDirectoryURL: URL = URL(fileURLWithPath: TCPViewerNetworkHelperConstants.launchDaemonsDirectoryPath),
        fileManager: FileManager = .default
    ) {
        self.serviceLabel = serviceLabel
        self.launchDaemonPlistName = "\(serviceLabel).plist"
        self.bundleURL = bundleURL
        self.privilegedHelperToolsDirectoryURL = privilegedHelperToolsDirectoryURL
        self.launchDaemonsDirectoryURL = launchDaemonsDirectoryURL
        self.fileManager = fileManager
    }

    private var bundledHelperToolURL: URL {
        bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(serviceLabel)")
    }

    private var bundledLaunchDaemonPlistURL: URL {
        bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(launchDaemonPlistName)")
    }

    private var installedHelperToolURL: URL {
        privilegedHelperToolsDirectoryURL.appendingPathComponent(serviceLabel)
    }

    private var installedLaunchDaemonPlistURL: URL {
        launchDaemonsDirectoryURL.appendingPathComponent(launchDaemonPlistName)
    }

    var status: TCPViewerNetworkHelperAuthorizationStatus {
        if installedServiceExists() {
            return .enabled
        }

        return bundledPayloadExists() ? .notRegistered : .notFound
    }

    func register() throws {
        try validateBundledPayload()
        let authorization = try makeAuthorization(for: kSMRightBlessPrivilegedHelper)
        defer { _ = AuthorizationFree(authorization, []) }

        var blessError: Unmanaged<CFError>?
        // SMJobBless discovers the tool by launchd label, so the bundle payload must use the legacy fixed path.
        guard SMJobBless(kSMDomainSystemLaunchd, serviceLabel as CFString, authorization, &blessError) else {
            throw TCPViewerNetworkHelperSMJobBlessError.serviceManagementFailure(
                blessError?.takeRetainedValue(),
                fallbackMessage: "macOS could not install the privileged helper."
            )
        }
    }

    func unregister() throws {
        // Avoid prompting for admin credentials when no blessed helper is present on disk.
        guard installedServiceExists() else {
            return
        }

        let authorization = try makeAuthorization(for: kSMRightModifySystemDaemons)
        defer { _ = AuthorizationFree(authorization, []) }

        var removeError: Unmanaged<CFError>?
        guard SMJobRemove(kSMDomainSystemLaunchd, serviceLabel as CFString, authorization, true, &removeError) else {
            throw TCPViewerNetworkHelperSMJobBlessError.serviceManagementFailure(
                removeError?.takeRetainedValue(),
                fallbackMessage: "macOS could not remove the privileged helper."
            )
        }
    }

    func openSystemSettings() {}

    private func bundledPayloadExists() -> Bool {
        fileManager.fileExists(atPath: bundledHelperToolURL.path) &&
            fileManager.fileExists(atPath: bundledLaunchDaemonPlistURL.path)
    }

    private func installedServiceExists() -> Bool {
        fileManager.fileExists(atPath: installedHelperToolURL.path) ||
            fileManager.fileExists(atPath: installedLaunchDaemonPlistURL.path)
    }

    private func validateBundledPayload() throws {
        guard fileManager.fileExists(atPath: bundledHelperToolURL.path) else {
            throw TCPViewerNetworkHelperSMJobBlessError.missingBundledHelper(bundledHelperToolURL)
        }

        guard fileManager.fileExists(atPath: bundledLaunchDaemonPlistURL.path) else {
            throw TCPViewerNetworkHelperSMJobBlessError.missingLaunchDaemonPlist(bundledLaunchDaemonPlistURL)
        }
    }

    private func makeAuthorization(for rightName: String) throws -> AuthorizationRef {
        var authorization: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let createStatus = AuthorizationCreate(nil, nil, flags, &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw TCPViewerNetworkHelperSMJobBlessError.authorizationFailure(createStatus)
        }

        do {
            // Scope admin rights to the single ServiceManagement operation instead of keeping reusable credentials.
            let copyStatus = rightName.withCString { authorizationRightName in
                var item = AuthorizationItem(name: authorizationRightName, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { itemPointer in
                    var rights = AuthorizationRights(count: 1, items: itemPointer)
                    return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
                }
            }

            guard copyStatus == errAuthorizationSuccess else {
                throw TCPViewerNetworkHelperSMJobBlessError.authorizationFailure(copyStatus)
            }

            return authorization
        } catch {
            _ = AuthorizationFree(authorization, [])
            throw error
        }
    }
}

private enum TCPViewerNetworkHelperSMJobBlessError: LocalizedError {
    case missingBundledHelper(URL)
    case missingLaunchDaemonPlist(URL)
    case authorizationFailure(OSStatus)
    case serviceManagementFailure(CFError?, fallbackMessage: String)

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper(let url):
            "TCP Viewer could not find the bundled helper at \(url.path)."
        case .missingLaunchDaemonPlist(let url):
            "TCP Viewer could not find the bundled helper launchd plist at \(url.path)."
        case .authorizationFailure(let status):
            "macOS authorization failed: \(Self.message(for: status))."
        case .serviceManagementFailure(let error, let fallbackMessage):
            error?.localizedDescription ?? fallbackMessage
        }
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
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
