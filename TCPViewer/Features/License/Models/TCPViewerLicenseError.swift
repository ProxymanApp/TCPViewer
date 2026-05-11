//
//  TCPViewerLicenseError.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation

enum TCPViewerLicenseError: Error, Equatable, LocalizedError {
    case invalidLicense
    case outOfSeats
    case renewalRequired
    case expired
    case couldNotGetDeviceUUID
    case noInternetConnection
    case error(String)

    var errorDescription: String? {
        switch self {
        case .invalidLicense:
            return "Invalid license key."
        case .outOfSeats:
            return "Your license has no available device seats."
        case .renewalRequired:
            return "This TCP Viewer build was released after your license update window. Your license is still valid for builds released before the update expiry date; download an older build or renew to use this build."
        case .expired:
            return "Your license is expired."
        case .couldNotGetDeviceUUID:
            return "Could not get this Mac's device identifier."
        case .noInternetConnection:
            return "No internet connection."
        case .error(let message):
            return message
        }
    }
}

enum TCPViewerLicenseStatus: Equatable {
    case authorized(TCPViewerLicense)
    case unauthorized(TCPViewerLicenseError)

    var isAuthorized: Bool {
        switch self {
        case .authorized:
            return true
        case .unauthorized:
            return false
        }
    }

    var license: TCPViewerLicense? {
        switch self {
        case .authorized(let license):
            return license
        case .unauthorized:
            return nil
        }
    }
}
