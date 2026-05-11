//
//  TCPViewerLicenseModelStorageTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerLicenseModelStorageTests {
    @Test func decodesServerPayloadAndFormatsExpiryDate() throws {
        let data = """
        {
          "signature": "abcdefghijklmnopqrstuvwxyz",
          "device_uuid": "device-1",
          "email": "ada@example.com",
          "purchaseAt": "2026-05-01T10:20:30.123Z",
          "expiryAt": "2027-05-01T10:20:30.123Z",
          "licenseType": "standard_license"
        }
        """.data(using: .utf8)!

        let license = try JSONDecoder().decode(TCPViewerLicense.self, from: data)

        #expect(license.signature == "abcdefghijklmnopqrstuvwxyz")
        #expect(license.deviceUUID == "device-1")
        #expect(license.email == "ada@example.com")
        #expect(license.expiryDate == "2027-05-01T10:20:30.123Z")
        #expect(license.licenseType == .standardLicense)
        #expect(license.formattedExpiryDate.contains("2027"))
        #expect(license.hasOneYearUpdateWindow)
    }

    @Test func decodesOldPayloadWithoutLicenseTypeAsStandard() throws {
        let data = """
        {
          "signature": "abcdefghijklmnopqrstuvwxyz",
          "device_uuid": "device-1",
          "email": "ada@example.com",
          "purchaseAt": "2026-05-01T10:20:30.123Z",
          "expiryAt": "2027-05-01T10:20:30.123Z"
        }
        """.data(using: .utf8)!

        let license = try JSONDecoder().decode(TCPViewerLicense.self, from: data)

        #expect(license.licenseType == .standardLicense)
    }

    @Test func updateWindowRejectsReceiptsLongerThanOneYear() {
        let license = TCPViewerLicense(
            signature: "abcdefghijklmnopqrstuvwxyz",
            deviceUUID: "device-1",
            email: "ada@example.com",
            purchaseAt: "2026-05-01T10:20:30.123Z",
            expiryDate: "2028-05-01T10:20:30.123Z"
        )

        #expect(!license.hasOneYearUpdateWindow)
    }

    @Test func lifetimeLicenseAllowsUnlimitedUpdateWindow() {
        let license = TCPViewerLicense(
            signature: "abcdefghijklmnopqrstuvwxyz",
            deviceUUID: "device-1",
            email: "ada@example.com",
            purchaseAt: "2026-05-01T10:20:30.123Z",
            expiryDate: "2036-05-01T10:20:30.123Z",
            licenseType: .lifetimeLicense
        )

        #expect(!license.hasOneYearUpdateWindow)
        #expect(license.hasValidUpdateEntitlement)
        #expect(license.updateAvailabilityDescription == "Lifetime updates included")
    }

    @Test func encryptedStorageRoundTripsAndRemovesLicense() throws {
        let fileURL = try makeReceiptURL()
        let storage = TCPViewerLicenseStorage(
            fileURL: fileURL,
            cipher: TCPViewerLicenseCipher(secret: "test-storage-secret")
        )
        let license = makeLicense()

        try storage.writeLicense(license)

        let encryptedData = try Data(contentsOf: fileURL)
        let encryptedString = String(data: encryptedData, encoding: .utf8) ?? ""
        #expect(!encryptedString.contains(license.email))
        #expect(storage.readLicense() == license)

        storage.removeLicense()

        #expect(storage.readLicense() == nil)
    }

    @Test func corruptEncryptedStorageReturnsNil() throws {
        let fileURL = try makeReceiptURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3, 4]).write(to: fileURL)

        let storage = TCPViewerLicenseStorage(
            fileURL: fileURL,
            cipher: TCPViewerLicenseCipher(secret: "test-storage-secret")
        )

        #expect(storage.readLicense() == nil)
    }

    private func makeLicense() -> TCPViewerLicense {
        TCPViewerLicense(
            signature: "abcdefghijklmnopqrstuvwxyz",
            deviceUUID: "device-1",
            email: "ada@example.com",
            purchaseAt: "2026-05-01T10:20:30.123Z",
            expiryDate: "2027-05-01T10:20:30.123Z"
        )
    }

    private func makeReceiptURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewerLicenseModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("receipt.bin")
    }
}
