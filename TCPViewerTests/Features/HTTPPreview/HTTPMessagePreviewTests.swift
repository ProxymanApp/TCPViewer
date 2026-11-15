//
//  HTTPMessagePreviewTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

// The trees below copy the shape Wireshark gives decrypted HTTP/1.1 and HTTP/2 packets.
struct HTTPMessagePreviewTests {
    @Test func http1ResponseKeepsHeadersAndPrettifiesJSONInOrder() throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 34\r\n\r\n"
        let body = #"{"b":1.50,"a":[true,null],"c":{}}"#
        let bytes = Data((head + body).utf8)
        let layer = node("http", "Hypertext Transfer Protocol", range: range(0, head.utf8.count), [
            node("text", #"HTTP/1.1 200 OK\r\n"#),
            node("http.request_in", "[Request in frame: 5]"),
            node("http.file_data", "File Data: 34 bytes", range: range(head.utf8.count, body.utf8.count)),
        ])
        let inspection = makeInspection([node("tcp", "Transmission Control Protocol"), layer], sources: ["decrypted-tls": bytes])

        #expect(HTTPMessagePreview.isAvailable(in: inspection))
        let preview = try #require(HTTPMessagePreview.make(from: inspection))
        #expect(preview.kind == .response)
        #expect(preview.title == "200 OK")
        #expect(preview.isJSONBody)
        #expect(preview.text == """
            HTTP/1.1 200 OK
            Content-Type: application/json
            Content-Length: 34

            {
              "b": 1.50,
              "a": [
                true,
                null
              ],
              "c": {}
            }
            """)
    }

    @Test func http1RequestWithoutBytesIsRebuiltFromRows() throws {
        let layer = node("http", "Hypertext Transfer Protocol", [
            node("text", #"GET /first HTTP/1.1\r\n"#),
            node("http.host", #"Host: example.com\r\n"#),
            node("text", #"\r\n"#),
            node("http.response_in", "[Response in frame: 6]"),
            node("http.file_data", "File Data: 3 bytes"),
        ])
        let preview = try #require(HTTPMessagePreview.make(from: makeInspection([layer])))
        #expect(preview.kind == .request)
        #expect(preview.title == "GET /first")
        #expect(preview.text == "GET /first HTTP/1.1\nHost: example.com")
        #expect(!preview.isJSONBody)
    }

    @Test func http2ResponseUsesDecodedHeadersAndTheStreamBody() throws {
        let body = Data(#"[{"id":1}]"#.utf8)
        let layer = node("http2", "HyperText Transfer Protocol 2", [
            node("http2.stream", "Stream: HEADERS, Stream ID: 3", [
                node("http2.streamid", "Stream Identifier: 3", value: "3"),
                header(":status", "200"),
                header("content-type", "application/json; charset=utf-8"),
            ]),
            node("http2.stream", "Stream: DATA, Stream ID: 3", [
                node("http2.streamid", "Stream Identifier: 3", value: "3"),
                node("http2.data.data", "Data", range: range(0, body.count)),
            ]),
        ])
        let preview = try #require(HTTPMessagePreview.make(from: makeInspection([layer], sources: ["decrypted-tls": body])))
        #expect(preview.kind == .response)
        #expect(preview.title == "200")
        #expect(preview.text == "HTTP/2 200\ncontent-type: application/json; charset=utf-8\n\n[\n  {\n    \"id\": 1\n  }\n]")
        #expect(preview.isJSONBody)
    }

    @Test func http2RequestWritesAStartLineFromPseudoHeaders() throws {
        let layer = node("http2", "HyperText Transfer Protocol 2", [
            node("http2.stream", "Stream: HEADERS, Stream ID: 1", [
                node("http2.streamid", "Stream Identifier: 1", value: "1"),
                header(":method", "GET"),
                header(":scheme", "https"),
                header(":path", "/json?x=1"),
                header(":authority", "example.com"),
                header("accept", "*/*"),
            ]),
        ])
        let preview = try #require(HTTPMessagePreview.make(from: makeInspection([layer])))
        #expect(preview.kind == .request)
        #expect(preview.title == "GET /json?x=1")
        #expect(preview.text == "GET /json?x=1 HTTP/2\n:scheme: https\n:authority: example.com\naccept: */*")
    }

    @Test func http2DataFrameAloneShowsTheBody() throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let layer = node("http2", "HyperText Transfer Protocol 2", [
            node("http2.stream", "Stream: DATA, Stream ID: 1", [
                node("http2.streamid", "Stream Identifier: 1", value: "1"),
                node("http2.data.data", "Data", range: PacketByteRange(offset: 0, length: body.count, sourceID: "reassembled-body")),
            ]),
        ])
        let inspection = makeInspection([layer], sources: ["reassembled-body": body])
        #expect(HTTPMessagePreview.isAvailable(in: inspection))
        let preview = try #require(HTTPMessagePreview.make(from: inspection))
        #expect(preview.kind == .body)
        #expect(preview.text == "{\n  \"ok\": true\n}")
        #expect(preview.isJSONBody)
    }

    @Test func packetsWithoutAnHTTPMessageHaveNoPreview() {
        let tlsOnly = makeInspection([node("tls", "Transport Layer Security")])
        let continuation = makeInspection([node("http", "Hypertext Transfer Protocol", [node("http.file_data", "File Data: 10 bytes")])])
        for inspection in [tlsOnly, continuation] {
            #expect(!HTTPMessagePreview.isAvailable(in: inspection))
            #expect(HTTPMessagePreview.make(from: inspection) == nil)
        }
    }

    @Test func bodiesThatAreNotJSONStayAsSent() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(HTTPMessagePreview.renderBody(png, contentType: "image/png") == ("[8 bytes of binary data, image/png]", false))
        #expect(HTTPMessagePreview.renderBody(Data("{not json".utf8), contentType: "application/json") == ("{not json", false))
        #expect(HTTPMessagePreview.renderBody(Data("<p>hi</p>\n".utf8), contentType: "text/html") == ("<p>hi</p>\n", false))
    }

    @Test func largeBodiesAreCutWithoutSplittingACharacter() {
        let limit = HTTPMessagePreview.maximumBodyBytes
        let body = Data(repeating: UInt8(ascii: "a"), count: limit - 1) + Data("é".utf8)
        let rendered = HTTPMessagePreview.renderBody(body, contentType: "text/plain")
        #expect(!rendered.isJSON)
        #expect(rendered.text.hasPrefix(String(repeating: "a", count: limit - 1) + "\n\n["))
        #expect(rendered.text.hasSuffix("more not shown]"))
    }

    @Test func jsonFormatterKeepsStringsKeysAndNumbersAsWritten() {
        #expect(HTTPMessageJSONFormatter.prettyPrinted(#"{"z":"x\"}{,:","a":[ ],"n":1e3}"#) == "{\n  \"z\": \"x\\\"}{,:\",\n  \"a\": [],\n  \"n\": 1e3\n}")
        #expect(HTTPMessageJSONFormatter.prettyPrinted("42") == "42")
        #expect(HTTPMessageJSONFormatter.prettyPrinted("{\"a\":") == nil)
    }

    @Test func subtitleNamesTheMessageKind() {
        let response = HTTPMessagePreview(kind: .response, title: "200 OK", text: "", isJSONBody: true)
        let request = HTTPMessagePreview(kind: .request, title: "GET /", text: "", isJSONBody: false)
        #expect(HTTPMessagePreviewViewController.subtitle(for: response) == "Response · JSON prettified")
        #expect(HTTPMessagePreviewViewController.subtitle(for: request) == "Request")
    }

    // MARK: Helpers

    private func node(_ field: String, _ label: String, value: String? = nil, range: PacketByteRange? = nil, _ children: [PacketDetailNode] = []) -> PacketDetailNode {
        PacketDetailNode(id: UUID().uuidString, name: label, label: label, fieldName: field, value: value, byteRange: range, children: children)
    }

    private func header(_ name: String, _ value: String) -> PacketDetailNode {
        node("http2.header", "Header: \(name): \(value)", [
            node("http2.header.name", "Name: \(name)", value: name),
            node("http2.header.value", "Value: \(value)", value: value),
        ])
    }

    private func range(_ offset: Int, _ length: Int) -> PacketByteRange {
        PacketByteRange(offset: offset, length: length, sourceID: "decrypted-tls")
    }

    private func makeInspection(_ layers: [PacketDetailNode], sources: [String: Data] = [:]) -> PacketInspection {
        PacketInspection(
            packetID: 1,
            packetNumber: 1,
            rawBytes: Data([0]),
            byteViews: [PacketByteView(id: "frame", label: "Packet", bytes: Data([0]))]
                + sources.map { PacketByteView(id: $0.key, label: $0.key, bytes: $0.value) },
            detailNodes: layers,
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }
}
