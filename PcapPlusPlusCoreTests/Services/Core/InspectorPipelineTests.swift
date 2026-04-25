import Foundation
import Testing
@testable import PcapPlusPlusCore

struct InspectorPipelineTests {

    @Test func nativeCoreCaptureFilterValidationNormalizesAndRejectsInvalidSyntax() async {
        let core = NativeTCPViewerCore()

        let empty = await core.validateCaptureFilter("   ")
        #expect(empty.disposition == .invalid)
        #expect(empty.normalizedExpression == nil)
        #expect(empty.message == "Capture filters cannot be empty.")

        let valid = await core.validateCaptureFilter(" tcp port 443 ")
        #expect(valid.disposition == .valid)
        #expect(valid.normalizedExpression == "tcp port 443")
        #expect(valid.message == nil)

        let invalid = await core.validateCaptureFilter("tcp and and")
        #expect(invalid.disposition == .invalid)
        #expect(invalid.normalizedExpression == "tcp and and")
        #expect(invalid.message?.contains("libpcap syntax") == true)
    }

    @Test func liveCaptureOptionsNormalizeCaptureFilterBeforeSessionSetup() {
        let options = CaptureOptions(
            promiscuousMode: true,
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            captureFilterExpression: " tcp port 443 ",
            stopCondition: .manual
        )

        let normalized = options.normalizedForLiveCapture()

        #expect(normalized.captureFilterExpression == "tcp port 443")
    }

    @Test func livePacketBatchBufferFlushesByCountTimerAndStop() {
        var buffer = LivePacketBatchBuffer<Int>(maxBatchSize: 3)

        #expect(buffer.append([1]) == nil)
        #expect(buffer.append([2]) == nil)
        #expect(buffer.append([3]) == [1, 2, 3])
        #expect(buffer.isEmpty)

        #expect(buffer.append([4, 5]) == nil)
        #expect(buffer.flush() == [4, 5])
        #expect(buffer.isEmpty)

        #expect(buffer.append([6]) == nil)
        #expect(buffer.flush() == [6])
        #expect(buffer.flush() == nil)
    }

    @Test func generatedCaptureInspectionCoversCoreProtocolsAndExactByteRanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("generated-protocols.pcap")
        try writePCAP(
            to: captureURL,
            packets: [
                makeARPRequestPacket(),
                makeIPv4TCPPayloadPacket(),
                makeIPv4UDPPayloadPacket(),
                makeIPv6UDPPayloadPacket(),
            ]
        )

        let document = try await NativeTCPViewerCore().openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()

        #expect(packets.count == 4)
        #expect(packets.map(\.transportHint) == [.arp, .tcp, .udp, .udp])

        let arpInspection = try await document.inspectPacket(id: packets[0].id)
        #expect(arpInspection.decodeStatus.kind == .complete)
        #expect(arpInspection.detailNodes.map(\.name).contains("Frame"))
        #expect(arpInspection.detailNodes.map(\.name).contains("Ethernet"))
        #expect(arpInspection.detailNodes.map(\.name).contains("ARP"))
        let ethDestination = try #require(findNode(in: arpInspection.detailNodes, id: "eth.dst"))
        #expect(ethDestination.byteRange == PacketByteRange(offset: 0, length: 6))
        let arpSenderIP = try #require(findNode(in: arpInspection.detailNodes, id: "arp.senderIP"))
        #expect(arpSenderIP.value == "192.168.0.1")
        #expect(arpSenderIP.byteRange == PacketByteRange(offset: 28, length: 4))

        let tcpInspection = try await document.inspectPacket(id: packets[1].id)
        #expect(tcpInspection.detailNodes.map(\.name).contains("IPv4"))
        #expect(tcpInspection.detailNodes.map(\.name).contains("TCP"))
        #expect(tcpInspection.detailNodes.map(\.name).contains("Payload"))
        let ipv4Source = try #require(findNode(in: tcpInspection.detailNodes, id: "ipv4.src"))
        #expect(ipv4Source.value == "192.168.0.1")
        #expect(ipv4Source.byteRange == PacketByteRange(offset: 26, length: 4))
        let tcpDestinationPort = try #require(findNode(in: tcpInspection.detailNodes, id: "tcp.dstPort"))
        #expect(tcpDestinationPort.value == "4321")
        #expect(tcpDestinationPort.byteRange == PacketByteRange(offset: 36, length: 2))
        let tcpPayloadLength = try #require(findNode(in: tcpInspection.detailNodes, id: "payload.length"))
        #expect(tcpPayloadLength.value == "4 bytes")
        #expect(tcpPayloadLength.byteRange == PacketByteRange(offset: 54, length: 4))

        let udpInspection = try await document.inspectPacket(id: packets[2].id)
        let udpLength = try #require(findNode(in: udpInspection.detailNodes, id: "udp.length"))
        #expect(udpLength.value == "12")
        #expect(udpLength.byteRange == PacketByteRange(offset: 38, length: 2))
        let udpPayloadLength = try #require(findNode(in: udpInspection.detailNodes, id: "udp.payloadLength"))
        #expect(udpPayloadLength.value == "4 bytes")
        #expect(udpPayloadLength.byteRange == PacketByteRange(offset: 38, length: 2))
        let udpChecksumStatus = try #require(findNode(in: udpInspection.detailNodes, id: "udp.checksum.status"))
        #expect(udpChecksumStatus.value == "Not present")

        let ipv6Inspection = try await document.inspectPacket(id: packets[3].id)
        #expect(ipv6Inspection.detailNodes.map(\.name).contains("IPv6"))
        #expect(ipv6Inspection.detailNodes.map(\.name).contains("UDP"))
        #expect(ipv6Inspection.detailNodes.map(\.name).contains("Payload"))
        let ipv6Source = try #require(findNode(in: ipv6Inspection.detailNodes, id: "ipv6.src"))
        #expect(ipv6Source.value == "2001:db8::1")
        #expect(ipv6Source.byteRange == PacketByteRange(offset: 22, length: 16))
        let ipv6PayloadPreview = try #require(findNode(in: ipv6Inspection.detailNodes, id: "payload.preview"))
        #expect(ipv6PayloadPreview.byteRange == PacketByteRange(offset: 62, length: 4))
        let ipv6UDPChecksumStatus = try #require(findNode(in: ipv6Inspection.detailNodes, id: "udp.checksum.status"))
        #expect(ipv6UDPChecksumStatus.value == "Illegal zero checksum")
    }

    @Test func tlsClientHelloInspectionRendersVersionedSummaryAndDetail() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("tls").appendingPathComponent("SSL-ClientHello1.pcap")
        let document = try await NativeTCPViewerCore().openOfflineCaptureDocument(at: fixtureURL)
        let packets = try await document.open()
        let packet = try #require(packets.first { $0.transportHint == .tls })

        #expect(packet.layers.contains { $0.name == "TLSv1.2" })

        let inspection = try await document.inspectPacket(id: packet.id)
        let tlsNode = try #require(inspection.detailNodes.first { $0.name == "Transport Layer Security" })
        #expect(tlsNode.value?.contains("TLSv1.2") == true)
        #expect(findNode(in: tlsNode.children, name: "Content Type")?.value?.contains("Handshake") == true)
        #expect(findNode(in: tlsNode.children, name: "Version") != nil)
        #expect(findNode(in: tlsNode.children, name: "Length") != nil)
        #expect(findNode(in: tlsNode.children, name: "Handshake Protocol: Client Hello") != nil)
        #expect(findNode(in: tlsNode.children, name: "Handshake Version")?.value?.contains("TLSv1.2") == true)
        #expect(findNode(in: tlsNode.children, name: "Server Name Indication")?.value == "www.google.com")
    }

    @Test func tlsApplicationDataInspectionRendersRecordVersionsAndEncryptedData() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("tls-application-data.pcap")
        try writePCAP(
            to: captureURL,
            packets: [
                makeIPv4TLSApplicationDataPacket(recordVersion: 0x0301),
                makeIPv4TLSApplicationDataPacket(recordVersion: 0x0303),
            ]
        )

        let document = try await NativeTCPViewerCore().openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()
        let firstPacket = try #require(packets.first)
        let secondPacket = try #require(packets.dropFirst().first)

        #expect(packets.map(\.transportHint) == [.tls, .tls])
        #expect(firstPacket.layers.contains { $0.name == "TLSv1.0" })
        #expect(secondPacket.layers.contains { $0.name == "TLSv1.2" })

        let inspection = try await document.inspectPacket(id: secondPacket.id)
        let tlsNode = try #require(inspection.detailNodes.first { $0.name == "Transport Layer Security" })
        #expect(tlsNode.value == "TLSv1.2, Application Data")
        #expect(findNode(in: tlsNode.children, name: "Content Type")?.value == "Application Data (23)")
        #expect(findNode(in: tlsNode.children, name: "Version")?.value == "TLSv1.2 (0x0303)")
        #expect(findNode(in: tlsNode.children, name: "Encrypted Application Data")?.value == "4 bytes")
        #expect(findNode(in: tlsNode.children, name: "Encrypted Data Preview")?.value == "de ad be ef")
    }

    @Test func tcpSynInspectionExpandsFlagsAndOptions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("tcp-syn-options.pcap")
        try writePCAP(to: captureURL, packets: [makeIPv4TCPSYNOptionsPacket()])

        let document = try await NativeTCPViewerCore().openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()
        let packet = try #require(packets.first)
        let inspection = try await document.inspectPacket(id: packet.id)

        let tcpSegmentLength = try #require(findNode(in: inspection.detailNodes, id: "tcp.segmentLength"))
        #expect(tcpSegmentLength.value == "0")
        let tcpFlags = try #require(findNode(in: inspection.detailNodes, id: "tcp.flags"))
        #expect(tcpFlags.value == "0x0c2 (SYN, ECE, CWR)")
        #expect(tcpFlags.byteRange == PacketByteRange(offset: 46, length: 2))
        #expect(findNode(in: tcpFlags.children, id: "tcp.flags.syn")?.value == "Set")
        #expect(findNode(in: tcpFlags.children, id: "tcp.flags.ece")?.value == "Set")
        #expect(findNode(in: tcpFlags.children, id: "tcp.flags.cwr")?.value == "Set")
        #expect(findNode(in: tcpFlags.children, id: "tcp.flags.ack")?.value == "Not set")

        let rawSequence = try #require(findNode(in: inspection.detailNodes, id: "tcp.sequence.raw"))
        #expect(rawSequence.value == "2849299978")
        #expect(rawSequence.byteRange == PacketByteRange(offset: 38, length: 4))
        let options = try #require(findNode(in: inspection.detailNodes, id: "tcp.options"))
        #expect(options.value == "24 bytes")
        #expect(options.byteRange == PacketByteRange(offset: 54, length: 24))
        #expect(options.children.count == 9)
        #expect(options.children[0].name == "TCP Option - Maximum segment size")
        #expect(options.children[0].value == "1440 bytes")
        #expect(options.children[0].byteRange == PacketByteRange(offset: 54, length: 4))
        #expect(options.children[1].name == "TCP Option - No-Operation")
        #expect(options.children[2].name == "TCP Option - Window scale")
        #expect(options.children[2].value == "6 (multiply by 64)")
        #expect(options.children[5].name == "TCP Option - Timestamps")
        #expect(options.children[5].value == "TSval 663237127, TSecr 0")
        #expect(options.children[6].name == "TCP Option - SACK permitted")
        #expect(options.children[6].value == "Permitted")
        #expect(options.children[7].name == "TCP Option - End of Option List")
        #expect(options.children[8].name == "TCP Option - End of Option List")
    }

    @Test func malformedInspectionAddsDecodeWarningAndKeepsRawBytes() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("malformed").appendingPathComponent("partial-http-request.pcap")
        let document = try await NativeTCPViewerCore().openOfflineCaptureDocument(at: fixtureURL)
        let packets = try await document.open()
        let packet = try #require(packets.first)

        let inspection = try await document.inspectPacket(id: packet.id)

        #expect(inspection.decodeStatus.kind != .complete)
        #expect(!inspection.rawBytes.isEmpty)
        #expect(inspection.rawBytes.count == packet.capturedLength)
        #expect(inspection.detailNodes.contains { $0.kind == .warning && $0.name == "Decode Warning" })
    }

    @Test func incrementalOpenEmitsAppendBatchesAndCompletedProgress() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("incremental-complete.pcap")
        let repeatedPacket = makeIPv4UDPPayloadPacket()
        let packetCount = 640
        try writePCAP(to: captureURL, repeating: repeatedPacket, count: packetCount)

        let document = try await NativeTCPViewerCore().openOfflineCaptureDocument(at: captureURL)
        let probe = LoadEventProbe()
        let events = document.events()
        let collector = Task {
            do {
                for try await event in events {
                    await probe.record(event)
                }
            } catch is CancellationError {
            } catch {
            }
        }
        defer { collector.cancel() }

        let packets = try await document.open()
        let progress = await document.loadProgress()
        let snapshot = await probe.current()

        #expect(packets.count == packetCount)
        #expect(progress.phase == .completed)
        #expect(progress.loadedPacketCount == packetCount)
        #expect(progress.fractionCompleted == .some(1.0))
        #expect(snapshot.replaceBatchCount == 1)
        #expect(snapshot.appendBatchCount >= 5)
        #expect(snapshot.appendedPacketCount == packetCount)
        #expect(snapshot.progressPhases.contains(.loading))
        #expect(snapshot.progressPhases.last == .completed)
    }

    @Test func incrementalOpenAllowsEarlyInspectionAndCancellation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("incremental-cancel.pcap")
        let repeatedPacket = makeIPv4UDPPayloadPacket()
        let totalPacketCount = 120_000
        try writePCAP(to: captureURL, repeating: repeatedPacket, count: totalPacketCount)

        let document = try await NativeTCPViewerCore().openOfflineCaptureDocument(at: captureURL)
        let probe = LoadEventProbe()
        let events = document.events()
        let collector = Task {
            do {
                for try await event in events {
                    await probe.record(event)
                }
            } catch is CancellationError {
            } catch {
            }
        }
        defer { collector.cancel() }

        let openTask = Task {
            try await document.open()
        }

        let observedLoading = await waitUntil(timeout: .seconds(5)) {
            let packets = await document.packetSummaries()
            let progress = await document.loadProgress()
            return packets.count >= 128 && progress.phase == .loading
        }
        #expect(observedLoading)

        let earlyPackets = await document.packetSummaries()
        let firstPacket = try #require(earlyPackets.first)
        let inspection = try await document.inspectPacket(id: firstPacket.id)
        #expect(!inspection.rawBytes.isEmpty)
        #expect(inspection.detailNodes.map(\.name).contains("UDP"))

        await document.cancelLoading()

        do {
            _ = try await openTask.value
            Issue.record("Expected loading cancellation to throw TCPViewerCoreError.operationCancelled.")
        } catch let error as TCPViewerCoreError {
            #expect(error.code == .operationCancelled)
        }

        let retainedPackets = await document.packetSummaries()
        let progress = await document.loadProgress()
        let snapshot = await probe.current()

        #expect(!retainedPackets.isEmpty)
        #expect(retainedPackets.count < totalPacketCount)
        #expect(progress.phase == .cancelled)
        #expect(progress.isPartialResult)
        #expect(snapshot.appendBatchCount >= 1)
        #expect(snapshot.progressPhases.contains(.cancelled))

        do {
            try await document.save()
            Issue.record("Expected save() to fail for a partially loaded capture.")
        } catch let error as TCPViewerCoreError {
            #expect(error.code == .offlineFileSaveFailed)
        }
    }
}

private struct LoadEventSnapshot: Sendable {
    var replaceBatchCount = 0
    var appendBatchCount = 0
    var appendedPacketCount = 0
    var progressPhases: [PacketLoadProgress.Phase] = []
}

private actor LoadEventProbe {
    private var state = LoadEventSnapshot()

    func record(_ event: PacketIngestEvent) {
        switch event {
        case .packetBatch(let packets, let disposition):
            switch disposition {
            case .replace:
                state.replaceBatchCount += 1
            case .append:
                state.appendBatchCount += 1
                state.appendedPacketCount += packets.count
            @unknown default:
                break
            }
        case .loadProgressChanged(let progress):
            state.progressPhases.append(progress.phase)
        case .liveStateChanged, .documentStateChanged, .healthChanged, .documentMetadataChanged:
            break
        }
    }

    func current() -> LoadEventSnapshot {
        state
    }
}

private func waitUntil(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(10),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
        if await condition() {
            return true
        }

        try? await Task.sleep(for: pollInterval)
    }

    return false
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writePCAP(to url: URL, packets: [Data]) throws {
    var data = Data()
    data.appendLittleEndian(UInt32(0xa1b2c3d4))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(4))
    data.appendLittleEndian(Int32(0))
    data.appendLittleEndian(UInt32(0))
    data.appendLittleEndian(UInt32(65_535))
    data.appendLittleEndian(UInt32(1))

    for (index, packet) in packets.enumerated() {
        try appendPacketRecord(packet, index: index, to: &data)
    }

    try data.write(to: url)
}

private func writePCAP(to url: URL, repeating packet: Data, count: Int) throws {
    var data = Data()
    data.appendLittleEndian(UInt32(0xa1b2c3d4))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(4))
    data.appendLittleEndian(Int32(0))
    data.appendLittleEndian(UInt32(0))
    data.appendLittleEndian(UInt32(65_535))
    data.appendLittleEndian(UInt32(1))

    data.reserveCapacity(24 + (16 + packet.count) * count)
    for index in 0..<count {
        try appendPacketRecord(packet, index: index, to: &data)
    }

    try data.write(to: url)
}

private func appendPacketRecord(_ packet: Data, index: Int, to data: inout Data) throws {
    let timestamp = UInt32(1_700_000_000 + index)
    let microseconds = UInt32((index % 1_000) * 1_000)
    let capturedLength = try UInt32(exactly: packet.count).unwrap()

    data.appendLittleEndian(timestamp)
    data.appendLittleEndian(microseconds)
    data.appendLittleEndian(capturedLength)
    data.appendLittleEndian(capturedLength)
    data.append(packet)
}

private func makeARPRequestPacket() -> Data {
    Data([
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x06,
        0x00, 0x01,
        0x08, 0x00,
        0x06,
        0x04,
        0x00, 0x01,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0xc0, 0xa8, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x02,
    ])
}

private func makeIPv4TCPPayloadPacket() -> Data {
    Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x00,
        0x45, 0x00, 0x00, 0x2c, 0x12, 0x34, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x01,
        0xc0, 0xa8, 0x00, 0x02,
        0x04, 0xd2, 0x10, 0xe1,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x18, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xde, 0xad, 0xbe, 0xef,
    ])
}

private func makeIPv4TLSApplicationDataPacket(recordVersion: UInt16) -> Data {
    let encryptedPayload: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
    let tlsRecordLength = 5 + encryptedPayload.count
    let ipv4TotalLength = UInt16(20 + 20 + tlsRecordLength)
    var packet = Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x00,
        0x45, 0x00,
    ])
    packet.appendBigEndian(ipv4TotalLength)
    packet.append(contentsOf: [
        0x12, 0x37, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x01,
        0xc0, 0xa8, 0x00, 0x02,
    ])
    packet.appendBigEndian(UInt16(54_321))
    packet.appendBigEndian(UInt16(443))
    packet.append(contentsOf: [
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x01,
        0x50, 0x18, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x17,
    ])
    packet.appendBigEndian(recordVersion)
    packet.appendBigEndian(UInt16(encryptedPayload.count))
    packet.append(contentsOf: encryptedPayload)
    return packet
}

private func makeIPv4TCPSYNOptionsPacket() -> Data {
    Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x00,
        0x45, 0x00, 0x00, 0x40, 0x12, 0x36, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x01,
        0xc0, 0xa8, 0x00, 0x02,
        0xd2, 0x55, 0xf2, 0x7e,
        0xa9, 0xd4, 0xde, 0x0a,
        0x00, 0x00, 0x00, 0x00,
        0xb0, 0xc2, 0xff, 0xff, 0x68, 0xb2, 0x00, 0x00,
        0x02, 0x04, 0x05, 0xa0,
        0x01,
        0x03, 0x03, 0x06,
        0x01,
        0x01,
        0x08, 0x0a, 0x27, 0x88, 0x32, 0x07, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x02,
        0x00,
        0x00,
    ])
}

private func makeIPv4UDPPayloadPacket() -> Data {
    Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x00,
        0x45, 0x00, 0x00, 0x20, 0x12, 0x35, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x01,
        0xc0, 0xa8, 0x00, 0x02,
        0x0f, 0xa0, 0x13, 0x88, 0x00, 0x0c, 0x00, 0x00,
        0xca, 0xfe, 0xba, 0xbe,
    ])
}

private func makeIPv6UDPPayloadPacket() -> Data {
    Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x86, 0xdd,
        0x60, 0x00, 0x00, 0x00,
        0x00, 0x0c,
        0x11,
        0x40,
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x04, 0xd2, 0x16, 0x2e, 0x00, 0x0c, 0x00, 0x00,
        0xaa, 0xbb, 0xcc, 0xdd,
    ])
}

private func findNode(in nodes: [PacketDetailNode], id: String) -> PacketDetailNode? {
    for node in nodes {
        if node.id == id {
            return node
        }

        if let match = findNode(in: node.children, id: id) {
            return match
        }
    }

    return nil
}

private func findNode(in nodes: [PacketDetailNode], name: String) -> PacketDetailNode? {
    for node in nodes {
        if node.name == name {
            return node
        }

        if let match = findNode(in: node.children, name: name) {
            return match
        }
    }

    return nil
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }
}

private extension Optional {
    func unwrap(fileID: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else {
            throw TestSupportError(message: "Unexpected nil while unwrapping an optional.", fileID: fileID, line: line)
        }
        return value
    }
}

private struct TestSupportError: Error, CustomStringConvertible {
    let message: String
    let fileID: String
    let line: Int

    var description: String {
        "\(message) (\(fileID):\(line))"
    }
}
