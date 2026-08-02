//
//  PacketMetadataDNSAttributionTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/8/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketMetadataDNSAttributionTests {

    @Test func attributesLaterOutboundPacketFromDNSResponse() throws {
        let service = makeService()
        let result = service.enrich([
            dnsPacket(domain: "spotify.com", address: "35.186.224.34", ttl: 60),
            flowPacket(number: 2, destination: "35.186.224.34", direction: .outbound),
        ], source: .offline)

        #expect(result.packets[1].dnsDomainName == "spotify.com")
        #expect(result.packets[1].domainName == "spotify.com")
        #expect(result.packets[1].domainSource == .dns)
    }

    @Test func attributesLaterInboundPacketFromDNSResponse() throws {
        let service = makeService()
        let result = service.enrich([
            dnsPacket(domain: "edge.example", address: "203.0.113.9", ttl: 60),
            flowPacket(
                number: 2,
                source: "203.0.113.9",
                destination: "192.168.1.5",
                direction: .inbound
            ),
        ], source: .offline)

        #expect(result.packets[1].dnsDomainName == "edge.example")
    }

    @Test func attributesCanonicalIPv6Endpoint() throws {
        let service = makeService()
        let result = service.enrich([
            dnsPacket(domain: "ipv6.example", address: "2001:db8::8", ttl: 60),
            flowPacket(number: 2, destination: "2001:0db8:0:0:0:0:0:8", direction: .outbound),
        ], source: .offline)

        #expect(result.packets[1].dnsDomainName == "ipv6.example")
    }

    @Test func keepsSNIAsHigherPriorityThanDNS() throws {
        let service = makeService()
        let result = service.enrich([
            dnsPacket(domain: "dns.example", address: "192.0.2.10", ttl: 60),
            flowPacket(
                number: 2,
                destination: "192.0.2.10",
                direction: .outbound,
                sniDomainName: "sni.example"
            ),
        ], source: .offline)

        #expect(result.packets[1].sniDomainName == "sni.example")
        #expect(result.packets[1].domainName == "sni.example")
        #expect(result.packets[1].domainSource == .sni)
    }

    @Test func laterSNIBackfillsDNSAttributedFlow() throws {
        let service = makeService()
        let dns = dnsPacket(domain: "dns.example", address: "192.0.2.11", ttl: 60)
        let first = flowPacket(
            number: 2,
            destination: "192.0.2.11",
            streamID: 77,
            direction: .outbound
        )
        let clientHello = flowPacket(
            number: 3,
            destination: "192.0.2.11",
            streamID: 77,
            direction: .outbound,
            sniDomainName: "sni.example"
        )

        _ = service.enrich([dns, first], source: .offline)
        let result = service.enrich([clientHello], source: .offline)

        #expect(result.packets.first?.domainName == "sni.example")
        #expect(result.updates.first?.packetIDs == [first.id])
        #expect(result.updates.first?.sniDomainName == "sni.example")
    }

    @Test func doesNotAttributeExpiredDNSObservation() throws {
        let service = makeService()
        let result = service.enrich([
            dnsPacket(domain: "expired.example", address: "192.0.2.12", ttl: 1, timestamp: 10),
            flowPacket(number: 2, destination: "192.0.2.12", direction: .outbound, timestamp: 11),
        ], source: .offline)

        #expect(result.packets[1].domainName == nil)
    }

    @Test func resetClearsDNSObservations() throws {
        let service = makeService()
        _ = service.enrich([
            dnsPacket(domain: "reset.example", address: "192.0.2.13", ttl: 60),
        ], source: .offline)

        service.reset()
        let result = service.enrich([
            flowPacket(number: 2, destination: "192.0.2.13", direction: .outbound),
        ], source: .offline)

        #expect(result.packets.first?.domainName == nil)
    }

    @Test func leavesPacketUnattributedWhenBothUnknownEndpointsMatch() throws {
        let service = makeService()
        let result = service.enrich([
            dnsPacket(domain: "source.example", address: "192.0.2.20", ttl: 60),
            dnsPacket(number: 2, domain: "destination.example", address: "192.0.2.21", ttl: 60),
            flowPacket(number: 3, source: "192.0.2.20", destination: "192.0.2.21", direction: nil),
        ], source: .offline)

        #expect(result.packets[2].domainName == nil)
    }

    @Test func skipsAttributionOnDNSPacketItself() throws {
        let service = makeService()
        let first = dnsPacket(domain: "resolver.example", address: "8.8.8.8", ttl: 60)
        let second = dnsPacket(number: 2, domain: "other.example", address: "192.0.2.30", ttl: 60)

        let result = service.enrich([first, second], source: .offline)

        #expect(result.packets.allSatisfy { $0.dnsDomainName == nil })
    }

    @Test func leavesDoTAndDoHTrafficUnattributedWithoutPlaintextEvidence() throws {
        let service = makeService()
        let dot = flowPacket(number: 1, destination: "1.1.1.1", destinationPort: 853, direction: .outbound)
        let doh = flowPacket(number: 2, destination: "1.1.1.1", destinationPort: 443, direction: .outbound)

        let result = service.enrich([dot, doh], source: .offline)

        #expect(result.packets.allSatisfy { $0.domainName == nil })
    }

    private func makeService() -> PacketMetadataEnrichmentService {
        PacketMetadataEnrichmentService(
            dnsResolutionCache: DNSResolutionCache(maximumRetention: 3_600),
            clientResolver: DNSAttributionClientResolver()
        )
    }

    private func dnsPacket(
        number: UInt64 = 1,
        domain: String,
        address: String,
        ttl: UInt32,
        timestamp: TimeInterval = 0
    ) -> PacketSummary {
        packet(
            number: number,
            timestamp: timestamp,
            transportHint: .dns,
            source: "8.8.8.8",
            sourcePort: 53,
            destination: "192.168.1.5",
            destinationPort: 53_000,
            dnsResolutions: [DNSResolutionObservation(domainName: domain, ipAddress: address, timeToLive: ttl)]
        )
    }

    private func flowPacket(
        number: UInt64,
        source: String = "192.168.1.5",
        destination: String,
        destinationPort: UInt16 = 443,
        streamID: UInt32? = nil,
        direction: PacketDirection?,
        sniDomainName: String? = nil,
        timestamp: TimeInterval = 1
    ) -> PacketSummary {
        packet(
            number: number,
            timestamp: timestamp,
            transportHint: .tls,
            source: source,
            sourcePort: 52_000,
            destination: destination,
            destinationPort: destinationPort,
            streamID: streamID,
            direction: direction,
            sniDomainName: sniDomainName
        )
    }

    private func packet(
        number: UInt64,
        timestamp: TimeInterval,
        transportHint: TransportProtocolHint,
        source: String,
        sourcePort: UInt16,
        destination: String,
        destinationPort: UInt16,
        streamID: UInt32? = nil,
        direction: PacketDirection? = nil,
        sniDomainName: String? = nil,
        dnsResolutions: [DNSResolutionObservation]? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: number,
            timestamp: Date(timeIntervalSince1970: timestamp),
            source: .offline,
            transportHint: transportHint,
            protocolSummary: transportHint.rawValue.uppercased(),
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: source, port: sourcePort),
                destination: PacketEndpoint(address: destination, port: destinationPort)
            ),
            originalLength: 100,
            capturedLength: 100,
            streamID: streamID,
            direction: direction,
            infoSummary: "Fixture",
            layers: [],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: sniDomainName,
            dnsResolutions: dnsResolutions
        )
    }
}

private final class DNSAttributionClientResolver: PacketClientResolving {
    func reset() {}
    func client(for packet: PacketSummary) -> PacketClient? { nil }
}
