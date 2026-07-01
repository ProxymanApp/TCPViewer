//
//  PacketInspectorByteCopyService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/7/26.
//

import Foundation
import PcapPlusPlusCore

enum PacketInspectorByteCopyFormat: String, CaseIterable, Sendable {
    case hexASCIIDump
    case hexDump
    case utf8Text
    case asciiText
    case hexStream
    case base64String
    case mimeData
    case cString
    case goLiteral
    case cArray

    var menuTitle: String {
        switch self {
        case .hexASCIIDump:
            return "Copy Bytes as Hex + ASCII Dump"
        case .hexDump:
            return "...as Hex Dump"
        case .utf8Text:
            return "...as UTF-8 Text"
        case .asciiText:
            return "...as ASCII Text"
        case .hexStream:
            return "...as a Hex Stream"
        case .base64String:
            return "...as a Base64 String"
        case .mimeData:
            return "...as MIME Data"
        case .cString:
            return "...as C String"
        case .goLiteral:
            return "...as Go literal"
        case .cArray:
            return "...as C Array"
        }
    }

    var toolTip: String {
        switch self {
        case .hexASCIIDump:
            return "Copy selected packet-detail bytes as offset, hex, and ASCII columns."
        case .hexDump:
            return "Copy selected packet-detail bytes as offset and hex columns."
        case .utf8Text:
            return "Copy selected packet-detail bytes decoded as UTF-8 text."
        case .asciiText:
            return "Copy selected packet-detail bytes as printable ASCII text."
        case .hexStream:
            return "Copy selected packet-detail bytes as unpunctuated hex."
        case .base64String:
            return "Copy selected packet-detail bytes as Base64."
        case .mimeData:
            return "Copy selected packet-detail bytes as MIME application/octet-stream data."
        case .cString:
            return "Copy selected packet-detail bytes as a C string literal."
        case .goLiteral:
            return "Copy selected packet-detail bytes as a Go string literal."
        case .cArray:
            return "Copy selected packet-detail bytes as a C byte array."
        }
    }
}

struct PacketInspectorByteCopySlice: Equatable {
    let itemID: String
    let sourceID: String
    let offset: Int
    let bytes: Data
}

struct PacketInspectorByteCopyService {
    // Report availability separately so menus can disable byte formats without formatting data eagerly.
    func canCopyBytes(from items: [PacketInspectorTreeItem], inspection: PacketInspection?) -> Bool {
        !byteSlices(from: items, inspection: inspection).isEmpty
    }

    // Format the selected byte slices using Wireshark-inspired copy variants.
    func copyText(
        format: PacketInspectorByteCopyFormat,
        inspection: PacketInspection?,
        items: [PacketInspectorTreeItem]
    ) -> String {
        let slices = byteSlices(from: items, inspection: inspection)
        guard !slices.isEmpty else {
            return ""
        }

        switch format {
        case .hexASCIIDump:
            return joinedSections(slices) { Self.hexDump($0, includesASCII: true) }
        case .hexDump:
            return joinedSections(slices) { Self.hexDump($0, includesASCII: false) }
        case .utf8Text:
            return joinedLines(slices) { String(decoding: $0.bytes, as: UTF8.self) }
        case .asciiText:
            return joinedLines(slices) { Self.asciiText(from: $0.bytes) }
        case .hexStream:
            return joinedLines(slices) { Self.hexStream(from: $0.bytes) }
        case .base64String:
            return joinedLines(slices) { $0.bytes.base64EncodedString() }
        case .mimeData:
            return joinedSections(slices) { Self.mimeData(from: $0.bytes) }
        case .cString:
            return joinedSections(slices) { Self.cString(from: $0.bytes) }
        case .goLiteral:
            return joinedSections(slices) { Self.goLiteral(from: $0.bytes) }
        case .cArray:
            return cArrays(from: slices)
        }
    }

    func byteSlices(from items: [PacketInspectorTreeItem], inspection: PacketInspection?) -> [PacketInspectorByteCopySlice] {
        guard let inspection else {
            return []
        }

        let byteViews = Self.byteViewMap(for: inspection)
        return items.flatMap { item in
            byteRanges(for: item).compactMap { range in
                guard let bytes = Self.bytes(for: range, in: byteViews) else {
                    return nil
                }

                return PacketInspectorByteCopySlice(
                    itemID: item.id,
                    sourceID: range.sourceID,
                    offset: range.offset,
                    bytes: bytes
                )
            }
        }
    }

    private func byteRanges(for item: PacketInspectorTreeItem) -> [PacketByteRange] {
        if let byteRange = item.byteRange {
            return [byteRange]
        }

        return Self.mergedRanges(Self.descendantByteRanges(in: item))
    }

    private static func byteViewMap(for inspection: PacketInspection) -> [String: Data] {
        var map: [String: Data] = ["frame": inspection.rawBytes]
        for byteView in inspection.byteViews {
            map[byteView.id] = byteView.bytes
        }
        return map
    }

    private static func bytes(for range: PacketByteRange, in byteViews: [String: Data]) -> Data? {
        guard range.offset >= 0,
              range.length > 0,
              let sourceBytes = byteViews[range.sourceID],
              range.offset < sourceBytes.count else {
            return nil
        }

        let boundedLength = min(range.length, sourceBytes.count - range.offset)
        guard boundedLength > 0 else {
            return nil
        }

        return sourceBytes.subdata(in: range.offset..<(range.offset + boundedLength))
    }

    private static func descendantByteRanges(in item: PacketInspectorTreeItem) -> [PacketByteRange] {
        item.children.flatMap { child -> [PacketByteRange] in
            if let byteRange = child.byteRange {
                return [byteRange]
            }

            return descendantByteRanges(in: child)
        }
    }

    private static func mergedRanges(_ ranges: [PacketByteRange]) -> [PacketByteRange] {
        // Child rows may be displayed in protocol order rather than byte-offset order, so sort before coalescing.
        let sortedRanges = ranges.sorted { lhs, rhs in
            if lhs.sourceID == rhs.sourceID {
                return lhs.offset < rhs.offset
            }
            return lhs.sourceID < rhs.sourceID
        }

        return sortedRanges.reduce(into: []) { result, range in
            guard let previous = result.last,
                  previous.sourceID == range.sourceID,
                  range.offset <= previous.upperBound else {
                result.append(range)
                return
            }

            let upperBound = max(previous.upperBound, range.upperBound)
            result[result.count - 1] = PacketByteRange(
                offset: previous.offset,
                length: upperBound - previous.offset,
                sourceID: previous.sourceID
            )
        }
    }

    private func joinedLines(
        _ slices: [PacketInspectorByteCopySlice],
        transform: (PacketInspectorByteCopySlice) -> String
    ) -> String {
        slices.map(transform).joined(separator: "\n")
    }

    private func joinedSections(
        _ slices: [PacketInspectorByteCopySlice],
        transform: (PacketInspectorByteCopySlice) -> String
    ) -> String {
        slices.map(transform).joined(separator: "\n\n")
    }

    private static func hexDump(_ slice: PacketInspectorByteCopySlice, includesASCII: Bool) -> String {
        let bytes = Array(slice.bytes)
        let rows = stride(from: 0, to: bytes.count, by: 16).map { rowStart in
            let rowBytes = Array(bytes[rowStart..<min(rowStart + 16, bytes.count)])
            let offset = String(format: "%04x", slice.offset + rowStart)
            let hex = rowBytes
                .map { String(format: "%02x", Int($0)) }
                .joined(separator: " ")

            guard includesASCII else {
                return "\(offset)  \(hex)"
            }

            let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            return "\(offset)  \(paddedHex)  \(asciiColumn(from: rowBytes))"
        }

        return rows.joined(separator: "\n")
    }

    private static func hexStream(from data: Data) -> String {
        data.map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func asciiText(from data: Data) -> String {
        data.map { byte in
            if byte == 0x09 || byte == 0x0a || byte == 0x0d {
                return String(UnicodeScalar(Int(byte))!)
            }
            guard let scalar = printableASCIIScalar(for: byte) else {
                return "."
            }
            return String(scalar)
        }.joined()
    }

    private static func asciiColumn(from bytes: [UInt8]) -> String {
        bytes.map { byte in
            guard let scalar = printableASCIIScalar(for: byte) else {
                return "."
            }
            return String(scalar)
        }.joined()
    }

    private static func printableASCIIScalar(for byte: UInt8) -> UnicodeScalar? {
        guard byte >= 0x20, byte <= 0x7e else {
            return nil
        }
        return UnicodeScalar(Int(byte))
    }

    private static func mimeData(from data: Data) -> String {
        [
            "Content-Type: application/octet-stream",
            "Content-Transfer-Encoding: base64",
            "",
            wrappedBase64(data.base64EncodedString()),
        ].joined(separator: "\n")
    }

    private static func wrappedBase64(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 76).map { start in
            let lower = value.index(value.startIndex, offsetBy: start)
            let upper = value.index(lower, offsetBy: min(76, value.distance(from: lower, to: value.endIndex)))
            return String(value[lower..<upper])
        }.joined(separator: "\n")
    }

    private static func cString(from data: Data) -> String {
        var output = "\""
        var previousWasHexEscape = false

        for byte in data {
            if let escaped = commonStringEscape(for: byte) {
                output += escaped
                previousWasHexEscape = false
            } else if let scalar = printableASCIIScalar(for: byte), byte != 0x22, byte != 0x5c {
                if previousWasHexEscape && isHexDigit(byte) {
                    output += "\" \""
                }
                output += String(scalar)
                previousWasHexEscape = false
            } else {
                output += "\\x\(String(format: "%02x", Int(byte)))"
                previousWasHexEscape = true
            }
        }

        return output + "\""
    }

    private static func goLiteral(from data: Data) -> String {
        var output = "\""
        for byte in data {
            if let escaped = commonStringEscape(for: byte) {
                output += escaped
            } else if let scalar = printableASCIIScalar(for: byte), byte != 0x22, byte != 0x5c {
                output += String(scalar)
            } else {
                output += "\\x\(String(format: "%02x", Int(byte)))"
            }
        }
        return output + "\""
    }

    private static func commonStringEscape(for byte: UInt8) -> String? {
        switch byte {
        case 0x09:
            return "\\t"
        case 0x0a:
            return "\\n"
        case 0x0d:
            return "\\r"
        case 0x22:
            return "\\\""
        case 0x5c:
            return "\\\\"
        default:
            return nil
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) ||
            (byte >= 0x41 && byte <= 0x46) ||
            (byte >= 0x61 && byte <= 0x66)
    }

    private func cArrays(from slices: [PacketInspectorByteCopySlice]) -> String {
        let multipleSlices = slices.count > 1
        return slices.enumerated().map { index, slice in
            let name = multipleSlices ? "packet_bytes_\(index + 1)" : "packet_bytes"
            return Self.cArray(from: slice.bytes, name: name)
        }.joined(separator: "\n\n")
    }

    private static func cArray(from data: Data, name: String) -> String {
        let bytes = Array(data)
        guard !bytes.isEmpty else {
            return "unsigned char \(name)[] = {};"
        }

        let rows = stride(from: 0, to: bytes.count, by: 12).map { rowStart in
            let rowBytes = Array(bytes[rowStart..<min(rowStart + 12, bytes.count)])
            return "    " + rowBytes.map { String(format: "0x%02x", Int($0)) }.joined(separator: ", ")
        }

        return "unsigned char \(name)[] = {\n\(rows.joined(separator: ",\n"))\n};"
    }
}
