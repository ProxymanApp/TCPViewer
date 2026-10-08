//
//  DNSMessageParserTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/8/26.
//

import Darwin
import Foundation
import Testing
@testable import PcapPlusPlusCore

struct DNSMessageParserTests {

    // MARK: - A records

    @Test func parsesSingleAResponse() throws {
        let observations = parse(response(
            questions: [("spotify.com", 1)],
            answers: [record(owner: .pointer(12), type: 1, ttl: 60, data: [35, 186, 224, 34])]
        ))

        #expect(observations == [DNSResolutionObservation(domainName: "spotify.com", ipAddress: "35.186.224.34", timeToLive: 60)])
    }

    @Test func lowercasesARecordDomain() throws {
        let observations = parse(response(
            questions: [("API.Example.COM", 1)],
            answers: [record(owner: .pointer(12), type: 1, ttl: 120, data: [192, 0, 2, 10])]
        ))

        #expect(observations.first?.domainName == "api.example.com")
    }

    @Test func parsesMultipleARecords() throws {
        let observations = parse(response(
            questions: [("pool.example", 1)],
            answers: [
                record(owner: .pointer(12), type: 1, ttl: 30, data: [192, 0, 2, 1]),
                record(owner: .pointer(12), type: 1, ttl: 45, data: [192, 0, 2, 2]),
            ]
        ))

        #expect(observations.map(\.ipAddress) == ["192.0.2.1", "192.0.2.2"])
        #expect(observations.map(\.timeToLive) == [30, 45])
    }

    @Test func deduplicatesRepeatedARecords() throws {
        let duplicate = record(owner: .pointer(12), type: 1, ttl: 30, data: [198, 51, 100, 7])
        let observations = parse(response(
            questions: [("duplicate.example", 1)],
            answers: [duplicate, duplicate]
        ))

        #expect(observations.count == 1)
    }

    @Test func ignoresARecordWithNonInternetClass() throws {
        let observations = parse(response(
            questions: [("class.example", 1)],
            answers: [record(owner: .pointer(12), type: 1, recordClass: 3, ttl: 30, data: [192, 0, 2, 3])]
        ))

        #expect(observations.isEmpty)
    }

    // MARK: - AAAA records

    @Test func parsesSingleAAAAResponse() throws {
        let observations = parse(response(
            questions: [("ipv6.example", 28)],
            answers: [record(owner: .pointer(12), type: 28, ttl: 60, data: ipv6("2001:db8::1"))]
        ))

        #expect(observations == [DNSResolutionObservation(domainName: "ipv6.example", ipAddress: "2001:db8::1", timeToLive: 60)])
    }

    @Test func parsesCompressedAAAAOwner() throws {
        let observations = parse(response(
            questions: [("compressed.example", 28)],
            answers: [record(owner: .pointer(12), type: 28, ttl: 90, data: ipv6("2001:db8::20"))]
        ))

        #expect(observations.first?.ipAddress == "2001:db8::20")
    }

    @Test func parsesMultipleAAAARecords() throws {
        let observations = parse(response(
            questions: [("pool6.example", 28)],
            answers: [
                record(owner: .name("pool6.example"), type: 28, ttl: 20, data: ipv6("2001:db8::1")),
                record(owner: .name("pool6.example"), type: 28, ttl: 25, data: ipv6("2001:db8::2")),
            ]
        ))

        #expect(observations.map(\.ipAddress) == ["2001:db8::1", "2001:db8::2"])
    }

    @Test func canonicalizesExpandedAAAAAddress() throws {
        let observations = parse(response(
            questions: [("canonical.example", 28)],
            answers: [record(owner: .pointer(12), type: 28, ttl: 60, data: ipv6("2001:0db8:0000:0000:0000:0000:0000:0001"))]
        ))

        #expect(observations.first?.ipAddress == "2001:db8::1")
    }

    @Test func rejectsAAAARecordWithInvalidLength() throws {
        let observations = parse(response(
            questions: [("broken6.example", 28)],
            answers: [record(owner: .pointer(12), type: 28, ttl: 60, data: [UInt8](repeating: 0, count: 15))]
        ))

        #expect(observations.isEmpty)
    }

    // MARK: - CNAME records

    @Test func resolvesCNAMEToARecord() throws {
        let observations = parse(response(
            questions: [("music.example", 1)],
            answers: [
                record(owner: .pointer(12), type: 5, ttl: 120, data: encodedName("edge.example")),
                record(owner: .name("edge.example"), type: 1, ttl: 60, data: [203, 0, 113, 8]),
            ]
        ))

        #expect(observations == [DNSResolutionObservation(domainName: "music.example", ipAddress: "203.0.113.8", timeToLive: 60)])
    }

    @Test func resolvesCNAMEToAAAARecord() throws {
        let observations = parse(response(
            questions: [("music6.example", 28)],
            answers: [
                record(owner: .pointer(12), type: 5, ttl: 120, data: encodedName("edge6.example")),
                record(owner: .name("edge6.example"), type: 28, ttl: 60, data: ipv6("2001:db8::8")),
            ]
        ))

        #expect(observations.first?.domainName == "music6.example")
        #expect(observations.first?.ipAddress == "2001:db8::8")
    }

    @Test func followsTwoCNAMEHops() throws {
        let observations = parse(response(
            questions: [("one.example", 1)],
            answers: [
                record(owner: .pointer(12), type: 5, ttl: 300, data: encodedName("two.example")),
                record(owner: .name("two.example"), type: 5, ttl: 200, data: encodedName("three.example")),
                record(owner: .name("three.example"), type: 1, ttl: 100, data: [203, 0, 113, 3]),
            ]
        ))

        #expect(observations.first?.ipAddress == "203.0.113.3")
    }

    @Test func usesMinimumTTLAlongCNAMEChain() throws {
        let observations = parse(response(
            questions: [("short.example", 1)],
            answers: [
                record(owner: .pointer(12), type: 5, ttl: 15, data: encodedName("target.example")),
                record(owner: .name("target.example"), type: 1, ttl: 300, data: [203, 0, 113, 15]),
            ]
        ))

        #expect(observations.first?.timeToLive == 15)
    }

    @Test func stopsCNAMECycles() throws {
        let observations = parse(response(
            questions: [("cycle-a.example", 1)],
            answers: [
                record(owner: .pointer(12), type: 5, ttl: 60, data: encodedName("cycle-b.example")),
                record(owner: .name("cycle-b.example"), type: 5, ttl: 60, data: encodedName("cycle-a.example")),
            ]
        ))

        #expect(observations.isEmpty)
    }

    // MARK: - Invalid and unsupported messages

    @Test func ignoresDNSQueries() throws {
        let message = response(
            flags: 0x0100,
            questions: [("query.example", 1)],
            answers: [record(owner: .pointer(12), type: 1, ttl: 60, data: [192, 0, 2, 1])]
        )

        #expect(parse(message).isEmpty)
    }

    @Test func ignoresTruncatedResponses() throws {
        let message = response(
            flags: 0x8380,
            questions: [("truncated.example", 1)],
            answers: [record(owner: .pointer(12), type: 1, ttl: 60, data: [192, 0, 2, 1])]
        )

        #expect(parse(message).isEmpty)
    }

    @Test func ignoresErrorResponses() throws {
        let message = response(flags: 0x8183, questions: [("missing.example", 1)], answers: [])

        #expect(parse(message).isEmpty)
    }

    @Test func rejectsOutOfBoundsRecordData() throws {
        var message = response(
            questions: [("short.example", 1)],
            answers: [record(owner: .pointer(12), type: 1, ttl: 60, data: [192, 0, 2, 1])]
        )
        message.removeLast()

        #expect(parse(message).isEmpty)
    }

    @Test func rejectsCompressionPointerCycles() throws {
        var message = Data([UInt8](repeating: 0, count: 12))
        message.replaceSubrange(0..<12, with: header(flags: 0x8180, questionCount: 1, answerCount: 0))
        message.append(contentsOf: [0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01])

        #expect(parse(message).isEmpty)
    }

    private func parse(_ data: Data) -> [DNSResolutionObservation] {
        DNSMessageParser(data: data).resolutions()
    }
}

private enum EncodedDNSName {
    case name(String)
    case pointer(UInt16)
}

private struct EncodedDNSRecord {
    let owner: EncodedDNSName
    let type: UInt16
    let recordClass: UInt16
    let ttl: UInt32
    let data: [UInt8]
}

private func record(
    owner: EncodedDNSName,
    type: UInt16,
    recordClass: UInt16 = 1,
    ttl: UInt32,
    data: [UInt8]
) -> EncodedDNSRecord {
    EncodedDNSRecord(owner: owner, type: type, recordClass: recordClass, ttl: ttl, data: data)
}

private func response(
    flags: UInt16 = 0x8180,
    questions: [(String, UInt16)],
    answers: [EncodedDNSRecord]
) -> Data {
    var data = header(
        flags: flags,
        questionCount: UInt16(questions.count),
        answerCount: UInt16(answers.count)
    )
    for (name, type) in questions {
        data.append(contentsOf: encodedName(name))
        data.appendBigEndian(type)
        data.appendBigEndian(UInt16(1))
    }
    for answer in answers {
        switch answer.owner {
        case .name(let value):
            data.append(contentsOf: encodedName(value))
        case .pointer(let offset):
            data.appendBigEndian(UInt16(0xc000) | offset)
        }
        data.appendBigEndian(answer.type)
        data.appendBigEndian(answer.recordClass)
        data.appendBigEndian(answer.ttl)
        data.appendBigEndian(UInt16(answer.data.count))
        data.append(contentsOf: answer.data)
    }
    return data
}

private func header(flags: UInt16, questionCount: UInt16, answerCount: UInt16) -> Data {
    var data = Data()
    data.appendBigEndian(UInt16(0x1234))
    data.appendBigEndian(flags)
    data.appendBigEndian(questionCount)
    data.appendBigEndian(answerCount)
    data.appendBigEndian(UInt16(0))
    data.appendBigEndian(UInt16(0))
    return data
}

private func encodedName(_ name: String) -> [UInt8] {
    var bytes: [UInt8] = []
    for label in name.split(separator: ".") {
        bytes.append(UInt8(label.utf8.count))
        bytes.append(contentsOf: label.utf8)
    }
    bytes.append(0)
    return bytes
}

private func ipv6(_ address: String) -> [UInt8] {
    var value = in6_addr()
    precondition(inet_pton(AF_INET6, address, &value) == 1)
    return withUnsafeBytes(of: value) { Array($0) }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
