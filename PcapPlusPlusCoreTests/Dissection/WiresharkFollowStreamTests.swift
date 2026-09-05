//
//  WiresharkFollowStreamTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct WiresharkFollowStreamTests {
    @Test func reassemblesBothDirectionsAndIgnoresRetransmissions() throws {
        let records = makeConversation()
        var progressUpdates: [FollowStreamProgress] = []

        let result = try followStream(
            containing: records[3],
            streamProtocol: nil,
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
        let result = try followStream(
            containing: records[3],
            streamProtocol: nil,
            records: records,
            limits: FollowStreamLimits(
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
        let result = try followStream(
            containing: records[3],
            streamProtocol: nil,
            records: records,
            limits: FollowStreamLimits(
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

    @Test func unrequestedDirectionDoesNotConsumeFollowLimits() throws {
        let records = makeConversation()
        let result = try followStream(
            containing: records[3],
            streamProtocol: nil,
            records: records,
            limits: FollowStreamLimits(
                maximumCandidatePacketCount: records.count,
                maximumPayloadBytes: 5,
                maximumRecordCount: 1,
                includedDirection: .serverToClient
            ),
            progress: nil,
            shouldCancel: nil
        )

        #expect(payload(in: result, direction: .serverToClient) == Data("reply".utf8))
        #expect(result.records.allSatisfy { $0.direction == .serverToClient })
        #expect(result.clientByteCount == 0)
        #expect(result.serverByteCount == 5)
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

        let candidates = try session.followStreamCandidatePacketIdentifiers(
            containing: 12,
            maximumPacketCount: 100
        )

        #expect(Set(candidates) == Set(secondConnection.map(\.identifier)))
        #expect(session.streamIdentifier(for: 4) != session.streamIdentifier(for: 12))
    }

    @Test func candidateIndexIncludesIPv4FragmentsNeededForTCPReassembly() throws {
        let records = makeFragmentedTCPPacket()
        let session = try WiresharkEpanSession()
        for record in records {
            try session.observe(record)
        }
        try session.finishFirstPass()

        let candidates = try session.followStreamCandidatePacketIdentifiers(
            containing: records[1].identifier,
            maximumPacketCount: 10
        )
        let result = try session.followObservedStream(
            containing: records[1],
            streamProtocol: nil,
            records: records,
            limits: .default,
            progress: nil,
            shouldCancel: nil
        )

        #expect(Set(candidates) == Set(records.map(\.identifier)))
        #expect(payload(in: result, direction: .clientToServer) == Data("fragmented".utf8))
    }

    @Test func rejectsUnsupportedPacketAndCancellation() throws {
        let unsupported = makeRecord(identifier: 20, bytes: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0x88, 0xb5, 0]))
        #expect(throws: NSError.self) {
            try followStream(
                containing: unsupported,
                streamProtocol: nil,
                records: [unsupported],
                limits: .default,
                progress: nil,
                shouldCancel: nil
            )
        }

        let records = makeConversation()
        #expect(throws: NSError.self) {
            try followStream(
                containing: records[0],
                streamProtocol: nil,
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
        let follow = try liveSession.followObservedStream(
            containing: records[3],
            streamProtocol: nil,
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
            try WiresharkEpanSession.followStreamInTemporarySession(
                containing: records[3],
                streamProtocol: nil,
                records: records,
                limits: .default,
                progress: nil,
                shouldCancel: nil
            )
        }
        #expect(try liveSession.summarize(liveRecord).infoSummary.isEmpty == false)
    }

    @Test(arguments: [false, true])
    func followsUDPDatagramsInBothDirections(ipv6: Bool) throws {
        let records = [
            makeUDPPacket(identifier: 1, payload: Data(), ipv6: ipv6),
            makeUDPPacket(identifier: 2, sourceIsClient: false, payload: Data("reply".utf8), ipv6: ipv6),
            makeUDPPacket(identifier: 3, payload: Data("dup".utf8), ipv6: ipv6),
            makeUDPPacket(identifier: 4, payload: Data("dup".utf8), ipv6: ipv6),
        ]
        let session = try WiresharkEpanSession()
        for record in records { try session.observe(record) }
        try session.finishFirstPass()
        let result = try session.followObservedStream(containing: records[1], streamProtocol: .udp,
            records: records, limits: .default, progress: nil, shouldCancel: nil)
        #expect(result.streamProtocol == .udp)
        #expect(result.client.port == 50_000)
        #expect(result.server.port == 8_080)
        #expect(result.records.map(\.packetID) == [1, 2, 3, 4])
        #expect(result.records.map(\.data) == [Data(), Data("reply".utf8), Data("dup".utf8), Data("dup".utf8)])
        #expect(result.records.map(\.direction) == [.clientToServer, .serverToClient, .clientToServer, .clientToServer])
        #expect(result.records.allSatisfy { $0.sequenceNumber == nil })
        #expect(result.clientByteCount == 6)
        #expect(result.serverByteCount == 5)
        #expect(!result.isTruncated)
    }

    @Test func udpClientPortZeroKeepsTheFirstSender() throws {
        let records = [
            makeUDPPacket(identifier: 1, payload: Data("client".utf8), clientPort: 0),
            makeUDPPacket(identifier: 2, sourceIsClient: false, payload: Data("server".utf8), clientPort: 0),
        ]
        let result = try WiresharkEpanSession.followStreamInTemporarySession(containing: records[1],
            streamProtocol: .udp, records: records, limits: .default, progress: nil, shouldCancel: nil)
        #expect(result.client.port == 0)
        #expect(result.server.port == 8_080)
        #expect(result.records.map(\.direction) == [.clientToServer, .serverToClient])
    }

    @Test func udpRecordLimitStopsEmptyDatagramsDuringCollection() throws {
        let records = (1...50).map { makeUDPPacket(identifier: UInt64($0)) }
        var processed = 0
        let result = try followStream(containing: records[0], records: records,
            limits: FollowStreamLimits(maximumRecordCount: 3), progress: nil,
            shouldCancel: { processed += 1; return false })
        #expect(result.records.count == 3)
        #expect(result.records.allSatisfy { $0.data.isEmpty })
        #expect(result.isTruncated)
        #expect(processed == 4)
    }

    @Test func udpDirectionAndByteLimitsExcludeTheOtherSide() throws {
        let records = [
            makeUDPPacket(identifier: 1, payload: Data(repeating: 1, count: 100)),
            makeUDPPacket(identifier: 2, sourceIsClient: false, payload: Data("reply".utf8)),
            makeUDPPacket(identifier: 3, sourceIsClient: false),
        ]
        let exact = try followStream(containing: records[0], records: records,
            limits: FollowStreamLimits(maximumPayloadBytes: 5, maximumRecordCount: 2, includedDirection: .serverToClient),
            progress: nil, shouldCancel: nil)
        #expect(exact.records.map(\.packetID) == [2, 3])
        #expect(exact.clientByteCount == 0)
        #expect(exact.serverByteCount == 5)
        #expect(!exact.isTruncated)
        let capped = try followStream(containing: records[0], records: records,
            limits: FollowStreamLimits(maximumPayloadBytes: 4, includedDirection: .serverToClient),
            progress: nil, shouldCancel: nil)
        #expect(capped.records.map(\.data) == [Data("repl".utf8)])
        #expect(capped.isTruncated)
    }

    @Test func tcpAndUDPIndexesDoNotMixMatchingNumbers() throws {
        let tcp = makeConversation()
        let udp = makeUDPPacket(identifier: 100, payload: Data("datagram".utf8))
        let session = try WiresharkEpanSession()
        for record in tcp + [udp] { try session.observe(record) }
        try session.finishFirstPass()
        let tcpID = try #require(session.streamIdentifier(for: tcp[0].identifier))
        let udpID = try #require(session.streamIdentifier(for: udp.identifier))
        #expect(tcpID.streamID == udpID.streamID)
        #expect(tcpID != udpID)
        #expect(try session.followStreamCandidatePacketIdentifiers(containing: udp.identifier, maximumPacketCount: 10) == [100])
        #expect(throws: NSError.self) {
            try session.followObservedStream(containing: udp, streamProtocol: .tcp,
                records: [udp], limits: .default, progress: nil, shouldCancel: nil)
        }
    }

    @Test func udpFragmentsAreIndexedAndFollowedAsOneDatagram() throws {
        let complete = makeUDPPacket(identifier: 1, payload: Data("fragmented datagram".utf8))
        let udpBytes = Data(complete.rawBytes.dropFirst(34))
        let records = [
            makeIPv4Fragment(identifier: 1, fragmentPayload: Data(udpBytes.prefix(16)), flagsAndOffset: 0x2000, transportProtocol: 17),
            makeIPv4Fragment(identifier: 2, fragmentPayload: Data(udpBytes.dropFirst(16)), flagsAndOffset: 2, transportProtocol: 17),
        ]
        let session = try WiresharkEpanSession()
        for record in records { try session.observe(record) }
        try session.finishFirstPass()
        #expect(try session.followStreamCandidatePacketIdentifiers(containing: 2, maximumPacketCount: 10) == [1, 2])
        let result = try session.followObservedStream(containing: records[1], streamProtocol: .udp,
            records: records, limits: .default, progress: nil, shouldCancel: nil)
        #expect(result.records.map(\.data) == [Data("fragmented datagram".utf8)])
    }

    @Test func udpIPv6FragmentsProduceOneCompleteDatagram() throws {
        let original = makeUDPPacket(identifier: 1, payload: Data("fragmented datagram".utf8), ipv6: true)
        let payload = Data(original.rawBytes.dropFirst(54))
        let records = [Data(payload.prefix(16)), Data(payload.dropFirst(16))].enumerated().map { index, fragment in
            var packet = Data(original.rawBytes.prefix(54))
            packet.replaceSubrange(18..<20, with: bytes(UInt16(8 + fragment.count)))
            packet[20] = 44
            packet.append(contentsOf: [17, 0])
            packet.append(contentsOf: bytes(UInt16(index == 0 ? 1 : 16)))
            packet.append(contentsOf: bytes(UInt32(123)))
            packet.append(fragment)
            return makeRecord(identifier: UInt64(index + 1), bytes: packet)
        }
        let session = try WiresharkEpanSession()
        for record in records { try session.observe(record) }
        try session.finishFirstPass()
        #expect(try session.followStreamCandidatePacketIdentifiers(containing: 2, maximumPacketCount: 10) == [1, 2])
        let result = try session.followObservedStream(containing: records[1], streamProtocol: .udp,
            records: records, limits: .default, progress: nil, shouldCancel: nil)
        #expect(result.records.map(\.data) == [Data("fragmented datagram".utf8)])
    }

    @Test func offlineDocumentExposesUDPIdentityAndFollowing() async throws {
        let records = [makeUDPPacket(identifier: 1, payload: Data("request".utf8)),
            makeUDPPacket(identifier: 2, sourceIsClient: false, payload: Data("response".utf8))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("udp-follow-\(UUID().uuidString).pcap")
        defer { try? FileManager.default.removeItem(at: url) }
        try NativeCaptureFile.write(records: records, to: url, format: .pcap)
        let document = try NativeOfflineCaptureDocument(fileURL: url)
        let packets = try await withCheckedThrowingContinuation { continuation in
            document.open { continuation.resume(with: $0) }
        }
        #expect(packets.allSatisfy { $0.followStreamID?.streamProtocol == .udp })
        let stream = try await withCheckedThrowingContinuation { continuation in
            document.followStream(containing: 2, streamProtocol: .udp) { continuation.resume(with: $0) }
        }
        #expect(stream.streamProtocol == .udp)
        #expect(stream.records.map(\.data) == [Data("request".utf8), Data("response".utf8)])
    }

    @Test(arguments: ["tls13-rfc8446.pcap", "tls12-chacha20poly1305.pcap"])
    func tlsFollowingStillReturnsEncryptedTCPRecords(fixture: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let capture = try NativeCaptureFile.load(from: root.appendingPathComponent("Vendor/Wireshark/test/captures/\(fixture)"))
        let session = try WiresharkEpanSession()
        for record in capture.records { try session.observe(record) }
        try session.finishFirstPass()
        let selected = try #require(capture.records.first)
        let candidates = Set(try session.followStreamCandidatePacketIdentifiers(containing: selected.identifier, maximumPacketCount: 100))
        let result = try session.followObservedStream(containing: selected, streamProtocol: .tcp,
            records: capture.records.filter { candidates.contains($0.identifier) }, limits: .default, progress: nil, shouldCancel: nil)
        #expect(result.streamProtocol == .tcp)
        #expect(result.records.allSatisfy { $0.sequenceNumber != nil })
        #expect(!result.isTruncated)
        #expect(payload(in: result, direction: .clientToServer).count == (fixture.hasPrefix("tls13") ? 347 : 304))
        #expect(payload(in: result, direction: .serverToClient).count == (fixture.hasPrefix("tls13") ? 1133 : 5013))
        #expect(payload(in: result, direction: .clientToServer).first == 22)
    }

    @Test func dnsDatagramsUseTheUDPIndexAndRecoverAfterCancellation() throws {
        let query = Data([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7]) + Data("example".utf8)
            + Data([4]) + Data("test".utf8) + Data([0, 0, 1, 0, 1])
        let records = [makeUDPPacket(identifier: 1, payload: query, serverPort: 53),
            makeUDPPacket(identifier: 2, payload: query, serverPort: 53)]
        let session = try WiresharkEpanSession()
        for record in records { try session.observe(record) }
        try session.finishFirstPass()
        #expect(try session.summarize(records[0]).protocolSummary == "DNS")
        #expect(session.streamIdentifier(for: 1)?.streamProtocol == .udp)
        #expect(throws: NSError.self) {
            try session.followStreamCandidatePacketIdentifiers(containing: 1, maximumPacketCount: 1)
        }
        #expect(throws: NSError.self) {
            try session.followObservedStream(containing: records[0], streamProtocol: .udp,
                records: records, limits: .default, progress: nil, shouldCancel: { true })
        }
        let result = try session.followObservedStream(containing: records[0], streamProtocol: .udp,
            records: records, limits: .default, progress: nil, shouldCancel: nil)
        #expect(result.records.map(\.data) == [query, query])
    }

    private func payload(in result: WiresharkFollowStreamFields, direction: FollowStreamDirection) -> Data {
        result.records
            .filter { $0.direction == direction }
            .reduce(into: Data()) { $0.append($1.data) }
    }

    // Prepare the same completed first-pass state used by an offline capture document.
    private func followStream(
        containing selectedRecord: NativePacketRecord,
        streamProtocol: FollowStreamProtocol? = nil,
        records: [NativePacketRecord],
        limits: FollowStreamLimits,
        progress: FollowStreamProgressHandler?,
        shouldCancel: FollowStreamCancellationCheck?
    ) throws -> WiresharkFollowStreamFields {
        let session = try WiresharkEpanSession()
        for record in records {
            try session.observe(record)
        }
        try session.finishFirstPass()
        return try session.followObservedStream(
            containing: selectedRecord,
            streamProtocol: nil,
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
        flagsAndOffset: UInt16,
        transportProtocol: UInt8 = 6
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
        packet.append(contentsOf: [0x40, transportProtocol, 0x00, 0x00, 192, 0, 2, 1, 198, 51, 100, 2])
        packet.append(fragmentPayload)
        return makeRecord(identifier: identifier, bytes: packet)
    }

    // Build small public-only datagrams for stream following and live-session tests.
    private func makeUDPPacket(
        identifier: UInt64,
        sourceIsClient: Bool = true,
        payload: Data = Data(),
        ipv6: Bool = false,
        clientPort: UInt16 = 50_000,
        serverPort: UInt16 = 8_080
    ) -> NativePacketRecord {
        let client: [UInt8] = ipv6 ? [0x20, 1, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [1] : [192, 0, 2, 1]
        let server: [UInt8] = ipv6 ? [0x20, 1, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [2] : [198, 51, 100, 2]
        var packet = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        packet.append(contentsOf: ipv6 ? [0x86, 0xdd, 0x60, 0, 0, 0] : [0x08, 0x00, 0x45, 0])
        packet.append(contentsOf: bytes(UInt16((ipv6 ? 0 : 20) + 8 + payload.count)))
        packet.append(contentsOf: ipv6 ? [17, 64] : [0, 1, 0, 0, 64, 17, 0, 0])
        packet.append(contentsOf: sourceIsClient ? client : server)
        packet.append(contentsOf: sourceIsClient ? server : client)
        packet.append(contentsOf: bytes(sourceIsClient ? clientPort : serverPort))
        packet.append(contentsOf: bytes(sourceIsClient ? serverPort : clientPort))
        packet.append(contentsOf: bytes(UInt16(8 + payload.count)))
        packet.append(contentsOf: [0, 0])
        packet.append(payload)
        return makeRecord(identifier: identifier, bytes: packet)
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
