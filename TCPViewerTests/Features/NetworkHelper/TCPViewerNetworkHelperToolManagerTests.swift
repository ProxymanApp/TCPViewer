//
//  TCPViewerNetworkHelperToolManagerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
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

    @Test func userFacingSnapshotTextUsesTCPViewerDisplayName() {
        #expect(TCPViewerNetworkHelperToolSnapshot.notInstalled.message == "TCP Viewer Network Helper Tool is not installed.")
        #expect(TCPViewerNetworkHelperToolSnapshot.notInstalled.title == "Install TCP Viewer Network Helper Tool")
    }

    private func makeManager(
        current: FakeNetworkHelperServiceController,
        legacy: [FakeNetworkHelperServiceController] = []
    ) -> TCPViewerNetworkHelperToolManager {
        TCPViewerNetworkHelperToolManager(
            serviceController: current,
            legacyServiceControllers: legacy,
            bpfChecker: ReadyNetworkHelperBPFChecker()
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

    private func makeBlessController(fixture: BlessFixture) -> TCPViewerNetworkHelperSMJobBlessController {
        TCPViewerNetworkHelperSMJobBlessController(
            bundleURL: fixture.bundleURL,
            privilegedHelperToolsDirectoryURL: fixture.privilegedHelperToolsDirectoryURL,
            launchDaemonsDirectoryURL: fixture.launchDaemonsDirectoryURL
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
}

private struct BlessFixture {
    let rootURL: URL
    let bundleURL: URL
    let privilegedHelperToolsDirectoryURL: URL
    let launchDaemonsDirectoryURL: URL
}

private final class FakeNetworkHelperServiceController: TCPViewerNetworkHelperServiceControlling {
    private let lock = NSLock()
    private var storedStatus: TCPViewerNetworkHelperAuthorizationStatus
    private let registerError: Error?
    private let unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        status: TCPViewerNetworkHelperAuthorizationStatus,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.storedStatus = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var status: TCPViewerNetworkHelperAuthorizationStatus {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
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
            message: "TCP Viewer can access 2 packet-capture devices."
        )
    }
}

private enum FakeNetworkHelperError: LocalizedError {
    case intentionalFailure

    var errorDescription: String? {
        "Intentional failure"
    }
}
