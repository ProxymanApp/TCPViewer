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

    @Test func everyConditionHasExpectedSingleFilterTruthTable() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .http1, capturedLength: 128, infoSummary: "Alpha Beta Gamma")
        let cases: [(PacketStructuredFilterCondition, PacketStructuredFilterQuery, String, Bool)] = [
            (.contains, .summary, "beta", true),
            (.contains, .summary, "delta", false),
            (.notContains, .summary, "delta", true),
            (.notContains, .summary, "beta", false),
            (.hasPrefix, .summary, "alpha", true),
            (.hasPrefix, .summary, "beta", false),
            (.notHasPrefix, .summary, "beta", true),
            (.notHasPrefix, .summary, "alpha", false),
            (.hasSuffix, .summary, "gamma", true),
            (.hasSuffix, .summary, "beta", false),
            (.notHasSuffix, .summary, "beta", true),
            (.notHasSuffix, .summary, "gamma", false),
            (.lessThan, .length, "129", true),
            (.lessThan, .length, "128", false),
            (.greaterThanOrEqual, .length, "128", true),
            (.greaterThanOrEqual, .length, "129", false),
            (.matchesRegex, .summary, "^alpha\\s+beta", true),
            (.matchesRegex, .summary, "delta$", false),
            (.notMatchesRegex, .summary, "delta$", true),
            (.notMatchesRegex, .summary, "beta", false),
        ]

        for (condition, query, text, expectedResult) in cases {
            let filter = PacketStructuredFilter(query: query, condition: condition, text: text)
            #expect(service.matches(packet, filter: filter) == expectedResult)
        }
    }

    @Test func everyConditionCanParticipateInAndGroups() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .http1, capturedLength: 128, infoSummary: "Alpha Beta Gamma")
        let matchingFilters = [
            PacketStructuredFilter(query: .summary, condition: .contains, text: "alpha"),
            PacketStructuredFilter(query: .summary, condition: .notContains, text: "delta"),
            PacketStructuredFilter(query: .summary, condition: .hasPrefix, text: "alpha"),
            PacketStructuredFilter(query: .summary, condition: .notHasPrefix, text: "beta"),
            PacketStructuredFilter(query: .summary, condition: .hasSuffix, text: "gamma"),
            PacketStructuredFilter(query: .summary, condition: .notHasSuffix, text: "beta"),
            PacketStructuredFilter(query: .length, condition: .lessThan, text: "129"),
            PacketStructuredFilter(query: .length, condition: .greaterThanOrEqual, text: "128"),
            PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "alpha.*gamma"),
            PacketStructuredFilter(query: .summary, condition: .notMatchesRegex, text: "delta"),
        ]

        for filter in matchingFilters {
            let group = PacketStructuredFilterGroup(
                filters: [
                    PacketStructuredFilter(query: .summary, condition: .contains, text: "alpha"),
                    filter,
                ],
                operator: .and
            )
            #expect(service.matches(packet, group: group))
        }

        let failingGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .summary, condition: .contains, text: "alpha"),
                PacketStructuredFilter(query: .summary, condition: .notContains, text: "beta"),
            ],
            operator: .and
        )
        #expect(!service.matches(packet, group: failingGroup))
    }

    @Test func everyConditionCanParticipateInOrGroups() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .http1, capturedLength: 128, infoSummary: "Alpha Beta Gamma")
        let failingFilters = [
            PacketStructuredFilter(query: .summary, condition: .contains, text: "delta"),
            PacketStructuredFilter(query: .summary, condition: .notContains, text: "beta"),
            PacketStructuredFilter(query: .summary, condition: .hasPrefix, text: "beta"),
            PacketStructuredFilter(query: .summary, condition: .notHasPrefix, text: "alpha"),
            PacketStructuredFilter(query: .summary, condition: .hasSuffix, text: "beta"),
            PacketStructuredFilter(query: .summary, condition: .notHasSuffix, text: "gamma"),
            PacketStructuredFilter(query: .length, condition: .lessThan, text: "128"),
            PacketStructuredFilter(query: .length, condition: .greaterThanOrEqual, text: "129"),
            PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "delta"),
            PacketStructuredFilter(query: .summary, condition: .notMatchesRegex, text: "beta"),
        ]

        for filter in failingFilters {
            let matchingGroup = PacketStructuredFilterGroup(
                filters: [
                    filter,
                    PacketStructuredFilter(query: .summary, condition: .contains, text: "gamma"),
                ],
                operator: .or
            )
            #expect(service.matches(packet, group: matchingGroup))

            let failingGroup = PacketStructuredFilterGroup(filters: [filter], operator: .or)
            #expect(!service.matches(packet, group: failingGroup))
        }
    }

    @Test func singleFiltersCanMatchEveryQuerySurface() {
        let service = PacketStructuredFilterService()
        let client = makeClient()
        let packet = makePacket(
            packetNumber: 42,
            transportHint: .tls,
            sourceAddress: "192.168.1.10",
            sourcePort: 54_321,
            destinationAddress: "93.184.216.34",
            destinationPort: 443,
            streamID: 77,
            direction: .outbound,
            tcpFlags: "SYN, ACK",
            tcpPayloadLength: 512,
            capturedLength: 1_024,
            decodeStatus: PacketDecodeStatus(kind: .malformed, reason: "Checksum mismatch"),
            isTruncated: true,
            interfaceName: "Wi-Fi",
            interfaceID: "en0",
            sniDomainName: "api.example.com",
            client: client,
            protocolSummary: "TLS",
            infoSummary: "GET /v1/users HTTP/2",
            layers: [
                PacketLayer(name: "Ethernet"),
                PacketLayer(name: "TLS Client Hello", detailSummary: "SNI cdn.example.com"),
            ]
        )

        let matchingFilters: [PacketStructuredFilter] = [
            PacketStructuredFilter(query: .anyText, condition: .contains, text: "curl"),
            PacketStructuredFilter(query: .urlDomain, condition: .contains, text: "api.example.com"),
            PacketStructuredFilter(query: .urlDomain, condition: .contains, text: "cdn.example.com"),
            PacketStructuredFilter(query: .protocol, condition: .contains, text: "tls"),
            PacketStructuredFilter(query: .source, condition: .contains, text: "192.168.1.10:54321"),
            PacketStructuredFilter(query: .destination, condition: .contains, text: "93.184.216.34"),
            PacketStructuredFilter(query: .sourcePort, condition: .contains, text: "54321"),
            PacketStructuredFilter(query: .destinationPort, condition: .contains, text: "443"),
            PacketStructuredFilter(query: .client, condition: .contains, text: "curl"),
            PacketStructuredFilter(query: .client, condition: .contains, text: "/usr/bin/curl"),
            PacketStructuredFilter(query: .pid, condition: .contains, text: "4242"),
            PacketStructuredFilter(query: .bundleIdentifier, condition: .contains, text: "com.example.curl"),
            PacketStructuredFilter(query: .streamID, condition: .contains, text: "77"),
            PacketStructuredFilter(query: .direction, condition: .contains, text: "outbound"),
            PacketStructuredFilter(query: .tcpFlags, condition: .contains, text: "ack"),
            PacketStructuredFilter(query: .tcpPayload, condition: .contains, text: "512"),
            PacketStructuredFilter(query: .decodeStatus, condition: .contains, text: "checksum"),
            PacketStructuredFilter(query: .interface, condition: .contains, text: "Wi-Fi"),
            PacketStructuredFilter(query: .interface, condition: .contains, text: "en0"),
            PacketStructuredFilter(query: .length, condition: .contains, text: "1024"),
            PacketStructuredFilter(query: .summary, condition: .contains, text: "/v1/users"),
            PacketStructuredFilter(query: .tags, condition: .contains, text: "truncated"),
            PacketStructuredFilter(query: .tags, condition: .contains, text: "malformed"),
        ]

        for filter in matchingFilters {
            #expect(service.matches(packet, filter: filter))
        }

        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .bundleIdentifier, condition: .contains, text: "com.other.app")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .tags, condition: .contains, text: "unsupported")))
    }

    @Test func inactiveSingleFiltersAlwaysMatch() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .tcp, infoSummary: "TLS packet")

        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .summary, condition: .contains, text: "missing", isEnabled: false)))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .summary, condition: .contains, text: "   ")))
    }

    @Test func numericConditionsCoverAllNumericQueriesAndBoundaries() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(
            packetNumber: 1,
            transportHint: .tcp,
            sourcePort: 1234,
            destinationPort: 8443,
            streamID: 99,
            tcpPayloadLength: 512,
            capturedLength: 1_500,
            client: makeClient(pid: 4242)
        )

        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .sourcePort, condition: .lessThan, text: "1235")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .sourcePort, condition: .lessThan, text: "1234")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "8443")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "8444")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .pid, condition: .greaterThanOrEqual, text: "4000")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .streamID, condition: .lessThan, text: "100")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .tcpPayload, condition: .greaterThanOrEqual, text: "512")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .length, condition: .lessThan, text: "1500.5")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .length, condition: .lessThan, text: "1,600")))
    }

    @Test func textNegativeConditionsFailWhenAnyValueMatches() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(
            packetNumber: 1,
            transportHint: .tls,
            sniDomainName: "api.example.com",
            infoSummary: "CONNECT api.example.com"
        )

        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notContains, text: "example")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notContains, text: "openai")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notHasPrefix, text: "api")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notHasPrefix, text: "www")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notHasSuffix, text: ".com")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .urlDomain, condition: .notHasSuffix, text: ".org")))
    }

    @Test func regexConditionsMatchAcrossMultipleValuesCaseInsensitively() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .tcp, client: makeClient(displayName: "Safari Browser"))

        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .client, condition: .matchesRegex, text: "safari|chrome")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .client, condition: .matchesRegex, text: "SAFARI")))
        #expect(!service.matches(packet, filter: PacketStructuredFilter(query: .client, condition: .notMatchesRegex, text: "browser")))
        #expect(service.matches(packet, filter: PacketStructuredFilter(query: .client, condition: .notMatchesRegex, text: "firefox")))
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

    @Test func andGroupsRequireEveryActiveFilterButIgnoreInactiveFilters() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(
            packetNumber: 1,
            transportHint: .tls,
            destinationPort: 443,
            sniDomainName: "api.example.com",
            client: makeClient(displayName: "Safari Browser"),
            infoSummary: "TLS Client Hello"
        )

        let matchingANDGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "tls"),
                PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "443"),
                PacketStructuredFilter(query: .client, condition: .matchesRegex, text: "safari|chrome"),
                PacketStructuredFilter(query: .summary, condition: .contains, text: "missing", isEnabled: false),
                PacketStructuredFilter(query: .summary, condition: .contains, text: ""),
            ],
            operator: .and
        )

        let failingANDGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "tls"),
                PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "443"),
                PacketStructuredFilter(query: .client, condition: .matchesRegex, text: "safari|chrome"),
                PacketStructuredFilter(query: .urlDomain, condition: .contains, text: "openai.com"),
            ],
            operator: .and
        )

        #expect(service.matches(packet, group: matchingANDGroup))
        #expect(!service.matches(packet, group: failingANDGroup))
    }

    @Test func orGroupsMatchAnyActiveFilterAndIgnoreInactiveMatches() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .udp, destinationPort: 53, infoSummary: "DNS query")

        let matchingORGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp"),
                PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "400"),
                PacketStructuredFilter(query: .summary, condition: .contains, text: "dns"),
            ],
            operator: .or
        )
        let failingORGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp"),
                PacketStructuredFilter(query: .summary, condition: .contains, text: "dns", isEnabled: false),
                PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "400"),
            ],
            operator: .or
        )

        #expect(service.matches(packet, group: matchingORGroup))
        #expect(!service.matches(packet, group: failingORGroup))
    }

    @Test func groupsWithOnlyDisabledOrEmptyFiltersMatchAllPacketsForBothOperators() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .tcp, infoSummary: "Any packet")
        let filters = [
            PacketStructuredFilter(query: .summary, condition: .contains, text: "missing", isEnabled: false),
            PacketStructuredFilter(query: .summary, condition: .contains, text: "   "),
        ]

        #expect(service.matches(packet, group: PacketStructuredFilterGroup(filters: filters, operator: .and)))
        #expect(service.matches(packet, group: PacketStructuredFilterGroup(filters: filters, operator: .or)))
    }

    @Test func invalidRegexParticipatesAsFalseInAndAndOrGroups() {
        let service = PacketStructuredFilterService()
        let packet = makePacket(packetNumber: 1, transportHint: .http1, infoSummary: "GET /health HTTP/1.1")
        let invalidRegex = PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "[")
        let matchingSummary = PacketStructuredFilter(query: .summary, condition: .contains, text: "health")

        #expect(!service.matches(packet, group: PacketStructuredFilterGroup(filters: [matchingSummary, invalidRegex], operator: .and)))
        #expect(service.matches(packet, group: PacketStructuredFilterGroup(filters: [matchingSummary, invalidRegex], operator: .or)))
        #expect(!service.matches(packet, group: PacketStructuredFilterGroup(filters: [invalidRegex], operator: .or)))
    }

    @Test func preparedEvaluationContextMatchesDirectGroupEvaluation() {
        let service = PacketStructuredFilterService()
        let packets = [
            makePacket(packetNumber: 1, transportHint: .tcp, destinationPort: 443, infoSummary: "TLS packet"),
            makePacket(packetNumber: 2, transportHint: .udp, destinationPort: 53, infoSummary: "DNS packet"),
            makePacket(packetNumber: 3, transportHint: .http1, destinationPort: 80, infoSummary: "GET /health"),
        ]
        let group = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .matchesRegex, text: "tcp|http"),
                PacketStructuredFilter(query: .destinationPort, condition: .lessThan, text: "500"),
            ],
            operator: .and
        )
        let context = service.evaluationContext(for: group)

        #expect(packets.map { service.matches($0, context: context) } == packets.map { service.matches($0, group: group) })
        #expect(packets.map { service.matches($0, context: context) } == [true, false, true])
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.PacketStructuredFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeClient(
        pid: Int32 = 4242,
        displayName: String = "Curl Client"
    ) -> PacketClient {
        PacketClient(
            pid: pid,
            name: "curl",
            displayName: displayName,
            executablePath: "/usr/bin/curl",
            bundleIdentifier: "com.example.curl",
            bundlePath: "/Applications/Curl.app"
        )
    }

    private func makePacket(
        packetNumber: UInt64,
        transportHint: TransportProtocolHint,
        sourceAddress: String? = "10.0.0.1",
        sourcePort: UInt16 = 1234,
        destinationAddress: String? = "10.0.0.2",
        destinationPort: UInt16 = 80,
        streamID: UInt32? = nil,
        direction: PacketDirection? = nil,
        tcpFlags: String? = nil,
        tcpPayloadLength: Int? = nil,
        capturedLength: Int = 128,
        decodeStatus: PacketDecodeStatus = PacketDecodeStatus(kind: .complete),
        isTruncated: Bool = false,
        interfaceName: String? = nil,
        interfaceID: String? = nil,
        sniDomainName: String? = nil,
        client: PacketClient? = nil,
        protocolSummary: String? = nil,
        infoSummary: String? = nil,
        layers: [PacketLayer]? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            interfaceID: interfaceID,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: sourcePort),
                destination: PacketEndpoint(address: destinationAddress, port: destinationPort)
            ),
            originalLength: capturedLength,
            capturedLength: capturedLength,
            streamID: streamID,
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary ?? "Packet \(packetNumber)",
            layers: layers ?? [PacketLayer(name: transportHint.rawValue.uppercased())],
            decodeStatus: decodeStatus,
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: isTruncated, interfaceName: interfaceName),
            sniDomainName: sniDomainName,
            client: client
        )
    }
}
