//
//  TCPViewerLicense.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation

enum TCPViewerLicenseType: String, Codable {
    case standardLicense = "standard_license"
    case comboLicense = "combo_license"
    case lifetimeLicense = "lifetime_license"
    case teamLicense = "team_license"
}

struct TCPViewerLicense: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case signature
        case deviceUUID = "device_uuid"
        case email
        case purchaseAt
        case expiryDate = "expiryAt"
        case licenseType
        case receipt, activationId, numberOfSeats, usedSeats
    }

    var signature: String
    let deviceUUID: String
    let email: String
    let purchaseAt: String
    var expiryDate: String
    let licenseType: TCPViewerLicenseType
    var receipt: TCPViewerLicenseReceipt?
    var activationId: String?
    var numberOfSeats: Int?
    var usedSeats: Int?

    init(
        signature: String,
        deviceUUID: String,
        email: String,
        purchaseAt: String,
        expiryDate: String,
        licenseType: TCPViewerLicenseType = .standardLicense,
        receipt: TCPViewerLicenseReceipt? = nil,
        activationId: String? = nil,
        numberOfSeats: Int? = nil,
        usedSeats: Int? = nil
    ) {
        self.signature = signature
        self.deviceUUID = deviceUUID
        self.email = email
        self.purchaseAt = purchaseAt
        self.expiryDate = expiryDate
        self.licenseType = licenseType
        self.receipt = receipt
        self.activationId = activationId
        self.numberOfSeats = numberOfSeats
        self.usedSeats = usedSeats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signature = try container.decode(String.self, forKey: .signature)
        deviceUUID = try container.decode(String.self, forKey: .deviceUUID)
        email = try container.decode(String.self, forKey: .email)
        purchaseAt = try container.decode(String.self, forKey: .purchaseAt)
        expiryDate = try container.decode(String.self, forKey: .expiryDate)
        licenseType = try container.decodeIfPresent(TCPViewerLicenseType.self, forKey: .licenseType) ?? .standardLicense
        receipt = try container.decodeIfPresent(TCPViewerLicenseReceipt.self, forKey: .receipt)
        activationId = try container.decodeIfPresent(String.self, forKey: .activationId)
        numberOfSeats = try container.decodeIfPresent(Int.self, forKey: .numberOfSeats)
        usedSeats = try container.decodeIfPresent(Int.self, forKey: .usedSeats)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signature, forKey: .signature)
        try container.encode(deviceUUID, forKey: .deviceUUID)
        try container.encode(email, forKey: .email)
        try container.encode(purchaseAt, forKey: .purchaseAt)
        try container.encode(expiryDate, forKey: .expiryDate)
        try container.encode(licenseType, forKey: .licenseType)
        try container.encodeIfPresent(receipt, forKey: .receipt)
        try container.encodeIfPresent(activationId, forKey: .activationId)
        try container.encodeIfPresent(numberOfSeats, forKey: .numberOfSeats)
        try container.encodeIfPresent(usedSeats, forKey: .usedSeats)
    }

    var remainingDays: Int? {
        guard let untilDate = TCPViewerLicenseDateParser.date(from: expiryDate) else {
            return nil
        }

        return Date().tcpViewerLicenseDifferenceInDays(with: untilDate)
    }

    var isExpired: Bool {
        guard let remainingDays else {
            return true
        }

        return remainingDays < 0
    }

    var hasLifetimeUpdates: Bool {
        licenseType == .lifetimeLicense
    }

    var formattedExpiryDate: String {
        guard let date = TCPViewerLicenseDateParser.date(from: expiryDate) else {
            return expiryDate
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    var updateAvailabilityDescription: String {
        if hasLifetimeUpdates {
            return "Lifetime updates included"
        }

        guard let remainingDays else {
            return "Updates available until \(formattedExpiryDate)"
        }

        if remainingDays < 0 {
            return "Updates available until \(formattedExpiryDate). Covered releases remain usable."
        }
        if remainingDays == 0 {
            return "Updates available until today"
        }
        if remainingDays < 30 {
            return "Updates available until \(formattedExpiryDate) (\(remainingDays) days from now)"
        }

        let months = remainingDays / 30
        return "Updates available until \(formattedExpiryDate) (\(months + 1) months from now)"
    }


}

enum TCPViewerLicenseDateParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // Server dates usually include fractional seconds, but old rows may not.
    static func date(from string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? standardFormatter.date(from: string)
    }
}

private extension Date {
    // Compare calendar days so "expires today" does not oscillate by clock time.
    func tcpViewerLicenseDifferenceInDays(with date: Date) -> Int? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: self)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day
    }
}
