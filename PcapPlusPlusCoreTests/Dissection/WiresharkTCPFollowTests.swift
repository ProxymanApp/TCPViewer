//
//  WiresharkTCPFollowTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkTCPFollowTests {
    @Test func reassemblesBothDirectionsAndIgnoresRetransmissions() throws {
        let records = makeConversation()
        var progressUpdates: [TCPFollowProgress] = []

        let result = try followTCPStream(
            containing: records[3],
            records: records,
            limits: .default,
            progress: { progressUpdates.append($0) },
            shouldCancel: nil
        )

        #expect(result.client.address == "192.0.2.1")
        #expect(result.client.port == 50_000)
        #expect(result.server.address == "198.51.100.2")
        #expect(result.server.port == 8_080)
        #expect(payload(in: result, direction: .clientToServer) == Data("hello world".utf8))
        #expect(payload(in: result, direction: .serverToClient) == Data("reply".utf8))
        #expect(result.clientByteCount == 11)
        #expect(result.serverByteCount == 5)
        #expect(result.isTruncated == false)
        #expect(Set(result.records.map(\.packetID)).isSubset(of: Set(records.map(\.identifier))))
        #expect(progressUpdates.map(\.processedPacketCount) == [1, records.count])
    }

    @Test func respectsPayloadAndRecordLimits() throws {
        let records = makeConversation()
        let result = try followTCPStream(
            containing: records[3],
            records: records,
            limits: TCPFollowLimits(
                maximumCandidatePacketCount: records.count,
                maximumPayloadBytes: 6,
                maximumRecordCount: 1
            ),
            progress: nil,
            shouldCancel: nil
        )

        #expect(result.isTruncated)
        #expect(result.records.count <= 1)
        #expect(result.records.reduce(0) { $0 + $1.data.count } <= 6)
    }

    @Test func exactPayloadLimitIsNotMarkedTruncated() throws {
        let records = makeConversation()
        let result = try followTCPStream(
            containing: records[3],
            records: records,
            limits: TCPFollowLimits(
                maximumCandidatePacketCount: records.count,
                maximumPayloadBytes: 16,
                maximumRecordCount: records.count
            ),
            progress: nil,
            shouldCancel: nil
        )

        #expect(result.records.reduce(0) { $0 + $1.data.count } == 16)
        #expect(!result.isTruncated)
    }

    @Test func candidateIndexSeparatesReusedEndpointTupleConnections() throws {
        let firstConnection = makeConversation()
        let firstReset = makeTCPPacket(
            identifier: 8,
            sourceIsClient: true,
            sequence: 112,
            acknowledgment: 906,
            flags: 0x14
        )
        let secondConnection = [
            makeTCPPacket(identifier: 9, sourceIsClient: true, sequence: 5_000, acknowledgment: 0, flags: 0x02),
            makeTCPPacket(identifier: 10, sourceIsClient: false, sequence: 6_000, acknowledgment: 5_001, flags: 0x12),
            makeTCPPacket(identifier: 11, sourceIsClient: true, sequence: 5_001, acknowledgment: 6_001, flags: 0x10),
            makeTCPPacket(
                identifier: 12,
                sourceIsClient: true,
                sequence: 5_001,
                acknowledgment: 6_001,
                flags: 0x18,
                payload: Data("second".utf8)
            ),
        ]
        let session = try WiresharkEpanSession()
        for record in firstConnection + [firstReset] + secondConnection {
            try session.observe(record)
        }
        try session.finishFirstPass()

        let candidates = try session.tcpFollowCandidatePacketIdentifiers(
            containing: 12,
            maximumPacketCount: 100
        )

        #expect(Set(candidates) == Set(secondConnection.map(\.identifier)))
    }

    @Test func candidateIndexIncludesIPv4FragmentsNeededForTCPReassembly() throws {
        let records = makeFragmentedTCPPacket()
        let session = try WiresharkEpanSession()
        for record in records {
            try session.observe(record)
        }
        try session.finishFirstPass()

        let candidates = try session.tcpFollowCandidatePacketIdentifiers(
            containing: records[1].identifier,
            maximumPacketCount: 10
        )
        let result = try session.followObservedTCPStream(
            containing: records[1],
            records: records,
            limits: .default,
            progress: nil,
            shouldCancel: nil
        )

        #expect(Set(candidates) == Set(records.map(\.identifier)))
        #expect(payload(in: result, direction: .clientToServer) == Data("fragmented".utf8))
    }

    @Test func rejectsNonTCPPacketAndCancellation() throws {
        let udp = makeUDPPacket(identifier: 20)
        #expect(throws: NSError.self) {
            try followTCPStream(
                containing: udp,
                records: [udp],
                limits: .default,
                progress: nil,
                shouldCancel: nil
            )
        }

        let records = makeConversation()
        #expect(throws: NSError.self) {
            try followTCPStream(
                containing: records[0],
                records: records,
                limits: .default,
                progress: nil,
                shouldCancel: { true }
            )
        }
    }

    @Test func liveFollowKeepsTheActiveFirstPassUsable() throws {
        let liveSession = try WiresharkEpanSession(purpose: .live)
        let liveRecord = makeUDPPacket(identifier: 100)
        try liveSession.observe(liveRecord)
        #expect(try liveSession.summarize(liveRecord).infoSummary.isEmpty == false)

        let records = makeConversation()
        for record in records {
            try liveSession.observe(record)
        }
        let concurrentlyCapturedRecord = makeTCPPacket(
            identifier: 102,
            sourceIsClient: true,
            sequence: 112,
            acknowledgment: 906,
            flags: 0x18,
            payload: Data("late".utf8)
        )
        var didObserveConcurrentRecord = false
        var concurrentObservationError: Error?
        let follow = try liveSession.followObservedTCPStream(
            containing: records[3],
            records: records,
            limits: .default,
            progress: { _ in
                guard !didObserveConcurrentRecord else {
                    return
                }
                didObserveConcurrentRecord = true
                do {
                    try liveSession.observe(concurrentlyCapturedRecord)
                } catch {
                    concurrentObservationError = error
                }
            },
            shouldCancel: nil
        )

        #expect(!follow.records.isEmpty)
        #expect(concurrentObservationError == nil)
        #expect(payload(in: follow, direction: .clientToServer) == Data("hello world".utf8))
        let laterRecord = makeUDPPacket(identifier: 101)
        try liveSession.observe(laterRecord)
        #expect(try liveSession.summarize(laterRecord).infoSummary.isEmpty == false)
        #expect(try liveSession.summarize(liveRecord).infoSummary.isEmpty == false)
    }

    @Test func temporaryOfflineFollowCannotEvictAnActiveLiveSession() throws {
        let liveSession = try WiresharkEpanSession(purpose: .live)
        let liveRecord = makeUDPPacket(identifier: 100)
        try liveSession.observe(liveRecord)

        let records = makeConversation()
        #expect(throws: NSError.self) {
            try WiresharkEpanSession.followTCPStreamInTemporarySession(
                containing: records[3],
                records: records,
                limits: .default,
                progress: nil,
                shouldCancel: nil
            )
        }
        #expect(try liveSession.summarize(liveRecord).infoSummary.isEmpty == false)
    }

    private func payload(in result: WiresharkTCPFollowFields, direction: TCPFollowDirection) -> Data {
        result.records
            .filter { $0.direction == direction }
            .reduce(into: Data()) { $0.append($1.data) }
    }

    // Prepare the same completed first-pass state used by an offline capture document.
    private func followTCPStream(
        containing selectedRecord: NativePacketRecord,
        records: [NativePacketRecord],
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?
    ) throws -> WiresharkTCPFollowFields {
        let session = try WiresharkEpanSession()
        for record in records {
            try session.observe(record)
        }
        try session.finishFirstPass()
        return try session.followObservedTCPStream(
            containing: selectedRecord,
            records: records,
            limits: limits,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    // Build a compact handshake followed by out-of-order data and one retransmission.
    private func makeConversation() -> [NativePacketRecord] {
        [
            makeTCPPacket(identifier: 1, sourceIsClient: true, sequence: 100, acknowledgment: 0, flags: 0x02),
            makeTCPPacket(identifier: 2, sourceIsClient: false, sequence: 900, acknowledgment: 101, flags: 0x12),
            makeTCPPacket(identifier: 3, sourceIsClient: true, sequence: 101, acknowledgment: 901, flags: 0x10),
            makeTCPPacket(
                identifier: 4,
                sourceIsClient: true,
                sequence: 107,
                acknowledgment: 901,
                flags: 0x18,
                payload: Data("world".utf8)
            ),
            makeTCPPacket(
                identifier: 5,
                sourceIsClient: true,
                sequence: 101,
                acknowledgment: 901,
                flags: 0x18,
                payload: Data("hello ".utf8)
            ),
            makeTCPPacket(
                identifier: 6,
                sourceIsClient: true,
                sequence: 101,
                acknowledgment: 901,
                flags: 0x18,
                payload: Data("hello ".utf8)
            ),
            makeTCPPacket(
                identifier: 7,
                sourceIsClient: false,
                sequence: 901,
                acknowledgment: 112,
                flags: 0x18,
                payload: Data("reply".utf8)
            ),
        ]
    }

    private func makeTCPPacket(
        identifier: UInt64,
        sourceIsClient: Bool,
        sequence: UInt32,
        acknowledgment: UInt32,
        flags: UInt8,
        payload: Data = Data()
    ) -> NativePacketRecord {
        let clientAddress: [UInt8] = [192, 0, 2, 1]
        let serverAddress: [UInt8] = [198, 51, 100, 2]
        let sourceAddress = sourceIsClient ? clientAddress : serverAddress
        let destinationAddress = sourceIsClient ? serverAddress : clientAddress
        let sourcePort: UInt16 = sourceIsClient ? 50_000 : 8_080
        let destinationPort: UInt16 = sourceIsClient ? 8_080 : 50_000
        var packet = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
            0x08, 0x00,
            0x45, 0x00,
        ])
        packet.append(contentsOf: bytes(UInt16(40 + payload.count)))
        packet.append(contentsOf: bytes(UInt16(truncatingIfNeeded: identifier)))
        packet.append(contentsOf: [0x40, 0x00, 0x40, 0x06, 0x00, 0x00])
        packet.append(contentsOf: sourceAddress)
        packet.append(contentsOf: destinationAddress)
        packet.append(contentsOf: bytes(sourcePort))
        packet.append(contentsOf: bytes(destinationPort))
        packet.append(contentsOf: bytes(sequence))
        packet.append(contentsOf: bytes(acknowledgment))
        packet.append(contentsOf: [0x50, flags, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00])
        packet.append(payload)
        return makeRecord(identifier: identifier, bytes: packet)
    }

    // Split one TCP segment on an eight-byte IPv4 fragment boundary after four payload bytes.
    private func makeFragmentedTCPPacket() -> [NativePacketRecord] {
        var tcpSegment = Data()
        tcpSegment.append(contentsOf: bytes(UInt16(50_000)))
        tcpSegment.append(contentsOf: bytes(UInt16(8_080)))
        tcpSegment.append(contentsOf: bytes(UInt32(100)))
        tcpSegment.append(contentsOf: bytes(UInt32(0)))
        tcpSegment.append(contentsOf: [0x50, 0x18, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00])
        tcpSegment.append(Data("fragmented".utf8))

        let firstPayload = tcpSegment.prefix(24)
        let secondPayload = tcpSegment.dropFirst(24)
        let first = makeIPv4Fragment(
            identifier: 30,
            fragmentPayload: Data(firstPayload),
            flagsAndOffset: 0x2000
        )
        let second = makeIPv4Fragment(
            identifier: 31,
            fragmentPayload: Data(secondPayload),
            flagsAndOffset: 3
        )
        return [first, second]
    }

    private func makeIPv4Fragment(
        identifier: UInt64,
        fragmentPayload: Data,
        flagsAndOffset: UInt16
    ) -> NativePacketRecord {
        var packet = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
            0x08, 0x00,
            0x45, 0x00,
        ])
        packet.append(contentsOf: bytes(UInt16(20 + fragmentPayload.count)))
        packet.append(contentsOf: bytes(UInt16(0x1234)))
        packet.append(contentsOf: bytes(flagsAndOffset))
        packet.append(contentsOf: [0x40, 0x06, 0x00, 0x00, 192, 0, 2, 1, 198, 51, 100, 2])
        packet.append(fragmentPayload)
        return makeRecord(identifier: identifier, bytes: packet)
    }

    private func makeUDPPacket(identifier: UInt64) -> NativePacketRecord {
        makeRecord(
            identifier: identifier,
            bytes: Data([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
                0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
                0x08, 0x00,
                0x45, 0x00, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00,
                0x40, 0x11, 0x00, 0x00, 192, 0, 2, 1, 198, 51, 100, 2,
                0xc3, 0x50, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00,
            ])
        )
    }

    private func makeRecord(identifier: UInt64, bytes: Data) -> NativePacketRecord {
        NativePacketRecord(
            identifier: identifier,
            packetNumber: identifier,
            timestamp: Date(timeIntervalSince1970: TimeInterval(identifier)),
            rawBytes: bytes,
            originalLength: bytes.count,
            linkLayerType: Libpcap.dltEthernet,
            interfaceIdentifier: "test0",
            interfaceName: "test0",
            packetComment: nil
        )
    }

    private func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
