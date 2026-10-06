//
//  TLSKeyLog.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation

// Validated NSS key log lines (the `SSLKEYLOGFILE` format) ready for the TLS dissector.
public struct TLSKeyLog: Sendable, Equatable {
    public static let empty = TLSKeyLog(lines: Data(), keyCount: 0, sessionCount: 0, skippedLineCount: 0, isTruncated: false)

    // Canonical `LABEL hex hex\n` lines. These are secrets: keep them in memory and never log them.
    public let lines: Data
    public let keyCount: Int
    // Distinct 32-byte client randoms, i.e. TLS connections this log can unlock.
    public let sessionCount: Int
    public let skippedLineCount: Int
    // True when the input exceeded the parser's size limit and the tail was ignored.
    public let isTruncated: Bool

    public var isEmpty: Bool {
        lines.isEmpty
    }
}

public enum TLSKeyLogParser {
    public static let maximumInputBytes = 64 * 1024 * 1024
    public static let maximumLineBytes = 1024
    private static let clientRandomHexLength = 64

    // Keep only well-formed `LABEL hex hex` lines so untrusted file content never reaches the dissector as-is.
    // Labels are not checked against a list: Wireshark ignores the ones it does not know, and a copy would drift.
    public static func parse(_ data: Data, maximumInputBytes: Int = TLSKeyLogParser.maximumInputBytes) -> TLSKeyLog {
        let isTruncated = data.count > maximumInputBytes
        var input = data.prefix(maximumInputBytes)
        // A cut-off final line could still look like a valid, shorter secret.
        if isTruncated {
            input = input.lastIndex(of: UInt8(ascii: "\n")).map { input[..<$0] } ?? Data()
        }
        var lines = Data()
        lines.reserveCapacity(input.count)
        var clientRandoms = Set<[UInt8]>()
        var keyCount = 0
        var skippedLineCount = 0

        for rawLine in input.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let fields = rawLine.split(whereSeparator: isBlank)
            // Blank lines and comments are normal in key logs, so they are not counted as skipped.
            guard let label = fields.first, label.first != UInt8(ascii: "#") else {
                continue
            }
            guard rawLine.count <= maximumLineBytes,
                  fields.count == 3,
                  label.allSatisfy(isLabelCharacter),
                  let identifier = lowercasedHex(fields[1]),
                  let secret = lowercasedHex(fields[2]) else {
                skippedLineCount += 1
                continue
            }

            lines.append(contentsOf: label)
            lines.append(UInt8(ascii: " "))
            lines.append(contentsOf: identifier)
            lines.append(UInt8(ascii: " "))
            lines.append(contentsOf: secret)
            lines.append(UInt8(ascii: "\n"))
            keyCount += 1
            if identifier.count == clientRandomHexLength {
                clientRandoms.insert(identifier)
            }
        }

        return TLSKeyLog(
            lines: lines,
            keyCount: keyCount,
            sessionCount: clientRandoms.count,
            skippedLineCount: skippedLineCount,
            isTruncated: isTruncated
        )
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private static func isLabelCharacter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "_")
    }

    // Return whole hex octets in lowercase so equal client randoms compare equal, or nil for anything else.
    private static func lowercasedHex(_ field: Data.SubSequence) -> [UInt8]? {
        guard !field.isEmpty, field.count.isMultiple(of: 2) else {
            return nil
        }
        var result: [UInt8] = []
        result.reserveCapacity(field.count)
        for byte in field {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"):
                result.append(byte)
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                result.append(byte | 0x20)
            default:
                return nil
            }
        }
        return result
    }
}

// Process-wide entry point, because libwireshark keeps a single TLS key map for the whole process.
public enum TLSKeyLogRegistry {
    private static let queue = DispatchQueue(
        label: "com.proxyman.tcpviewer.PcapPlusPlusCore.TLSKeyLogRegistry",
        qos: .userInitiated
    )

    // Replace the keys used by every capture dissected from now on. Packets that were already
    // dissected keep their old result until the capture is re-dissected.
    public static func apply(_ keyLogs: [TLSKeyLog], completion: @escaping () -> Void) {
        queue.async {
            var lines = Data()
            for keyLog in keyLogs {
                lines.append(keyLog.lines)
            }
            WiresharkEpanSession.setTLSKeyLog(lines)
            completion()
        }
    }

    // Add keys that were just written to a key log. A running capture can use them for handshakes
    // it has not dissected yet; connections it already passed need a re-dissect once it stops.
    public static func append(_ keyLog: TLSKeyLog, completion: @escaping () -> Void) {
        queue.async {
            WiresharkEpanSession.appendTLSKeyLog(keyLog.lines)
            completion()
        }
    }
}
