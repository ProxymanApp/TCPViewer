//
//  InspectorPipelineTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
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

        #expect(buffer.append([7, 8]) == nil)
        #expect(buffer.pendingCount == 2)
        buffer.discardPending(releasingCapacity: true)
        #expect(buffer.isEmpty)
        #expect(buffer.flush() == nil)
    }

    @Test func wiresharkUnavailableBackendFallsBackToPcapPlusPlusDetails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("wireshark-fallback.pcap")
        try writePCAP(to: captureURL, packets: [makeIPv4UDPPayloadPacket()])

        let document = try await wiresharkDisabledCore().openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()
        let packet = try #require(packets.first)
        let inspection = try await document.inspectPacket(id: packet.id)

        let fallback = try #require(findNode(in: inspection.detailNodes, id: "wireshark.fallback"))
        #expect(fallback.name == "Wireshark Dissector Unavailable")
        #expect(fallback.fieldName == "tcpviewer.wireshark.fallback")
        #expect(fallback.severity == .warning)
        let fallbackValue = try #require(fallback.value)
        #expect(fallbackValue.contains("disabled for this capture"))
        #expect(findNode(in: inspection.detailNodes, id: "udp.length") != nil)
    }

    @Test func offlinePcapNgInterfaceNamesFlowIntoFrameDetails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("named-interfaces.pcapng")
        try writePCAPNG(
            to: captureURL,
            interfaces: ["alpha0", "beta1"],
            packets: [(packet: makeIPv4UDPPayloadPacket(), interfaceID: 1)]
        )

        let document = try await wiresharkDisabledCore().openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()
        let packet = try #require(packets.first)

        #expect(packet.captureMetadata.interfaceName == "beta1")

        let inspection = try await document.inspectPacket(id: packet.id)
        let interfaceNode = try #require(findNode(in: inspection.detailNodes, id: "frame.interface"))
        #expect(interfaceNode.value == "beta1")
    }

    @Test func generatedCaptureInspectionCoversCoreProtocolsAndExactByteRanges() async throws {
        try await withWiresharkDisabled { core in
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
                    makeIPv4ICMPEchoRequestPacket(),
                    makeIPv6ICMPEchoRequestPacket(),
                ]
            )

        let document = try await core.openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()

        #expect(packets.count == 6)
        #expect(packets.map(\.transportHint) == [.arp, .tcp, .udp, .udp, .icmp, .icmp])

        let arpInspection = try await document.inspectPacket(id: packets[0].id)
        #expect(arpInspection.decodeStatus.kind == .complete)
        #expect(arpInspection.detailNodes.map(\.name).contains("Frame"))
        #expect(arpInspection.detailNodes.map(\.name).contains("Ethernet"))
        #expect(arpInspection.detailNodes.map(\.name).contains("ARP"))
        let ethDestination = try #require(findNode(in: arpInspection.detailNodes, id: "eth.dst"))
        #expect(ethDestination.fieldName == "eth.dst")
        #expect(ethDestination.rawValue == "ff ff ff ff ff ff")
        #expect(ethDestination.byteRange == PacketByteRange(offset: 0, length: 6))
        let arpSenderIP = try #require(findNode(in: arpInspection.detailNodes, id: "arp.senderIP"))
        #expect(arpSenderIP.value == "192.168.0.1")
        #expect(arpSenderIP.byteRange == PacketByteRange(offset: 28, length: 4))

        let tcpInspection = try await document.inspectPacket(id: packets[1].id)
        #expect(tcpInspection.detailNodes.map(\.name).contains("IPv4"))
        #expect(tcpInspection.detailNodes.map(\.name).contains("TCP"))
        #expect(tcpInspection.detailNodes.map(\.name).contains("Payload"))
        let ipv4Source = try #require(findNode(in: tcpInspection.detailNodes, id: "ipv4.src"))
        let ipv4Version = try #require(findNode(in: tcpInspection.detailNodes, id: "ipv4.version"))
        let ipv4DontFragment = try #require(findNode(in: tcpInspection.detailNodes, id: "ipv4.flags.df"))
        #expect(ipv4Source.value == "192.168.0.1")
        #expect(ipv4Source.byteRange == PacketByteRange(offset: 26, length: 4))
        #expect(ipv4Version.byteRange == PacketByteRange(offset: 14, length: 1, bitOffset: 0, bitLength: 4, hasBitRange: true))
        #expect(ipv4DontFragment.value == "Set")
        #expect(ipv4DontFragment.byteRange == PacketByteRange(offset: 20, length: 1, bitOffset: 1, bitLength: 1, hasBitRange: true))
        let tcpDestinationPort = try #require(findNode(in: tcpInspection.detailNodes, id: "tcp.dstPort"))
        #expect(tcpDestinationPort.value == "4321")
        #expect(tcpDestinationPort.byteRange == PacketByteRange(offset: 36, length: 2))
        #expect(tcpDestinationPort.fieldName == "tcp.dstport")
        #expect(tcpDestinationPort.rawValue == "10 e1")
        let tcpAckFlag = try #require(findNode(in: tcpInspection.detailNodes, id: "tcp.flags.ack"))
        #expect(tcpAckFlag.value == "Set")
        #expect(tcpAckFlag.byteRange == PacketByteRange(offset: 47, length: 1, bitOffset: 3, bitLength: 1, hasBitRange: true))
        let tcpPayloadLength = try #require(findNode(in: tcpInspection.detailNodes, id: "payload.length"))
        #expect(tcpPayloadLength.value == "4 bytes")
        #expect(tcpPayloadLength.byteRange == PacketByteRange(offset: 54, length: 4))
        let payloadDecodeNote = try #require(findNode(in: tcpInspection.detailNodes, id: "warning.decode"))
        #expect(payloadDecodeNote.name == "Payload Not Decoded")
        #expect(payloadDecodeNote.value == "The remaining payload is encrypted, unsupported, or needs stream reassembly.")
        #expect(payloadDecodeNote.severity == .info)

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

        let icmpInspection = try await document.inspectPacket(id: packets[4].id)
        let icmpNode = try #require(icmpInspection.detailNodes.first { $0.name == "ICMP" })
        #expect(findNode(in: icmpNode.children, id: "icmp.type")?.value == "Echo Request (8)")
        #expect(findNode(in: icmpNode.children, id: "icmp.identifier")?.value == "4660")
        #expect(findNode(in: icmpNode.children, id: "icmp.sequence")?.byteRange == PacketByteRange(offset: 40, length: 2))

            let icmpv6Inspection = try await document.inspectPacket(id: packets[5].id)
            let icmpv6Node = try #require(icmpv6Inspection.detailNodes.first { $0.name == "ICMPv6" })
            #expect(findNode(in: icmpv6Node.children, id: "icmpv6.type")?.value == "Echo Request (128)")
            #expect(findNode(in: icmpv6Node.children, id: "icmpv6.identifier")?.value == "22136")
            #expect(findNode(in: icmpv6Node.children, id: "icmpv6.sequence")?.byteRange == PacketByteRange(offset: 60, length: 2))
        }
    }

    @Test func tlsApplicationDataInspectionRendersRecordVersionsAndEncryptedData() async throws {
        try await withWiresharkDisabled { core in
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

        let document = try await core.openOfflineCaptureDocument(at: captureURL)
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
    }

    @Test func tcpSynInspectionExpandsFlagsAndOptions() async throws {
        try await withWiresharkDisabled { core in
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("tcp-syn-options.pcap")
        try writePCAP(to: captureURL, packets: [makeIPv4TCPSYNOptionsPacket()])

        let document = try await core.openOfflineCaptureDocument(at: captureURL)
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
    }

    @Test func dnsInspectionRendersHeaderFlagsAndRecords() async throws {
        try await withWiresharkDisabled { core in
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("dns-response.pcap")
        try writePCAP(to: captureURL, packets: [makeIPv4DNSResponsePacket()])

        let document = try await core.openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()
        let packet = try #require(packets.first)
        let inspection = try await document.inspectPacket(id: packet.id)

        #expect(packet.transportHint == .dns)
        let dnsNode = try #require(inspection.detailNodes.first { $0.name == "Domain Name System" })
        #expect(findNode(in: dnsNode.children, id: "dns.id")?.value == "0x1234")
        #expect(findNode(in: dnsNode.children, id: "dns.flags.response")?.value == "Response")
        #expect(findNode(in: dnsNode.children, id: "dns.count.queries")?.value == "1")
        #expect(findNode(in: dnsNode.children, id: "dns.count.answers")?.value == "1")
        #expect(findNode(in: dnsNode.children, id: "dns.query.0.name")?.value == "www.example.com")
        #expect(findNode(in: dnsNode.children, id: "dns.query.0.type")?.value == "A (1)")
        #expect(findNode(in: dnsNode.children, id: "dns.answer.0.name")?.value == "www.example.com")
            #expect(findNode(in: dnsNode.children, id: "dns.answer.0.data")?.value == "93.184.216.34")
            #expect(findNode(in: dnsNode.children, id: "dns.answer.0.data")?.byteRange == PacketByteRange(offset: 87, length: 4))
        }
    }

    @Test func phaseTwoInspectionRendersHTTPHeadersAndWebSocketFrames() async throws {
        try await withWiresharkDisabled { core in
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("phase-two-app-protocols.pcap")
        try writePCAP(
            to: captureURL,
            packets: [
                makeIPv4HTTPRequestPacket(),
                makeIPv4WebSocketTextFramePacket(),
            ]
        )

        let document = try await core.openOfflineCaptureDocument(at: captureURL)
        let packets = try await document.open()
        #expect(packets.count == 2)
        #expect(packets[0].transportHint == .http1)
        #expect(packets[1].transportHint == .websocket)

        let httpInspection = try await document.inspectPacket(id: packets[0].id)
        let httpNode = try #require(httpInspection.detailNodes.first { $0.name == "HTTP Request" })
        let method = try #require(findNode(in: httpNode.children, id: "http.request.54.method"))
        #expect(method.value == "GET")
        #expect(method.fieldName == "http.request.method")
        #expect(method.byteRange == PacketByteRange(offset: 54, length: 3))
        #expect(findNode(in: httpNode.children, id: "http.request.54.uri")?.value == "/chat")
        #expect(findNode(in: httpNode.children, id: "http.request.54.version")?.value == "HTTP/1.1")

        let host = try #require(findNode(in: httpNode.children, id: "http.request.54.header.0.value"))
        #expect(host.value == "example.com")
        #expect(host.fieldName == "http.host")
        #expect(host.byteRange == PacketByteRange(offset: 80, length: 11))
        #expect(findNode(in: httpNode.children, id: "http.request.54.header.complete")?.value == "Yes")

        let websocketInspection = try await document.inspectPacket(id: packets[1].id)
        #expect(packets[1].layers.contains { $0.name == "WebSocket" })
        let websocketNode = try #require(websocketInspection.detailNodes.first { $0.name == "WebSocket" })
        #expect(websocketNode.value == "Text, 5 bytes")
        #expect(findNode(in: websocketNode.children, id: "websocket.54.fin")?.value == "Set")
        #expect(findNode(in: websocketNode.children, id: "websocket.54.opcode")?.byteRange == PacketByteRange(offset: 54, length: 1, bitOffset: 4, bitLength: 4, hasBitRange: true))
        #expect(findNode(in: websocketNode.children, id: "websocket.54.payloadLength")?.byteRange == PacketByteRange(offset: 55, length: 1, bitOffset: 1, bitLength: 7, hasBitRange: true))

        let maskingKey = try #require(findNode(in: websocketNode.children, id: "websocket.54.maskingKey"))
        #expect(maskingKey.rawValue == "01 02 03 04")
        #expect(maskingKey.byteRange == PacketByteRange(offset: 56, length: 4))
            let websocketPayload = try #require(findNode(in: websocketNode.children, id: "websocket.54.payload"))
            #expect(websocketPayload.value == "69 67 6f 68 6e")
            #expect(websocketPayload.byteRange == PacketByteRange(offset: 60, length: 5))
        }
    }

    @Test func incrementalOpenEmitsAppendBatchesAndCompletedProgress() async throws {
        try await withWiresharkDisabled { core in
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("incremental-complete.pcap")
        let repeatedPacket = makeIPv4UDPPayloadPacket()
        let packetCount = 640
        try writePCAP(to: captureURL, repeating: repeatedPacket, count: packetCount)

        let document = try await core.openOfflineCaptureDocument(at: captureURL)
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
    }

    @Test func incrementalOpenAllowsEarlyInspectionAndCancellation() async throws {
        try await withWiresharkDisabled { core in
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("incremental-cancel.pcap")
        let repeatedPacket = makeIPv4UDPPayloadPacket()
        let totalPacketCount = 120_000
        try writePCAP(to: captureURL, repeating: repeatedPacket, count: totalPacketCount)

        let document = try await core.openOfflineCaptureDocument(at: captureURL)
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

    #if DEBUG
    @Test func livePacketDiskStoreAppendsInspectsAndCleansUpLargeCounts() throws {
        let harness = NativeLivePacketDiskStoreTestHarness()
        let packet = makeIPv4UDPPayloadPacket()
        let checkpoints = [10_000, 50_000, 100_000]
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var lastCheckpoint = 0

        for checkpoint in checkpoints {
            for packetNumber in (lastCheckpoint + 1)...checkpoint {
                try harness.appendPacket(
                    identifier: UInt64(packetNumber),
                    rawBytes: packet,
                    timestamp: timestamp.addingTimeInterval(TimeInterval(packetNumber))
                )
            }

            let snapshot = harness.snapshot
            #expect(snapshot.packetCount == checkpoint)
            #expect(snapshot.backingFileExists)
            #expect(snapshot.backingFileSize == UInt64(packet.count * checkpoint))
            #expect(try harness.offset(identifier: 1) == 0)
            #expect(try harness.offset(identifier: UInt64(checkpoint)) == UInt64(packet.count * (checkpoint - 1)))
            lastCheckpoint = checkpoint
        }

        for identifier in [UInt64(1), 50_000, 100_000] {
            let inspection = try harness.inspectPacket(identifier: identifier)
            #expect(inspection.packetID == identifier)
            #expect(inspection.rawBytes == packet)
            #expect(inspection.detailNodes.map(\.name).contains("UDP"))
        }

        do {
            _ = try harness.inspectPacket(identifier: 100_001)
            Issue.record("Expected a missing packet identifier to fail.")
        } catch {
            #expect(String(describing: error).contains("backing store"))
        }

        let backingFilePath = harness.snapshot.backingFilePath
        #expect(FileManager.default.fileExists(atPath: backingFilePath))

        harness.cleanup()

        #expect(!FileManager.default.fileExists(atPath: backingFilePath))
        #expect(harness.snapshot.packetCount == 0)
        #expect(!harness.snapshot.backingFileExists)
    }

    @Test func livePacketDiskStoreUnitAppendsAtEOFAfterInspectionReads() throws {
        let harness = NativeLivePacketDiskStoreTestHarness()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstPacket = makeIPv4UDPPayloadPacket()
        var secondPacket = makePaddedPacket(base: makeIPv4UDPPayloadPacket(), byteCount: 64)
        secondPacket[secondPacket.count - 1] = 0x22
        var thirdPacket = makePaddedPacket(base: makeIPv4UDPPayloadPacket(), byteCount: 96)
        thirdPacket[thirdPacket.count - 1] = 0x33

        try harness.appendPacket(identifier: 1, rawBytes: firstPacket, timestamp: timestamp)
        try harness.appendPacket(identifier: 2, rawBytes: secondPacket, timestamp: timestamp.addingTimeInterval(1))

        let firstInspection = try harness.inspectPacket(identifier: 1)
        #expect(firstInspection.rawBytes == firstPacket)

        try harness.appendPacket(identifier: 3, rawBytes: thirdPacket, timestamp: timestamp.addingTimeInterval(2))

        #expect(try harness.offset(identifier: 1) == 0)
        #expect(try harness.offset(identifier: 2) == UInt64(firstPacket.count))
        #expect(try harness.offset(identifier: 3) == UInt64(firstPacket.count + secondPacket.count))
        #expect(harness.snapshot.backingFileSize == UInt64(firstPacket.count + secondPacket.count + thirdPacket.count))
        #expect(try harness.inspectPacket(identifier: 2).rawBytes == secondPacket)
        #expect(try harness.inspectPacket(identifier: 3).rawBytes == thirdPacket)

        harness.cleanup()
    }

    @Test func livePacketReanalysisIntegrationDoesNotCorruptLaterPacketSummaries() throws {
        let harness = NativeLivePacketDiskStoreTestHarness()
        let timestamp = Date(timeIntervalSince1970: 1_700_200_000)
        let firstPacket = makeIPv4UDPPayloadPacket()
        var secondPacket = makePaddedPacket(base: makeIPv4UDPPayloadPacket(), byteCount: 94)
        secondPacket[secondPacket.count - 1] = 0x22
        let thirdPacket = makeUnknownEtherTypePacket(etherType: 0xb681, byteCount: 66)

        try harness.appendPacket(identifier: 1, rawBytes: firstPacket, timestamp: timestamp)
        try harness.appendPacket(identifier: 2, rawBytes: secondPacket, timestamp: timestamp.addingTimeInterval(1))

        let staleReanalysis = try harness.reanalyzePacketSummaries(upTo: 1)
        #expect(staleReanalysis.count == 1)
        #expect(staleReanalysis.first?.layers.map(\.name).contains("UDP") == true)

        try harness.appendPacket(identifier: 3, rawBytes: thirdPacket, timestamp: timestamp.addingTimeInterval(2))

        let summaries = try harness.reanalyzePacketSummaries(upTo: 2)
        let secondSummary = try #require(summaries.last)
        #expect(secondSummary.id == 2)
        #expect(secondSummary.layers.map(\.name).contains("UDP"))
        #expect(secondSummary.infoSummary != "Ethernet II")
        if let protocolSummary = secondSummary.protocolSummary {
            #expect(!isHexEtherTypeProtocol(protocolSummary))
        }

        #expect(try harness.offset(identifier: 1) == 0)
        #expect(try harness.offset(identifier: 2) == UInt64(firstPacket.count))
        #expect(try harness.offset(identifier: 3) == UInt64(firstPacket.count + secondPacket.count))
        #expect(try harness.inspectPacket(identifier: 2).rawBytes == secondPacket)
        #expect(try harness.inspectPacket(identifier: 3).rawBytes == thirdPacket)

        harness.cleanup()
    }

    @Test func livePacketReanalysisSummariesRemainValidAfterNativeStoreCleanup() throws {
        let harness = NativeLivePacketDiskStoreTestHarness()
        defer { harness.cleanup() }

        let packet = makeIPv4UDPPayloadPacket()
        let timestamp = Date(timeIntervalSince1970: 1_700_300_000)
        for packetNumber in 1...3 {
            try harness.appendPacket(
                identifier: UInt64(packetNumber),
                rawBytes: packet,
                timestamp: timestamp.addingTimeInterval(TimeInterval(packetNumber))
            )
        }

        let summaries = try harness.reanalyzePacketSummaries()
        let backingFilePath = harness.snapshot.backingFilePath

        harness.cleanup()

        #expect(!FileManager.default.fileExists(atPath: backingFilePath))

        // Force value copies after native descriptors and their packet store are gone.
        let copiedSummaries = summaries.map { $0 }
        let summarySet = Set(copiedSummaries)

        #expect(copiedSummaries.map(\.id) == [1, 2, 3])
        #expect(summarySet.count == 3)
        #expect(copiedSummaries.allSatisfy { $0.source == .live })
        #expect(copiedSummaries.allSatisfy { $0.endpoints.source.address == "192.168.0.1" })
        #expect(copiedSummaries.allSatisfy { $0.endpoints.destination.address == "192.168.0.2" })
        #expect(copiedSummaries.allSatisfy { $0.layers.map(\.name).contains("UDP") })
        #expect(copiedSummaries.allSatisfy { !$0.infoSummary.isEmpty })
    }

    @Test func livePacketReanalysisUpdatesReturnStableTextAfterStoreReads() throws {
        let harness = NativeLivePacketDiskStoreTestHarness()
        defer { harness.cleanup() }

        let timestamp = Date(timeIntervalSince1970: 1_700_400_000)
        let firstPacket = makeIPv4UDPPayloadPacket()
        var secondPacket = makePaddedPacket(base: makeIPv4UDPPayloadPacket(), byteCount: 94)
        secondPacket[secondPacket.count - 1] = 0x44

        try harness.appendPacket(identifier: 1, rawBytes: firstPacket, timestamp: timestamp)
        try harness.appendPacket(identifier: 2, rawBytes: secondPacket, timestamp: timestamp.addingTimeInterval(1))

        let firstInspection = try harness.inspectPacket(identifier: 1)
        #expect(firstInspection.rawBytes == firstPacket)

        let updates = try harness.reanalyzePacketSummaryUpdates(upTo: 2)
        let copiedUpdates = updates.map { $0 }

        #expect(copiedUpdates.map(\.packetID) == [1, 2])
        #expect(copiedUpdates.allSatisfy { !$0.infoSummary.isEmpty })
        #expect(copiedUpdates.last?.infoSummary != "Ethernet II")
        if let protocolSummary = copiedUpdates.last?.protocolSummary {
            #expect(!isHexEtherTypeProtocol(protocolSummary))
        }
    }

    @Test func livePacketDiskStoreRSSStressIsGated() throws {
        guard ProcessInfo.processInfo.environment["TCPVIEWER_RUN_MEMORY_STRESS"] == "1" else {
            return
        }

        let harness = NativeLivePacketDiskStoreTestHarness()
        let packet = makePaddedPacket(base: makeIPv4UDPPayloadPacket(), byteCount: 2_048)
        let timestamp = Date(timeIntervalSince1970: 1_700_100_000)
        var samples: [(String, UInt64)] = [("before", residentMemoryBytes())]
        var appended = 0

        for checkpoint in [10_000, 50_000, 100_000] {
            for packetNumber in (appended + 1)...checkpoint {
                try harness.appendPacket(
                    identifier: UInt64(packetNumber),
                    rawBytes: packet,
                    timestamp: timestamp.addingTimeInterval(TimeInterval(packetNumber))
                )
            }

            appended = checkpoint
            samples.append(("after \(checkpoint)", residentMemoryBytes()))
        }

        for identifier in [UInt64(1), 50_000, 100_000] {
            let inspection = try harness.inspectPacket(identifier: identifier)
            #expect(inspection.rawBytes.count == packet.count)
        }
        samples.append(("after inspections", residentMemoryBytes()))

        let beforeCleanupPath = harness.snapshot.backingFilePath
        harness.cleanup()
        samples.append(("after cleanup", residentMemoryBytes()))

        let capturedBytes = UInt64(packet.count * 100_000)
        let growthAt100K = samples[3].1 > samples[0].1 ? samples[3].1 - samples[0].1 : 0
        let growthAfterInspections = samples[4].1 > samples[0].1 ? samples[4].1 - samples[0].1 : 0
        logMemorySamples(samples)

        #expect(!FileManager.default.fileExists(atPath: beforeCleanupPath))
        #expect(growthAt100K < 96 * 1_024 * 1_024)
        #expect(growthAfterInspections < 112 * 1_024 * 1_024)
        #expect(growthAt100K < capturedBytes / 2)
    }
    #endif
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
        case .liveStateChanged, .documentStateChanged, .healthChanged, .documentMetadataChanged, .packetSummaryUpdates:
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

private func writePCAPNG(to url: URL, interfaces: [String], packets: [(packet: Data, interfaceID: UInt32)]) throws {
    var data = Data()

    var sectionBody = Data()
    sectionBody.appendLittleEndian(UInt32(0x1a2b3c4d))
    sectionBody.appendLittleEndian(UInt16(1))
    sectionBody.appendLittleEndian(UInt16(0))
    sectionBody.appendLittleEndian(UInt64.max)
    appendPCAPNGBlock(type: 0x0a0d0d0a, body: sectionBody, to: &data)

    for interfaceName in interfaces {
        var interfaceBody = Data()
        interfaceBody.appendLittleEndian(UInt16(1))
        interfaceBody.appendLittleEndian(UInt16(0))
        interfaceBody.appendLittleEndian(UInt32(65_535))
        appendPCAPNGStringOption(code: 2, value: interfaceName, to: &interfaceBody)
        interfaceBody.appendLittleEndian(UInt16(0))
        interfaceBody.appendLittleEndian(UInt16(0))
        appendPCAPNGBlock(type: 1, body: interfaceBody, to: &data)
    }

    for (index, entry) in packets.enumerated() {
        let packetLength = try UInt32(exactly: entry.packet.count).unwrap()
        let timestamp = UInt64(1_700_000_000 + index) * 1_000_000
        var packetBody = Data()
        packetBody.appendLittleEndian(entry.interfaceID)
        packetBody.appendLittleEndian(UInt32(timestamp >> 32))
        packetBody.appendLittleEndian(UInt32(timestamp & 0xffff_ffff))
        packetBody.appendLittleEndian(packetLength)
        packetBody.appendLittleEndian(packetLength)
        packetBody.append(entry.packet)
        packetBody.appendPCAPNGPadding(for: entry.packet.count)
        packetBody.appendLittleEndian(UInt16(0))
        packetBody.appendLittleEndian(UInt16(0))
        appendPCAPNGBlock(type: 6, body: packetBody, to: &data)
    }

    try data.write(to: url)
}

private func appendPCAPNGBlock(type: UInt32, body: Data, to data: inout Data) {
    let totalLength = UInt32(12 + body.count)
    data.appendLittleEndian(type)
    data.appendLittleEndian(totalLength)
    data.append(body)
    data.appendLittleEndian(totalLength)
}

private func appendPCAPNGStringOption(code: UInt16, value: String, to data: inout Data) {
    let bytes = Array(value.utf8)
    data.appendLittleEndian(code)
    data.appendLittleEndian(UInt16(bytes.count))
    data.append(contentsOf: bytes)
    data.appendPCAPNGPadding(for: bytes.count)
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

private func makeIPv4DNSResponsePacket() -> Data {
    let dnsPayload: [UInt8] = [
        0x12, 0x34,
        0x81, 0x80,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00,
        0x03, 0x77, 0x77, 0x77,
        0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
        0x03, 0x63, 0x6f, 0x6d,
        0x00,
        0x00, 0x01,
        0x00, 0x01,
        0xc0, 0x0c,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x3c,
        0x00, 0x04,
        0x5d, 0xb8, 0xd8, 0x22,
    ]
    let udpLength = UInt16(8 + dnsPayload.count)
    let ipv4TotalLength = UInt16(20 + Int(udpLength))
    var packet = Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x00,
        0x45, 0x00,
    ])
    packet.appendBigEndian(ipv4TotalLength)
    packet.append(contentsOf: [
        0x12, 0x38, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x02,
        0xc0, 0xa8, 0x00, 0x01,
    ])
    packet.appendBigEndian(UInt16(53))
    packet.appendBigEndian(UInt16(54_321))
    packet.appendBigEndian(udpLength)
    packet.appendBigEndian(UInt16(0))
    packet.append(contentsOf: dnsPayload)
    return packet
}

private func makeIPv4HTTPRequestPacket() -> Data {
    makeIPv4TCPPacket(
        sourcePort: 54_321,
        destinationPort: 80,
        identification: 0x1240,
        payload: Array("""
GET /chat HTTP/1.1\r
Host: example.com\r
Upgrade: websocket\r
Connection: Upgrade\r
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
\r
""".utf8)
    )
}

private func makeIPv4WebSocketTextFramePacket() -> Data {
    makeIPv4TCPPacket(
        sourcePort: 54_321,
        destinationPort: 80,
        identification: 0x1241,
        payload: [
            0x81, 0x85,
            0x01, 0x02, 0x03, 0x04,
            0x69, 0x67, 0x6f, 0x68, 0x6e,
        ]
    )
}

private func makeIPv4TCPPacket(sourcePort: UInt16, destinationPort: UInt16, identification: UInt16, payload: [UInt8]) -> Data {
    let ipv4TotalLength = UInt16(20 + 20 + payload.count)
    var packet = Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x00,
        0x45, 0x00,
    ])
    packet.appendBigEndian(ipv4TotalLength)
    packet.appendBigEndian(identification)
    packet.append(contentsOf: [
        0x40, 0x00, 0x40, 0x06, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x01,
        0xc0, 0xa8, 0x00, 0x02,
    ])
    packet.appendBigEndian(sourcePort)
    packet.appendBigEndian(destinationPort)
    packet.append(contentsOf: [
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x01,
        0x50, 0x18, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
    packet.append(contentsOf: payload)
    return packet
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

private func makeIPv4ICMPEchoRequestPacket() -> Data {
    Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x08, 0x00,
        0x45, 0x00, 0x00, 0x20, 0x12, 0x39, 0x40, 0x00, 0x40, 0x01, 0x00, 0x00,
        0xc0, 0xa8, 0x00, 0x01,
        0xc0, 0xa8, 0x00, 0x02,
        0x08, 0x00, 0x00, 0x00,
        0x12, 0x34,
        0x00, 0x02,
        0xaa, 0xbb, 0xcc, 0xdd,
    ])
}

private func makeIPv6ICMPEchoRequestPacket() -> Data {
    Data([
        0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x86, 0xdd,
        0x60, 0x00, 0x00, 0x00,
        0x00, 0x0c,
        0x3a,
        0x40,
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x80, 0x00, 0x00, 0x00,
        0x56, 0x78,
        0x00, 0x03,
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

private func nodeHasByteSource(_ node: PacketDetailNode, sourceID: String) -> Bool {
    if node.byteRange?.sourceID == sourceID {
        return true
    }
    return node.children.contains { nodeHasByteSource($0, sourceID: sourceID) }
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

private func wiresharkDisabledCore() -> NativeTCPViewerCore {
    NativeTCPViewerCore(disablesWiresharkForOfflineDocuments: true, disablesWiresharkForLiveSessions: true)
}

private func withWiresharkDisabled<T>(_ body: (NativeTCPViewerCore) async throws -> T) async rethrows -> T {
    try await body(wiresharkDisabledCore())
}

private func makePaddedPacket(base: Data, byteCount: Int) -> Data {
    var packet = base
    if packet.count < byteCount {
        packet.append(Data(repeating: 0, count: byteCount - packet.count))
    }
    return packet
}

private func makeUnknownEtherTypePacket(etherType: UInt16, byteCount: Int) -> Data {
    var packet = makePaddedPacket(base: makeIPv4UDPPayloadPacket(), byteCount: byteCount)
    packet[12] = UInt8((etherType >> 8) & 0xff)
    packet[13] = UInt8(etherType & 0xff)
    return packet
}

private func isHexEtherTypeProtocol(_ value: String) -> Bool {
    value.range(of: #"^0x[0-9a-fA-F]{4}$"#, options: .regularExpression) != nil
}

private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
        }
    }

    guard result == KERN_SUCCESS else {
        return 0
    }

    return UInt64(info.resident_size)
}

private func logMemorySamples(_ samples: [(String, UInt64)]) {
    let formatted = samples.map { label, bytes in
        String(format: "%@: %.1f MB", label, Double(bytes) / 1_048_576.0)
    }
    print("TCPViewer RSS stress samples: \(formatted.joined(separator: ", "))")
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

    mutating func appendPCAPNGPadding(for byteCount: Int) {
        let padding = (4 - (byteCount % 4)) % 4
        if padding > 0 {
            append(Data(repeating: 0, count: padding))
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
