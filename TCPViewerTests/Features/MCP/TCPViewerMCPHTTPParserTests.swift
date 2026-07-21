//
//  TCPViewerMCPHTTPParserTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerMCPHTTPParserTests {
    @Test func parsesOneStrictContentLengthRequestIncrementally() throws {
        let body = Data(#"{"command":"get_app_status"}"#.utf8)
        let bytes = request(body: body)
        let partial = bytes.prefix(bytes.count - 1)
        #expect(TCPViewerMCPHTTPParser.parse(Data(partial)) == .needsMoreData)

        let parsed = TCPViewerMCPHTTPParser.parse(bytes)
        guard case .request(let request) = parsed else {
            Issue.record("Expected a parsed request, got \(parsed)")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer test")
        #expect(request.body == body)
    }

    @Test func rejectsMalformedOrAmbiguousFraming() {
        let failures: [(Data, Int)] = [
            (Data("BAD\r\nContent-Length: 0\r\n\r\n".utf8), 400),
            (Data("POST /mcp HTTP/9\r\nContent-Length: 0\r\n\r\n".utf8), 505),
            (Data("POST /mcp HTTP/1.1\r\n\r\n".utf8), 411),
            (Data("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8), 411),
            (Data("POST /mcp HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8), 400),
            (Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n".utf8), 400),
            (Data("POST /mcp HTTP/1.1\r\n Folded: bad\r\nContent-Length: 0\r\n\r\n".utf8), 400),
            (Data("POST /mcp HTTP/1.1\r\nBad Header: value\r\nContent-Length: 0\r\n\r\n".utf8), 400),
            (Data("POST /mcp HTTP/1.1\r\nX-Bad: value\u{7f}\r\nContent-Length: 0\r\n\r\n".utf8), 400),
            (Data("POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra".utf8), 400),
            (Data("POST /mcp HTTP/1.1\r\nContent-Length: \(TCPViewerMCPHTTPParser.maximumBodyByteCount + 1)\r\n\r\n".utf8), 413),
        ]
        for (bytes, status) in failures {
            guard case .failure(let actualStatus, _) = TCPViewerMCPHTTPParser.parse(bytes) else {
                Issue.record("Expected failure status \(status)")
                continue
            }
            #expect(actualStatus == status)
        }
    }

    @Test func enforcesHeaderLimitAndUTF8() {
        let oversized = Data(("POST /mcp HTTP/1.1\r\nX-Large: " + String(repeating: "x", count: TCPViewerMCPHTTPParser.maximumHeaderByteCount)).utf8)
        #expect(TCPViewerMCPHTTPParser.parse(oversized) == .failure(statusCode: 431, message: "Request headers are too large."))

        var invalidUTF8 = Data("POST /mcp HTTP/1.1\r\nX: ".utf8)
        invalidUTF8.append(0xff)
        invalidUTF8.append(Data("\r\nContent-Length: 0\r\n\r\n".utf8))
        guard case .failure(let status, _) = TCPViewerMCPHTTPParser.parse(invalidUTF8) else {
            Issue.record("Expected invalid UTF-8 failure")
            return
        }
        #expect(status == 400)
    }

    private func request(body: Data) -> Data {
        Data((
            "POST /mcp HTTP/1.1\r\n" +
            "Authorization: Bearer test\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n\r\n"
        ).utf8) + body
    }
}
