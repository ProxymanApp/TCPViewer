//
//  WiresharkTLSDecryptionTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

// The key log is process-wide, so every test restores the empty default before it returns.
@Suite(.serialized)
struct WiresharkTLSDecryptionTests {
    @Test func tls13KeyLogTurnsApplicationDataIntoHTTP() async throws {
        setKeyLog(named: ["tls13-rfc8446.keys"])
        defer { clearKeyLog() }

        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        let summaries = try await document.open()

        #expect(httpPacketNumbers(in: summaries) == [5, 6, 8, 10, 12, 13])
        let response = try await document.inspectPacket(id: 6)
        #expect(response.byteViews.contains { $0.id.hasPrefix("decrypted-tls") })
        #expect(try bodyText(in: response) == "Request for /first, version TLSv1.3, Early data: no\n")
        #expect(try bodyText(in: try await document.inspectPacket(id: 10)) == "Request for /early, version TLSv1.3, Early data: yes\n")
        #expect(try bodyText(in: try await document.inspectPacket(id: 13)) == "Request for /second, version TLSv1.3, Early data: yes\n")
    }

    @Test func tls13WithoutTheEarlySecretLeavesTheEarlyRequestEncrypted() async throws {
        setKeyLog(named: ["tls13-rfc8446-noearly.keys"])
        defer { clearKeyLog() }

        let document = try await openCapture(named: "tls13-rfc8446.pcap")

        #expect(httpPacketNumbers(in: try await document.open()) == [5, 6, 10, 12, 13])
    }

    @Test func captureStaysEncryptedWithoutAKeyLog() async throws {
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        let summaries = try await document.open()

        #expect(httpPacketNumbers(in: summaries).isEmpty)
        let inspection = try await document.inspectPacket(id: 6)
        #expect(!inspection.byteViews.contains { $0.id.hasPrefix("decrypted-tls") })
        #expect(findNode(in: inspection.detailNodes, fieldName: "http") == nil)
    }

    @Test func keyLogOfAnotherCaptureDecryptsNothing() async throws {
        setKeyLog(named: ["tls12-chacha20poly1305.keys"])
        defer { clearKeyLog() }

        let document = try await openCapture(named: "tls13-rfc8446.pcap")

        #expect(httpPacketNumbers(in: try await document.open()).isEmpty)
    }

    @Test func clearedKeyLogAppliesToTheNextCapture() async throws {
        setKeyLog(named: ["tls13-rfc8446.keys"])
        clearKeyLog()

        let document = try await openCapture(named: "tls13-rfc8446.pcap")

        #expect(!WiresharkEpanSession.hasTLSKeyLog)
        #expect(httpPacketNumbers(in: try await document.open()).isEmpty)
    }

    @Test func tls12ChaCha20SuitesDecrypt() async throws {
        setKeyLog(named: ["tls12-chacha20poly1305.keys"])
        defer { clearKeyLog() }

        let document = try await openCapture(named: "tls12-chacha20poly1305.pcap")
        let summaries = try await document.open()
        var decryptedText = ""
        for summary in summaries {
            let inspection = try await document.inspectPacket(id: summary.id)
            for byteView in inspection.byteViews where byteView.id.hasPrefix("decrypted-tls") {
                decryptedText += String(decoding: byteView.bytes, as: UTF8.self)
            }
        }

        // One connection per suite; each server reply names the suite it negotiated.
        for cipher in [
            "ECDHE-ECDSA-CHACHA20-POLY1305",
            "ECDHE-RSA-CHACHA20-POLY1305",
            "DHE-RSA-CHACHA20-POLY1305",
            "RSA-PSK-CHACHA20-POLY1305",
            "DHE-PSK-CHACHA20-POLY1305",
            "ECDHE-PSK-CHACHA20-POLY1305",
            "PSK-CHACHA20-POLY1305",
        ] {
            #expect(decryptedText.contains("Cipher is \(cipher)"), "\(cipher) was not decrypted")
        }
    }

    @Test func eachKeyLogFileUnlocksItsOwnConnection() async throws {
        defer { clearKeyLog() }

        // Secrets embedded in the pcapng are not read, so this capture needs the external files.
        #expect(try await requestedHosts(in: "tls12-dsb.pcapng").isEmpty)

        setKeyLog(named: ["tls12-dsb-1.keys"])
        #expect(try await requestedHosts(in: "tls12-dsb.pcapng").count == 1)

        setKeyLog(named: ["tls12-dsb-1.keys", "tls12-dsb-2.keys"])
        #expect(try await requestedHosts(in: "tls12-dsb.pcapng") == ["example.com", "example.net"])
    }

    @Test func http2OverTLSIsDissected() async throws {
        setKeyLog(named: ["http2-data-reassembly.keys"])
        defer { clearKeyLog() }

        let document = try await openCapture(named: "http2-data-reassembly.pcap")
        let summaries = try await document.open()

        let http2Info = summaries.filter { $0.protocolSummary == "HTTP2" }.map(\.infoSummary)
        #expect(http2Info.contains("HEADERS[1]: GET /wireshark.png"))
        #expect(http2Info.contains("HEADERS[1]: 200 OK"))
        // The body spans five DATA frames; Wireshark names its type once the last one arrives.
        #expect(http2Info.contains("DATA[1] (PNG)"))
    }

    @Test func keysAddedAfterOpeningApplyOnlyAfterARedissect() async throws {
        defer { clearKeyLog() }
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        _ = try await document.open()

        setKeyLog(named: ["tls13-rfc8446.keys"])
        // Wireshark already passed the handshakes, so the loaded rows cannot pick the keys up.
        #expect(httpPacketNumbers(in: document.packetSummaries()).isEmpty)

        let updates = try await document.redissectPackets()

        let httpUpdates = updates.filter { $0.protocolSummary == "HTTP" }
        #expect(httpUpdates.map(\.packetID) == [5, 6, 8, 10, 12, 13])
        #expect(httpUpdates.allSatisfy { $0.transportHint == .http1 })
        #expect(httpPacketNumbers(in: document.packetSummaries()) == [5, 6, 8, 10, 12, 13])
        #expect(try bodyText(in: try await document.inspectPacket(id: 6)) == "Request for /first, version TLSv1.3, Early data: no\n")
    }

    @Test func clearingTheKeyLogRevertsRowsAfterARedissect() async throws {
        setKeyLog(named: ["tls13-rfc8446.keys"])
        defer { clearKeyLog() }
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        _ = try await document.open()

        clearKeyLog()
        let updates = try await document.redissectPackets()

        #expect(httpPacketNumbers(in: document.packetSummaries()).isEmpty)
        #expect(updates.first { $0.packetID == 6 }?.transportHint == .tls)
        let inspection = try await document.inspectPacket(id: 6)
        #expect(!inspection.byteViews.contains { $0.id.hasPrefix("decrypted-tls") })
    }

    @Test func redissectWithUnchangedKeysReportsNoRows() async throws {
        setKeyLog(named: ["tls13-rfc8446.keys"])
        defer { clearKeyLog() }
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        _ = try await document.open()

        #expect(try await document.redissectPackets().isEmpty)
        #expect(httpPacketNumbers(in: document.packetSummaries()) == [5, 6, 8, 10, 12, 13])
    }

    @Test func inspectionStaysDecryptedAfterAnotherCaptureTakesWireshark() async throws {
        setKeyLog(named: ["tls13-rfc8446.keys"])
        defer { clearKeyLog() }
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        _ = try await document.open()

        // Only one capture can own Wireshark's state, so loading another one evicts the first.
        let otherDocument = try await openCapture(named: "tls12-chacha20poly1305.pcap")
        _ = try await otherDocument.open()

        #expect(try bodyText(in: try await document.inspectPacket(id: 6)) == "Request for /first, version TLSv1.3, Early data: no\n")
    }

    @Test func decryptedHTTP1PacketsYieldReadableMessages() async throws {
        setKeyLog(named: ["tls13-rfc8446.keys"])
        defer { clearKeyLog() }
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        _ = try await document.open()

        let request = try await document.inspectPacket(id: 5)
        let response = try await document.inspectPacket(id: 6)

        #expect(PacketHTTPMessageExtractor.hasDecryptedTLS(request))
        #expect(PacketHTTPMessageExtractor.messages(in: request) == [
            PacketHTTPMessage(kind: .request, head: "GET /first HTTP/1.1", body: Data())
        ])
        let responseMessage = try #require(PacketHTTPMessageExtractor.messages(in: response).first)
        #expect(responseMessage.kind == .response)
        #expect(responseMessage.head.hasPrefix("HTTP/1.1 200 OK\n"))
        #expect(String(decoding: responseMessage.body, as: UTF8.self) == "Request for /first, version TLSv1.3, Early data: no\n")
    }

    @Test func decryptedHTTP2PacketsYieldReadableMessages() async throws {
        setKeyLog(named: ["http2-data-reassembly.keys"])
        defer { clearKeyLog() }
        let document = try await openCapture(named: "http2-data-reassembly.pcap")
        _ = try await document.open()

        let request = PacketHTTPMessageExtractor.messages(in: try await document.inspectPacket(id: 13))
        let response = PacketHTTPMessageExtractor.messages(in: try await document.inspectPacket(id: 18))
        let lastData = PacketHTTPMessageExtractor.messages(in: try await document.inspectPacket(id: 37))

        #expect(request == [PacketHTTPMessage(
            kind: .request,
            head: "GET /wireshark.png HTTP/2\nhost: 172.16.5.10:8443\nuser-agent: curl/7.52.1\naccept: */*",
            body: Data()
        )])
        #expect(response.first?.kind == .response)
        #expect(response.first?.head.hasPrefix("HTTP/2 200\ncontent-type: image/png\ndate: ") == true)
        // The final DATA frame carries the body Wireshark reassembled from five frames.
        #expect(lastData.map(\.kind) == [.continuation])
        #expect(lastData.first?.body.count == 76_091)
        #expect(lastData.first?.body.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func plainHTTPYieldsMessagesButIsNotMarkedAsDecrypted() async throws {
        let document = try await openCapture(named: "http-brotli.pcapng")
        _ = try await document.open()

        let response = try await document.inspectPacket(id: 6)
        let message = try #require(PacketHTTPMessageExtractor.messages(in: response).first)

        #expect(!PacketHTTPMessageExtractor.hasDecryptedTLS(response))
        #expect(message.kind == .response)
        #expect(message.head.hasPrefix("HTTP/1.1 200 OK\n"))
        // Wireshark already decompressed the brotli body, so the message carries the readable text.
        #expect(message.body.count == 66)
        #expect(String(data: message.body, encoding: .utf8) != nil)
    }

    @Test func appendedKeysDecryptHandshakesDissectedAfterwards() async throws {
        defer { clearKeyLog() }
        let connections = try keyLinesByConnection(in: "tls13-rfc8446.keys")
        let capture = try NativeCaptureFile.load(from: wiresharkTestDirectory.appendingPathComponent("captures/tls13-rfc8446.pcap"))
        WiresharkEpanSession.setTLSKeyLog(connections.first)
        let session = try WiresharkEpanSession()
        var httpPacketNumbers: [UInt64] = []

        for record in capture.records {
            // The second connection starts at packet 7; its keys land just before, as a live key log delivers them.
            if record.identifier == 7 {
                WiresharkEpanSession.appendTLSKeyLog(connections.second)
            }
            try session.observe(record)
            if try session.summarize(record).protocolSummary == "HTTP" {
                httpPacketNumbers.append(record.identifier)
            }
        }

        #expect(httpPacketNumbers == [5, 6, 8, 10, 12, 13])
        // Appended keys are kept for captures opened later, too.
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        #expect(self.httpPacketNumbers(in: try await document.open()) == [5, 6, 8, 10, 12, 13])
    }

    @Test func keysAppendedAfterTheirHandshakeNeedARedissect() async throws {
        defer { clearKeyLog() }
        let connections = try keyLinesByConnection(in: "tls13-rfc8446.keys")
        WiresharkEpanSession.setTLSKeyLog(connections.first)
        let document = try await openCapture(named: "tls13-rfc8446.pcap")
        #expect(httpPacketNumbers(in: try await document.open()) == [5, 6])

        // This is the live-capture race: the key is written a moment after its handshake was dissected.
        WiresharkEpanSession.appendTLSKeyLog(connections.second)
        #expect(httpPacketNumbers(in: document.packetSummaries()) == [5, 6])

        _ = try await document.redissectPackets()
        #expect(httpPacketNumbers(in: document.packetSummaries()) == [5, 6, 8, 10, 12, 13])
    }

    // Split a key log into the lines of its first connection and the lines of every other one.
    private func keyLinesByConnection(in fileName: String) throws -> (first: Data, second: Data) {
        let url = wiresharkTestDirectory.appendingPathComponent("keys/\(fileName)")
        let lines = String(decoding: TLSKeyLogParser.parse(try Data(contentsOf: url)).lines, as: UTF8.self)
            .split(separator: "\n")
        let firstClientRandom = try #require(lines.first?.split(separator: " ").dropFirst().first)
        let first = lines.filter { $0.contains(firstClientRandom) }
        let second = lines.filter { !$0.contains(firstClientRandom) }
        return (Data((first.joined(separator: "\n") + "\n").utf8), Data((second.joined(separator: "\n") + "\n").utf8))
    }

    private func setKeyLog(named fileNames: [String]) {
        var lines = Data()
        for fileName in fileNames {
            let url = wiresharkTestDirectory.appendingPathComponent("keys/\(fileName)")
            lines.append(TLSKeyLogParser.parse((try? Data(contentsOf: url)) ?? Data()).lines)
        }
        WiresharkEpanSession.setTLSKeyLog(lines)
    }

    private func clearKeyLog() {
        WiresharkEpanSession.setTLSKeyLog(Data())
    }

    private func openCapture(named fileName: String) async throws -> any OfflineCaptureDocumentProviding {
        try await NativeTCPViewerCore().openOfflineCaptureDocument(
            at: wiresharkTestDirectory.appendingPathComponent("captures/\(fileName)")
        )
    }

    private func httpPacketNumbers(in summaries: [PacketSummary]) -> [UInt64] {
        summaries.filter { $0.protocolSummary == "HTTP" }.map(\.packetNumber)
    }

    // Read the decoded HTTP body through its byte range, the same way the inspector does.
    private func bodyText(in inspection: PacketInspection) throws -> String {
        let node = try #require(findNode(in: inspection.detailNodes, fieldName: "http.file_data"))
        let range = try #require(node.byteRange)
        let byteView = try #require(inspection.byteViews.first { $0.id == range.sourceID })
        try #require(range.upperBound <= byteView.bytes.count)
        let start = byteView.bytes.startIndex + range.offset
        return String(decoding: byteView.bytes[start..<start + range.length], as: UTF8.self)
    }

    private func requestedHosts(in fileName: String) async throws -> [String] {
        let document = try await openCapture(named: fileName)
        var hosts: [String] = []
        for summary in try await document.open() where summary.protocolSummary == "HTTP" {
            let inspection = try await document.inspectPacket(id: summary.id)
            // Node values are display text, so the header's line ending arrives escaped.
            if let host = findNode(in: inspection.detailNodes, fieldName: "http.host")?.value {
                hosts.append(host.replacingOccurrences(of: "\\r\\n", with: ""))
            }
        }
        return hosts
    }

    private func findNode(in nodes: [PacketDetailNode], fieldName: String) -> PacketDetailNode? {
        for node in nodes {
            if node.fieldName == fieldName {
                return node
            }
            if let match = findNode(in: node.children, fieldName: fieldName) {
                return match
            }
        }
        return nil
    }

    private var wiresharkTestDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/Wireshark/test")
    }
}
