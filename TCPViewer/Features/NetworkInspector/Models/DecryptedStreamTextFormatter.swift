//
//  DecryptedStreamTextFormatter.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import Foundation

enum DecryptedStreamTextFormatter {
    // Text mode is intentionally strict so binary HTTP/2 and QUIC payloads remain inspectable.
    static func string(for data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), text.unicodeScalars.allSatisfy(isReadable) {
            return text
        }
        return hexDump(data)
    }

    private static func isReadable(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D ||
            (scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value))
    }

    private static func hexDump(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }
        let bytes = [UInt8](data)
        var lines: [String] = []
        lines.reserveCapacity((bytes.count + 15) / 16)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let line = Array(bytes[offset..<min(offset + 16, bytes.count)])
            let hex = line.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padding = String(repeating: " ", count: max(16 * 3 - 1 - hex.count, 0))
            let ascii = line.map { byte in
                byte >= 0x20 && byte <= 0x7E ? String(UnicodeScalar(byte)) : "."
            }.joined()
            lines.append(String(format: "%08x  %@%@  |%@|", offset, hex, padding, ascii))
        }
        return lines.joined(separator: "\n")
    }
}
