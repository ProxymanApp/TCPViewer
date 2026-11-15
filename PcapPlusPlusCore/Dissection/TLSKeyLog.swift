//
//  TLSKeyLog.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import Foundation

// What a TLS key log file holds. Reading it counts lines only; secrets are never kept in memory.
public struct TLSKeyLogSummary: Sendable, Equatable {
    public var byteCount: UInt64 = 0
    public var keyCount = 0
    public var sessionCount = 0
    public var invalidLineCount = 0
    public var containsBinaryData = false

    // Lets a later read of the same, grown file continue after the last complete line instead of from the start.
    var fileNumber: UInt64?
    var resumeOffset: UInt64 = 0
    // The unterminated last line is counted above but read again later, once it is complete.
    var trailingLine = TLSKeyLogLineCounts()

    public init(
        byteCount: UInt64 = 0,
        keyCount: Int = 0,
        sessionCount: Int = 0,
        invalidLineCount: Int = 0,
        containsBinaryData: Bool = false
    ) {
        self.byteCount = byteCount
        self.keyCount = keyCount
        self.sessionCount = sessionCount
        self.invalidLineCount = invalidLineCount
        self.containsBinaryData = containsBinaryData
    }

    // An empty file is a key log still waiting for keys; text with no usable line is something else.
    public var isKeyLog: Bool {
        keyCount > 0 || (invalidLineCount == 0 && !containsBinaryData)
    }

    mutating func add(_ counts: TLSKeyLogLineCounts, sign: Int = 1) {
        keyCount += sign * counts.keyCount
        sessionCount += sign * counts.sessionCount
        invalidLineCount += sign * counts.invalidLineCount
    }
}

struct TLSKeyLogLineCounts: Sendable, Equatable {
    var keyCount = 0
    var sessionCount = 0
    var invalidLineCount = 0
}

// NSS key log files (SSLKEYLOGFILE), as written by Proxyman, browsers and curl, decrypt TLS, DTLS and QUIC.
public enum TLSKeyLog {
    private static let readChunkSize = 1 << 20
    // Wireshark reads key log lines into a 1110-byte buffer; anything longer is not a key line.
    private static let maximumLineLength = 1_110

    // Use a key log for every capture; nil turns key log decryption off.
    // Captures dissected before the change keep their result until they are dissected again.
    public static func setKeyLogFile(_ url: URL?) {
        WiresharkEpanSession.setTLSKeyLogFile(path: url.flatMap { $0.isFileURL ? $0.path : nil })
    }

    // Stream the file in bounded chunks so a key log that grew for months does not load into memory.
    // With `previous` from the same file, only the bytes after its last complete line are read.
    public static func summarize(fileAt url: URL, continuing previous: TLSKeyLogSummary? = nil) throws -> TLSKeyLogSummary {
        let fileNumber = try regularFileNumber(of: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var summary = TLSKeyLogSummary()
        summary.fileNumber = fileNumber
        if var previous, previous.fileNumber == fileNumber, !previous.containsBinaryData,
           try handle.seekToEnd() >= previous.resumeOffset {
            previous.add(previous.trailingLine, sign: -1)
            previous.trailingLine = TLSKeyLogLineCounts()
            previous.byteCount = previous.resumeOffset
            summary = previous
        }
        try handle.seek(toOffset: summary.byteCount)

        var pendingLine = Data()
        while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
            if chunk.contains(0) {
                summary.byteCount += UInt64(chunk.count)
                summary.containsBinaryData = true
                return summary
            }
            var lineStart = chunk.startIndex
            while let newline = chunk[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                pendingLine.append(chunk[lineStart..<newline])
                summary.add(lineCounts(pendingLine))
                pendingLine.removeAll(keepingCapacity: true)
                lineStart = chunk.index(after: newline)
                summary.resumeOffset = summary.byteCount + UInt64(lineStart - chunk.startIndex)
            }
            // Keep at most one line past the limit; longer lines are invalid either way.
            if pendingLine.count <= maximumLineLength {
                pendingLine.append(chunk[lineStart...].prefix(maximumLineLength + 1 - pendingLine.count))
            }
            summary.byteCount += UInt64(chunk.count)
        }
        summary.trailingLine = lineCounts(pendingLine)
        summary.add(summary.trailingLine)
        return summary
    }

    // A FIFO or device would block the read forever, so only regular files, or links to them, are key logs.
    private static func regularFileNumber(of url: URL) throws -> UInt64? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NativeNSError(.fileReadFailed, "It isn't a regular file.")
        }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    // Count one line, using the same line shapes Wireshark's key log parser accepts.
    static func lineCounts(_ lineData: Data) -> TLSKeyLogLineCounts {
        guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              line.utf8.count <= maximumLineLength else {
            return TLSKeyLogLineCounts(invalidLineCount: 1)
        }
        if line.isEmpty || line.hasPrefix("#") {
            return TLSKeyLogLineCounts()
        }
        switch lineKind(line) {
        case .connection:
            return TLSKeyLogLineCounts(keyCount: 1, sessionCount: 1)
        case .secret:
            return TLSKeyLogLineCounts(keyCount: 1)
        case nil:
            return TLSKeyLogLineCounts(invalidLineCount: 1)
        }
    }

    private enum LineKind {
        // The one line every connection has: its TLS 1.2 master secret or TLS 1.3 client handshake secret.
        case connection
        case secret
    }

    private static func lineKind(_ line: String) -> LineKind? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        if fields.count == 3, fields[0] == "RSA", fields[1].hasPrefix("Session-ID:"), fields[2].hasPrefix("Master-Key:") {
            let sessionID = fields[1].dropFirst("Session-ID:".count)
            let masterKey = fields[2].dropFirst("Master-Key:".count)
            return isHex(sessionID) && isHex(masterKey, byteCount: 48) ? .connection : nil
        }
        guard fields.count == 3 else {
            return nil
        }
        let identifier = fields[1]
        let secret = fields[2]
        switch fields[0] {
        case "CLIENT_RANDOM":
            return isHex(identifier, byteCount: 32) && isHex(secret, byteCount: 48) ? .connection : nil
        case "PMS_CLIENT_RANDOM":
            return isHex(identifier, byteCount: 32) && isHex(secret) ? .connection : nil
        case "RSA":
            return isHex(identifier, byteCount: 8) && isHex(secret) ? .connection : nil
        case "CLIENT_HANDSHAKE_TRAFFIC_SECRET":
            return isHex(identifier, byteCount: 32) && isHex(secret) ? .connection : nil
        case "CLIENT_EARLY_TRAFFIC_SECRET", "SERVER_HANDSHAKE_TRAFFIC_SECRET", "CLIENT_TRAFFIC_SECRET_0",
             "SERVER_TRAFFIC_SECRET_0", "EARLY_EXPORTER_SECRET", "EXPORTER_SECRET":
            return isHex(identifier, byteCount: 32) && isHex(secret) ? .secret : nil
        case "ECH_SECRET":
            return isHex(identifier) && (64...128).contains(identifier.count) && isHex(secret) ? .secret : nil
        case "ECH_CONFIG":
            return isHex(identifier) && identifier.count >= 44 && isHex(secret) ? .secret : nil
        default:
            return nil
        }
    }

    // Accept whole hex octets, optionally of an exact byte length.
    private static func isHex(_ value: Substring, byteCount: Int? = nil) -> Bool {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else {
            return false
        }
        if let byteCount, value.count != byteCount * 2 {
            return false
        }
        return value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
    }
}
