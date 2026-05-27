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
    let installedHelperToolVersion: String?

    static let notInstalled = TCPViewerNetworkHelperToolSnapshot(
        status: .notInstalled,
        authorizationStatus: .notRegistered,
        lastCheckedAt: nil,
        message: "TCP Viewer Network Helper Tool is not installed.",
        installedHelperToolVersion: nil
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
    var installedHelperToolVersion: String? { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

protocol TCPViewerNetworkHelperBPFChecking {
    func inspect() -> TCPViewerNetworkHelperBPFInspection
}

enum TCPViewerNetworkHelperAuthorizationRight {
    case named(String)
    case executeTool(String)

    var name: String {
        switch self {
        case .named(let name):
            name
        case .executeTool:
            kAuthorizationRightExecute
        }
    }
}

protocol TCPViewerNetworkHelperAuthorizationProviding {
    func makeAuthorization(for rights: [TCPViewerNetworkHelperAuthorizationRight]) throws -> AuthorizationRef
    func free(_ authorization: AuthorizationRef)
}

protocol TCPViewerNetworkHelperServiceManagementControlling {
    func blessJob(label: String, authorization: AuthorizationRef) throws
    func removeJob(label: String, authorization: AuthorizationRef, wait: Bool) throws
}

protocol TCPViewerNetworkHelperInstalledItemRemoving {
    func removeItems(at urls: [URL], authorization: AuthorizationRef) throws
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
    private let logger: TCPViewerNetworkHelperLogger
    private let workerQueue = DispatchQueue(label: "com.proxyman.tcpviewer.NetworkHelperToolManager", qos: .userInitiated)

    convenience init() {
        self.init(
            serviceController: TCPViewerNetworkHelperSMJobBlessController(),
            legacyServiceControllers: TCPViewerNetworkHelperConstants.legacyServiceLabels.map {
                TCPViewerNetworkHelperSMJobBlessController(serviceLabel: $0)
            },
            bpfChecker: TCPViewerNetworkHelperBPFChecker(),
            logger: TCPViewerNetworkHelperLogger()
        )
    }

    init(
        serviceController: any TCPViewerNetworkHelperServiceControlling,
        legacyServiceControllers: [any TCPViewerNetworkHelperServiceControlling] = [],
        bpfChecker: any TCPViewerNetworkHelperBPFChecking,
        logger: TCPViewerNetworkHelperLogger = TCPViewerNetworkHelperLogger()
    ) {
        self.serviceController = serviceController
        self.legacyServiceControllers = legacyServiceControllers
        self.bpfChecker = bpfChecker
        self.logger = logger
        self.snapshot = .notInstalled
    }

    @discardableResult
    func refreshStatus(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        refreshStatus(operation: nil, completion: completion)
    }

    @discardableResult
    func refreshStatusForLaunch(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        refreshStatus(operation: .launchStatus, completion: completion)
    }

    @discardableResult
    private func refreshStatus(
        operation: TCPViewerNetworkHelperLogOperation?,
        completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void
    ) -> TCPViewerNetworkHelperToolSnapshot {
        let currentSnapshot = snapshot
        workerQueue.async {
            let updatedSnapshot = self.makeSnapshot()
            if let operation {
                self.logger.log(operation, snapshot: updatedSnapshot)
            }
            self.publish(updatedSnapshot, completion: completion)
        }
        return currentSnapshot
    }

    @discardableResult
    func install(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        install(operation: .install, completion: completion)
    }

    @discardableResult
    private func install(
        operation: TCPViewerNetworkHelperLogOperation,
        completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void
    ) -> TCPViewerNetworkHelperToolSnapshot {
        let installingSnapshot = TCPViewerNetworkHelperToolSnapshot(
            status: .installing,
            authorizationStatus: serviceController.status,
            lastCheckedAt: Date(),
            message: "Registering TCP Viewer Network Helper Tool with macOS.",
            installedHelperToolVersion: serviceController.installedHelperToolVersion
        )
        snapshot = installingSnapshot
        workerQueue.async {
            do {
                try self.serviceController.register()
                self.unregisterLegacyServices()
                let updatedSnapshot = self.makeSnapshot()
                self.logger.log(operation, snapshot: updatedSnapshot)
                self.publish(updatedSnapshot, completion: completion)
            } catch {
                let refreshedSnapshot = self.makeSnapshot()
                self.logger.logFailure(operation, error: error, snapshot: refreshedSnapshot)
                // A failed bless call can still leave launchd usable, so trust the refreshed helper status.
                guard refreshedSnapshot.status == .notInstalled else {
                    self.logger.log(operation, snapshot: refreshedSnapshot)
                    self.publish(refreshedSnapshot, completion: completion)
                    return
                }

                let failedSnapshot = TCPViewerNetworkHelperToolSnapshot(
                    status: .broken,
                    authorizationStatus: refreshedSnapshot.authorizationStatus,
                    lastCheckedAt: Date(),
                    message: "TCP Viewer could not register the helper: \(error.localizedDescription)",
                    installedHelperToolVersion: refreshedSnapshot.installedHelperToolVersion
                )
                self.logger.log(operation, snapshot: failedSnapshot)
                self.publish(failedSnapshot, completion: completion)
            }
        }
        return installingSnapshot
    }

    @discardableResult
    func repair(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void = { _ in }) -> TCPViewerNetworkHelperToolSnapshot {
        install(operation: .repair, completion: completion)
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
            // Removal succeeds only when launchd no longer reports the current helper.
            if let unregisterError, refreshedSnapshot.status != .notInstalled {
                self.logger.logFailure(.remove, error: unregisterError, snapshot: refreshedSnapshot)
                let failedSnapshot = TCPViewerNetworkHelperToolSnapshot(
                    status: .broken,
                    authorizationStatus: refreshedSnapshot.authorizationStatus,
                    lastCheckedAt: Date(),
                    message: "TCP Viewer could not uninstall the helper: \(unregisterError.localizedDescription)",
                    installedHelperToolVersion: refreshedSnapshot.installedHelperToolVersion
                )
                self.logger.log(.remove, snapshot: failedSnapshot)
                self.publish(failedSnapshot, completion: completion)
                return
            }

            self.logger.log(.remove, snapshot: refreshedSnapshot)
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
            message = "Install the Helper Tool to enable live capture."
        case .notFound:
            status = .notInstalled
            message = "This app build is missing the Helper Tool needed for live capture."
        case .requiresApproval:
            status = .waitingForApproval
            message = "Approve TCP Viewer in System Settings > General > Login Items, then retry."
        case .enabled:
            if !bpfInspection.groupExists || !bpfInspection.expectedPermissionsReady {
                status = .broken
                message = bpfInspection.message
            } else if !bpfInspection.currentProcessHasCaptureGroup {
                status = .installedNeedsRelaunch
                message = "Relaunch TCP Viewer to finish enabling live capture."
            } else if !bpfInspection.currentProcessCanAccessBPF {
                status = .broken
                message = bpfInspection.message
            } else {
                status = .ready
                message = bpfInspection.message
            }
        case .unknown(let rawValue):
            status = .unsupported
            message = "TCP Viewer could not understand the Helper Tool status from macOS: \(rawValue)."
        }

        return TCPViewerNetworkHelperToolSnapshot(
            status: status,
            authorizationStatus: authorizationStatus,
            lastCheckedAt: Date(),
            message: message,
            installedHelperToolVersion: serviceController.installedHelperToolVersion
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
        message: "TCP Viewer Network Helper Tool is ready.",
        installedHelperToolVersion: nil
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
    private let authorizationProvider: any TCPViewerNetworkHelperAuthorizationProviding
    private let serviceManagementController: any TCPViewerNetworkHelperServiceManagementControlling
    private let installedItemRemover: any TCPViewerNetworkHelperInstalledItemRemoving

    init(
        serviceLabel: String = TCPViewerNetworkHelperConstants.serviceLabel,
        bundleURL: URL = Bundle.main.bundleURL,
        privilegedHelperToolsDirectoryURL: URL = URL(fileURLWithPath: TCPViewerNetworkHelperConstants.privilegedHelperToolsDirectoryPath),
        launchDaemonsDirectoryURL: URL = URL(fileURLWithPath: TCPViewerNetworkHelperConstants.launchDaemonsDirectoryPath),
        fileManager: FileManager = .default,
        authorizationProvider: any TCPViewerNetworkHelperAuthorizationProviding = TCPViewerNetworkHelperAuthorizationProvider(),
        serviceManagementController: any TCPViewerNetworkHelperServiceManagementControlling = TCPViewerNetworkHelperServiceManagementController(),
        installedItemRemover: any TCPViewerNetworkHelperInstalledItemRemoving = TCPViewerNetworkHelperPrivilegedInstalledItemRemover()
    ) {
        self.serviceLabel = serviceLabel
        self.launchDaemonPlistName = "\(serviceLabel).plist"
        self.bundleURL = bundleURL
        self.privilegedHelperToolsDirectoryURL = privilegedHelperToolsDirectoryURL
        self.launchDaemonsDirectoryURL = launchDaemonsDirectoryURL
        self.fileManager = fileManager
        self.authorizationProvider = authorizationProvider
        self.serviceManagementController = serviceManagementController
        self.installedItemRemover = installedItemRemover
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

    var installedHelperToolVersion: String? {
        guard fileManager.fileExists(atPath: installedHelperToolURL.path) else {
            return nil
        }

        return helperToolVersion(at: installedHelperToolURL)
    }

    func register() throws {
        try validateBundledPayload()
        let authorization = try authorizationProvider.makeAuthorization(for: [.named(kSMRightBlessPrivilegedHelper)])
        defer { authorizationProvider.free(authorization) }

        // SMJobBless discovers the tool by launchd label, so the bundle payload must use the legacy fixed path.
        try serviceManagementController.blessJob(label: serviceLabel, authorization: authorization)
    }

    func unregister() throws {
        // Avoid prompting for admin credentials when no blessed helper is present on disk.
        guard installedServiceExists() else {
            return
        }

        let authorization = try authorizationProvider.makeAuthorization(
            for: [
                .named(kSMRightModifySystemDaemons),
                .executeTool(TCPViewerNetworkHelperPrivilegedInstalledItemRemover.removalToolPath),
            ]
        )
        defer { authorizationProvider.free(authorization) }

        var jobRemovalError: Error?
        if installedLaunchDaemonPlistExists() {
            do {
                try serviceManagementController.removeJob(label: serviceLabel, authorization: authorization, wait: true)
            } catch {
                jobRemovalError = error
            }
        }

        // SMJobRemove can unload launchd while leaving root-owned SMJobBless files behind.
        try installedItemRemover.removeItems(at: installedItemURLs, authorization: authorization)
        let remainingURLs = installedItemURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard remainingURLs.isEmpty else {
            throw TCPViewerNetworkHelperSMJobBlessError.installedItemsRemain(remainingURLs, underlyingError: jobRemovalError)
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

    private func installedLaunchDaemonPlistExists() -> Bool {
        fileManager.fileExists(atPath: installedLaunchDaemonPlistURL.path)
    }

    private var installedItemURLs: [URL] {
        [installedHelperToolURL, installedLaunchDaemonPlistURL]
    }

    private func validateBundledPayload() throws {
        guard fileManager.fileExists(atPath: bundledHelperToolURL.path) else {
            throw TCPViewerNetworkHelperSMJobBlessError.missingBundledHelper(bundledHelperToolURL)
        }

        guard fileManager.fileExists(atPath: bundledLaunchDaemonPlistURL.path) else {
            throw TCPViewerNetworkHelperSMJobBlessError.missingLaunchDaemonPlist(bundledLaunchDaemonPlistURL)
        }
    }

    private func helperToolVersion(at url: URL) -> String? {
        // Prefer signed helper metadata, then fall back to plist fixtures used by unit tests.
        guard let info = embeddedInfoDictionary(at: url) ?? plistInfoDictionary(at: url) else {
            return nil
        }

        let shortVersion = trimmedInfoValue(info["CFBundleShortVersionString"])
        let buildVersion = trimmedInfoValue(info["CFBundleVersion"])
        switch (shortVersion, buildVersion) {
        case (let short?, let build?):
            return "\(short) (\(build))"
        case (let short?, nil):
            return short
        case (nil, let build?):
            return "build \(build)"
        case (nil, nil):
            return nil
        }
    }

    private func embeddedInfoDictionary(at url: URL) -> [String: Any]? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return nil
        }

        var signingInfo: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard copyStatus == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let plist = info[kSecCodeInfoPList as String] as? [String: Any] else {
            return nil
        }

        return plist
    }

    private func plistInfoDictionary(at url: URL) -> [String: Any]? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
              ) as? [String: Any] else {
            return nil
        }

        return plist
    }

    private func trimmedInfoValue(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}

struct TCPViewerNetworkHelperAuthorizationProvider: TCPViewerNetworkHelperAuthorizationProviding {
    // Create short-lived admin credentials scoped to the requested helper operation.
    func makeAuthorization(for rights: [TCPViewerNetworkHelperAuthorizationRight]) throws -> AuthorizationRef {
        var authorization: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let createStatus = AuthorizationCreate(nil, nil, flags, &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw TCPViewerNetworkHelperSMJobBlessError.authorizationFailure(createStatus)
        }

        do {
            let copyStatus = try withAuthorizationItems(for: rights) { items in
                var authorizationRights = AuthorizationRights(
                    count: UInt32(items.count),
                    items: items.baseAddress
                )
                return AuthorizationCopyRights(authorization, &authorizationRights, nil, flags, nil)
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

    func free(_ authorization: AuthorizationRef) {
        _ = AuthorizationFree(authorization, [])
    }

    private func withAuthorizationItems<Result>(
        for rights: [TCPViewerNetworkHelperAuthorizationRight],
        _ body: (UnsafeMutableBufferPointer<AuthorizationItem>) throws -> Result
    ) throws -> Result {
        let names = rights.map { strdup($0.name)! }
        let values = rights.map { right -> UnsafeMutablePointer<CChar>? in
            guard case .executeTool(let toolPath) = right else {
                return nil
            }
            return strdup(toolPath)
        }
        defer {
            names.forEach { Darwin.free($0) }
            values.forEach { value in
                if let value {
                    Darwin.free(value)
                }
            }
        }

        var items = rights.enumerated().map { index, _ in
            AuthorizationItem(
                name: names[index],
                valueLength: values[index].map { strlen($0) } ?? 0,
                value: values[index].map { UnsafeMutableRawPointer($0) },
                flags: 0
            )
        }
        return try items.withUnsafeMutableBufferPointer { buffer in
            try body(buffer)
        }
    }
}

struct TCPViewerNetworkHelperServiceManagementController: TCPViewerNetworkHelperServiceManagementControlling {
    func blessJob(label: String, authorization: AuthorizationRef) throws {
        var blessError: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, label as CFString, authorization, &blessError) else {
            throw TCPViewerNetworkHelperSMJobBlessError.serviceManagementFailure(
                blessError?.takeRetainedValue(),
                fallbackMessage: "macOS could not install the privileged helper."
            )
        }
    }

    func removeJob(label: String, authorization: AuthorizationRef, wait: Bool) throws {
        var removeError: Unmanaged<CFError>?
        guard SMJobRemove(kSMDomainSystemLaunchd, label as CFString, authorization, wait, &removeError) else {
            throw TCPViewerNetworkHelperSMJobBlessError.serviceManagementFailure(
                removeError?.takeRetainedValue(),
                fallbackMessage: "macOS could not remove the privileged helper."
            )
        }
    }
}

struct TCPViewerNetworkHelperPrivilegedInstalledItemRemover: TCPViewerNetworkHelperInstalledItemRemoving {
    static let removalToolPath = "/bin/rm"

    private typealias ExecuteWithPrivilegesFunction = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func removeItems(at urls: [URL], authorization: AuthorizationRef) throws {
        let existingURLs = urls.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else {
            return
        }

        try executePrivilegedRemove(arguments: ["-f"] + existingURLs.map(\.path), authorization: authorization)

        let remainingURLs = existingURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard remainingURLs.isEmpty else {
            throw TCPViewerNetworkHelperSMJobBlessError.installedItemsRemain(remainingURLs, underlyingError: nil)
        }
    }

    private func executePrivilegedRemove(arguments: [String], authorization: AuthorizationRef) throws {
        var pipe: UnsafeMutablePointer<FILE>?
        let executeWithPrivileges = try Self.loadExecuteWithPrivileges()
        let status = try Self.removalToolPath.withCString { toolPath in
            try arguments.withUnsafeMutableCStringArray { argumentPointer in
                executeWithPrivileges(authorization, toolPath, [], argumentPointer, &pipe)
            }
        }

        guard status == errAuthorizationSuccess else {
            throw TCPViewerNetworkHelperSMJobBlessError.authorizationFailure(status)
        }

        if let pipe {
            drain(pipe)
        }
    }

    private static func loadExecuteWithPrivileges() throws -> ExecuteWithPrivilegesFunction {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            throw TCPViewerNetworkHelperSMJobBlessError.privilegedExecutionUnavailable(Self.dynamicLoaderErrorMessage())
        }

        guard let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else {
            throw TCPViewerNetworkHelperSMJobBlessError.privilegedExecutionUnavailable(Self.dynamicLoaderErrorMessage())
        }

        return unsafeBitCast(symbol, to: ExecuteWithPrivilegesFunction.self)
    }

    private static func dynamicLoaderErrorMessage() -> String {
        guard let message = dlerror() else {
            return "Unknown dynamic loader error."
        }
        return String(cString: message)
    }

    private func drain(_ pipe: UnsafeMutablePointer<FILE>) {
        var buffer = [CChar](repeating: 0, count: 1024)
        while buffer.withUnsafeMutableBufferPointer({ fgets($0.baseAddress, Int32($0.count), pipe) }) != nil {}
        fclose(pipe)
    }
}

private enum TCPViewerNetworkHelperSMJobBlessError: LocalizedError {
    case missingBundledHelper(URL)
    case missingLaunchDaemonPlist(URL)
    case authorizationFailure(OSStatus)
    case serviceManagementFailure(CFError?, fallbackMessage: String)
    case installedItemsRemain([URL], underlyingError: Error?)
    case privilegedExecutionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper(let url):
            return "TCP Viewer could not find the bundled helper at \(url.path)."
        case .missingLaunchDaemonPlist(let url):
            return "TCP Viewer could not find the bundled helper launchd plist at \(url.path)."
        case .authorizationFailure(let status):
            return "macOS authorization failed: \(Self.message(for: status))."
        case .serviceManagementFailure(let error, let fallbackMessage):
            return error?.localizedDescription ?? fallbackMessage
        case .installedItemsRemain(let urls, let underlyingError):
            let paths = urls.map(\.path).joined(separator: ", ")
            if let underlyingError {
                return "macOS could not delete the installed helper files at \(paths): \(underlyingError.localizedDescription)"
            }
            return "macOS could not delete the installed helper files at \(paths)."
        case .privilegedExecutionUnavailable(let message):
            return "macOS could not start the privileged removal tool: \(message)"
        }
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}

private extension Array where Element == String {
    func withUnsafeMutableCStringArray<Result>(
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>>) throws -> Result
    ) throws -> Result {
        let cStrings = map { strdup($0)! }
        defer { cStrings.forEach { Darwin.free($0) } }

        let arguments = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count + 1)
        defer { arguments.deallocate() }

        for (index, cString) in cStrings.enumerated() {
            arguments[index] = cString
        }
        arguments[cStrings.count] = nil

        return try arguments.withMemoryRebound(to: UnsafeMutablePointer<CChar>.self, capacity: cStrings.count + 1) { reboundArguments in
            try body(UnsafePointer(reboundArguments))
        }
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
                message: "TCP Viewer needs the Helper Tool to finish setting up live capture."
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
                message: "TCP Viewer could not find the system resources needed for live capture."
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
            ? "TCP Viewer is ready to capture live traffic."
            : "TCP Viewer needs Helper Tool access to capture live traffic."

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
