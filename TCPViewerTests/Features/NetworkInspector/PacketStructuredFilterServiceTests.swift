//
//  PacketStructuredFilterServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/5/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketStructuredFilterServiceTests {
    @Test func filterGroupDefaultsClampAndCodableRoundTrips() throws {
        let defaultGroup = PacketStructuredFilterGroup.default
        #expect(defaultGroup.filters.count == 1)
        #expect(defaultGroup.filters.first?.query == .urlDomain)
        #expect(defaultGroup.operator == .and)

        let tooManyFilters = (0..<8).map { index in
            PacketStructuredFilter(text: "filter-\(index)")
        }
        let clampedGroup = PacketStructuredFilterGroup(filters: tooManyFilters, operator: .or)
        #expect(clampedGroup.filters.count == PacketStructuredFilterGroup.maxFilterCount)
        #expect(clampedGroup.operator == .or)
        #expect(PacketStructuredFilterGroup(filters: []).filters.count == 1)

        let fullGroup = (0..<PacketStructuredFilterGroup.maxFilterCount).reduce(PacketStructuredFilterGroup.default) { group, _ in
            group.addingCopy(of: group.filters.first?.id)
        }
        #expect(fullGroup.filters.count == PacketStructuredFilterGroup.maxFilterCount)
        #expect(fullGroup.addingCopy(of: fullGroup.filters.first?.id).filters.count == PacketStructuredFilterGroup.maxFilterCount)

        let sourceFilter = PacketStructuredFilter(query: .protocol, condition: .matchesRegex, text: "tcp|udp", isEnabled: true)
        let copiedGroup = PacketStructuredFilterGroup(filters: [sourceFilter]).addingCopy(of: sourceFilter.id)
        let copiedFilter = try #require(copiedGroup.filters.last)
        #expect(copiedFilter.id != sourceFilter.id)
        #expect(copiedFilter.query == sourceFilter.query)
        #expect(copiedFilter.condition == sourceFilter.condition)
        #expect(copiedFilter.isEnabled == sourceFilter.isEnabled)
        #expect(copiedFilter.text == "")

        let singleFilterID = try #require(defaultGroup.filters.first?.id)
        let clearedGroup = defaultGroup.removingOrClearing(filterID: singleFilterID)
        #expect(clearedGroup.filters.count == 1)
        #expect(clearedGroup.filters.first?.id == singleFilterID)
        #expect(clearedGroup.filters.first?.isEnabled == false)
        #expect(clearedGroup.filters.first?.text == "")

        let data = try JSONEncoder().encode(clampedGroup)
        let decodedGroup = try JSONDecoder().decode(PacketStructuredFilterGroup.self, from: data)
        #expect(decodedGroup == clampedGroup)
    }

    @Test func filterStorePersistsAndRestoresGroup() {
        let defaults = isolatedDefaults()
        let store = PacketStructuredFilterStore(defaults: defaults)
        let group = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp"),
                PacketStructuredFilter(query: .length, condition: .greaterThanOrEqual, text: "128"),
            ],
            operator: .and
        )

        store.save(group)

        let restoredStore = PacketStructuredFilterStore(defaults: defaults)
        #expect(restoredStore.load() == group)

        restoredStore.clear()
        #expect(restoredStore.load() == .default)
    }

    @Test func textConditionsMatchCaseInsensitively() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(
            packetNumber: 1,
            transportHint: .tls,
            sniDomainName: "api.example.com",
            infoSummary: "TLS Client Hello"
        )

        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .contains, text: "EXAMPLE")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notContains, text: "example")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .hasPrefix, text: "api")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notHasPrefix, text: "www")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .hasSuffix, text: ".com")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notHasSuffix, text: ".org")))
    }

    @Test func numericConditionsOnlyMatchNumericQueries() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(
            packetNumber: 1,
            transportHint: .tcp,
            sourcePort: 1234,
            destinationPort: 443,
            tcpPayloadLength: 42,
            capturedLength: 128
        )

        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .length, condition: .lessThan, text: "256")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .sourcePort, condition: .greaterThanOrEqual, text: "1234")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .tcpPayload, condition: .lessThan, text: "50")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .summary, condition: .lessThan, text: "999")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .length, condition: .greaterThanOrEqual, text: "not-a-number")))
    }

    @Test func regexConditionsDoNotCrashForInvalidPatterns() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .http1, infoSummary: "GET /login HTTP/1.1")

        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "GET.*/login")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .summary, condition: .notMatchesRegex, text: "POST")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "[")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .summary, condition: .notMatchesRegex, text: "[")))
    }

    @Test func groupOperatorAppliesAcrossAllActiveFilters() {
        let service = PacketStructuredFilterService()
        let tcpPacket = makePacket(packetNumber: 1, transportHint: .tcp, destinationPort: 443, infoSummary: "TLS packet")
        let udpPacket = makePacket(packetNumber: 2, transportHint: .udp, destinationPort: 53, infoSummary: "DNS packet")
        let filters = [
            PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp"),
            PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "400"),
        ]

        #expect(service.matches(tcpPacket, group: PacketStructuredFilterGroup(filters: filters, operator: .and)))
        #expect(!service.matches(udpPacket, group: PacketStructuredFilterGroup(filters: filters, operator: .and)))
        #expect(service.matches(tcpPacket, group: PacketStructuredFilterGroup(filters: filters, operator: .or)))
        #expect(!service.matches(udpPacket, group: PacketStructuredFilterGroup(filters: filters, operator: .or)))

        let disabledFilter = PacketStructuredFilter(query: .summary, condition: .contains, text: "missing", isEnabled: false)
        #expect(service.matches(udpPacket, group: PacketStructuredFilterGroup(filters: [disabledFilter], operator: .and)))
        #expect(service.matches(udpPacket, group: PacketStructuredFilterGroup(filters: [PacketStructuredFilter(text: "")], operator: .and)))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.PacketStructuredFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makePacket(
        packetNumber: UInt64,
        transportHint: TransportProtocolHint,
        sourcePort: UInt16 = 1234,
        destinationPort: UInt16 = 80,
        tcpPayloadLength: Int? = nil,
        capturedLength: Int = 128,
        sniDomainName: String? = nil,
        infoSummary: String? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: sourcePort),
                destination: PacketEndpoint(address: "10.0.0.2", port: destinationPort)
            ),
            originalLength: capturedLength,
            capturedLength: capturedLength,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary ?? "Packet \(packetNumber)",
            layers: [PacketLayer(name: transportHint.rawValue.uppercased())],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: sniDomainName
        )
    }
}
