//
//  DNSTCPStreamParserTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/8/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

struct DNSTCPStreamParserTests {
    private let expectedResolution = DNSResolutionObservation(
        domainName: "www.example.com",
        ipAddress: "93.184.216.34",
        timeToLive: 60
    )

    @Test func reassemblesSplitLengthPrefix() {
        var parser = DNSTCPStreamParser()
        let message = framedResponse()

        #expect(parse(&parser, sequence: 10, payload: Array(message.prefix(1))).isEmpty)
        #expect(parse(&parser, sequence: 11, payload: Array(message.dropFirst())) == [expectedResolution])
    }

    @Test func reassemblesMessageBodyAcrossSegments() {
        var parser = DNSTCPStreamParser()
        let message = framedResponse()
        let splitIndex = message.count / 2

        #expect(parse(&parser, sequence: 100, payload: Array(message[..<splitIndex])).isEmpty)
        #expect(parse(
            &parser,
            sequence: UInt32(100 + splitIndex),
            payload: Array(message[splitIndex...])
        ) == [expectedResolution])
    }

    @Test func parsesMultipleMessagesFromOneSegment() {
        var parser = DNSTCPStreamParser()
        let secondResolution = DNSResolutionObservation(
            domainName: "www.example.com",
            ipAddress: "203.0.113.9",
            timeToLive: 60
        )
        let payload = framedResponse() + framedResponse(address: [203, 0, 113, 9])

        #expect(parse(&parser, sequence: 1, payload: payload) == [expectedResolution, secondResolution])
    }

    @Test func ignoresFullyRetransmittedBytes() {
        var parser = DNSTCPStreamParser()
        let message = framedResponse()
        let splitIndex = message.count / 2
        let firstSegment = Array(message[..<splitIndex])

        #expect(parse(&parser, sequence: 500, payload: firstSegment).isEmpty)
        #expect(parse(&parser, sequence: 500, payload: firstSegment).isEmpty)
        #expect(parse(
            &parser,
            sequence: UInt32(500 + splitIndex),
            payload: Array(message[splitIndex...])
        ) == [expectedResolution])
    }

    @Test func keepsConcurrentClientStreamsIsolated() {
        var parser = DNSTCPStreamParser()
        let message = framedResponse()
        let splitIndex = message.count / 2

        #expect(parse(&parser, sequence: 1, payload: Array(message[..<splitIndex]), destinationPort: 50_001).isEmpty)
        #expect(parse(&parser, sequence: 80, payload: Array(message[..<splitIndex]), destinationPort: 50_002).isEmpty)
        #expect(parse(
            &parser,
            sequence: UInt32(1 + splitIndex),
            payload: Array(message[splitIndex...]),
            destinationPort: 50_001
        ) == [expectedResolution])
        #expect(parse(
            &parser,
            sequence: UInt32(80 + splitIndex),
            payload: Array(message[splitIndex...]),
            destinationPort: 50_002
        ) == [expectedResolution])
    }

    @Test func resetDiscardsPartialMessages() {
        var parser = DNSTCPStreamParser()
        let message = framedResponse()

        #expect(parse(&parser, sequence: 1, payload: Array(message.prefix(10))).isEmpty)
        parser.reset()
        #expect(parse(&parser, sequence: 100, payload: message) == [expectedResolution])
    }

    private func parse(
        _ parser: inout DNSTCPStreamParser,
        sequence: UInt32,
        payload: [UInt8],
        destinationPort: UInt16 = 50_000
    ) -> [DNSResolutionObservation] {
        var packet = AnalyzedPacket()
        packet.sourceAddress = "192.0.2.53"
        packet.sourcePort = 53
        packet.destinationAddress = "192.0.2.10"
        packet.destinationPort = destinationPort
        packet.dnsTCPStreamSegment = DNSTCPStreamSegment(
            payloadSequenceNumber: sequence,
            payload: payload,
            resetsStream: false,
            endsStream: false
        )
        return parser.resolutions(for: packet, at: Date(timeIntervalSince1970: TimeInterval(sequence)))
    }

    private func framedResponse(address: [UInt8] = [93, 184, 216, 34]) -> [UInt8] {
        let response = dnsResponse(address: address)
        return [UInt8(response.count >> 8), UInt8(response.count & 0xff)] + response
    }

    private func dnsResponse(address: [UInt8]) -> [UInt8] {
        [
            0x12, 0x34, 0x81, 0x80,
            0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x03, 0x77, 0x77, 0x77,
            0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
            0x03, 0x63, 0x6f, 0x6d, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x3c, 0x00, 0x04,
        ] + address
    }
}
