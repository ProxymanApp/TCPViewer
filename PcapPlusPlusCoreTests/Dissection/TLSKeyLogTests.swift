//
//  TLSKeyLogTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct TLSKeyLogTests {
    private let clientRandom = String(repeating: "ab", count: 32)
    private let masterSecret = String(repeating: "cd", count: 48)
    private let trafficSecret = String(repeating: "ef", count: 32)

    @Test func countsTLS12AndTLS13SessionsAndIgnoresComments() throws {
        let summary = try summarize("""
        # Proxyman TLS key log
        CLIENT_RANDOM \(clientRandom) \(masterSecret)
        CLIENT_HANDSHAKE_TRAFFIC_SECRET \(clientRandom) \(trafficSecret)
        SERVER_HANDSHAKE_TRAFFIC_SECRET \(clientRandom) \(trafficSecret)
        CLIENT_TRAFFIC_SECRET_0 \(clientRandom) \(trafficSecret)
        SERVER_TRAFFIC_SECRET_0 \(clientRandom) \(trafficSecret)
        EXPORTER_SECRET \(clientRandom) \(trafficSecret)

        """)

        #expect(summary.keyCount == 6)
        #expect(summary.sessionCount == 2)
        #expect(summary.invalidLineCount == 0)
        #expect(summary.isKeyLog)
    }

    @Test func acceptsCRLFLineEndingsAndAMissingFinalNewline() throws {
        let summary = try summarize("CLIENT_RANDOM \(clientRandom) \(masterSecret)\r\nRSA 0011223344556677 \(masterSecret)")

        #expect(summary.keyCount == 2)
        #expect(summary.sessionCount == 2)
        #expect(summary.invalidLineCount == 0)
    }

    @Test func emptyFileIsAKeyLogWaitingForKeys() throws {
        let summary = try summarize("")

        #expect(summary.byteCount == 0)
        #expect(summary.keyCount == 0)
        #expect(summary.isKeyLog)
    }

    @Test func plainTextIsNotAKeyLog() throws {
        let summary = try summarize("Hello world\nThis is a README, not a key log.\n")

        #expect(summary.keyCount == 0)
        #expect(summary.invalidLineCount == 2)
        #expect(!summary.isKeyLog)
    }

    @Test func malformedKeyLinesAreCountedAsInvalid() throws {
        let summary = try summarize("""
        CLIENT_RANDOM \(clientRandom) \(masterSecret)
        CLIENT_RANDOM tooshort \(masterSecret)
        CLIENT_RANDOM \(clientRandom) \(String(repeating: "zz", count: 48))
        UNKNOWN_LABEL \(clientRandom) \(masterSecret)
        """)

        #expect(summary.keyCount == 1)
        #expect(summary.invalidLineCount == 3)
        #expect(summary.isKeyLog)
    }

    @Test func binaryFileIsNotAKeyLog() throws {
        // A capture file dropped by mistake starts with binary magic bytes.
        let summary = try summarize(Data([0xd4, 0xc3, 0xb2, 0xa1, 0x02, 0x00, 0x04, 0x00]))

        #expect(summary.containsBinaryData)
        #expect(!summary.isKeyLog)
    }

    @Test func overlongLineAcrossReadChunksIsInvalid() throws {
        // A 3 MiB line spans several 1 MiB reads but is bounded in memory and counted once.
        let longLine = "CLIENT_RANDOM \(clientRandom) " + String(repeating: "a", count: 3 << 20)
        let summary = try summarize(longLine + "\nCLIENT_RANDOM \(clientRandom) \(masterSecret)\n")

        #expect(summary.invalidLineCount == 1)
        #expect(summary.keyCount == 1)
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try TLSKeyLog.summarize(fileAt: URL(fileURLWithPath: "/nonexistent/tcpviewer-missing.keys"))
        }
    }

    private func summarize(_ text: String) throws -> TLSKeyLogSummary {
        try summarize(Data(text.utf8))
    }

    private func summarize(_ data: Data) throws -> TLSKeyLogSummary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).keys")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try TLSKeyLog.summarize(fileAt: url)
    }
}
