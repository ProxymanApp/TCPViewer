//
//  TCPViewerLicenseSigningKeys.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/7/26.
//

import Foundation

enum TCPViewerLicenseSigningKeys {
    // Deploy the matching private key on the backend before shipping this public key.
    static let publicKeys: [String: Data] = [
        "tcpviewer-2026-09-08": Data(base64Encoded: "907A+t0nMdjrOgoQZmzDZLEQIuiB2B+KTmdC3d3ohAo=")!,
    ]
}
