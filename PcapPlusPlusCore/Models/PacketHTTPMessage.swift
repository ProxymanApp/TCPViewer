//
//  PacketHTTPMessage.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation

// One HTTP request or response carried by a packet, in a form that can be shown as text.
public struct PacketHTTPMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case request
        case response
        // No start line: body data or trailers of a message that began in an earlier packet.
        case continuation
    }

    public let kind: Kind
    // Start line and header lines joined by "\n", without the blank line that ends the headers.
    public let head: String
    // The body as Wireshark decoded it: de-chunked and decompressed when it could.
    public let body: Data

    public init(kind: Kind, head: String, body: Data) {
        self.kind = kind
        self.head = head
        self.body = body
    }
}

public enum PacketHTTPMessageExtractor {
    private struct HTTP2Message {
        let streamID: String
        var headers: [(name: String, value: String)]
        var body: Data
    }

    // Whether the packet carries TLS records that a key log decrypted.
    public static func hasDecryptedTLS(_ inspection: PacketInspection) -> Bool {
        inspection.byteViews.contains { $0.id.hasPrefix("decrypted-tls") }
    }

    // Collect the HTTP/1.x and HTTP/2 messages Wireshark dissected in this packet, in wire order.
    // Text is always sliced from the byte sources: node values are display strings that Wireshark
    // escapes and truncates, so they cannot reproduce a message.
    public static func messages(in inspection: PacketInspection) -> [PacketHTTPMessage] {
        let sources = Dictionary(
            inspection.byteViews.map { ($0.id, $0.bytes) },
            uniquingKeysWith: { first, _ in first }
        )
        var messages: [PacketHTTPMessage] = []
        var http2Messages: [HTTP2Message] = []
        for node in inspection.detailNodes {
            switch node.fieldName {
            case "http":
                if let message = http1Message(from: node, sources: sources) {
                    messages.append(message)
                }
            case "http2":
                for frame in node.children where frame.fieldName == "http2.stream" {
                    appendHTTP2Frame(frame, sources: sources, to: &http2Messages)
                }
            default:
                break
            }
        }
        return messages + http2Messages.map(message)
    }


    private static func http1Message(from node: PacketDetailNode, sources: [String: Data]) -> PacketHTTPMessage? {
        guard let range = node.byteRange,
              let source = sources[range.sourceID],
              range.offset >= 0, range.offset < source.count else {
            return nil
        }
        let start = source.startIndex + range.offset
        let nodeEnd = min(start + max(range.length, 0), source.endIndex)
        let decodedBody = firstDescendant(of: node, named: "http.file_data")
            .flatMap { bytes(in: $0.byteRange, sources: sources) }

        let kind: PacketHTTPMessage.Kind
        if firstDescendant(of: node, named: "http.request.method") != nil {
            kind = .request
        } else if firstDescendant(of: node, named: "http.response.code") != nil {
            kind = .response
        } else {
            let body = decodedBody ?? Data(source[start..<nodeEnd])
            return body.isEmpty ? nil : PacketHTTPMessage(kind: .continuation, head: "", body: body)
        }

        // The node's length stops at the headers once a body dissector claims the rest, so the
        // blank line is searched for instead of trusting that length.
        let terminator = Data("\r\n\r\n".utf8)
        let headEnd = source.range(of: terminator, in: start..<source.endIndex)?.lowerBound ?? nodeEnd
        let head = String(decoding: source[start..<headEnd], as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        // A byte range can point at the wrong source when Wireshark's own source was not extracted.
        guard isPrintable(head.prefix { $0 != "\n" }) else {
            return nil
        }

        let bodyStart = min(headEnd + terminator.count, source.endIndex)
        let undecodedBody = bodyStart < nodeEnd ? Data(source[bodyStart..<nodeEnd]) : Data()
        return PacketHTTPMessage(kind: kind, head: head, body: decodedBody ?? undecodedBody)
    }


    // Frames of one stream that share a packet (HEADERS followed by DATA) form a single message.
    private static func appendHTTP2Frame(
        _ frame: PacketDetailNode,
        sources: [String: Data],
        to messages: inout [HTTP2Message]
    ) {
        let headers = frame.children.filter { $0.fieldName == "http2.header" }.compactMap { header -> (name: String, value: String)? in
            let nameRange = header.children.first { $0.fieldName == "http2.header.name" }?.byteRange
            let valueRange = header.children.first { $0.fieldName == "http2.header.value" }?.byteRange
            guard let name = bytes(in: nameRange, sources: sources).map({ String(decoding: $0, as: UTF8.self) }),
                  isPrintable(name[...]) else {
                return nil
            }
            let value = bytes(in: valueRange, sources: sources).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return (name, value)
        }
        let body = firstDescendant(of: frame, named: "http2.data.data").flatMap { bytes(in: $0.byteRange, sources: sources) }
        // SETTINGS, WINDOW_UPDATE and similar control frames carry no message content.
        guard !headers.isEmpty || body != nil else {
            return
        }

        let streamID = frame.children.first { $0.fieldName == "http2.streamid" }?.value ?? ""
        if let lastIndex = messages.indices.last, messages[lastIndex].streamID == streamID {
            messages[lastIndex].headers.append(contentsOf: headers)
            messages[lastIndex].body.append(body ?? Data())
        } else {
            messages.append(HTTP2Message(streamID: streamID, headers: headers, body: body ?? Data()))
        }
    }

    // HTTP/2 has no textual start line, so one is rebuilt from the pseudo-headers to read like HTTP/1.x.
    private static func message(from http2Message: HTTP2Message) -> PacketHTTPMessage {
        var pseudoHeaders: [String: String] = [:]
        var lines: [String] = []
        for header in http2Message.headers {
            let value = header.value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            if header.name.hasPrefix(":") {
                pseudoHeaders[header.name] = value
            } else {
                lines.append("\(header.name): \(value)")
            }
        }

        let kind: PacketHTTPMessage.Kind
        if let method = pseudoHeaders[":method"] {
            kind = .request
            if let authority = pseudoHeaders[":authority"] {
                lines.insert("host: \(authority)", at: 0)
            }
            lines.insert("\(method) \(pseudoHeaders[":path"] ?? "/") HTTP/2", at: 0)
        } else if let status = pseudoHeaders[":status"] {
            kind = .response
            lines.insert("HTTP/2 \(status)", at: 0)
        } else {
            kind = .continuation
        }
        return PacketHTTPMessage(kind: kind, head: lines.joined(separator: "\n"), body: http2Message.body)
    }


    private static func bytes(in range: PacketByteRange?, sources: [String: Data]) -> Data? {
        guard let range, range.length > 0, range.offset >= 0,
              let source = sources[range.sourceID],
              range.upperBound <= source.count else {
            return nil
        }
        let start = source.startIndex + range.offset
        return Data(source[start..<start + range.length])
    }

    private static func firstDescendant(of node: PacketDetailNode, named fieldName: String) -> PacketDetailNode? {
        for child in node.children {
            if child.fieldName == fieldName {
                return child
            }
            if let match = firstDescendant(of: child, named: fieldName) {
                return match
            }
        }
        return nil
    }

    private static func isPrintable(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && $0.value != 0xFFFD }
    }
}
