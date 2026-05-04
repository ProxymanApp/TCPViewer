//
//  TCPViewerLicenseAppVersion.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation

struct TCPViewerLicenseAppVersion {
    static let current = TCPViewerLicenseAppVersion(bundleInfo: Bundle.main.infoDictionary ?? [:])

    let appVersion: String
    let buildNumber: String

    init(bundleInfo: [String: Any]) {
        self.appVersion = bundleInfo["CFBundleShortVersionString"] as? String ?? "Unknown"
        self.buildNumber = bundleInfo["CFBundleVersion"] as? String ?? "Unknown"
    }
}
