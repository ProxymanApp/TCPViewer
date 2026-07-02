//
//  WiresharkCriticalExceptionLoggerTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/7/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkCriticalExceptionLoggerTests {

    @Test func runtimeConfigurationUsesTCPViewerOwnedSettingsDirectory() throws {
        let baseURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let configuration = WiresharkRuntimeConfiguration(applicationSupportBaseURL: baseURL)

        let directory = try configuration.createPersonalConfigurationDirectoryIfNeeded()

        #expect(directory == baseURL
            .appendingPathComponent("TCPViewer", isDirectory: true)
            .appendingPathComponent("settings", isDirectory: true)
            .appendingPathComponent("Wireshark", isDirectory: true))
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func writesPrivacySafeCriticalExceptionLog() throws {
        let baseURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let logger = WiresharkCriticalExceptionLogger(
            applicationSupportBaseURL: baseURL,
            bundleInfo: [
                "CFBundleDisplayName": "TCP Viewer",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "45",
                "CFBundleIdentifier": "com.proxyman.tcpviewer",
            ],
            operatingSystemVersion: "macOS Test 1.0",
            architecture: "arm64",
            dateProvider: { Date(timeIntervalSince1970: 0) }
        )
        let report = WiresharkCriticalExceptionReport(
            operation: "running Wireshark second-pass dissection",
            exceptionName: "DissectorError",
            exceptionGroup: 1,
            exceptionCode: 6,
            packetIdentifier: 42,
            reason: "Wireshark raised a critical exception while running Wireshark second-pass dissection. TCP Viewer stopped this operation to keep the app running."
        )

        let logURL = try logger.log(report)
        let content = try String(contentsOf: logURL, encoding: .utf8)

        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: logger.logsDirectoryURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(logURL.lastPathComponent == WiresharkCriticalExceptionLogger.logFileName)
        #expect(content.contains("App Version: 1.2.3"))
        #expect(content.contains("Build Version: 45"))
        #expect(content.contains("macOS: macOS Test 1.0"))
        #expect(content.contains("Operation: running Wireshark second-pass dissection"))
        #expect(content.contains("Exception: DissectorError"))
        #expect(content.contains("Packet Identifier: 42"))
        #expect(!content.contains("Packet Bytes"))
        #expect(!content.contains("File Path"))
        #expect(!content.contains("Interface Name"))
        #expect(!content.contains("api.example.com"))
    }

    @Test func testHookCatchesWiresharkExceptionWithoutAbort() throws {
        let report = try #require(WiresharkExceptionHandlingTestProbe.caughtExceptionReport())

        #expect(report.operation == "testing Wireshark exception handling")
        #expect(report.exceptionName == "DissectorError")
        #expect(report.exceptionGroup == 1)
        #expect(report.exceptionCode == 6)
        #expect(report.packetIdentifier == 42)
        #expect(!report.reason.contains("test-only private message"))
    }

    @Test func sessionCriticalExceptionPathLogsAndThrowsNativeError() throws {
        let baseURL = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let logger = WiresharkCriticalExceptionLogger(
            applicationSupportBaseURL: baseURL,
            bundleInfo: [
                "CFBundleDisplayName": "TCP Viewer",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "45",
                "CFBundleIdentifier": "com.proxyman.tcpviewer",
            ],
            operatingSystemVersion: "macOS Test 1.0",
            architecture: "arm64",
            dateProvider: { Date(timeIntervalSince1970: 1) }
        )
        let session = try WiresharkEpanSession(criticalExceptionLogger: logger)

        do {
            try session.testInjectCriticalException()
            Issue.record("Expected injected Wireshark exception to throw.")
        } catch {
            #expect(NativeErrorIsCriticalWiresharkException(error))
        }

        let content = try String(contentsOf: logger.logFileURL, encoding: .utf8)
        #expect(content.contains("Operation: testing Wireshark session exception handling"))
        #expect(content.contains("Exception: DissectorError"))
        #expect(content.contains("Packet Identifier: 42"))
        #expect(!content.contains("test-only private message"))
        #expect(!content.contains("Packet Bytes"))
        #expect(!content.contains("Interface Name"))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
