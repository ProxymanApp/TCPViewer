//
//  EndpointStatisticsServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct EndpointStatisticsServiceTests {
    @Test func endpointRowsUseOriginalLengthAndEndpointRelativeDirection() throws {
        let packet = makePacket(
            id: 1,
            transportHint: .tls,
            layerNames: ["Ethernet", "IPv4", "TCP"],
            direction: .outbound,
            originalLength: 400,
            capturedLength: 80,
            sourceAddress: "10.0.0.2",
            sourcePort: 51_000,
            destinationAddress: "93.184.216.34",
            destinationPort: 443
        )

        let snapshot = EndpointStatisticsService().rebuild(from: [packet])
        let sourceIP = try row(in: snapshot, group: .ipv4, key: "10.0.0.2")
        let destinationIP = try row(in: snapshot, group: .ipv4, key: "93.184.216.34")
        let sourceTCP = try row(in: snapshot, group: .tcp, key: "10.0.0.2:51000")
        let destinationTCP = try row(in: snapshot, group: .tcp, key: "93.184.216.34:443")

        #expect(sourceIP.packets == 1)
        #expect(sourceIP.bytes == 400)
        #expect(sourceIP.txPackets == 1)
        #expect(sourceIP.txBytes == 400)
        #expect(sourceIP.rxPackets == 0)
        #expect(sourceIP.port == "51000")
        #expect(sourceIP.protocolName == "TLS")
        #expect(destinationIP.rxPackets == 1)
        #expect(destinationIP.rxBytes == 400)
        #expect(sourceTCP.txPackets == 1)
        #expect(sourceTCP.port == "51000")
        #expect(destinationTCP.rxPackets == 1)
        #expect(destinationTCP.port == "443")
        #expect(snapshot.footerTotals.bytes == 400)
        #expect(EndpointStatisticsRowID(group: .tcp, key: "93.184.216.34:443").matches(packet))
    }

    @Test func appAndDomainRowsUseOppositeDirectionalSemantics() throws {
        let client = makeClient(displayName: "Example Browser", bundleIdentifier: "com.example.browser")
        let packets = [
            makePacket(id: 1, direction: .outbound, originalLength: 200, domain: "Example.COM.", client: client),
            makePacket(
                id: 2,
                direction: .inbound,
                originalLength: 100,
                sourceAddress: "93.184.216.34",
                sourcePort: 443,
                destinationAddress: "10.0.0.2",
                destinationPort: 51_000,
                domain: "example.com",
                client: client
            ),
            makePacket(id: 3, direction: .unknown, originalLength: 50, domain: "EXAMPLE.COM", client: client),
        ]

        let snapshot = EndpointStatisticsService().rebuild(from: packets)
        let app = try row(
            in: snapshot,
            group: .apps,
            key: "bundleIdentifier:com.example.browser"
        )
        let domain = try row(in: snapshot, group: .domains, key: "example.com")

        #expect(snapshot.endpointCount(for: .apps) == 1)
        #expect(snapshot.endpointCount(for: .domains) == 1)
        #expect(app.client == "Example Browser")
        #expect(app.packets == 3)
        #expect(app.bytes == 350)
        #expect(app.txPackets == 1)
        #expect(app.txBytes == 200)
        #expect(app.rxPackets == 1)
        #expect(app.rxBytes == 100)
        #expect(app.unclassifiedPackets == 1)
        #expect(app.unclassifiedBytes == 50)
        #expect(app.summary == "Tx 57% · Rx 29% · Unclassified 14%")
        #expect(domain.txBytes == 100)
        #expect(domain.rxBytes == 200)
        #expect(domain.unclassifiedBytes == 50)
        #expect(snapshot.footerTotals == app.totals)
    }

    @Test func summaryPercentagesDoNotOverflowAtUInt64Limits() {
        let totals = EndpointStatisticsTotals(
            packets: 3,
            bytes: .max,
            txPackets: 1,
            txBytes: .max,
            rxPackets: 1,
            rxBytes: .max,
            unclassifiedPackets: 1,
            unclassifiedBytes: .max
        )

        #expect(totals.summary == "Tx 33% · Rx 33% · Unclassified 33%")
    }

    @Test func canonicalDomainsAndIPv6AddressesMergeEquivalentRows() throws {
        let packets = [
            makePacket(
                id: 1,
                sourceAddress: "2001:0db8:0:0:0:0:0:1",
                destinationAddress: "2001:db8::2",
                domain: " API.Example.COM. "
            ),
            makePacket(
                id: 2,
                sourceAddress: "[2001:db8::1]",
                destinationAddress: "2001:0DB8:0:0:0:0:0:2",
                domain: "api.example.com"
            ),
        ]

        let snapshot = EndpointStatisticsService().rebuild(from: packets)
        let source = try row(in: snapshot, group: .ipv6, key: "2001:db8::1")
        let domain = try row(in: snapshot, group: .domains, key: "api.example.com")

        #expect(snapshot.endpointCount(for: .ipv6) == 2)
        #expect(snapshot.endpointCount(for: .domains) == 1)
        #expect(source.packets == 2)
        #expect(domain.packets == 2)
        #expect(EndpointStatisticsRowID(group: .tcp, key: "[2001:db8::1]:51000").matches(packets[0]))
    }

    @Test func relatedFieldsChangeBetweenOneValueAndMultipleAfterBackfill() throws {
        let client = makeClient(displayName: "Browser", bundleIdentifier: "com.example.browser")
        var state = PacketIngestState.empty
        state.append([
            makePacket(id: 1, domain: "one.example", client: client),
            makePacket(id: 2, domain: "two.example", client: client),
        ], source: .live)
        let service = EndpointStatisticsService()

        var snapshot = service.snapshot(for: state)
        var app = try row(in: snapshot, group: .apps, key: "bundleIdentifier:com.example.browser")
        #expect(app.domain == EndpointStatisticsRow.multipleValue)
        #expect(app.isDomainMultiple)

        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [2],
                sniDomainName: "one.example",
                client: client,
                direction: .outbound
            ),
        ])
        snapshot = service.snapshot(for: state)
        app = try row(in: snapshot, group: .apps, key: "bundleIdentifier:com.example.browser")

        #expect(app.domain == "one.example")
        #expect(!app.isDomainMultiple)
        #expect(snapshot.endpointCount(for: .domains) == 1)
        #expect(try row(in: snapshot, group: .domains, key: "one.example").packets == 2)
        #expect(service.debugSnapshot().metadataPacketCount == 1)
    }

    @Test func literalMultipleClientNameIsNotMarkedAsAnAggregatePlaceholder() throws {
        let client = makeClient(displayName: EndpointStatisticsRow.multipleValue, bundleIdentifier: "com.example.multiple")
        let snapshot = EndpointStatisticsService().rebuild(from: [makePacket(id: 1, client: client)])
        let app = try row(in: snapshot, group: .apps, key: "bundleIdentifier:com.example.multiple")

        #expect(app.client == EndpointStatisticsRow.multipleValue)
        #expect(!app.isClientMultiple)
    }

    @Test func appDisplayNameUpdatesWhenMetadataImprovesForTheSameStableKey() throws {
        let originalClient = makeClient(displayName: "Helper", bundleIdentifier: "com.example.browser")
        let improvedClient = makeClient(displayName: "Example Browser", bundleIdentifier: "com.example.browser")
        var state = PacketIngestState.empty
        state.append([makePacket(id: 1, client: originalClient)], source: .live)
        let service = EndpointStatisticsService()

        _ = service.snapshot(for: state)
        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [1],
                sniDomainName: nil,
                client: improvedClient,
                direction: .outbound
            ),
        ])
        let snapshot = service.snapshot(for: state)
        let app = try row(in: snapshot, group: .apps, key: "bundleIdentifier:com.example.browser")

        #expect(app.client == "Example Browser")
        #expect(app.packets == 1)
    }

    @Test func layerNamesClassifyApplicationHintsIntoTCPAndUDP() {
        let packets = [
            makePacket(id: 1, transportHint: .tls, layerNames: ["Ethernet", "IPv4", "TCP"]),
            makePacket(id: 2, transportHint: .dns, layerNames: ["Ethernet", "IPv4", "UDP"]),
            makePacket(id: 3, transportHint: .dns, layerNames: ["Ethernet", "IPv4"]),
        ]

        let snapshot = EndpointStatisticsService().rebuild(from: packets)

        #expect(snapshot.endpointCount(for: .tcp) == 2)
        #expect(snapshot.endpointCount(for: .udp) == 2)
        #expect(snapshot.rows(for: .tcp).allSatisfy { $0.protocolName == "TLS" })
        #expect(snapshot.rows(for: .udp).allSatisfy { $0.protocolName == "DNS" })
    }

    @Test func sameSourceAndDestinationCountsBothEndpointOccurrences() throws {
        let packet = makePacket(
            id: 1,
            originalLength: 64,
            sourceAddress: "127.0.0.1",
            sourcePort: 8_080,
            destinationAddress: "127.0.0.1",
            destinationPort: 8_080
        )

        let snapshot = EndpointStatisticsService().rebuild(from: [packet])
        let ip = try row(in: snapshot, group: .ipv4, key: "127.0.0.1")
        let tcp = try row(in: snapshot, group: .tcp, key: "127.0.0.1:8080")

        for endpoint in [ip, tcp] {
            #expect(endpoint.packets == 2)
            #expect(endpoint.bytes == 128)
            #expect(endpoint.txPackets == 1)
            #expect(endpoint.txBytes == 64)
            #expect(endpoint.rxPackets == 1)
            #expect(endpoint.rxBytes == 64)
            #expect(endpoint.summary == "Tx 50% · Rx 50%")
        }
    }

    @Test func missingAddressAndPortSkipOnlyUnavailableEndpointRows() {
        let missingSourceAddress = makePacket(
            id: 1,
            sourceAddress: nil,
            sourcePort: 51_000,
            destinationAddress: "93.184.216.34",
            destinationPort: 443
        )
        let missingDestinationPort = makePacket(
            id: 2,
            sourceAddress: "10.0.0.2",
            sourcePort: 51_000,
            destinationAddress: "93.184.216.34",
            destinationPort: nil
        )

        let snapshot = EndpointStatisticsService().rebuild(from: [missingSourceAddress, missingDestinationPort])

        #expect(snapshot.endpointCount(for: .ipv4) == 2)
        #expect(snapshot.endpointCount(for: .tcp) == 2)
        #expect(snapshot.rows(for: .tcp).contains { $0.id.key == "93.184.216.34:443" })
        #expect(snapshot.rows(for: .tcp).contains { $0.id.key == "10.0.0.2:51000" })
    }

    @Test func invalidInboundSourceDoesNotUseTheLocalDestinationAsRemoteAddress() throws {
        let client = makeClient(displayName: "Browser", bundleIdentifier: "com.example.browser")
        let packet = makePacket(
            id: 1,
            direction: .inbound,
            sourceAddress: "not-an-ip",
            sourcePort: 443,
            destinationAddress: "10.0.0.2",
            destinationPort: 51_000,
            domain: "example.com",
            client: client
        )

        let snapshot = EndpointStatisticsService().rebuild(from: [packet])
        let app = try row(in: snapshot, group: .apps, key: "bundleIdentifier:com.example.browser")
        let domain = try row(in: snapshot, group: .domains, key: "example.com")
        let localIP = try row(in: snapshot, group: .ipv4, key: "10.0.0.2")

        #expect(app.address == nil)
        #expect(app.port == nil)
        #expect(domain.address == nil)
        #expect(domain.port == nil)
        #expect(localIP.rxPackets == 1)
    }

    @Test func ingestMutationsAppendAndReclassifyOnlyAffectedPackets() throws {
        let client = makeClient(displayName: "Browser", bundleIdentifier: "com.example.browser")
        var state = PacketIngestState.empty
        state.append([makePacket(id: 1, direction: nil)], source: .live)
        let service = EndpointStatisticsService()

        _ = service.snapshot(for: state)
        state.appendAndApplyMetadataUpdates(
            [makePacket(id: 2, direction: .inbound)],
            metadataUpdates: [
                PacketMetadataUpdate(
                    packetIDs: [1],
                    sniDomainName: "example.com",
                    client: client,
                    direction: .outbound
                ),
            ],
            source: .live
        )
        let snapshot = service.snapshot(for: state)
        _ = service.snapshot(for: state)
        let debug = service.debugSnapshot()

        #expect(debug.fullRebuildCount == 1)
        #expect(debug.processedPacketCount == 2)
        #expect(debug.appendedPacketCount == 1)
        #expect(debug.metadataPacketCount == 1)
        #expect(debug.unchangedSnapshotCount == 1)
        #expect(snapshot.footerTotals.txPackets == 1)
        #expect(snapshot.footerTotals.rxPackets == 1)
        #expect(snapshot.footerTotals.unclassifiedPackets == 0)
        #expect(try row(in: snapshot, group: .apps, key: "bundleIdentifier:com.example.browser").packets == 1)
    }

    @Test func lineageReplacementClearsRowsFromThePreviousCapture() {
        var state = PacketIngestState.empty
        state.append([makePacket(id: 1, domain: "old.example")], source: .live)
        let service = EndpointStatisticsService()
        _ = service.snapshot(for: state)

        state.reset(source: .live, message: "Cleared")
        let emptySnapshot = service.snapshot(for: state)

        #expect(emptySnapshot.footerTotals == .zero)
        #expect(EndpointStatisticsGroup.allCases.allSatisfy { emptySnapshot.rows(for: $0).isEmpty })
        #expect(service.debugSnapshot().fullRebuildCount == 2)
    }

    @Test func slimIngestUpdatesCarryOnlyChangedPacketsAndRejectRevisionGaps() {
        var state = PacketIngestState.empty
        state.append([makePacket(id: 1)], source: .live)
        let service = EndpointStatisticsService()
        let initial = EndpointStatisticsIngestUpdate(ingestState: state, previousCursor: nil)

        guard case .replace(let initialPackets) = initial.kind else {
            Issue.record("Expected an initial replacement update.")
            return
        }
        #expect(initialPackets.count == 1)
        #expect(service.consume(initial))

        state.append([makePacket(id: 2)], source: .live)
        let append = EndpointStatisticsIngestUpdate(ingestState: state, previousCursor: initial.cursor)
        guard case .append(let appendedPackets) = append.kind else {
            Issue.record("Expected a slim append update.")
            return
        }
        #expect(appendedPackets.map(\.id) == [2])
        #expect(service.consume(append))

        state.append([makePacket(id: 3)], source: .live)
        let recovery = EndpointStatisticsIngestUpdate(ingestState: state, previousCursor: initial.cursor)
        guard case .replace(let recoveryPackets) = recovery.kind else {
            Issue.record("Expected a replacement after a skipped revision.")
            return
        }
        #expect(recoveryPackets.count == 3)
        #expect(service.consume(recovery))

        let skippedRevision = EndpointStatisticsIngestUpdate(
            packetRevision: recovery.packetRevision + 2,
            packetLineageRevision: recovery.packetLineageRevision,
            totalPacketCount: recovery.totalPacketCount,
            kind: .metadata([])
        )
        #expect(!service.consume(skippedRevision))
        #expect(service.currentSnapshot().footerTotals.packets == 3)
    }

    @Test func oneHundredThousandPacketBaselineKeepsAppendWorkBounded() {
        let baseline = (1...100_000).map { makePacket(id: UInt64($0), layerNames: []) }
        var state = PacketIngestState.empty
        state.append(baseline, source: .live)
        let service = EndpointStatisticsService()

        _ = service.snapshot(for: state)
        let appended = (100_001...100_128).map { makePacket(id: UInt64($0), layerNames: []) }
        state.append(appended, source: .live)
        let snapshot = service.snapshot(for: state)
        _ = service.snapshot(for: state)
        let debug = service.debugSnapshot()

        #expect(debug.fullRebuildCount == 1)
        #expect(debug.processedPacketCount == 100_128)
        #expect(debug.appendedPacketCount == 128)
        #expect(debug.metadataPacketCount == 0)
        #expect(debug.unchangedSnapshotCount == 1)
        #expect(snapshot.footerTotals.packets == 100_128)
        #expect(snapshot.endpointCount(for: .ipv4) == 2)
        #expect(snapshot.endpointCount(for: .tcp) == 2)
    }

    @Test func selectedGroupSnapshotDoesNotMaterializeHighCardinalityTransportRows() {
        let client = makeClient(displayName: "Browser", bundleIdentifier: "com.example.browser")
        let packets = (1...10_000).map { value in
            makePacket(
                id: UInt64(value),
                destinationPort: UInt16(value + 1_000),
                client: client
            )
        }
        let service = EndpointStatisticsService()
        let update = EndpointStatisticsIngestUpdate(
            packetRevision: 1,
            packetLineageRevision: 1,
            totalPacketCount: packets.count,
            kind: .replace(packets)
        )

        #expect(service.consume(update))
        let snapshot = service.currentSnapshot(for: .apps)
        let firstDebug = service.debugSnapshot()
        _ = service.currentSnapshot(for: .apps)
        let secondDebug = service.debugSnapshot()

        #expect(snapshot.rows.count == 1)
        #expect(snapshot.endpointCount(for: .apps) == 1)
        #expect(snapshot.endpointCount(for: .tcp) == 10_001)
        #expect(firstDebug.rowMaterializationCountByGroup == [.apps: 1])
        #expect(firstDebug.materializedRowCount == 1)
        #expect(secondDebug.rowMaterializationCountByGroup == firstDebug.rowMaterializationCountByGroup)
        #expect(secondDebug.materializedRowCount == firstDebug.materializedRowCount)
    }

    @Test func cancellationStopsAndDiscardsAPartialLargeReplacement() {
        let packets = (1...10_000).map { makePacket(id: UInt64($0), layerNames: []) }
        let update = EndpointStatisticsIngestUpdate(
            packetRevision: 1,
            packetLineageRevision: 1,
            totalPacketCount: packets.count,
            kind: .replace(packets)
        )
        let cancellationToken = EndpointStatisticsCancellationToken(cancelAfterCheckCount: 2)
        let service = EndpointStatisticsService()

        let result = service.consume(update, cancellationToken: cancellationToken)
        let snapshot = service.currentSnapshot(for: .ipv4)

        #expect(result == .cancelled)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.footerTotals == .zero)
        #expect(service.debugSnapshot().processedPacketCount == 0)
    }

    @Test func cancellationDoesNotCachePartiallyMaterializedRows() {
        let packets = (1...10_000).map { value in
            makePacket(id: UInt64(value), destinationPort: UInt16(value + 1_000))
        }
        let update = EndpointStatisticsIngestUpdate(
            packetRevision: 1,
            packetLineageRevision: 1,
            totalPacketCount: packets.count,
            kind: .replace(packets)
        )
        let service = EndpointStatisticsService()
        #expect(service.consume(update))
        let cancellationToken = EndpointStatisticsCancellationToken(cancelAfterCheckCount: 2)

        let cancelledSnapshot = service.currentSnapshot(for: .tcp, cancellationToken: cancellationToken)
        let cancelledDebug = service.debugSnapshot()
        let completeSnapshot = service.currentSnapshot(for: .tcp)

        #expect(cancelledSnapshot == nil)
        #expect(cancelledDebug.rowMaterializationCountByGroup[.tcp] == nil)
        #expect(cancelledDebug.materializedRowCount == 0)
        #expect(completeSnapshot.rows.count == 10_001)
    }

    private func row(
        in snapshot: EndpointStatisticsSnapshot,
        group: EndpointStatisticsGroup,
        key: String
    ) throws -> EndpointStatisticsRow {
        try #require(snapshot.rows(for: group).first { $0.id.key == key })
    }

    private func makePacket(
        id: UInt64,
        transportHint: TransportProtocolHint = .tcp,
        layerNames: [String] = ["Ethernet", "IPv4", "TCP"],
        direction: PacketDirection? = .outbound,
        originalLength: Int = 128,
        capturedLength: Int? = nil,
        sourceAddress: String? = "10.0.0.2",
        sourcePort: UInt16? = 51_000,
        destinationAddress: String? = "93.184.216.34",
        destinationPort: UInt16? = 443,
        domain: String? = nil,
        client: PacketClient? = nil
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
            source: .live,
            interfaceID: "en0",
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: sourcePort),
                destination: PacketEndpoint(address: destinationAddress, port: destinationPort)
            ),
            originalLength: originalLength,
            capturedLength: capturedLength ?? originalLength,
            direction: direction,
            infoSummary: "Packet \(id)",
            layers: layerNames.map { PacketLayer(name: $0) },
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: domain,
            client: client
        )
    }

    private func makeClient(displayName: String, bundleIdentifier: String) -> PacketClient {
        PacketClient(
            pid: 123,
            name: displayName,
            displayName: displayName,
            executablePath: "/Applications/\(displayName).app/Contents/MacOS/\(displayName)",
            bundleIdentifier: bundleIdentifier,
            bundlePath: "/Applications/\(displayName).app"
        )
    }
}
