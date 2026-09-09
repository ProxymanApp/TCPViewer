//
//  TCPViewerLicenseReceiptTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/7/26.
//

import CryptoKit
import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerLicenseReceiptTests {
    @Test func authenticatesSharedNodeFixture() throws {
        struct Fixture: Decodable { let publicKey: String; let now: TimeInterval; let license: TCPViewerLicense }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/license-receipt-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let verifier = TCPViewerLicenseReceiptVerifier(publicKeys: ["cross-language-fixture": Data(base64Encoded: fixture.publicKey)!])
        let (license, claims) = try verifier.verify(fixture.license, deviceMatches: { $0 == "fixture-mac" }, buildNumber: "999", now: Date(timeIntervalSince1970: fixture.now))
        #expect(license.licenseType == .teamLicense)
        #expect(claims.offlineUntil == fixture.now + 604800)
        #expect(license.expiryDate.hasPrefix("2028-01-01"))
    }

    @Test func rejectsTamperedSignaturePayloadVersionAndUnknownKey() throws {
        let rig = LicenseTestRig(); let license = try rig.signed(); let receipt = try #require(license.receipt)
        let variants = [
            TCPViewerLicenseReceipt(version: 1, keyId: "test", payload: receipt.payload + "x", signature: receipt.signature),
            TCPViewerLicenseReceipt(version: 1, keyId: "test", payload: receipt.payload, signature: Data(repeating: 0, count: 64).licenseBase64URL),
            TCPViewerLicenseReceipt(version: 2, keyId: "test", payload: receipt.payload, signature: receipt.signature),
            TCPViewerLicenseReceipt(version: 1, keyId: "unknown", payload: receipt.payload, signature: receipt.signature),
        ]
        for receipt in variants {
            var altered = license; altered.receipt = receipt
            #expect(throws: TCPViewerLicenseError.invalidReceipt) { try verifier(rig).verify(altered, deviceMatches: { _ in true }, buildNumber: "999", now: rig.date) }
        }
    }

    @Test func rejectsWrongMacBuildAndActivationCredential() throws {
        let rig = LicenseTestRig(); let license = try rig.signed()
        #expect(throws: TCPViewerLicenseError.invalidReceipt) { try verifier(rig).verify(license, deviceMatches: { _ in false }, buildNumber: "999", now: rig.date) }
        #expect(throws: TCPViewerLicenseError.verificationRequired) { try verifier(rig).verify(license, deviceMatches: { _ in true }, buildNumber: "1000", now: rig.date) }
        var altered = license; altered.signature = "stolen-other-token"
        #expect(throws: TCPViewerLicenseError.invalidReceipt) { try verifier(rig).verify(altered, deviceMatches: { _ in true }, buildNumber: "999", now: rig.date) }
    }

    @Test func trustsOnlySignedFieldsAndEnforcesExactDeadline() throws {
        let rig = LicenseTestRig(); var license = try rig.signed()
        license.expiryDate = "2099-01-01T00:00:00Z"; license.numberOfSeats = 999
        let (verified, _) = try verifier(rig).verify(license, deviceMatches: { _ in true }, buildNumber: "999", now: rig.date)
        #expect(verified.expiryDate == "2028-01-01T23:59:59.999Z"); #expect(verified.numberOfSeats == 5)
        _ = try verifier(rig).verify(license, deviceMatches: { _ in true }, buildNumber: "999", now: rig.date.addingTimeInterval(604799))
        #expect(throws: TCPViewerLicenseError.offlineVerificationRequired) {
            try verifier(rig).verify(license, deviceMatches: { _ in true }, buildNumber: "999", now: rig.date.addingTimeInterval(604800))
        }
    }

    @Test func rejectsSignedReceiptsWithInvalidProductSeatBoundsAndOfflineTerms() throws {
        let rig = LicenseTestRig(); let license = try rig.signed(); let receipt = try #require(license.receipt)
        let original = try #require(TCPViewerLicenseReceiptVerifier.decodeBase64URL(receipt.payload))
        for (field, value) in [("productID", "another-app" as Any), ("numberOfSeats", 4), ("usedSeats", 6), ("offlineUntil", rig.date.timeIntervalSince1970 + 604801)] {
            var claims = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); claims[field] = value
            let payload = try JSONSerialization.data(withJSONObject: claims).licenseBase64URL
            let signature = try rig.key.signature(for: Data("1.test.\(payload)".utf8)).licenseBase64URL
            var altered = license; altered.receipt = TCPViewerLicenseReceipt(version: 1, keyId: "test", payload: payload, signature: signature)
            #expect(throws: TCPViewerLicenseError.invalidReceipt) { try verifier(rig).verify(altered, deviceMatches: { _ in true }, buildNumber: "999", now: rig.date) }
        }
    }

    @Test func signedStorageKeepsCredentialInsideEncryptedReceiptFile() throws {
        let rig = LicenseTestRig(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("receipt.bin")
        let cipher = TCPViewerLicenseCipher(secret: "test-only")
        let storage = TCPViewerLicenseStorage(fileURL: url, cipher: cipher)
        let license = try rig.signed(); try storage.writeLicense(license)
        let encrypted = try Data(contentsOf: url)
        let stored = try JSONDecoder().decode(TCPViewerLicense.self, from: cipher.decrypt(encrypted))
        #expect(stored.signature == license.signature)
        #expect(!String(decoding: encrypted, as: UTF8.self).contains(license.signature))
        #expect(storage.readLicense() == license)
        try storage.writeLicense(rig.legacy())
        #expect(storage.readLicense() == rig.legacy())
        storage.removeLicense()
        #expect(storage.readLicense() == nil)
    }

    private func verifier(_ rig: LicenseTestRig) -> TCPViewerLicenseReceiptVerifier {
        TCPViewerLicenseReceiptVerifier(publicKeys: ["test": rig.key.publicKey.rawRepresentation])
    }
}
