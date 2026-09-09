//
//  TCPViewerLicenseReceipt.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/7/26.
//

import CryptoKit
import Foundation

struct TCPViewerLicenseReceipt: Codable, Equatable {
    let version: Int
    let keyId: String
    let payload: String
    let signature: String
}

struct TCPViewerLicenseReceiptClaims: Codable, Equatable {
    let activationId: String
    let activationTokenHash: String
    let productID: String
    let device_uuid: String
    let licenseType: TCPViewerLicenseType
    let email: String
    let purchaseAt: String
    let expiryAt: String
    let numberOfSeats: Int
    let usedSeats: Int
    let buildNumber: String
    let issuedAt: TimeInterval
    let offlineUntil: TimeInterval?
}

struct TCPViewerLicenseReceiptVerifier {
    let publicKeys: [String: Data]

    init(publicKeys: [String: Data] = TCPViewerLicenseSigningKeys.publicKeys) {
        self.publicKeys = publicKeys
    }

    // Authenticate the exact wire bytes before decoding; only signed fields become entitlements.
    func verify(_ license: TCPViewerLicense, deviceMatches: (String) -> Bool,
                buildNumber: String, now: Date) throws -> (TCPViewerLicense, TCPViewerLicenseReceiptClaims) {
        guard let receipt = license.receipt else { throw TCPViewerLicenseError.verificationRequired }
        guard receipt.version == 1, receipt.payload.count <= 16384,
              let keyData = publicKeys[receipt.keyId],
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Self.decodeBase64URL(receipt.signature),
              let payload = Self.decodeBase64URL(receipt.payload),
              key.isValidSignature(signature, for: Data("1.\(receipt.keyId).\(receipt.payload)".utf8)),
              let claims = try? JSONDecoder().decode(TCPViewerLicenseReceiptClaims.self, from: payload) else {
            throw TCPViewerLicenseError.invalidReceipt
        }
        let tokenHash = SHA256.hash(data: Data(license.signature.utf8)).map { String(format: "%02x", $0) }.joined()
        guard claims.productID == "com.proxyman.TCPViewer",
              !claims.activationId.isEmpty, claims.activationTokenHash == tokenHash,
              deviceMatches(claims.device_uuid), claims.device_uuid == license.deviceUUID,
              claims.numberOfSeats > 0, claims.usedSeats >= 0, claims.usedSeats <= claims.numberOfSeats,
              let purchase = TCPViewerLicenseDateParser.date(from: claims.purchaseAt),
              let expiry = TCPViewerLicenseDateParser.date(from: claims.expiryAt), expiry >= purchase,
              claims.issuedAt > 0, claims.issuedAt <= now.timeIntervalSince1970 + 300 else {
            throw TCPViewerLicenseError.invalidReceipt
        }
        guard claims.buildNumber == buildNumber else { throw TCPViewerLicenseError.verificationRequired }
        if claims.licenseType == .teamLicense {
            guard claims.numberOfSeats >= 5, let deadline = claims.offlineUntil,
                  deadline == claims.issuedAt + 7 * 86400 else { throw TCPViewerLicenseError.invalidReceipt }
            guard now.timeIntervalSince1970 < deadline else { throw TCPViewerLicenseError.offlineVerificationRequired }
        } else if claims.offlineUntil != nil {
            throw TCPViewerLicenseError.invalidReceipt
        }
        let authenticated = TCPViewerLicense(signature: license.signature, deviceUUID: claims.device_uuid,
            email: claims.email, purchaseAt: claims.purchaseAt, expiryDate: claims.expiryAt,
            licenseType: claims.licenseType, receipt: receipt, activationId: claims.activationId,
            numberOfSeats: claims.numberOfSeats, usedSeats: claims.usedSeats)
        return (authenticated, claims)
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}
