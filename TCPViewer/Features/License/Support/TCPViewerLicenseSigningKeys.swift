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
        "tcpviewer-2026-09-07": Data(base64Encoded: "ofl9iAHMKZafSmv2Wsp6j6D6h+/tLujuQX0sRpaVkgE=")!,
    ]
}
