//
//  TCPViewerMCPHTTPParser.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import Foundation

struct TCPViewerMCPHTTPRequest: Equatable {
    let method: String
    let path: String
    let version: String
    let headers: [String: String]
    let body: Data
}

enum TCPViewerMCPHTTPParseResult: Equatable {
    case needsMoreData
    case request(TCPViewerMCPHTTPRequest)
    case failure(statusCode: Int, message: String)
}

enum TCPViewerMCPHTTPParser {
    static let maximumHeaderByteCount = 32 * 1_024
    static let maximumBodyByteCount = 1_024 * 1_024

    private static let headerSeparator = Data([13, 10, 13, 10])

    // Parse exactly one close-delimited request and reject ambiguous framing.
    static func parse(_ data: Data) -> TCPViewerMCPHTTPParseResult {
        guard let separatorRange = data.range(of: headerSeparator) else {
            return data.count > maximumHeaderByteCount
                ? .failure(statusCode: 431, message: "Request headers are too large.")
                : .needsMoreData
        }
        guard separatorRange.lowerBound <= maximumHeaderByteCount else {
            return .failure(statusCode: 431, message: "Request headers are too large.")
        }

        let headerData = data[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(statusCode: 400, message: "Request headers must be valid UTF-8.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(statusCode: 400, message: "Missing HTTP request line.")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            return .failure(statusCode: 400, message: "Malformed HTTP request line.")
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(statusCode: 505, message: "Unsupported HTTP version.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t",
                  let separator = line.firstIndex(of: ":") else {
                return .failure(statusCode: 400, message: "Malformed HTTP header.")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidHeaderName(name), isValidHeaderValue(value), headers[name] == nil else {
                return .failure(statusCode: 400, message: "Invalid or duplicate HTTP header.")
            }
            headers[name] = value
        }

        guard headers["transfer-encoding"] == nil else {
            return .failure(statusCode: 400, message: "Transfer-Encoding is not supported.")
        }
        guard let rawContentLength = headers["content-length"],
              let contentLength = Int(rawContentLength), contentLength >= 0 else {
            return .failure(statusCode: 411, message: "A valid Content-Length header is required.")
        }
        guard contentLength <= maximumBodyByteCount else {
            return .failure(statusCode: 413, message: "Request body is too large.")
        }

        let bodyStart = separatorRange.upperBound
        let receivedBodyCount = data.count - bodyStart
        if receivedBodyCount < contentLength {
            return .needsMoreData
        }
        guard receivedBodyCount == contentLength else {
            return .failure(statusCode: 400, message: "Request contains bytes beyond Content-Length.")
        }

        return .request(TCPViewerMCPHTTPRequest(
            method: method,
            path: path,
            version: version,
            headers: headers,
            body: data[bodyStart...]
        ))
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte == 9 || (byte >= 32 && byte != 127)
        }
    }
}
