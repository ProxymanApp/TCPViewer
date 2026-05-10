//
//  TCPViewerAboutInfo.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/5/26.
//

import Darwin
import Foundation

struct TCPViewerAboutInfo: Equatable {
    static let current = TCPViewerAboutInfo()

    let appName: String
    let appVersion: String
    let buildVersion: String
    let bundleIdentifier: String
    let operatingSystemVersion: String
    let hardwareModel: String
    let architecture: String

    init(
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        processNameFallback: String = ProcessInfo.processInfo.processName,
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: String = Self.currentHardwareModel(),
        architecture: String = Self.currentArchitecture()
    ) {
        self.appName = Self.firstNonEmptyString(
            in: bundleInfo,
            keys: ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"]
        ) ?? Self.nonEmpty(processNameFallback) ?? "TCP Viewer"
        self.appVersion = Self.nonEmpty(bundleInfo["CFBundleShortVersionString"] as? String) ?? "Unknown"
        self.buildVersion = Self.nonEmpty(bundleInfo["CFBundleVersion"] as? String) ?? "Unknown"
        self.bundleIdentifier = Self.nonEmpty(bundleInfo["CFBundleIdentifier"] as? String) ?? "Unknown"
        self.operatingSystemVersion = Self.nonEmpty(operatingSystemVersion) ?? "Unknown"
        self.hardwareModel = Self.nonEmpty(hardwareModel) ?? "Unknown"
        self.architecture = Self.nonEmpty(architecture) ?? "Unknown"
    }

    var versionDisplayText: String {
        "Version \(appVersion) (Build \(buildVersion))"
    }

    var appVersionCopyText: String {
        """
        App Name: \(appName)
        App Version: \(appVersion)
        Build Version: \(buildVersion)
        """
    }

    var debugInformationText: String {
        // Keep this intentionally narrow so support receives useful context without private identifiers.
        [
            "App Name: \(appName)",
            "App Version: \(appVersion)",
            "Build Version: \(buildVersion)",
            "Bundle Identifier: \(bundleIdentifier)",
            "macOS: \(operatingSystemVersion)",
            "Mac Model: \(hardwareModel)",
            "Architecture: \(architecture)",
        ].joined(separator: "\n")
    }

    private static func firstNonEmptyString(in bundleInfo: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmpty(bundleInfo[key] as? String) {
                return value
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }
        return trimmedValue
    }

    private static func currentHardwareModel() -> String {
        // sysctl exposes the public model identifier, not serial number or computer name.
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown"
        }

        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return "Unknown"
        }

        return nonEmpty(String(cString: model)) ?? "Unknown"
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
