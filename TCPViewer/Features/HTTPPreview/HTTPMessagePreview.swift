//
//  HTTPMessagePreview.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import Foundation
import PcapPlusPlusCore

// One HTTP request or response from a packet as readable text, for the bytes pane's Preview popover.
// It is rebuilt from Wireshark's dissection: exact header bytes for HTTP/1.x, decoded header fields for
// HTTP/2, and the decoded body (de-chunked, uncompressed, reassembled) that Wireshark points to.
struct HTTPMessagePreview: Equatable {
    enum Kind: Equatable {
        case request
        case response
        // An HTTP/2 DATA frame whose headers came in another packet.
        case body
    }

    let kind: Kind
    // "GET /json", "200 OK" or "HTTP/2 body".
    let title: String
    let text: String
    let isJSONBody: Bool

    // Monaco stays responsive with a few MB; larger bodies are cut with a note.
    static let maximumBodyBytes = 1 << 20

    // Cheap check for the Preview button: no body is decoded.
    static func isAvailable(in inspection: PacketInspection) -> Bool {
        inspection.detailNodes.contains { layer in
            switch layer.fieldName {
            case "http":
                return layer.children.first.flatMap { startLineKind(of: unescapedLine($0.label ?? $0.name)) } != nil
            case "http2":
                return layer.children.contains { stream in
                    stream.fieldName == "http2.stream"
                        && stream.children.contains { $0.fieldName == "http2.header" || $0.fieldName == "http2.data.data" }
                }
            default:
                return false
            }
        }
    }

    // The first HTTP message in the packet, or nil when it carries none.
    static func make(from inspection: PacketInspection) -> HTTPMessagePreview? {
        let sources = Dictionary(inspection.byteViews.map { ($0.id, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        for layer in inspection.detailNodes {
            switch layer.fieldName {
            case "http":
                if let message = http1Message(layer, sources: sources) { return message }
            case "http2":
                if let message = http2Message(layer, sources: sources) { return message }
            default:
                continue
            }
        }
        return nil
    }

    // MARK: HTTP/1.x

    // The layer's byte range covers exactly the start line, the headers and the blank line.
    private static func http1Message(_ layer: PacketDetailNode, sources: [String: Data]) -> HTTPMessagePreview? {
        let head: String
        if let bytes = bytes(at: layer.byteRange, in: sources) {
            head = decodedText(bytes) ?? String(decoding: bytes, as: UTF8.self)
        } else {
            // Without bytes, rebuild the head from the rows (\r\n escaped) up to the blank line;
            // generated rows such as "[Response in frame: 6]" are in brackets.
            head = layer.children
                .lazy
                .map { unescapedLine($0.label ?? $0.name) }
                .filter { !$0.hasPrefix("[") }
                .prefix { !$0.isEmpty }
                .joined(separator: "\n")
        }
        let headLines = normalizedLines(head)
        guard let startLine = headLines.first, let kind = startLineKind(of: startLine) else {
            return nil
        }
        let body = layer.children.first { $0.fieldName == "http.file_data" }.flatMap { bytes(at: $0.byteRange, in: sources) }
        return message(kind: kind, title: title(forStartLine: startLine, kind: kind), headLines: headLines, body: body)
    }

    // MARK: HTTP/2

    // HTTP/2 has no text headers on the wire, so the message is written from Wireshark's decoded fields.
    private static func http2Message(_ layer: PacketDetailNode, sources: [String: Data]) -> HTTPMessagePreview? {
        let streams = layer.children.filter { $0.fieldName == "http2.stream" }
        guard let headerStream = streams.first(where: { $0.children.contains { $0.fieldName == "http2.header" } }) else {
            // Headers came in an earlier packet: preview the body alone.
            guard let body = streams.lazy.compactMap({ body(of: $0, sources: sources) }).first else { return nil }
            return message(kind: .body, title: "HTTP/2 body", headLines: [], body: body)
        }
        let headers = headerStream.children.filter { $0.fieldName == "http2.header" }.compactMap { header -> (name: String, value: String)? in
            guard let name = header.children.first(where: { $0.fieldName == "http2.header.name" })?.value,
                  let value = header.children.first(where: { $0.fieldName == "http2.header.value" })?.value else {
                return nil
            }
            return (name, value)
        }
        let pseudoHeaders = Dictionary(headers.filter { $0.name.hasPrefix(":") }.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        let kind: Kind
        let startLine: String
        if let status = pseudoHeaders[":status"] {
            kind = .response
            startLine = "HTTP/2 \(status)"
        } else if let method = pseudoHeaders[":method"], let path = pseudoHeaders[":path"] {
            kind = .request
            startLine = "\(method) \(path) HTTP/2"
        } else {
            return nil
        }
        let headerLines = headers
            .filter { ![":method", ":path", ":status"].contains($0.name) }
            .map { "\($0.name): \($0.value)" }
        let streamID = streamIdentifier(of: headerStream)
        let body = streams.lazy
            .filter { streamIdentifier(of: $0) == streamID }
            .compactMap { body(of: $0, sources: sources) }
            .first
        return message(kind: kind, title: title(forStartLine: startLine, kind: kind), headLines: [startLine] + headerLines, body: body)
    }

    // In the last DATA frame of a stream, Wireshark points this field at the whole reassembled body.
    private static func body(of stream: PacketDetailNode, sources: [String: Data]) -> Data? {
        stream.children.first { $0.fieldName == "http2.data.data" }.flatMap { bytes(at: $0.byteRange, in: sources) }
    }

    private static func streamIdentifier(of stream: PacketDetailNode) -> String? {
        stream.children.first { $0.fieldName == "http2.streamid" }?.value
    }

    // MARK: Message text

    private static func message(kind: Kind, title: String, headLines: [String], body: Data?) -> HTTPMessagePreview {
        let contentType = headLines.dropFirst().first { $0.lowercased().hasPrefix("content-type:") }
            .map { String($0.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces) }
        let renderedBody = body.flatMap { $0.isEmpty ? nil : renderBody($0, contentType: contentType) }
        let parts = [headLines.isEmpty ? nil : headLines.joined(separator: "\n"), renderedBody?.text].compactMap { $0 }
        return HTTPMessagePreview(
            kind: kind,
            title: title,
            text: parts.joined(separator: "\n\n"),
            isJSONBody: renderedBody?.isJSON ?? false
        )
    }

    // Text bodies show as sent, JSON is pretty-printed, and binary bodies are described rather than dumped.
    static func renderBody(_ body: Data, contentType: String?) -> (text: String, isJSON: Bool) {
        let isTruncated = body.count > maximumBodyBytes
        guard let text = decodedText(body.prefix(maximumBodyBytes), mayEndMidCharacter: isTruncated) else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file)
            return ("[\(size) of binary data\(contentType.map { ", \($0)" } ?? "")]", false)
        }
        let mayBeJSON = contentType?.lowercased().contains("json") == true
            || text.first(where: { !$0.isWhitespace }).map { $0 == "{" || $0 == "[" } == true
        if !isTruncated, mayBeJSON, let pretty = HTTPMessageJSONFormatter.prettyPrinted(text) {
            return (pretty, true)
        }
        guard isTruncated else { return (text, false) }
        let rest = ByteCountFormatter.string(fromByteCount: Int64(body.count - maximumBodyBytes), countStyle: .file)
        return (text + "\n\n[\(rest) more not shown]", false)
    }

    // UTF-8 text without control characters other than tabs and line breaks; nil for binary data.
    private static func decodedText(_ data: Data, mayEndMidCharacter: Bool = false) -> String? {
        // A cut body may end inside a multi-byte character, which is at most 3 bytes short.
        for trim in 0...(mayEndMidCharacter ? min(3, data.count) : 0) {
            guard let text = String(data: data.dropLast(trim), encoding: .utf8) else { continue }
            let isText = text.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F || scalar == "\t" || scalar == "\n" || scalar == "\r"
            }
            return isText ? text : nil
        }
        return nil
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .reversed()
            .drop { $0.isEmpty }
            .reversed()
    }

    // Wireshark rows show line breaks escaped, e.g. "GET / HTTP/1.1\r\n".
    private static func unescapedLine(_ label: String) -> String {
        label.replacingOccurrences(of: "\\r\\n", with: "").replacingOccurrences(of: "\\n", with: "")
    }

    private static func startLineKind(of line: String) -> Kind? {
        if line.range(of: #"^HTTP/\d(\.\d)? \d{3}"#, options: .regularExpression) != nil {
            return .response
        }
        if line.range(of: #"^[A-Z][A-Z-]* \S+ HTTP/\d(\.\d)?\s*$"#, options: .regularExpression) != nil {
            return .request
        }
        return nil
    }

    // "GET /json HTTP/1.1" reads "GET /json"; "HTTP/1.1 200 OK" reads "200 OK".
    private static func title(forStartLine line: String, kind: Kind) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        switch kind {
        case .request:
            return parts.prefix(2).joined(separator: " ")
        case .response:
            return parts.dropFirst().joined(separator: " ")
        case .body:
            return line
        }
    }

    private static func bytes(at range: PacketByteRange?, in sources: [String: Data]) -> Data? {
        guard let range, let source = sources[range.sourceID], range.offset >= 0, range.length > 0,
              range.offset + range.length <= source.count else {
            return nil
        }
        let start = source.startIndex + range.offset
        return source[start..<(start + range.length)]
    }
}

// Indents JSON without parsing it into dictionaries, so keys keep their order and numbers their spelling.
enum HTTPMessageJSONFormatter {
    static func prettyPrinted(_ text: String, indent: String = "  ") -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        var output = String.UnicodeScalarView()
        var depth = 0
        var isInString = false
        var isEscaped = false
        // An opened container gets its line break only once we know it is not empty.
        var isContainerOpen = false

        func newLine() {
            output.append("\n")
            for _ in 0..<depth { output.append(contentsOf: indent.unicodeScalars) }
        }

        for scalar in text.unicodeScalars {
            if isInString {
                output.append(scalar)
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInString = false
                }
                continue
            }
            if scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                continue
            }
            if isContainerOpen {
                isContainerOpen = false
                if scalar == "}" || scalar == "]" {
                    depth -= 1
                    output.append(scalar)
                    continue
                }
                newLine()
            }
            switch scalar {
            case "\"":
                isInString = true
                output.append(scalar)
            case "{", "[":
                output.append(scalar)
                depth += 1
                isContainerOpen = true
            case "}", "]":
                depth -= 1
                newLine()
                output.append(scalar)
            case ",":
                output.append(scalar)
                newLine()
            case ":":
                output.append(contentsOf: ": ".unicodeScalars)
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }
}
