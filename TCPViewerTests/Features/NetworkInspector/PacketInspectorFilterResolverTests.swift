//
//  PacketInspectorFilterResolverTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketInspectorFilterResolverTests {
    @Test func exactDisplayFilterExpressionIsPreferredAndRetainsNativeFallback() throws {
        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: "  tls.handshake.extensions_server_name == \"api.example.com\"  ",
            fieldName: "tls.handshake.extensions_server_name",
            value: "api.example.com",
            rawValue: nil
        ))
        let nativeFilter = try #require(request.nativeFilter)

        #expect(request.displayFilterExpression == "tls.handshake.extensions_server_name == \"api.example.com\"")
        #expect(nativeFilter.query == .urlDomain)
        #expect(nativeFilter.condition == .matchesRegex)
        #expect(nativeFilter.text == "^api\\.example\\.com$")
        let service = PacketStructuredFilterService()
        #expect(service.matches(makePacket(sniDomainName: "api.example.com"), filter: nativeFilter))
        #expect(!service.matches(makePacket(sniDomainName: "other.example.com"), filter: nativeFilter))
    }

    @Test func displayFilterExpressionKeepsOtherwiseUnknownRowsFilterable() throws {
        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: "tls.handshake.ciphersuite == 0x1301",
            fieldName: "tls.handshake.ciphersuite",
            value: "TLS_AES_128_GCM_SHA256 (0x1301)",
            rawValue: "13 01"
        ))

        #expect(request.displayFilterExpression == "tls.handshake.ciphersuite == 0x1301")
        #expect(request.nativeFilter == nil)
    }

    @Test func nativeEndpointAndPortFallbacksMatchOnlyTheSelectedSummaryValue() throws {
        let sourceRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "ip.src",
            value: "10.0.0.1",
            rawValue: "0a 00 00 01"
        ))
        let portRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.dstport",
            value: "443",
            rawValue: "01 bb"
        ))
        let sourceFilter = try #require(sourceRequest.nativeFilter)
        let portFilter = try #require(portRequest.nativeFilter)
        let service = PacketStructuredFilterService()

        #expect(sourceRequest.displayFilterExpression == nil)
        #expect(sourceFilter.query == .source)
        #expect(service.matches(makePacket(sourceAddress: "10.0.0.1", destinationPort: 443), filter: sourceFilter))
        #expect(!service.matches(makePacket(sourceAddress: "10.0.0.10", destinationPort: 443), filter: sourceFilter))
        #expect(portFilter.query == .destinationPort)
        #expect(service.matches(makePacket(sourceAddress: "10.0.0.1", destinationPort: 443), filter: portFilter))
        #expect(!service.matches(makePacket(sourceAddress: "10.0.0.1", destinationPort: 1_443), filter: portFilter))
    }

    @Test func nativeLengthFallbackNormalizesDisplayedNumbersWhileWiresharkStreamsRequireWireshark() throws {
        let lengthRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "frame.cap_len",
            value: "1,024 bytes",
            rawValue: nil
        ))
        let streamRequest = PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.stream",
            value: "Stream 77",
            rawValue: nil
        )

        #expect(lengthRequest.nativeFilter?.query == .length)
        #expect(lengthRequest.nativeFilter?.text == "^1024$")
        #expect(streamRequest == nil)
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "udp.stream",
            value: "Stream 77",
            rawValue: nil
        ) == nil)

        let wiresharkStreamRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: "tcp.stream == 77",
            fieldName: "tcp.stream",
            value: "Stream 77",
            rawValue: nil
        ))
        #expect(wiresharkStreamRequest.displayFilterExpression == "tcp.stream == 77")
        #expect(wiresharkStreamRequest.nativeFilter == nil)
    }

    @Test func protocolAndHTTPSummaryRowsUseTheirNativePacketSummarySurfaces() throws {
        let protocolRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tls",
            value: "TLSv1.3 Record Layer",
            rawValue: nil
        ))
        let methodRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "http.request.method",
            value: "GET",
            rawValue: nil
        ))
        let service = PacketStructuredFilterService()
        let packet = makePacket(transportHint: .tls, protocolSummary: "TLS 1.3", infoSummary: "GET /v1/users HTTP/1.1")

        let protocolFilter = try #require(protocolRequest.nativeFilter)
        let methodFilter = try #require(methodRequest.nativeFilter)
        #expect(protocolFilter.query == .protocol)
        #expect(protocolFilter.condition == .matchesRegex)
        #expect(protocolFilter.text == "^TLS$")
        #expect(methodFilter.query == .summary)
        #expect(service.matches(packet, filter: protocolFilter))
        #expect(service.matches(packet, filter: methodFilter))
        #expect(!service.matches(makePacket(infoSummary: "POST /v1/users HTTP/1.1"), filter: methodFilter))

        let ipRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "ip",
            value: "Internet Protocol Version 4",
            rawValue: nil
        ))
        let ipFilter = try #require(ipRequest.nativeFilter)
        #expect(service.matches(makePacket(layerNames: ["Ethernet", "IPv4", "TCP"]), filter: ipFilter))
    }

    @Test func exactProtocolFallbackDoesNotConflateHTTPAndHTTP2() throws {
        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "http",
            value: "Hypertext Transfer Protocol",
            rawValue: nil
        ))
        let filter = try #require(request.nativeFilter)
        let service = PacketStructuredFilterService()

        #expect(filter.condition == .matchesRegex)
        #expect(filter.text == "^HTTP$")
        #expect(service.matches(makePacket(transportHint: .http1, protocolSummary: "HTTP"), filter: filter))
        #expect(!service.matches(makePacket(transportHint: .tcp, protocolSummary: "HTTP/2"), filter: filter))

        let http2Request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "http2",
            value: "Hypertext Transfer Protocol 2",
            rawValue: nil
        ))
        let http2Filter = try #require(http2Request.nativeFilter)
        #expect(http2Filter.text == "^HTTP2$")
        #expect(service.matches(makePacket(transportHint: .tcp, protocolSummary: "HTTP2"), filter: http2Filter))
        #expect(!service.matches(makePacket(transportHint: .http1, protocolSummary: "HTTP"), filter: http2Filter))
    }

    @Test func hostAndAuthorityRequireWiresharkWhileCapturedLengthUsesNativeFallback() throws {
        let hostRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: "http.host == \"api.example.com\"",
            fieldName: "http.host",
            value: "api.example.com",
            rawValue: nil
        ))
        let authorityRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: "http2.headers.authority == \"api.example.com\"",
            fieldName: "http2.headers.authority",
            value: "api.example.com",
            rawValue: nil
        ))
        let captureLengthRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "frame.cap_len",
            value: "1,024 bytes",
            rawValue: nil
        ))

        #expect(hostRequest.nativeFilter == nil)
        #expect(authorityRequest.nativeFilter == nil)
        #expect(captureLengthRequest.nativeFilter?.query == .length)
        #expect(captureLengthRequest.nativeFilter?.text == "^1024$")
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "frame.len",
            value: "1,024 bytes",
            rawValue: nil
        ) == nil)
    }

    @Test func syntheticSummaryFragmentsDoNotUseTheUnrelatedPacketSummary() {
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcpviewer.summary_fragment",
            value: "server.example.com",
            rawValue: nil
        ) == nil)
    }

    @Test func interfaceFallbackOnlyUsesValuesStoredByPacketSummary() throws {
        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "frame.interface_name",
            value: "Wi-Fi",
            rawValue: nil
        ))
        let filter = try #require(request.nativeFilter)
        let service = PacketStructuredFilterService()

        #expect(filter.query == .interface)
        #expect(service.matches(makePacket(interfaceName: "Wi-Fi"), filter: filter))
        #expect(!service.matches(makePacket(interfaceName: "Ethernet"), filter: filter))
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "frame.interface",
            value: "unknown",
            rawValue: nil
        ) == nil)
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "frame.interface_id",
            value: "0",
            rawValue: nil
        ) == nil)
    }

    @Test func dnsNamesRequireWiresharkBecausePacketSummaryHasNoExactNativeField() throws {
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "dns.qry.name",
            value: "api.example.com",
            rawValue: nil
        ) == nil)
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "dns.resp.name",
            value: "api.example.com",
            rawValue: nil
        ) == nil)

        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: "dns.qry.name == \"api.example.com\"",
            fieldName: "dns.qry.name",
            value: "api.example.com",
            rawValue: nil
        ))
        #expect(request.nativeFilter == nil)
    }

    @Test func decodeWarningRowsUseTheExactNativeDecodeReason() throws {
        let reason = "Unsupported IP protocol 253."
        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcpviewer.warning.unsupported",
            value: reason,
            rawValue: nil
        ))
        let filter = try #require(request.nativeFilter)
        let service = PacketStructuredFilterService()

        #expect(filter.query == .decodeStatus)
        #expect(filter.condition == .matchesRegex)
        #expect(service.matches(
            makePacket(decodeStatus: PacketDecodeStatus(kind: .unsupported, reason: reason)),
            filter: filter
        ))
        #expect(!service.matches(
            makePacket(decodeStatus: PacketDecodeStatus(kind: .malformed, reason: "Truncated IPv4 header.")),
            filter: filter
        ))
    }

    @Test func individualTCPFlagFallbackOnlyRepresentsSetRowsAccurately() throws {
        let setRequest = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.flags.syn",
            value: "Set",
            rawValue: nil
        ))
        let notSetRequest = PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.flags.ack",
            value: "Not set",
            rawValue: nil
        )
        let service = PacketStructuredFilterService()
        let packet = makePacket(tcpFlags: "SYN")

        let setFilter = try #require(setRequest.nativeFilter)
        #expect(setFilter.condition == .matchesRegex)
        #expect(service.matches(packet, filter: setFilter))
        #expect(notSetRequest == nil)

        for (fieldName, storedName) in [("tcp.flags.push", "PSH"), ("tcp.flags.reset", "RST")] {
            let request = try #require(PacketInspectorFilterResolver.resolve(
                displayFilterExpression: nil,
                fieldName: fieldName,
                value: "Set",
                rawValue: nil
            ))
            let filter = try #require(request.nativeFilter)
            #expect(service.matches(makePacket(tcpFlags: storedName), filter: filter))
        }
    }

    @Test func aggregateZeroTCPFlagsFallbackMatchesOnlyTCPPacketsWithoutSetFlags() throws {
        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.flags",
            value: "0x000 (<None>)",
            rawValue: nil
        ))
        let filter = try #require(request.nativeFilter)
        let service = PacketStructuredFilterService()

        #expect(filter.text == "^$")
        #expect(service.matches(makePacket(tcpFlags: ""), filter: filter))
        #expect(!service.matches(makePacket(tcpFlags: "SYN"), filter: filter))
        #expect(!service.matches(makePacket(tcpFlags: nil), filter: filter))
    }

    @Test func aggregateTCPFlagsFallbackAcceptsOnlyNamesStoredByPacketSummary() throws {
        let request = try #require(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.flags",
            value: "0x012 (SYN, ACK)",
            rawValue: nil
        ))
        let filter = try #require(request.nativeFilter)
        let service = PacketStructuredFilterService()

        #expect(service.matches(makePacket(tcpFlags: "SYN, ACK"), filter: filter))
        #expect(!service.matches(makePacket(tcpFlags: "SYN"), filter: filter))
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.flags",
            value: "0x100 (AE)",
            rawValue: nil
        ) == nil)
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcp.flags",
            value: "0x200 (Reserved)",
            rawValue: nil
        ) == nil)
    }

    @Test func nativeFallbackRejectsRowsWithoutAnExactPacketSummaryValue() {
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcpviewer.warning.decode",
            value: "Opaque TCP payload",
            rawValue: nil
        ) == nil)
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "sctp.srcport",
            value: "443",
            rawValue: nil
        ) == nil)
    }

    @Test func blankOrUnknownRowsDoNotCreateAFilterRequest() {
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: "   ",
            fieldName: "tls.handshake.ciphersuite",
            value: "TLS_AES_128_GCM_SHA256",
            rawValue: "13 01"
        ) == nil)
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "tcpviewer.wireshark.fallback",
            value: "Not decoded",
            rawValue: nil
        ) == nil)
        #expect(PacketInspectorFilterResolver.resolve(
            displayFilterExpression: nil,
            fieldName: "ip.src",
            value: "   ",
            rawValue: "0a 00 00 01"
        ) == nil)
    }

    private func makePacket(
        sourceAddress: String = "10.0.0.1",
        destinationPort: UInt16 = 443,
        transportHint: TransportProtocolHint = .tcp,
        protocolSummary: String? = "TCP",
        infoSummary: String = "TCP packet",
        streamID: UInt32? = 77,
        tcpFlags: String? = "SYN",
        capturedLength: Int = 1_024,
        layerNames: [String]? = nil,
        decodeStatus: PacketDecodeStatus = PacketDecodeStatus(kind: .complete),
        interfaceName: String? = nil,
        sniDomainName: String? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            source: .offline,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: 12_345),
                destination: PacketEndpoint(address: "10.0.0.2", port: destinationPort)
            ),
            originalLength: capturedLength,
            capturedLength: capturedLength,
            streamID: streamID,
            tcpFlags: tcpFlags,
            tcpPayloadLength: 512,
            infoSummary: infoSummary,
            layers: (layerNames ?? [protocolSummary ?? transportHint.rawValue]).map { PacketLayer(name: $0) },
            decodeStatus: decodeStatus,
            captureMetadata: PacketCaptureMetadata(
                linkType: .ethernet,
                isTruncated: false,
                interfaceName: interfaceName
            ),
            sniDomainName: sniDomainName
        )
    }
}
