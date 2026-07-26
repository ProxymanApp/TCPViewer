//
//  PacketComment.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/7/26.
//

import Foundation

public enum PacketComment {
    public static let maximumCharacterCount = 1_000

    // Normalize line endings, trim outer whitespace, and enforce the UI storage limit.
    public static func sanitized(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(maximumCharacterCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
