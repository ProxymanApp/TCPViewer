//
//  TCPViewerMCPSensitiveDataRedactor.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation

final class TCPViewerMCPSensitiveDataRedactor: @unchecked Sendable {
    static let placeholder = "<redacted>"

    private struct Replacement: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String
    }

    private let sensitiveNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "proxy-authenticate",
        "www-authenticate",
        "x-api-key",
        "x-auth-token",
        "x-access-token",
        "api-key",
        "api_key",
        "apikey",
        "access-token",
        "access_token",
        "auth-token",
        "auth_token",
        "refresh-token",
        "refresh_token",
        "client-secret",
        "client_secret",
        "private-key",
        "private_key",
        "password",
        "passwd",
        "passphrase",
        "pwd",
        "secret",
        "token",
        "auth",
        "credential",
        "credentials",
        "session-id",
        "session-token",
        "signing-key",
    ]

    private let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "proxy-authenticate",
        "www-authenticate",
        "x-api-key",
        "x-auth-token",
        "x-access-token",
    ]

    private let replacements: [Replacement]

    init() {
        let patterns: [(String, String)] = [
            (
                #"(?is)-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----.*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
                Self.placeholder
            ),
            (
                #"(?im)^(authorization|proxy-authorization|cookie|set-cookie|proxy-authenticate|www-authenticate|x-api-key|x-auth-token|x-access-token)\s*:\s*[^\r\n]+"#,
                #"$1: <redacted>"#
            ),
            (
                #"(?i)([?&])([^=&\s]*(?:token|secret|password|passwd|passphrase|pwd|api[_-]?key|private[_-]?key|client[_-]?secret)[^=&\s]*)=([^&#\s]*)"#,
                #"$1$2=<redacted>"#
            ),
            (
                #"(?i)(^|[&;\s])([^=&;\s]*(?:token|secret|password|passwd|passphrase|pwd|api[_-]?key|private[_-]?key|client[_-]?secret)[^=&;\s]*)=([^&;\s]*)"#,
                #"$1$2=<redacted>"#
            ),
            (
                #"(?i)(\"(?:\\.|[^\"\\])*(?:token|secret|password|passwd|passphrase|pwd|api[_-]?key|private[_-]?key|client[_-]?secret|credential|authorization|cookie|session[_-]?(?:id|token)|signing[_-]?key)(?:\\.|[^\"\\])*\"\s*:\s*)(?:\"(?:\\.|[^\"\\])*\"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)"#,
                #"$1\"<redacted>\""#
            ),
            (
                #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#,
                #"$1 <redacted>"#
            ),
            (
                #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\b"#,
                Self.placeholder
            ),
            (
                #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})\b"#,
                Self.placeholder
            ),
            (
                #"(?i)([a-z][a-z0-9+.-]*://[^/@:\s]+:)[^/@\s]+(@)"#,
                #"$1<redacted>$2"#
            ),
        ]

        replacements = patterns.compactMap { pattern, template in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            return Replacement(expression: expression, template: template)
        }
    }

    // Apply all credential-oriented patterns without hiding normal packet metadata.
    func redact(_ text: String) -> String {
        var output = redactedStructuredJSON(text) ?? text
        for replacement in replacements {
            output = replacement.expression.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output),
                withTemplate: replacement.template
            )
        }
        return output
    }

    func redact(_ value: TCPViewerMCPValue, fieldName: String? = nil) -> TCPViewerMCPValue {
        if let fieldName, isSensitiveName(fieldName) {
            return .string(Self.placeholder)
        }

        switch value {
        case .string(let text):
            return .string(redact(text))
        case .array(let values):
            return .array(values.map { redact($0) })
        case .object(let values):
            return .object(redactObject(values))
        case .int, .double, .bool, .null:
            return value
        }
    }

    func isSensitiveName(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        if sensitiveNames.contains(normalized) {
            return true
        }

        let compact = normalized.replacingOccurrences(of: "-", with: "")
        let components = Set(normalized.split(separator: "-").map(String.init))
        return compact.contains("password") ||
            compact.contains("passwd") ||
            compact.contains("passphrase") ||
            compact.contains("apikey") ||
            compact.contains("accesstoken") ||
            compact.contains("authtoken") ||
            compact.contains("refreshtoken") ||
            compact.contains("clientsecret") ||
            compact.contains("privatekey") ||
            compact.contains("sessionid") ||
            compact.contains("signingkey") ||
            !components.isDisjoint(with: ["credential", "credentials", "secret", "token"])
    }

    private func redactObject(_ values: [String: TCPViewerMCPValue]) -> [String: TCPViewerMCPValue] {
        var output = values.mapValues { value in
            redact(value)
        }

        for (key, value) in values where isSensitiveName(key) {
            output[key] = redact(value, fieldName: key)
        }

        // Header and query arrays commonly encode entries as {key/name, value}.
        let entryName = values["name"]?.stringValue ?? values["key"]?.stringValue
        if let entryName,
           values["value"] != nil,
           sensitiveHeaderNames.contains(normalizedName(entryName)) || isSensitiveName(entryName) {
            output["value"] = .string(Self.placeholder)
        }

        return output
    }

    private func normalizedName(_ name: String) -> String {
        name.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1-$2",
            options: .regularExpression
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    // Parse complete JSON bodies so sensitive keys protect values of every JSON type.
    private func redactedStructuredJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first,
              let last = trimmed.last,
              (first == "{" && last == "}") || (first == "[" && last == "]"),
              let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(TCPViewerMCPValue.self, from: data) else {
            return nil
        }
        let redactedValue = redact(value)
        guard redactedValue != value,
              let encoded = try? JSONEncoder().encode(redactedValue) else {
            return nil
        }
        return String(data: encoded, encoding: .utf8)
    }
}
