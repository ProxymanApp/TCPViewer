//
//  TCPViewerFactoryResetServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 17/5/26.
//

import Foundation
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPViewerFactoryResetServiceTests {
    @Test func resetRemovesLocalFilesAndPreferences() async throws {
        let fixture = try FactoryResetFixture()
        let service = fixture.makeService()
        try fixture.writeLocalState()
        fixture.defaults.set("visible", forKey: "TCPViewer.test.windowState")

        let result = await reset(service, uninstallHelperTool: false)

        try #require(result.get().helperToolSnapshot == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.userDataDirectory.appDirectoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.cacheDirectoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.savedApplicationStateURL.path))
        #expect(fixture.defaults.object(forKey: "TCPViewer.test.windowState") == nil)
    }

    @Test func resetDoesNotUninstallHelperToolWhenUnchecked() async throws {
        let fixture = try FactoryResetFixture()
        let helperToolManager = FakeFactoryResetHelperToolManager()
        let service = fixture.makeService(helperToolManager: helperToolManager)

        let result = await reset(service, uninstallHelperTool: false)

        try #require(result.get().helperToolSnapshot == nil)
        #expect(helperToolManager.uninstallCallCount == 0)
    }

    @Test func resetUninstallsHelperToolWhenChecked() async throws {
        let fixture = try FactoryResetFixture()
        let helperToolManager = FakeFactoryResetHelperToolManager()
        let service = fixture.makeService(helperToolManager: helperToolManager)

        let result = await reset(service, uninstallHelperTool: true)

        try #require(result.get().helperToolSnapshot?.status == .notInstalled)
        #expect(helperToolManager.uninstallCallCount == 1)
    }

    private func reset(
        _ service: TCPViewerFactoryResetService,
        uninstallHelperTool: Bool
    ) async -> Result<TCPViewerFactoryResetResult, Error> {
        await withCheckedContinuation { continuation in
            service.reset(uninstallHelperTool: uninstallHelperTool) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

private struct FactoryResetFixture {
    let rootURL: URL
    let userDataDirectory: TCPViewerUserDataDirectory
    let cacheDirectoryURL: URL
    let savedApplicationStateURL: URL
    let defaults: UserDefaults
    let defaultsDomainName: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewerFactoryResetServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        userDataDirectory = TCPViewerUserDataDirectory(
            applicationSupportBaseURL: rootURL.appendingPathComponent("Application Support", isDirectory: true)
        )
        cacheDirectoryURL = rootURL.appendingPathComponent("Caches/com.proxyman.tcpviewer", isDirectory: true)
        savedApplicationStateURL = rootURL
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("com.proxyman.tcpviewer.savedState", isDirectory: true)
        defaultsDomainName = "TCPViewerFactoryResetServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsDomainName)!
        defaults.removePersistentDomain(forName: defaultsDomainName)
    }

    func makeService(
        helperToolManager: (any TCPViewerNetworkHelperToolManaging)? = nil
    ) -> TCPViewerFactoryResetService {
        TCPViewerFactoryResetService(
            defaults: defaults,
            defaultsDomainName: defaultsDomainName,
            userDataDirectory: userDataDirectory,
            cacheDirectoryURL: cacheDirectoryURL,
            savedApplicationStateURL: savedApplicationStateURL,
            helperToolManager: helperToolManager
        )
    }

    func writeLocalState() throws {
        try FileManager.default.createDirectory(at: userDataDirectory.settingsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedApplicationStateURL, withIntermediateDirectories: true)
        try "settings".write(to: userDataDirectory.settingsFileURL(named: "FactoryReset.json"), atomically: true, encoding: .utf8)
        try "cache".write(to: cacheDirectoryURL.appendingPathComponent("Cache.db"), atomically: true, encoding: .utf8)
        try "window".write(to: savedApplicationStateURL.appendingPathComponent("windows.plist"), atomically: true, encoding: .utf8)
    }
}

private final class FakeFactoryResetHelperToolManager: TCPViewerNetworkHelperToolManaging {
    private(set) var snapshot = TCPViewerNetworkHelperToolSnapshot(
        status: .ready,
        authorizationStatus: .enabled,
        lastCheckedAt: nil,
        message: "Ready",
        installedHelperToolVersion: nil
    )
    private(set) var uninstallCallCount = 0

    func refreshStatus(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func install(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func repair(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func uninstall(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        uninstallCallCount += 1
        snapshot = .notInstalled
        completion(snapshot)
        return snapshot
    }

    func openSystemSettings() {}
}
