//
//  TCPViewerNetworkHelperToolManagerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import Security
import Testing
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct TCPViewerNetworkHelperToolManagerTests {
    @Test func installRegistersCurrentHelperAndCleansLegacyHelpers() async {
        let current = FakeNetworkHelperServiceController(status: .notRegistered)
        let legacyOriginal = FakeNetworkHelperServiceController(status: .enabled)
        let legacyIntermediate = FakeNetworkHelperServiceController(status: .enabled)
        let manager = makeManager(current: current, legacy: [legacyOriginal, legacyIntermediate])

        let snapshot = await install(manager)

        #expect(current.registerCallCount == 1)
        #expect(legacyOriginal.unregisterCallCount == 1)
        #expect(legacyIntermediate.unregisterCallCount == 1)
        #expect(snapshot.status == .ready)
    }

    @Test func legacyCleanupFailureDoesNotHideSuccessfulInstall() async {
        let current = FakeNetworkHelperServiceController(status: .notRegistered)
        let legacy = FakeNetworkHelperServiceController(
            status: .enabled,
            unregisterError: FakeNetworkHelperError.intentionalFailure
        )
        let manager = makeManager(current: current, legacy: [legacy])

        let snapshot = await install(manager)

        #expect(current.registerCallCount == 1)
        #expect(legacy.unregisterCallCount == 1)
        #expect(snapshot.status == .ready)
    }

    @Test func uninstallAttemptsCurrentAndLegacyHelpers() async {
        let current = FakeNetworkHelperServiceController(status: .enabled)
        let legacyOriginal = FakeNetworkHelperServiceController(status: .enabled)
        let legacyIntermediate = FakeNetworkHelperServiceController(status: .enabled)
        let manager = makeManager(current: current, legacy: [legacyOriginal, legacyIntermediate])

        let snapshot = await uninstall(manager)

        #expect(current.unregisterCallCount == 1)
        #expect(legacyOriginal.unregisterCallCount == 1)
        #expect(legacyIntermediate.unregisterCallCount == 1)
        #expect(snapshot.status == .notInstalled)
    }

    @Test func installSuccessLogsDebugStatus() async {
        let logs = LockedLogSink()
        let manager = makeManager(
            current: FakeNetworkHelperServiceController(status: .notRegistered),
            logger: TCPViewerNetworkHelperLogger(output: logs.append)
        )

        _ = await install(manager)

        #expect(logs.messages.contains { $0.contains("🔧 DEBUG") && $0.contains("✅ Install helper tool succeeded") })
    }

    @Test func installFailureLogsUnderlyingError() async {
        let logs = LockedLogSink()
        let manager = makeManager(
            current: FakeNetworkHelperServiceController(
                status: .notRegistered,
                registerError: FakeNetworkHelperError.intentionalFailure
            ),
            logger: TCPViewerNetworkHelperLogger(output: logs.append)
        )

        _ = await install(manager)

        #expect(logs.messages.contains { $0.contains("❌ ERROR") && $0.contains("Install helper tool failed") })
        #expect(logs.messages.contains { $0.contains("Intentional failure") })
    }

    @Test func uninstallFailureLogsUnderlyingError() async {
        let logs = LockedLogSink()
        let manager = makeManager(
            current: FakeNetworkHelperServiceController(
                status: .enabled,
                unregisterError: FakeNetworkHelperError.intentionalFailure
            ),
            logger: TCPViewerNetworkHelperLogger(output: logs.append)
        )

        _ = await uninstall(manager)

        #expect(logs.messages.contains { $0.contains("❌ ERROR") && $0.contains("Remove helper tool failed") })
        #expect(logs.messages.contains { $0.contains("Intentional failure") })
    }

    @Test func launchStatusLogsErrorWhenHelperIsNotReady() async {
        let logs = LockedLogSink()
        let manager = TCPViewerNetworkHelperToolManager(
            serviceController: FakeNetworkHelperServiceController(status: .notRegistered),
            bpfChecker: ReadyNetworkHelperBPFChecker(),
            logger: TCPViewerNetworkHelperLogger(output: logs.append)
        )

        _ = await refreshStatusForLaunch(manager)

        #expect(logs.messages.contains { $0.contains("❌ ERROR") && $0.contains("Launch helper status failed") })
    }

    @Test func launchStatusLogsInstalledHelperVersion() async throws {
        let logs = LockedLogSink()
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let installedHelperURL = fixture.privilegedHelperToolsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.serviceLabel)
        try createHelperInfoPlist(at: installedHelperURL, shortVersion: "2.3", buildVersion: "45")
        let manager = TCPViewerNetworkHelperToolManager(
            serviceController: makeBlessController(fixture: fixture),
            bpfChecker: ReadyNetworkHelperBPFChecker(),
            logger: TCPViewerNetworkHelperLogger(output: logs.append)
        )

        _ = await refreshStatusForLaunch(manager)

        #expect(logs.messages.contains {
            $0.contains("Launch helper status succeeded") && $0.contains("installedVersion=2.3 (45)")
        })
    }

    @Test func constantsUseTCPViewerHelperIdentityAndFreshCaptureGroup() {
        #expect(TCPViewerNetworkHelperConstants.serviceLabel == "com.proxyman.tcpviewer.helpertool")
        #expect(TCPViewerNetworkHelperConstants.launchDaemonPlistName == "com.proxyman.tcpviewer.helpertool.plist")
        #expect(TCPViewerNetworkHelperConstants.bundledHelperToolRelativePath == "Contents/Library/LaunchServices/com.proxyman.tcpviewer.helpertool")
        #expect(TCPViewerNetworkHelperConstants.captureGroupName == "tcpviewer_capture")
        #expect(TCPViewerNetworkHelperConstants.displayName == "TCP Viewer Network Helper Tool")
    }

    @Test func smJobBlessStatusReportsNotFoundWhenBundledPayloadIsMissing() throws {
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let controller = makeBlessController(fixture: fixture)

        #expect(controller.status == .notFound)
    }

    @Test func smJobBlessStatusReportsNotRegisteredWhenBundledPayloadExists() throws {
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try createBundledBlessPayload(in: fixture.bundleURL)

        let controller = makeBlessController(fixture: fixture)

        #expect(controller.status == .notRegistered)
    }

    @Test func smJobBlessStatusReportsEnabledWhenInstalledHelperExists() throws {
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let installedHelperURL = fixture.privilegedHelperToolsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.serviceLabel)
        try createEmptyFile(at: installedHelperURL)

        let controller = makeBlessController(fixture: fixture)

        #expect(controller.status == .enabled)
    }

    @Test func smJobBlessUnregisterDeletesInstalledHelperFilesWhenLaunchdRemoveSucceeds() throws {
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try createBundledBlessPayload(in: fixture.bundleURL)
        let installedHelperURL = fixture.privilegedHelperToolsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.serviceLabel)
        let installedPlistURL = fixture.launchDaemonsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.launchDaemonPlistName)
        try createEmptyFile(at: installedHelperURL)
        try createEmptyFile(at: installedPlistURL)
        let serviceManagement = FakeNetworkHelperServiceManagementController()
        let remover = FakeNetworkHelperInstalledItemRemover()
        let controller = makeBlessController(
            fixture: fixture,
            serviceManagementController: serviceManagement,
            installedItemRemover: remover
        )

        try controller.unregister()

        #expect(serviceManagement.removeJobCallCount == 1)
        #expect(remover.removedURLs.map(\.path).contains(installedHelperURL.path))
        #expect(remover.removedURLs.map(\.path).contains(installedPlistURL.path))
        #expect(!FileManager.default.fileExists(atPath: installedHelperURL.path))
        #expect(!FileManager.default.fileExists(atPath: installedPlistURL.path))
        #expect(controller.status == .notRegistered)
    }

    @Test func smJobBlessUnregisterCleansFilesWhenLaunchdJobIsAlreadyMissing() throws {
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try createBundledBlessPayload(in: fixture.bundleURL)
        let installedHelperURL = fixture.privilegedHelperToolsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.serviceLabel)
        let installedPlistURL = fixture.launchDaemonsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.launchDaemonPlistName)
        try createEmptyFile(at: installedHelperURL)
        try createEmptyFile(at: installedPlistURL)
        let serviceManagement = FakeNetworkHelperServiceManagementController(removeError: FakeNetworkHelperError.intentionalFailure)
        let controller = makeBlessController(fixture: fixture, serviceManagementController: serviceManagement)

        try controller.unregister()

        #expect(serviceManagement.removeJobCallCount == 1)
        #expect(!FileManager.default.fileExists(atPath: installedHelperURL.path))
        #expect(!FileManager.default.fileExists(atPath: installedPlistURL.path))
        #expect(controller.status == .notRegistered)
    }

    @Test func smJobBlessUnregisterSkipsLaunchdRemoveForStaleHelperOnlyInstall() throws {
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try createBundledBlessPayload(in: fixture.bundleURL)
        let installedHelperURL = fixture.privilegedHelperToolsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.serviceLabel)
        try createEmptyFile(at: installedHelperURL)
        let serviceManagement = FakeNetworkHelperServiceManagementController()
        let controller = makeBlessController(fixture: fixture, serviceManagementController: serviceManagement)

        try controller.unregister()

        #expect(serviceManagement.removeJobCallCount == 0)
        #expect(!FileManager.default.fileExists(atPath: installedHelperURL.path))
        #expect(controller.status == .notRegistered)
    }

    @Test func smJobBlessUnregisterThrowsWhenInstalledFileCleanupFails() throws {
        let fixture = try makeBlessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let installedHelperURL = fixture.privilegedHelperToolsDirectoryURL
            .appendingPathComponent(TCPViewerNetworkHelperConstants.serviceLabel)
        try createEmptyFile(at: installedHelperURL)
        let remover = FakeNetworkHelperInstalledItemRemover(removeError: FakeNetworkHelperError.intentionalFailure)
        let controller = makeBlessController(fixture: fixture, installedItemRemover: remover)

        var didThrow = false
        do {
            try controller.unregister()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: installedHelperURL.path))
    }

    @Test func userFacingSnapshotTextUsesTCPViewerDisplayName() {
        #expect(TCPViewerNetworkHelperToolSnapshot.notInstalled.message == "TCP Viewer Network Helper Tool is not installed.")
        #expect(TCPViewerNetworkHelperToolSnapshot.notInstalled.title == "Install TCP Viewer Network Helper Tool")
    }

    private func makeManager(
        current: FakeNetworkHelperServiceController,
        legacy: [FakeNetworkHelperServiceController] = [],
        logger: TCPViewerNetworkHelperLogger = TCPViewerNetworkHelperLogger(output: { _ in })
    ) -> TCPViewerNetworkHelperToolManager {
        TCPViewerNetworkHelperToolManager(
            serviceController: current,
            legacyServiceControllers: legacy,
            bpfChecker: ReadyNetworkHelperBPFChecker(),
            logger: logger
        )
    }

    private func install(_ manager: TCPViewerNetworkHelperToolManager) async -> TCPViewerNetworkHelperToolSnapshot {
        await withCheckedContinuation { continuation in
            manager.install { snapshot in
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func uninstall(_ manager: TCPViewerNetworkHelperToolManager) async -> TCPViewerNetworkHelperToolSnapshot {
        await withCheckedContinuation { continuation in
            manager.uninstall { snapshot in
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func refreshStatusForLaunch(_ manager: TCPViewerNetworkHelperToolManager) async -> TCPViewerNetworkHelperToolSnapshot {
        await withCheckedContinuation { continuation in
            manager.refreshStatusForLaunch { snapshot in
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func makeBlessFixture() throws -> BlessFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewerNetworkHelperToolManagerTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("TCP Viewer.app", isDirectory: true)
        let privilegedHelperToolsDirectoryURL = rootURL.appendingPathComponent("PrivilegedHelperTools", isDirectory: true)
        let launchDaemonsDirectoryURL = rootURL.appendingPathComponent("LaunchDaemons", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privilegedHelperToolsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchDaemonsDirectoryURL, withIntermediateDirectories: true)

        return BlessFixture(
            rootURL: rootURL,
            bundleURL: bundleURL,
            privilegedHelperToolsDirectoryURL: privilegedHelperToolsDirectoryURL,
            launchDaemonsDirectoryURL: launchDaemonsDirectoryURL
        )
    }

    private func makeBlessController(
        fixture: BlessFixture,
        serviceManagementController: any TCPViewerNetworkHelperServiceManagementControlling = FakeNetworkHelperServiceManagementController(),
        installedItemRemover: any TCPViewerNetworkHelperInstalledItemRemoving = FakeNetworkHelperInstalledItemRemover()
    ) -> TCPViewerNetworkHelperSMJobBlessController {
        TCPViewerNetworkHelperSMJobBlessController(
            bundleURL: fixture.bundleURL,
            privilegedHelperToolsDirectoryURL: fixture.privilegedHelperToolsDirectoryURL,
            launchDaemonsDirectoryURL: fixture.launchDaemonsDirectoryURL,
            authorizationProvider: FakeNetworkHelperAuthorizationProvider(),
            serviceManagementController: serviceManagementController,
            installedItemRemover: installedItemRemover
        )
    }

    private func createBundledBlessPayload(in bundleURL: URL) throws {
        let helperURL = bundleURL.appendingPathComponent(TCPViewerNetworkHelperConstants.bundledHelperToolRelativePath)
        let launchDaemonPlistURL = bundleURL.appendingPathComponent(TCPViewerNetworkHelperConstants.bundledLaunchDaemonPlistRelativePath)
        try createEmptyFile(at: helperURL)
        try createEmptyFile(at: launchDaemonPlistURL)
    }

    private func createEmptyFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func createHelperInfoPlist(at url: URL, shortVersion: String, buildVersion: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = [
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": buildVersion,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }
}

private struct BlessFixture {
    let rootURL: URL
    let bundleURL: URL
    let privilegedHelperToolsDirectoryURL: URL
    let launchDaemonsDirectoryURL: URL
}

private final class LockedLogSink {
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedMessages
    }

    func append(_ message: String) {
        lock.lock()
        storedMessages.append(message)
        lock.unlock()
    }
}

private final class FakeNetworkHelperServiceController: TCPViewerNetworkHelperServiceControlling {
    private let lock = NSLock()
    private var storedStatus: TCPViewerNetworkHelperAuthorizationStatus
    private let registerError: Error?
    private let unregisterError: Error?
    private let storedInstalledHelperToolVersion: String?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        status: TCPViewerNetworkHelperAuthorizationStatus,
        registerError: Error? = nil,
        unregisterError: Error? = nil,
        installedHelperToolVersion: String? = nil
    ) {
        self.storedStatus = status
        self.registerError = registerError
        self.unregisterError = unregisterError
        self.storedInstalledHelperToolVersion = installedHelperToolVersion
    }

    var status: TCPViewerNetworkHelperAuthorizationStatus {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    var installedHelperToolVersion: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus == .enabled ? storedInstalledHelperToolVersion : nil
    }

    func register() throws {
        lock.lock()
        defer { lock.unlock() }
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        storedStatus = .enabled
    }

    func unregister() throws {
        lock.lock()
        defer { lock.unlock() }
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        storedStatus = .notRegistered
    }

    func openSystemSettings() {}
}

private struct ReadyNetworkHelperBPFChecker: TCPViewerNetworkHelperBPFChecking {
    func inspect() -> TCPViewerNetworkHelperBPFInspection {
        TCPViewerNetworkHelperBPFInspection(
            groupExists: true,
            deviceCount: 2,
            expectedPermissionsReady: true,
            currentProcessHasCaptureGroup: true,
            currentProcessCanAccessBPF: true,
            message: "TCP Viewer is ready to capture live traffic."
        )
    }
}

private enum FakeNetworkHelperError: LocalizedError {
    case intentionalFailure

    var errorDescription: String? {
        "Intentional failure"
    }
}

private final class FakeNetworkHelperAuthorizationProvider: TCPViewerNetworkHelperAuthorizationProviding {
    private(set) var requestedRights: [[TCPViewerNetworkHelperAuthorizationRight]] = []

    func makeAuthorization(for rights: [TCPViewerNetworkHelperAuthorizationRight]) throws -> AuthorizationRef {
        requestedRights.append(rights)
        var authorization: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw FakeNetworkHelperError.intentionalFailure
        }
        return authorization
    }

    func free(_ authorization: AuthorizationRef) {
        _ = AuthorizationFree(authorization, [])
    }
}

private final class FakeNetworkHelperServiceManagementController: TCPViewerNetworkHelperServiceManagementControlling {
    private let blessError: Error?
    private let removeError: Error?
    private(set) var blessJobCallCount = 0
    private(set) var removeJobCallCount = 0

    init(blessError: Error? = nil, removeError: Error? = nil) {
        self.blessError = blessError
        self.removeError = removeError
    }

    func blessJob(label: String, authorization: AuthorizationRef) throws {
        blessJobCallCount += 1
        if let blessError {
            throw blessError
        }
    }

    func removeJob(label: String, authorization: AuthorizationRef, wait: Bool) throws {
        removeJobCallCount += 1
        if let removeError {
            throw removeError
        }
    }
}

private final class FakeNetworkHelperInstalledItemRemover: TCPViewerNetworkHelperInstalledItemRemoving {
    private let removeError: Error?
    private(set) var removedURLs: [URL] = []

    init(removeError: Error? = nil) {
        self.removeError = removeError
    }

    func removeItems(at urls: [URL], authorization: AuthorizationRef) throws {
        removedURLs = urls
        if let removeError {
            throw removeError
        }

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
