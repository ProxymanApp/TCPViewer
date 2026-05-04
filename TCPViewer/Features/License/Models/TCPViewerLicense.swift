//
//  TCPViewerLicense.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation

struct TCPViewerLicense: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case signature
        case deviceUUID = "device_uuid"
        case email
        case purchaseAt
        case expiryDate = "expiryAt"
    }

    let signature: String
    let deviceUUID: String
    let email: String
    let purchaseAt: String
    var expiryDate: String

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

    var formattedExpiryDate: String {
        guard let date = TCPViewerLicenseDateParser.date(from: expiryDate) else {
            return expiryDate
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
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
