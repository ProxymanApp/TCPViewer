//
//  TCPViewerLicenseWebsiteService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import AppKit
import Foundation

enum TCPViewerLicenseWebsiteService {
    enum WebsiteURL: String {
        case buyLicense = "https://tcpviewer.proxyman.com/pricing"
        case renewLicense = "https://tcpviewer.proxyman.com/pricing#renew"
        case licenseManager = "https://tcpviewer.proxyman.com/license-manager/access-link"
        case support = "mailto:tcpviewer@proxyman.com"
    }

    static func open(_ websiteURL: WebsiteURL) {
        guard let url = URL(string: websiteURL.rawValue) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
