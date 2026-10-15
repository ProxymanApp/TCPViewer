//
//  CaptureOverviewServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct CaptureOverviewServiceTests {
    @Test func duplicateAppsAndDomainsUseLocalDirectionAndOriginalLength() throws {
        let client = makeClient(name: "Browser", bundleIdentifier: "com.example.browser")
        let packets = [
            makePacket(id: 1, length: 200, direction: .outbound, domain: "Example.COM.", client: client),
            makePacket(id: 2, length: 100, direction: .inbound, domain: "example.com", client: client),
            makePacket(
                id: 3,
                length: 50,
                direction: .unknown,
                domain: " EXAMPLE.COM ",
                client: client,
                decodeStatus: PacketDecodeStatus(kind: .malformed)
            ),
        ]

        let snapshot = replacementSnapshot(packets)
        let app = try #require(snapshot.topApps.first)
        let domain = try #require(snapshot.topDestinations.first)

        #expect(snapshot.totals.packets == 3)
        #expect(snapshot.totals.bytes == 350)
        #expect(snapshot.totals.sentBytes == 200)
        #expect(snapshot.totals.receivedBytes == 100)
        #expect(snapshot.totals.unclassifiedBytes == 50)
        #expect(snapshot.malformedPacketCount == 1)
        #expect(snapshot.appCount == 1)
        #expect(snapshot.domainCount == 1)
        #expect(app.selection == .app(PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.browser")))
        #expect(domain.selection == .domain(PacketSourceDomainKey(rawValue: "example.com", isMissingDomain: false)))
        #expect(app.totals == snapshot.totals)
        #expect(domain.totals == snapshot.totals)
    }

    @Test func metadataReclassificationRemovesThePreviousContribution() throws {
        let oldClient = makeClient(name: "Old App", bundleIdentifier: "com.example.old")
        let newClient = makeClient(name: "New App", bundleIdentifier: "com.example.new")
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk([
            makePacket(id: 1, length: 128, direction: .outbound, domain: "old.example", client: oldClient),
        ])
        let didFinishInitialReplacement = accumulator.finishReplacement(cursor: cursor(revision: 1, count: 1))
        #expect(didFinishInitialReplacement)

        let updatedPacket = makePacket(
            id: 1,
            length: 128,
            direction: .inbound,
            domain: "new.example",
            client: newClient
        )
        let didConsumeMetadata = accumulator.consume(EndpointStatisticsIngestUpdate(
            packetRevision: 2,
            packetLineageRevision: 1,
            totalPacketCount: 1,
            kind: .metadata([updatedPacket]),
            previousPacketRevision: 1
        ))
        #expect(didConsumeMetadata)

        let snapshot = accumulator.snapshot()
        #expect(snapshot.appCount == 1)
        #expect(snapshot.domainCount == 1)
        #expect(snapshot.topApps.map(\.title) == ["New App"])
        #expect(snapshot.topDestinations.map(\.title) == ["new.example"])
        #expect(snapshot.totals.sentBytes == 0)
        #expect(snapshot.totals.receivedBytes == 128)
        #expect(snapshot.totals.bytes == 128)
    }

    @Test func resetDropsThePreviousCaptureLineage() {
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk([makePacket(id: 1, domain: "old.example")])
        let didFinishOldReplacement = accumulator.finishReplacement(cursor: cursor(revision: 1, count: 1))
        #expect(didFinishOldReplacement)

        accumulator.reset()
        accumulator.appendReplacementChunk([makePacket(id: 2, length: 512, domain: "new.example")])
        let didFinishNewReplacement = accumulator.finishReplacement(cursor: cursor(revision: 1, lineage: 2, count: 1))
        #expect(didFinishNewReplacement)

        let snapshot = accumulator.snapshot()
        #expect(snapshot.totals.packets == 1)
        #expect(snapshot.totals.bytes == 512)
        #expect(snapshot.topDestinations.map(\.title) == ["new.example"])
    }

    @Test func topRowsAreBoundedAndUseStableTieOrdering() {
        let tiedPackets = [
            makePacket(id: 1, length: 50, domain: "gamma.example"),
            makePacket(id: 2, length: 50, domain: "gamma.example"),
            makePacket(id: 3, length: 100, domain: "beta.example"),
            makePacket(id: 4, length: 100, domain: "alpha.example"),
        ]
        let extraPackets = (0..<8).map { index in
            makePacket(id: UInt64(index + 10), length: 10 - index, domain: "extra-\(index).example")
        }

        let snapshot = replacementSnapshot(tiedPackets + extraPackets)

        #expect(snapshot.topDestinations.count == CaptureOverviewAccumulator.maximumTopRowCount)
        #expect(snapshot.topDestinations.prefix(3).map(\.title) == [
            "gamma.example",
            "alpha.example",
            "beta.example",
        ])
    }

    @Test func unresolvedAddressesJoinDomainsInTheDestinationRanking() {
        let snapshot = replacementSnapshot([
            makePacket(id: 1, length: 256),
            makePacket(id: 2, length: 128, domain: "api.example"),
        ])

        #expect(snapshot.topDestinations.map(\.title) == [
            "10.0.0.2",
            "93.184.216.34",
            "api.example",
        ])
        #expect(snapshot.topDestinations[0].selection == .ipAddress(
            PacketSourceIPAddressKey(rawValue: "10.0.0.2")
        ))
        #expect(snapshot.topDestinations[2].selection == .domain(
            PacketSourceDomainKey(rawValue: "api.example", isMissingDomain: false)
        ))
    }

    @Test func protocolTotalsAndRenderedTimelineStayBounded() {
        let hints: [TransportProtocolHint] = [.tcp, .udp, .dns, .tls, .http1, .arp, .icmp]
        var packets = hints.enumerated().map { index, hint in
            makePacket(id: UInt64(index + 1), length: (index + 1) * 10, transportHint: hint)
        }
        packets += (0..<2_000).map { index in
            makePacket(
                id: UInt64(index + 100),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                transportHint: .tcp
            )
        }

        let snapshot = replacementSnapshot(packets)
        let protocolBytes = snapshot.protocols.reduce(UInt64(0)) { $0 + $1.totals.bytes }

        #expect(snapshot.protocols.count == CaptureOverviewAccumulator.maximumProtocolRowCount + 1)
        #expect(snapshot.protocols.last?.title == "Other")
        #expect(protocolBytes == snapshot.totals.bytes)
        #expect(snapshot.timeline.count <= CaptureOverviewAccumulator.maximumRenderedTimelinePointCount)
    }

    @Test func timelineHoverMapsThePointerToOneSlotAndKeepsTheTooltipInside() {
        #expect(CaptureOverviewChartHoverSelection.slotIndex(fraction: nil, slotCount: 12) == nil)
        #expect(CaptureOverviewChartHoverSelection.slotIndex(fraction: 0.5, slotCount: 0) == nil)
        #expect(CaptureOverviewChartHoverSelection.slotIndex(fraction: 0, slotCount: 12) == 0)
        #expect(CaptureOverviewChartHoverSelection.slotIndex(fraction: 0.5, slotCount: 12) == 6)
        #expect(CaptureOverviewChartHoverSelection.slotIndex(fraction: 1, slotCount: 12) == 11)
        #expect(CaptureOverviewChartHoverSelection.slotIndex(fraction: -0.2, slotCount: 12) == 0)

        // Beside the slot when it fits, flipped to the left near the trailing edge.
        #expect(CaptureOverviewChartHoverSelection.tooltipX(slot: 0, slotCount: 10, width: 300, tooltipWidth: 100) == 38)
        #expect(CaptureOverviewChartHoverSelection.tooltipX(slot: 9, slotCount: 10, width: 300, tooltipWidth: 100) == 162)
    }

    @Test func tcpIssuesReadEveryWiresharkInfoMarker() {
        func issues(
            _ info: String,
            tcpFlags: String? = "ACK",
            transportHint: TransportProtocolHint = .tcp,
            decodeStatus: PacketDecodeStatus.Kind = .complete
        ) -> CaptureOverviewTCPIssueSet {
            let packet = makePacket(
                id: 1,
                transportHint: transportHint,
                info: info,
                tcpFlags: tcpFlags,
                decodeStatus: PacketDecodeStatus(kind: decodeStatus)
            )
            return CaptureOverviewClassifier.tcpIssues(for: packet, isTCP: CaptureOverviewClassifier.isTCP(packet))
        }

        #expect(issues("[TCP Retransmission] 51000 → 443 [PSH, ACK]") == CaptureOverviewTCPIssueSet(.retransmission))
        #expect(issues("[TCP Fast Retransmission] 51000 → 443") == CaptureOverviewTCPIssueSet(.retransmission))
        #expect(issues("[TCP Spurious Retransmission] 51000 → 443") == CaptureOverviewTCPIssueSet(.retransmission))
        #expect(issues("[TCP Dup ACK 12#1] 443 → 51000 [ACK]") == CaptureOverviewTCPIssueSet(.duplicateAck))
        #expect(issues("[TCP Out-Of-Order] 443 → 51000") == CaptureOverviewTCPIssueSet(.outOfOrder))
        #expect(issues("[TCP ZeroWindow] 443 → 51000") == CaptureOverviewTCPIssueSet(.zeroWindow))
        #expect(issues("[TCP ZeroWindowProbe] 443 → 51000") == CaptureOverviewTCPIssueSet(.zeroWindow))
        #expect(issues("[TCP Window Full] 443 → 51000") == CaptureOverviewTCPIssueSet(.zeroWindow))
        #expect(issues("[TCP Previous segment not captured] 443 → 51000") == CaptureOverviewTCPIssueSet(.lostSegment))
        // Every marker counts, so each row matches the packets its display filter shows.
        #expect(issues("[TCP Dup ACK 5#1] [TCP ACKed unseen segment] 443 → 51000") ==
            [CaptureOverviewTCPIssueSet(.duplicateAck), CaptureOverviewTCPIssueSet(.lostSegment)])
        #expect(issues("[TCP Retransmission] 443 → 51000 [RST, ACK]", tcpFlags: "RST, ACK") ==
            [CaptureOverviewTCPIssueSet(.retransmission), CaptureOverviewTCPIssueSet(.reset)])
        #expect(issues("Ignored [Malformed Packet]") == CaptureOverviewTCPIssueSet(.malformed))
        #expect(issues("Response [Malformed Packet: length of contained item exceeds length of containing item]") ==
            CaptureOverviewTCPIssueSet(.malformed))
        // Only Wireshark's marker counts, because the row filters on _ws.malformed.
        #expect(issues("Client Hello", decodeStatus: .malformed).isEmpty)
        #expect(issues("[TCP Keep-Alive] 51000 → 443").isEmpty)
        #expect(issues("[TCP Window Update] 51000 → 443").isEmpty)
        #expect(issues("Application Data").isEmpty)
        #expect(!CaptureOverviewTCPIssueSet(.malformed).hasTCPIssue)
        #expect(issues("Standard query [Malformed Packet]", tcpFlags: nil, transportHint: .dns) ==
            CaptureOverviewTCPIssueSet(.malformed))
    }

    @Test func malformedPacketsAreNotTCPIssuesAndMultiFlagPacketsCountOnce() {
        let snapshot = replacementSnapshot([
            makePacket(id: 1, transportHint: .dns, info: "Standard query [Malformed Packet]"),
            makePacket(id: 2, info: "[TCP Dup ACK 5#1] [TCP ACKed unseen segment] 443 → 51000", tcpFlags: "ACK"),
            makePacket(id: 3, info: "51000 → 443 [ACK]", tcpFlags: "ACK"),
        ])

        #expect(snapshot.tcpPacketCount == 2)
        #expect(snapshot.totals.issuePackets == 1)
        #expect(snapshot.tcpIssues == [
            CaptureOverviewTCPIssueRow(kind: .malformed, packets: 1),
            CaptureOverviewTCPIssueRow(kind: .lostSegment, packets: 1),
            CaptureOverviewTCPIssueRow(kind: .duplicateAck, packets: 1),
        ])
    }

    @Test func conversationBucketsStayBoundedAndPrunedOnesNeverUnderflow() {
        var accumulator = CaptureOverviewAccumulator()
        let limit = CaptureOverviewAccumulator.maximumConversationBucketCount
        accumulator.appendReplacementChunk([
            makePacket(id: 1, length: 100, sourcePort: 40_000),
            makePacket(id: 2, length: 50, sourcePort: 40_001),
        ])
        // A DNS-like burst of one-packet conversations, each bigger than the first two.
        accumulator.appendReplacementChunk((0..<(limit * 2)).map { index in
            makePacket(id: UInt64(index + 10), length: 200, sourcePort: UInt16(10_000 + index))
        })
        #expect(accumulator.conversationBucketCountForTesting <= limit * 2)
        #expect(!accumulator.snapshot().topConversations.contains { $0.endpoints.clientPort == 40_000 })

        // The pruned conversation comes back; reclassifying packet 1 must not subtract its old bytes from the
        // new bucket, which never contained them.
        accumulator.appendReplacementChunk([makePacket(id: 3, length: 1_000, sourcePort: 40_000)])
        let client = makeClient(name: "App", bundleIdentifier: "com.example.app")
        accumulator.applyMetadata([makePacket(id: 1, length: 100, client: client, sourcePort: 40_000)])

        let snapshot = accumulator.snapshot()
        #expect(snapshot.topConversations.first?.endpoints.clientPort == 40_000)
        #expect(snapshot.topConversations.first?.totals.bytes == 1_100)
        #expect(snapshot.totals.packets == UInt64(limit * 2 + 3))
    }

    @Test func tcpIssuesFollowSummaryUpdatesAndRollUpPerApp() throws {
        let client = makeClient(name: "Browser", bundleIdentifier: "com.example.browser")
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk([
            makePacket(id: 1, client: client, info: "51000 → 443 [ACK]", tcpFlags: "ACK"),
            makePacket(id: 2, client: client, info: "[TCP Dup ACK 1#1] 51000 → 443 [ACK]", tcpFlags: "ACK"),
            makePacket(id: 3, transportHint: .dns, info: "Standard query"),
        ])
        let didFinishReplacement = accumulator.finishReplacement(cursor: cursor(revision: 1, count: 3))
        #expect(didFinishReplacement)

        // Wireshark refines the Info column later; the old classification must be removed, not added twice.
        let didConsume = accumulator.consume(EndpointStatisticsIngestUpdate(
            packetRevision: 2,
            packetLineageRevision: 1,
            totalPacketCount: 3,
            kind: .metadata([
                makePacket(id: 1, client: client, info: "[TCP Retransmission] 51000 → 443 [ACK]", tcpFlags: "ACK"),
            ]),
            previousPacketRevision: 1
        ))
        #expect(didConsume)

        let snapshot = accumulator.snapshot()
        let app = try #require(snapshot.topApps.first)
        #expect(snapshot.tcpPacketCount == 2)
        #expect(snapshot.totals.issuePackets == 2)
        #expect(app.totals.issuePackets == 2)
        #expect(snapshot.tcpIssues == [
            CaptureOverviewTCPIssueRow(kind: .retransmission, packets: 1),
            CaptureOverviewTCPIssueRow(kind: .duplicateAck, packets: 1),
        ])
        #expect(snapshot.timeline.reduce(0) { $0 + $1.totals.issuePackets } == 2)
    }

    @Test func conversationsMergeBothDirectionsAndServicesUseTheServerPort() throws {
        let snapshot = replacementSnapshot([
            makePacket(id: 1, length: 100, direction: .outbound, domain: "api.example", tcpFlags: "SYN"),
            makePacket(
                id: 2,
                length: 300,
                direction: .inbound,
                tcpFlags: "SYN, ACK",
                sourceAddress: "93.184.216.34",
                sourcePort: 443,
                destinationAddress: "10.0.0.2",
                destinationPort: 51_000
            ),
            makePacket(
                id: 3,
                length: 80,
                transportHint: .dns,
                sourcePort: 53_000,
                destinationAddress: "1.1.1.1",
                destinationPort: 53
            ),
        ])

        let conversation = try #require(snapshot.topConversations.first)
        #expect(snapshot.topConversations.count == 2)
        let endpoints = CaptureOverviewConversationEndpoints(
            transport: .tcp,
            clientAddress: "10.0.0.2",
            clientPort: 51_000,
            serverAddress: "93.184.216.34",
            serverPort: 443
        )
        #expect(conversation.key == .endpoints(endpoints))
        #expect(conversation.endpoints == endpoints)
        #expect(conversation.domainName == "api.example")
        #expect(conversation.totals.bytes == 400)
        #expect(conversation.totals.sentBytes == 100)
        #expect(conversation.totals.receivedBytes == 300)

        #expect(snapshot.topServices.map(\.key) == [
            CaptureOverviewServiceKey(transport: .tcp, port: 443),
            CaptureOverviewServiceKey(transport: .udp, port: 53),
        ])
        #expect(CaptureOverviewClassifier.serviceName(for: CaptureOverviewServiceKey(transport: .udp, port: 443)) == "QUIC")
        #expect(CaptureOverviewClassifier.serviceName(for: CaptureOverviewServiceKey(transport: .tcp, port: 443)) == "HTTPS")
    }

    @Test func displayFiltersOnlyUsePlainAddressLiterals() {
        let conversation = CaptureOverviewConversationKey.endpoints(CaptureOverviewConversationEndpoints(
            transport: .tcp,
            clientAddress: "10.0.0.2",
            clientPort: 51_000,
            serverAddress: "93.184.216.34",
            serverPort: 443
        ))
        #expect(CaptureOverviewClassifier.displayFilter(for: conversation) ==
            "ip.addr == 10.0.0.2 && tcp.port == 51000 && ip.addr == 93.184.216.34 && tcp.port == 443")

        let ipv6 = CaptureOverviewConversationKey.endpoints(CaptureOverviewConversationEndpoints(
            transport: .udp,
            clientAddress: "fe80::1",
            clientPort: 5_353,
            serverAddress: "ff02::fb",
            serverPort: 5_353
        ))
        #expect(CaptureOverviewClassifier.displayFilter(for: ipv6) ==
            "ipv6.addr == fe80::1 && udp.port == 5353 && ipv6.addr == ff02::fb && udp.port == 5353")

        let injected = CaptureOverviewConversationKey.endpoints(CaptureOverviewConversationEndpoints(
            transport: .tcp,
            clientAddress: "10.0.0.2 || frame",
            clientPort: 1,
            serverAddress: "10.0.0.3",
            serverPort: 2
        ))
        #expect(CaptureOverviewClassifier.displayFilter(for: injected) == nil)
        #expect(CaptureOverviewClassifier.displayFilter(for: .stream(FollowStreamID(streamProtocol: .udp, streamID: 7))) ==
            "udp.stream eq 7")
        #expect(CaptureOverviewClassifier.displayFilter(for: CaptureOverviewServiceKey(transport: .udp, port: 53)) == "udp.port == 53")
    }

    @Test func wiresharkStreamIndexSeparatesReusedPortsAndTheSYNNamesTheClient() throws {
        let firstConnection = FollowStreamID(streamProtocol: .tcp, streamID: 3)
        let secondConnection = FollowStreamID(streamProtocol: .tcp, streamID: 9)
        // The server here uses a higher port than its client, so only the handshake tells them apart.
        let snapshot = replacementSnapshot([
            makePacket(
                id: 1,
                length: 300,
                tcpFlags: "SYN",
                sourceAddress: "10.0.0.2",
                sourcePort: 1_024,
                destinationAddress: "10.0.0.9",
                destinationPort: 8_080,
                followStreamID: firstConnection
            ),
            makePacket(
                id: 2,
                length: 200,
                tcpFlags: "ACK",
                sourceAddress: "10.0.0.9",
                sourcePort: 8_080,
                destinationAddress: "10.0.0.2",
                destinationPort: 1_024,
                followStreamID: firstConnection
            ),
            // A later connection reusing the same ports is its own stream.
            makePacket(
                id: 3,
                length: 100,
                tcpFlags: "ACK",
                sourceAddress: "10.0.0.2",
                sourcePort: 1_024,
                destinationAddress: "10.0.0.9",
                destinationPort: 8_080,
                followStreamID: secondConnection
            ),
        ])

        let first = try #require(snapshot.topConversations.first)
        #expect(snapshot.topConversations.count == 2)
        #expect(first.key == .stream(firstConnection))
        #expect(first.totals.bytes == 500)
        #expect(first.endpoints.clientPort == 1_024)
        #expect(first.endpoints.serverPort == 8_080)
        #expect(CaptureOverviewClassifier.displayFilter(for: first.key) == "tcp.stream eq 3")
        #expect(snapshot.topConversations.last?.key == .stream(secondConnection))
    }

    // The classifier reads Info text, so every marker must still exist in the pinned Wireshark sources.
    @Test func tcpInfoMarkersMatchTheVendoredWireshark() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tcpDissector = try String(
            contentsOf: root.appendingPathComponent("Vendor/Wireshark/epan/dissectors/packet-tcp.c"),
            encoding: .utf8
        )
        let exceptions = try String(
            contentsOf: root.appendingPathComponent("Vendor/Wireshark/epan/show_exception.c"),
            encoding: .utf8
        )

        for (kind, markers) in CaptureOverviewClassifier.tcpInfoMarkers {
            for marker in markers {
                #expect(tcpDissector.contains("\"\(marker)"), "\(kind) marker \(marker) is missing from packet-tcp.c")
            }
        }
        #expect(exceptions.contains("\"\(CaptureOverviewClassifier.malformedInfoMarker)"))
    }

    @Test func packetLengthsUseWiresharkRanges() {
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 0) == 0)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 79) == 0)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 80) == 1)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 1_514) == 5)
        #expect(CaptureOverviewClassifier.packetLengthBucket(for: 2_560) == 6)
        #expect(CaptureOverviewClassifier.packetLengthTitle(forBucket: 4) == "640–1279 bytes")
        #expect(CaptureOverviewClassifier.packetLengthAxisTitle(forBucket: 0) == "<80")
        #expect(CaptureOverviewClassifier.packetLengthAxisTitle(forBucket: 6) == "2560+")

        let snapshot = replacementSnapshot([
            makePacket(id: 1, length: 60),
            makePacket(id: 2, length: 1_514),
            makePacket(id: 3, length: 1_500),
        ])
        #expect(snapshot.packetLengthCounts == [1, 0, 0, 0, 0, 2, 0])
    }

    @Test func timelineUsesDenseRoundSlotsWithAMinimumCount() {
        let shortCapture = replacementSnapshot([
            makePacket(id: 1, timestamp: Date(timeIntervalSince1970: 100.2)),
            makePacket(id: 2, timestamp: Date(timeIntervalSince1970: 102.7)),
        ])
        #expect(shortCapture.timelineInterval == 1)
        #expect(shortCapture.timeline.first?.date == Date(timeIntervalSince1970: 100))
        #expect(shortCapture.timeline.map(\.totals.packets) == [1, 0, 1])
        // Only the charts pad a short capture, so automation output keeps the real time range.
        let padded = CaptureOverviewTimelinePresentation.padded(shortCapture.timeline, interval: 1)
        #expect(padded.count == CaptureOverviewTimelinePresentation.minimumSlotCount)
        #expect(padded.last?.date == Date(timeIntervalSince1970: 111))

        let longCapture = replacementSnapshot((0..<200).map { index in
            makePacket(id: UInt64(index + 1), timestamp: Date(timeIntervalSince1970: TimeInterval(index * 10)))
        })
        #expect(longCapture.timelineInterval == 60)
        #expect(longCapture.timeline.count <= CaptureOverviewAccumulator.maximumRenderedTimelinePointCount)
        #expect(longCapture.timeline.reduce(0) { $0 + $1.totals.packets } == 200)
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk((0..<200).map { index in
            makePacket(id: UInt64(index + 1), timestamp: Date(timeIntervalSince1970: TimeInterval(index * 10)))
        })
        let automationSnapshot = accumulator.snapshot(maximumTimelinePointCount: 240)
        #expect(automationSnapshot.timelineInterval == 10)
        #expect(automationSnapshot.timeline.count == 200)

        #expect(CaptureOverviewAccumulator.renderedTimelineWidth(span: 30, storageWidth: 1) == 1)
        #expect(CaptureOverviewAccumulator.renderedTimelineWidth(span: 200, storageWidth: 1) == 5)
        // A 2 s storage width can't render 5 s slots, so the next multiple, 10 s, is used.
        #expect(CaptureOverviewAccumulator.renderedTimelineWidth(span: 200, storageWidth: 2) == 10)
    }

    @Test func protocolChartHoverSelectsOnlyDonutSegments() {
        let rows = [
            makeProtocolRow(id: "tcp", fraction: 0.25),
            makeProtocolRow(id: "tls", fraction: 0.5),
            makeProtocolRow(id: "dns", fraction: 0.25),
        ]
        let size = CGSize(width: 100, height: 100)

        #expect(CaptureOverviewChartHoverSelection.protocolRow(
            at: CGPoint(x: 50, y: 0),
            in: size,
            innerRadiusRatio: 0.67,
            rows: rows
        )?.id == "tcp")
        #expect(CaptureOverviewChartHoverSelection.protocolRow(
            at: CGPoint(x: 90, y: 70),
            in: size,
            innerRadiusRatio: 0.67,
            rows: rows
        )?.id == "tls")
        #expect(CaptureOverviewChartHoverSelection.protocolRow(
            at: CGPoint(x: 30, y: 10),
            in: size,
            innerRadiusRatio: 0.67,
            rows: rows
        )?.id == "dns")
        #expect(CaptureOverviewChartHoverSelection.protocolRow(
            at: CGPoint(x: 50, y: 50),
            in: size,
            innerRadiusRatio: 0.67,
            rows: rows
        ) == nil)
    }

    @MainActor
    @Test func livePublishingIsThrottledToOneSnapshotPerInterval() async throws {
        var state = PacketIngestState.empty
        state.append([makePacket(id: 1)], source: .live)
        let service = CaptureOverviewService(latestIngestStateProvider: { state })
        var snapshots: [CaptureOverviewSnapshot] = []
        service.snapshotHandler = { snapshots.append($0) }
        service.consume(state)
        try await waitUntil { snapshots.count == 1 }

        for id in 2...24 {
            state.append([makePacket(id: UInt64(id))], source: .live)
            service.consume(state)
        }
        try await waitUntil(timeout: 2) { snapshots.last?.totals.packets == 24 }

        #expect(snapshots.count == 2)
        service.cancel()
    }

    @MainActor
    @Test func backingIdentityChangeRebuildsEvenWhenTheCursorValuesMatch() async throws {
        var state = PacketIngestState.empty
        state.backingIdentity = "capture-a"
        state.append([makePacket(id: 1, domain: "old.example")], source: .live)
        let service = CaptureOverviewService(latestIngestStateProvider: { state })
        var latestSnapshot = CaptureOverviewSnapshot.empty
        service.snapshotHandler = { latestSnapshot = $0 }
        service.consume(state)
        try await waitUntil { latestSnapshot.topDestinations.first?.title == "old.example" }

        var replacement = PacketIngestState.empty
        replacement.backingIdentity = "capture-b"
        replacement.append([makePacket(id: 2, domain: "new.example")], source: .live)
        #expect(replacement.packetRevision == state.packetRevision)
        #expect(replacement.packetLineageRevision == state.packetLineageRevision)
        state = replacement
        service.consume(state)
        try await waitUntil(timeout: 2) { latestSnapshot.topDestinations.first?.title == "new.example" }

        #expect(latestSnapshot.totals.packets == 1)
        service.cancel()
    }

    private func replacementSnapshot(_ packets: [PacketSummary]) -> CaptureOverviewSnapshot {
        var accumulator = CaptureOverviewAccumulator()
        accumulator.appendReplacementChunk(packets)
        let didFinish = accumulator.finishReplacement(cursor: cursor(revision: 1, count: packets.count))
        #expect(didFinish)
        return accumulator.snapshot()
    }

    private func cursor(revision: UInt64, lineage: UInt64 = 1, count: Int) -> EndpointStatisticsIngestCursor {
        EndpointStatisticsIngestCursor(
            packetRevision: revision,
            packetLineageRevision: lineage,
            totalPacketCount: count
        )
    }

    private func makePacket(
        id: UInt64,
        length: Int = 128,
        timestamp: Date? = nil,
        direction: PacketDirection? = .outbound,
        domain: String? = nil,
        client: PacketClient? = nil,
        transportHint: TransportProtocolHint = .tcp,
        info: String? = nil,
        tcpFlags: String? = nil,
        sourceAddress: String = "10.0.0.2",
        sourcePort: UInt16 = 51_000,
        destinationAddress: String = "93.184.216.34",
        destinationPort: UInt16 = 443,
        followStreamID: FollowStreamID? = nil,
        decodeStatus: PacketDecodeStatus = PacketDecodeStatus(kind: .complete)
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: id,
            timestamp: timestamp ?? Date(timeIntervalSince1970: TimeInterval(id)),
            source: .live,
            interfaceID: "en0",
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: sourcePort),
                destination: PacketEndpoint(address: destinationAddress, port: destinationPort)
            ),
            originalLength: length,
            capturedLength: min(length, 64),
            followStreamID: followStreamID,
            direction: direction,
            tcpFlags: tcpFlags,
            infoSummary: info ?? "Packet \(id)",
            layers: [PacketLayer(name: transportHint.rawValue.uppercased())],
            decodeStatus: decodeStatus,
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: domain,
            client: client
        )
    }

    private func makeClient(name: String, bundleIdentifier: String) -> PacketClient {
        PacketClient(
            pid: 123,
            name: name,
            displayName: name,
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            bundleIdentifier: bundleIdentifier,
            bundlePath: "/Applications/\(name).app"
        )
    }

    private func makeProtocolRow(id: String, fraction: Double) -> CaptureOverviewProtocolPresentation {
        CaptureOverviewProtocolPresentation(
            id: id,
            title: id.uppercased(),
            totalText: "1 KB",
            percentageText: "25%",
            fraction: fraction,
            colorIndex: 0
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}
