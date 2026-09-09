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
    case verificationRequired
    case offlineVerificationRequired
    case clockChanged
    case invalidReceipt
    case deviceRevoked
    case licenseDisabled
    case appUpdateRequired
    case temporaryFailure
    case error(String)

    var isTemporary: Bool {
        switch self {
        case .noInternetConnection, .temporaryFailure, .error: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidLicense:
            return "Check the license key in your purchase email. Contact support if you need help."
        case .outOfSeats:
            return "All seats are occupied. Free a seat in License Manager, or add seats to your Team license."
        case .renewalRequired:
            return "This TCP Viewer build was released after your license update window. Your license is still valid for builds released before the update expiry date; download an older build or renew to use this build."
        case .expired:
            return "Updates do not cover this build. Covered releases remain usable; renew to use newer releases."
        case .couldNotGetDeviceUUID:
            return "Could not get this Mac's device identifier."
        case .noInternetConnection:
            return "No internet connection."
        case .verificationRequired:
            return "Connect to the internet to verify this license for this version of TCP Viewer."
        case .offlineVerificationRequired:
            return "Your Team license needs an online check every seven days. Reconnect and retry verification."
        case .clockChanged:
            return "Your Mac’s clock changed. Set the correct date and time, then retry verification online."
        case .invalidReceipt:
            return "The license receipt could not be verified. Reconnect and retry verification."
        case .deviceRevoked:
            return "This Mac was removed in License Manager. Activate the license again to use an available seat."
        case .licenseDisabled:
            return "This license has been disabled. Contact support for help."
        case .appUpdateRequired:
            return "Update TCP Viewer to activate this Team license."
        case .temporaryFailure:
            return "The license server is temporarily unavailable. Please retry shortly."
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
