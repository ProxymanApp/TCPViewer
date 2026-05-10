//
//  TCPViewerAboutInfoTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/5/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerAboutInfoTests {
    @Test func appVersionCopyTextContainsVisibleVersionDetails() {
        let info = Self.makeInfo()

        #expect(info.appVersionCopyText == """
        App Name: TCP Viewer
        App Version: 1.2.3
        Build Version: 45
        """)
    }

    @Test func debugInformationUsesBasicNonPrivateFieldsOnly() {
        let info = Self.makeInfo()

        #expect(info.debugInformationText == """
        App Name: TCP Viewer
        App Version: 1.2.3
        Build Version: 45
        Bundle Identifier: com.proxyman.tcpviewer
        macOS: Version 15.6 (Build 24G84)
        Mac Model: Mac16,1
        Architecture: arm64
        """)
    }

    @Test func emptyBundleValuesFallBackToUnknown() {
        let info = TCPViewerAboutInfo(
            bundleInfo: [:],
            processNameFallback: "",
            operatingSystemVersion: "",
            hardwareModel: "",
            architecture: ""
        )

        #expect(info.appName == "TCP Viewer")
        #expect(info.appVersion == "Unknown")
        #expect(info.buildVersion == "Unknown")
        #expect(info.bundleIdentifier == "Unknown")
        #expect(info.operatingSystemVersion == "Unknown")
        #expect(info.hardwareModel == "Unknown")
        #expect(info.architecture == "Unknown")
    }

    private static func makeInfo() -> TCPViewerAboutInfo {
        TCPViewerAboutInfo(
            bundleInfo: [
                "CFBundleDisplayName": "TCP Viewer",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "45",
                "CFBundleIdentifier": "com.proxyman.tcpviewer",
            ],
            operatingSystemVersion: "Version 15.6 (Build 24G84)",
            hardwareModel: "Mac16,1",
            architecture: "arm64"
        )
    }
}
