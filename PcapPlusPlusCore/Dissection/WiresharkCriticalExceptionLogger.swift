//
//  WiresharkCriticalExceptionLogger.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/7/26.
//

import Foundation
@_implementationOnly import TCPViewerWiresharkEpanShim

struct WiresharkCriticalExceptionReport: Equatable {
    let operation: String
    let exceptionName: String
    let exceptionGroup: UInt
    let exceptionCode: UInt
    let packetIdentifier: UInt64?
    let reason: String

    init(
        operation: String,
        exceptionName: String,
        exceptionGroup: UInt,
        exceptionCode: UInt,
        packetIdentifier: UInt64?,
        reason: String
    ) {
        self.operation = operation
        self.exceptionName = exceptionName
        self.exceptionGroup = exceptionGroup
        self.exceptionCode = exceptionCode
        self.packetIdentifier = packetIdentifier
        self.reason = reason
    }

    init(_ report: TCPViewerWiresharkExceptionReport) {
        self.init(
            operation: Self.string(report.operation) ?? "Wireshark operation",
            exceptionName: Self.string(report.exceptionName) ?? "Unknown",
            exceptionGroup: UInt(report.exceptionGroup),
            exceptionCode: UInt(report.exceptionCode),
            packetIdentifier: report.hasPacketIdentifier ? report.packetIdentifier : nil,
            reason: Self.string(report.reason) ?? "Wireshark raised a critical exception."
        )
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

final class WiresharkCriticalExceptionLogger {
    static let shared = WiresharkCriticalExceptionLogger()

    static let appFolderName = "TCPViewer"
    static let logsFolderName = "Logs"
    static let logFileName = "wireshark-critical-exceptions.log"

    private let fileManager: FileManager
    private let applicationSupportBaseURL: URL
    private let bundleInfo: [String: Any]
    private let operatingSystemVersion: String
    private let architecture: String
    private let dateProvider: () -> Date
    private let queue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.WiresharkCriticalExceptionLogger")

    init(
        fileManager: FileManager = .default,
        applicationSupportBaseURL: URL? = nil,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: String = WiresharkCriticalExceptionLogger.currentArchitecture(),
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.applicationSupportBaseURL = applicationSupportBaseURL ?? Self.defaultApplicationSupportBaseURL(fileManager: fileManager)
        self.bundleInfo = bundleInfo
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
        self.dateProvider = dateProvider
    }

    var logsDirectoryURL: URL {
        applicationSupportBaseURL
            .appendingPathComponent(Self.appFolderName, isDirectory: true)
            .appendingPathComponent(Self.logsFolderName, isDirectory: true)
    }

    var logFileURL: URL {
        logsDirectoryURL.appendingPathComponent(Self.logFileName)
    }

    @discardableResult
    func createLogsDirectoryIfNeeded() throws -> URL {
        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        return logsDirectoryURL
    }

    @discardableResult
    func log(_ report: WiresharkCriticalExceptionReport) throws -> URL {
        try queue.sync {
            try createLogsDirectoryIfNeeded()
            let entry = logEntry(for: report)
            let data = Data(entry.utf8)
            if fileManager.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL, options: .atomic)
            }
            return logFileURL
        }
    }

    private func logEntry(for report: WiresharkCriticalExceptionReport) -> String {
        // Keep this support log narrow and free of packet content or user-identifying paths.
        let timestamp = ISO8601DateFormatter().string(from: dateProvider())
        let packetLine = report.packetIdentifier.map { "Packet Identifier: \($0)" } ?? "Packet Identifier: unavailable"
        return """
        ---
        Timestamp: \(timestamp)
        App Name: \(appName)
        App Version: \(appVersion)
        Build Version: \(buildVersion)
        Bundle Identifier: \(bundleIdentifier)
        macOS: \(operatingSystemVersion)
        Architecture: \(architecture)
        Operation: \(report.operation)
        Exception: \(report.exceptionName)
        Exception Group: \(report.exceptionGroup)
        Exception Code: \(report.exceptionCode)
        \(packetLine)
        Reason: \(report.reason)

        """
    }

    private var appName: String {
        firstNonEmptyString(in: bundleInfo, keys: ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"]) ?? "TCP Viewer"
    }

    private var appVersion: String {
        nonEmpty(bundleInfo["CFBundleShortVersionString"] as? String) ?? "Unknown"
    }

    private var buildVersion: String {
        nonEmpty(bundleInfo["CFBundleVersion"] as? String) ?? "Unknown"
    }

    private var bundleIdentifier: String {
        nonEmpty(bundleInfo["CFBundleIdentifier"] as? String) ?? "Unknown"
    }

    private func firstNonEmptyString(in bundleInfo: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmpty(bundleInfo[key] as? String) {
                return value
            }
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }
        return trimmedValue
    }

    private static func defaultApplicationSupportBaseURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "Unknown"
        #endif
    }
}

#if DEBUG
enum WiresharkExceptionHandlingTestProbe {
    static func caughtExceptionReport() -> WiresharkCriticalExceptionReport? {
        guard let reportPointer = TCPViewerWiresharkTestCopyCaughtExceptionReport() else {
            return nil
        }
        defer { TCPViewerWiresharkExceptionReportDestroy(reportPointer) }
        return WiresharkCriticalExceptionReport(reportPointer.pointee)
    }
}
#endif
