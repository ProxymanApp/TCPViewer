//
//  TLSKeyLogParserTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct TLSKeyLogParserTests {
    private let clientRandom = String(repeating: "ab", count: 32)
    private let otherClientRandom = String(repeating: "cd", count: 32)
    private let secret = String(repeating: "01", count: 32)

    @Test func scrubbedProxymanSampleKeepsEverySession() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TLSKeyLogs/proxyman-tls13-scrubbed.keylog")

        let keyLog = TLSKeyLogParser.parse(try Data(contentsOf: fixtureURL))

        // 39 TLS 1.3 sessions, each with two handshake secrets, two traffic secrets and an exporter secret.
        #expect(keyLog.sessionCount == 39)
        #expect(keyLog.keyCount == 195)
        #expect(keyLog.skippedLineCount == 0)
        #expect(!keyLog.isTruncated)
        let labels = Set(text(keyLog).split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
        #expect(labels == [
            "CLIENT_HANDSHAKE_TRAFFIC_SECRET",
            "SERVER_HANDSHAKE_TRAFFIC_SECRET",
            "CLIENT_TRAFFIC_SECRET_0",
            "SERVER_TRAFFIC_SECRET_0",
            "EXPORTER_SECRET",
        ])
    }

    @Test func emptyInputIsAnEmptyKeyLog() {
        #expect(TLSKeyLogParser.parse(Data()) == .empty)
        #expect(TLSKeyLog.empty.isEmpty)
    }

    @Test func blankLinesCommentsAndWindowsLineEndingsAreIgnored() {
        let keyLog = parse("# exported by a browser\r\n\r\n   \r\nCLIENT_RANDOM \(clientRandom) \(secret)\r\n\n")

        #expect(text(keyLog) == "CLIENT_RANDOM \(clientRandom) \(secret)\n")
        #expect(keyLog.keyCount == 1)
        #expect(keyLog.skippedLineCount == 0)
    }

    @Test func whitespaceAndHexCaseAreNormalized() {
        let keyLog = parse("  CLIENT_TRAFFIC_SECRET_0\t\(clientRandom.uppercased())   \(secret.uppercased())  ")

        #expect(text(keyLog) == "CLIENT_TRAFFIC_SECRET_0 \(clientRandom) \(secret)\n")
    }

    @Test func finalLineWithoutNewlineIsKept() {
        let keyLog = parse("CLIENT_RANDOM \(clientRandom) \(secret)\nCLIENT_RANDOM \(otherClientRandom) \(secret)")

        #expect(keyLog.keyCount == 2)
        #expect(keyLog.sessionCount == 2)
        #expect(text(keyLog).hasSuffix("\(otherClientRandom) \(secret)\n"))
    }

    @Test func sessionsAreCountedByDistinctClientRandom() {
        let keyLog = parse("""
        CLIENT_HANDSHAKE_TRAFFIC_SECRET \(clientRandom) \(secret)
        SERVER_HANDSHAKE_TRAFFIC_SECRET \(clientRandom.uppercased()) \(secret)
        CLIENT_RANDOM \(otherClientRandom) \(String(repeating: "02", count: 48))
        RSA 0011223344556677 \(String(repeating: "03", count: 48))
        """)

        // The legacy RSA line is keyed by an encrypted pre-master prefix, not a client random.
        #expect(keyLog.keyCount == 4)
        #expect(keyLog.sessionCount == 2)
    }

    @Test(arguments: [
        "CLIENT_RANDOM",
        "CLIENT_RANDOM abcd",
        "CLIENT_RANDOM abcd 0102 0304",
        "CLIENT_RANDOM abc 0102",
        "CLIENT_RANDOM abcd 010",
        "CLIENT_RANDOM wxyz 0102",
        "client_random abcd 0102",
        "CLIENT-RANDOM abcd 0102",
        "RSA Session-ID:abcd Master-Key:0102",
    ])
    func malformedLinesAreSkipped(line: String) {
        let keyLog = parse("\(line)\nCLIENT_RANDOM \(clientRandom) \(secret)\n")

        #expect(keyLog.keyCount == 1)
        #expect(keyLog.skippedLineCount == 1)
        #expect(text(keyLog) == "CLIENT_RANDOM \(clientRandom) \(secret)\n")
    }

    @Test func overlongLinesAreSkipped() {
        let hugeSecret = String(repeating: "ab", count: TLSKeyLogParser.maximumLineBytes)

        let keyLog = parse("CLIENT_RANDOM \(clientRandom) \(hugeSecret)\n")

        #expect(keyLog.isEmpty)
        #expect(keyLog.skippedLineCount == 1)
    }

    @Test func binaryInputYieldsNoKeys() {
        var bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        bytes.append(Data([0x0A, 0x00, 0xFF, 0x0A]))

        let keyLog = TLSKeyLogParser.parse(bytes)

        #expect(keyLog.isEmpty)
        #expect(keyLog.keyCount == 0)
    }

    @Test func inputBeyondTheSizeLimitDropsTheCutOffLine() {
        let firstLine = "CLIENT_RANDOM \(clientRandom) \(secret)\n"
        let input = Data((firstLine + "CLIENT_RANDOM \(otherClientRandom) \(secret)\n").utf8)

        // The limit lands inside the second secret, which would otherwise parse as a shorter key.
        let keyLog = TLSKeyLogParser.parse(input, maximumInputBytes: input.count - 9)

        #expect(keyLog.isTruncated)
        #expect(text(keyLog) == firstLine)
    }

    private func parse(_ text: String) -> TLSKeyLog {
        TLSKeyLogParser.parse(Data(text.utf8))
    }

    private func text(_ keyLog: TLSKeyLog) -> String {
        String(decoding: keyLog.lines, as: UTF8.self)
    }
}
