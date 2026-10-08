//
//  PacketHTTPMessageExtractorTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct PacketHTTPMessageExtractorTests {
    @Test func requestIsReadFromTheDecryptedSource() {
        let request = "GET /a HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n"
        let inspection = makeInspection(
            sources: ["decrypted-tls": Data(request.utf8)],
            nodes: [http(source: "decrypted-tls", offset: 0, length: request.utf8.count, marker: "http.request.method")]
        )

        #expect(PacketHTTPMessageExtractor.hasDecryptedTLS(inspection))
        #expect(PacketHTTPMessageExtractor.messages(in: inspection) == [
            PacketHTTPMessage(kind: .request, head: "GET /a HTTP/1.1\nHost: example.com\nAccept: */*", body: Data())
        ])
    }

    @Test func responseBodyComesFromTheDecodedSource() {
        // Wireshark ends the HTTP node at the headers once it decompressed the body into its own source.
        let headers = "HTTP/1.1 200 OK\r\nContent-Encoding: br\r\n\r\n"
        let wire = Data(headers.utf8) + Data([0x1b, 0x03, 0x00, 0xf8])
        let fileData = node("http.file_data", source: "uncompressed-entity-body", offset: 0, length: 5)
        let inspection = makeInspection(
            sources: ["decrypted-tls": wire, "uncompressed-entity-body": Data("hello".utf8)],
            nodes: [http(
                source: "decrypted-tls",
                offset: 0,
                length: headers.utf8.count,
                marker: "http.response.code",
                extraChildren: [node("text", source: "decrypted-tls", offset: headers.utf8.count, length: 4, children: [fileData])]
            )]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: inspection) == [
            PacketHTTPMessage(kind: .response, head: "HTTP/1.1 200 OK\nContent-Encoding: br", body: Data("hello".utf8))
        ])
    }

    @Test func bodyFallsBackToTheBytesAfterTheHeaders() {
        let message = "POST /submit HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc"
        let inspection = makeInspection(
            sources: [:],
            frame: Data(repeating: 0, count: 10) + Data(message.utf8),
            nodes: [http(source: "frame", offset: 10, length: message.utf8.count, marker: "http.request.method")]
        )

        #expect(!PacketHTTPMessageExtractor.hasDecryptedTLS(inspection))
        #expect(PacketHTTPMessageExtractor.messages(in: inspection) == [
            PacketHTTPMessage(kind: .request, head: "POST /submit HTTP/1.1\nContent-Length: 3", body: Data("abc".utf8))
        ])
    }

    @Test func pipelinedMessagesStayInWireOrder() {
        let first = "GET /1 HTTP/1.1\r\nHost: a\r\n\r\n"
        let second = "GET /2 HTTP/1.1\r\nHost: a\r\n\r\n"
        let inspection = makeInspection(
            sources: ["decrypted-tls": Data((first + second).utf8)],
            nodes: [
                http(source: "decrypted-tls", offset: 0, length: first.utf8.count, marker: "http.request.method"),
                http(source: "decrypted-tls", offset: first.utf8.count, length: second.utf8.count, marker: "http.request.method"),
            ]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: inspection).map(\.head) == [
            "GET /1 HTTP/1.1\nHost: a",
            "GET /2 HTTP/1.1\nHost: a",
        ])
    }

    @Test func headerLongerThanADisplayValueStaysExact() {
        // Node values are display text capped near 240 bytes; the message must come from the bytes.
        let cookie = String(repeating: "c", count: 2_000)
        let request = "GET / HTTP/1.1\r\nCookie: \(cookie)\r\n\r\n"
        let inspection = makeInspection(
            sources: ["decrypted-tls": Data(request.utf8)],
            nodes: [http(source: "decrypted-tls", offset: 0, length: request.utf8.count, marker: "http.request.method")]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: inspection).first?.head == "GET / HTTP/1.1\nCookie: \(cookie)")
    }

    @Test func bodyOnlyPacketIsAContinuation() {
        let chunk = Data("more of the body".utf8)
        let inspection = makeInspection(
            sources: ["decrypted-tls": chunk],
            nodes: [http(source: "decrypted-tls", offset: 0, length: chunk.count, marker: nil)]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: inspection) == [
            PacketHTTPMessage(kind: .continuation, head: "", body: chunk)
        ])
    }

    @Test func rangesThatDoNotFitTheirSourceAreIgnored() {
        let request = "GET / HTTP/1.1\r\n\r\n"
        let missingSource = makeInspection(
            sources: [:],
            nodes: [http(source: "decrypted-tls", offset: 0, length: request.utf8.count, marker: "http.request.method")]
        )
        let pastTheEnd = makeInspection(
            sources: ["decrypted-tls": Data(request.utf8)],
            nodes: [http(source: "decrypted-tls", offset: 500, length: 10, marker: "http.request.method")]
        )
        // When Wireshark's source was not extracted the range falls back to the frame bytes.
        let wrongSource = makeInspection(
            sources: [:],
            frame: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]),
            nodes: [http(source: "frame", offset: 0, length: 8, marker: "http.request.method")]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: missingSource).isEmpty)
        #expect(PacketHTTPMessageExtractor.messages(in: pastTheEnd).isEmpty)
        #expect(PacketHTTPMessageExtractor.messages(in: wrongSource).isEmpty)
    }

    @Test func http2RequestGetsAStartLineFromItsPseudoHeaders() {
        let headers = HeaderBlock([(":method", "GET"), (":path", "/index.html"), (":scheme", "https"), (":authority", "example.com"), ("accept", "*/*")])
        let inspection = makeInspection(
            sources: ["decrypted-tls": Data(count: 16), "decompressed-header": headers.bytes],
            nodes: [http2(frames: [frame(streamID: "1", headers: headers.nodes(source: "decompressed-header"))])]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: inspection) == [
            PacketHTTPMessage(kind: .request, head: "GET /index.html HTTP/2\nhost: example.com\naccept: */*", body: Data())
        ])
    }

    @Test func http2HeadersAndDataOfOneStreamFormOneResponse() {
        let headers = HeaderBlock([(":status", "200"), ("content-type", "text/plain")])
        let body = Data("hello".utf8)
        let inspection = makeInspection(
            sources: ["decrypted-tls": body, "decompressed-header": headers.bytes],
            nodes: [
                http2(frames: [frame(streamID: "3", headers: headers.nodes(source: "decompressed-header"))]),
                http2(frames: [frame(streamID: "3", data: node("http2.data.data", source: "decrypted-tls", offset: 0, length: body.count))]),
            ]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: inspection) == [
            PacketHTTPMessage(kind: .response, head: "HTTP/2 200\ncontent-type: text/plain", body: body)
        ])
    }

    @Test func http2StreamsStaySeparateAndControlFramesAreSkipped() {
        let first = HeaderBlock([(":method", "GET"), (":path", "/a")])
        let second = HeaderBlock([(":method", "GET"), (":path", "/b")])
        let data = Data("tail".utf8)
        let inspection = makeInspection(
            sources: ["decrypted-tls": data, "decompressed-header": first.bytes, "decompressed-header-2": second.bytes],
            nodes: [http2(frames: [
                frame(streamID: "0"),
                frame(streamID: "1", headers: first.nodes(source: "decompressed-header")),
                frame(streamID: "3", headers: second.nodes(source: "decompressed-header-2")),
                frame(streamID: "5", data: node("http2.data.data", source: "decrypted-tls", offset: 0, length: data.count)),
            ])]
        )

        #expect(PacketHTTPMessageExtractor.messages(in: inspection) == [
            PacketHTTPMessage(kind: .request, head: "GET /a HTTP/2", body: Data()),
            PacketHTTPMessage(kind: .request, head: "GET /b HTTP/2", body: Data()),
            PacketHTTPMessage(kind: .continuation, head: "", body: data),
        ])
    }

    // HPACK output as Wireshark lays it out: length-prefixed names and values in one byte source.
    private struct HeaderBlock {
        private(set) var bytes = Data()
        private var ranges: [(name: Range<Int>, value: Range<Int>)] = []

        init(_ headers: [(String, String)]) {
            for (name, value) in headers {
                bytes.append(contentsOf: [0, 0, 0, UInt8(name.utf8.count)])
                let nameStart = bytes.count
                bytes.append(Data(name.utf8))
                bytes.append(contentsOf: [0, 0, 0, UInt8(value.utf8.count)])
                let valueStart = bytes.count
                bytes.append(Data(value.utf8))
                ranges.append((nameStart..<nameStart + name.utf8.count, valueStart..<valueStart + value.utf8.count))
            }
        }

        func nodes(source: String) -> [PacketDetailNode] {
            ranges.enumerated().map { index, range in
                PacketDetailNode(id: "header.\(source).\(index)", name: "Header", fieldName: "http2.header", children: [
                    PacketDetailNode(
                        id: "name.\(source).\(index)",
                        name: "Name",
                        fieldName: "http2.header.name",
                        byteRange: PacketByteRange(offset: range.name.lowerBound, length: range.name.count, sourceID: source)
                    ),
                    PacketDetailNode(
                        id: "value.\(source).\(index)",
                        name: "Value",
                        fieldName: "http2.header.value",
                        byteRange: PacketByteRange(offset: range.value.lowerBound, length: range.value.count, sourceID: source)
                    ),
                ])
            }
        }
    }

    private func makeInspection(
        sources: [String: Data],
        frame: Data = Data(repeating: 0xEE, count: 64),
        nodes: [PacketDetailNode]
    ) -> PacketInspection {
        let byteViews = [PacketByteView(id: "frame", label: "Frame", bytes: frame)]
            + sources.sorted { $0.key < $1.key }.map { PacketByteView(id: $0.key, label: $0.key, bytes: $0.value) }
        return PacketInspection(
            packetID: 1,
            packetNumber: 1,
            rawBytes: frame,
            byteViews: byteViews,
            detailNodes: [PacketDetailNode(id: "frame", name: "Frame", fieldName: "frame", kind: .layer)] + nodes,
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }

    // An HTTP/1.x layer shaped like Wireshark's: the start-line field sits under a text item.
    private func http(
        source: String,
        offset: Int,
        length: Int,
        marker: String?,
        extraChildren: [PacketDetailNode] = []
    ) -> PacketDetailNode {
        let startLine = node("text", source: source, offset: offset, length: 1, children: marker.map {
            [node($0, source: source, offset: offset, length: 1)]
        } ?? [])
        return node("http", source: source, offset: offset, length: length, children: [startLine] + extraChildren)
    }

    private func http2(frames: [PacketDetailNode]) -> PacketDetailNode {
        PacketDetailNode(id: "http2.\(UUID())", name: "HyperText Transfer Protocol 2", fieldName: "http2", kind: .layer, children: frames)
    }

    private func frame(streamID: String, headers: [PacketDetailNode] = [], data: PacketDetailNode? = nil) -> PacketDetailNode {
        let streamNode = PacketDetailNode(id: "streamid.\(UUID())", name: "Stream Identifier", fieldName: "http2.streamid", value: streamID)
        return PacketDetailNode(
            id: "stream.\(UUID())",
            name: "Stream",
            fieldName: "http2.stream",
            children: [streamNode] + headers + (data.map { [$0] } ?? [])
        )
    }

    private func node(
        _ fieldName: String,
        source: String,
        offset: Int,
        length: Int,
        children: [PacketDetailNode] = []
    ) -> PacketDetailNode {
        PacketDetailNode(
            id: "\(fieldName).\(source).\(offset)",
            name: fieldName,
            fieldName: fieldName,
            byteRange: PacketByteRange(offset: offset, length: length, sourceID: source),
            children: children
        )
    }
}
