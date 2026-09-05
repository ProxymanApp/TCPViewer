//
//  PacketQuickFilterServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/5/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct PacketQuickFilterServiceTests {
    @Test func quickFilterSelectionDefaultsToAllAndTogglesExclusively() {
        let service = PacketQuickFilterService()

        #expect(service.selection.selectedIDs == [.all])
        #expect(service.items().first { $0.id == .all }?.isSelected == true)

        service.toggle(.tcp)
        #expect(service.selection.selectedIDs == [.tcp])

        service.toggle(.udp)
        #expect(service.selection.selectedIDs == [.tcp, .udp])

        service.toggle(.tcp)
        #expect(service.selection.selectedIDs == [.udp])

        service.toggle(.udp)
        #expect(service.selection.selectedIDs == [.all])

        service.toggle(.tls)
        service.toggle(.all)
        #expect(service.selection.selectedIDs == [.all])
    }

    @Test func quickFilterSelectionUsesUnionMatching() {
        let service = PacketQuickFilterService(selection: PacketQuickFilterSelection(selectedIDs: [.tcp, .udp]))
        let tcpPacket = makePacket(packetNumber: 1, transportHint: .tcp, layers: ["Ethernet", "TCP"])
        let udpPacket = makePacket(packetNumber: 2, transportHint: .udp, layers: ["Ethernet", "UDP"])
        let arpPacket = makePacket(packetNumber: 3, transportHint: .arp, layers: ["Ethernet", "ARP"])

        #expect(service.matches(tcpPacket))
        #expect(service.matches(udpPacket))
        #expect(!service.matches(arpPacket))
    }

    // Decode issues narrow the protocol union instead of admitting unrelated or healthy packets.
    @Test func decodeIssuesIntersectSelectedProtocols() {
        let service = PacketQuickFilterService(selection: PacketQuickFilterSelection(selectedIDs: [.tcp, .udp, .errors]))
        let packets = [
            makePacket(packetNumber: 1, transportHint: .tcp, layers: ["TCP"]),
            makePacket(packetNumber: 2, transportHint: .udp, layers: ["UDP"]),
            makePacket(packetNumber: 3, transportHint: .tcp, layers: ["TCP"], decodeStatus: PacketDecodeStatus(kind: .partial)),
            makePacket(packetNumber: 4, transportHint: .udp, layers: ["UDP"], decodeStatus: PacketDecodeStatus(kind: .malformed)),
            makePacket(packetNumber: 5, transportHint: .arp, layers: ["ARP"], decodeStatus: PacketDecodeStatus(kind: .unsupported)),
            makePacket(packetNumber: 6, transportHint: .tcp, layers: ["TCP"], isTruncated: true),
        ]

        #expect(packets.filter { service.matches($0) }.map(\.packetNumber) == [3, 4, 6])

        service.toggle(.udp)
        #expect(packets.filter { service.matches($0) }.map(\.packetNumber) == [3, 6])

        service.toggle(.errors)
        #expect(packets.filter { service.matches($0) }.map(\.packetNumber) == [1, 3, 6])
    }

    // All changes only protocols, while Reset Filters clears both independent selections.
    @Test func allProtocolsPreservesDecodeIssuesUntilReset() {
        let service = PacketQuickFilterService(selection: PacketQuickFilterSelection(selectedIDs: [.tcp, .errors]))
        let issue = makePacket(packetNumber: 1, transportHint: .arp, layers: ["ARP"], decodeStatus: PacketDecodeStatus(kind: .unsupported))
        let healthy = makePacket(packetNumber: 2, transportHint: .tcp, layers: ["TCP"])

        service.toggle(.all)

        #expect(service.selection.contains(.errors))
        #expect(service.items().first { $0.id == .all }?.isSelected == true)
        #expect(service.selection.isActive)
        #expect(service.matches(issue))
        #expect(!service.matches(healthy))

        service.toggle(.tcp)
        #expect(!service.selection.contains(.all))
        service.toggle(.tcp)
        #expect(service.selection.contains(.all))
        #expect(service.selection.contains(.errors))

        service.reset()
        #expect(service.selection == .all)
        #expect(!service.selection.isActive)
        #expect(service.matches(healthy))
    }

    // Existing session files retain their saved troubleshooting selection after the label changes.
    @Test func legacyErrorsSelectionSurvivesCodingAndUsesIntersection() throws {
        let data = Data(#"{"selectedIDs":["tcp","errors"]}"#.utf8)
        let selection = try JSONDecoder().decode(PacketQuickFilterSelection.self, from: data)
        let restored = try JSONDecoder().decode(PacketQuickFilterSelection.self, from: JSONEncoder().encode(selection))
        let service = PacketQuickFilterService(selection: restored)

        #expect(restored == selection)
        #expect(restored.activeLabels == ["TCP", "Decode issues"])
        #expect(!service.matches(makePacket(packetNumber: 1, transportHint: .tcp, layers: ["TCP"])))
        #expect(service.matches(makePacket(packetNumber: 2, transportHint: .tcp, layers: ["TCP"], isTruncated: true)))
    }

    @Test func quickFilterPredicatesMatchRepresentativePackets() {
        let service = PacketQuickFilterService()
        let httpOverTCP = makePacket(packetNumber: 1, transportHint: .http1, layers: ["Ethernet", "TCP", "HTTP Request"])
        let dnsOverUDP = makePacket(packetNumber: 2, transportHint: .dns, layers: ["Ethernet", "UDP", "DNS"])
        let clientHello = makePacket(
            packetNumber: 3,
            transportHint: .tls,
            layers: ["Ethernet", "TCP", "TLSv1.2"],
            protocolSummary: "TLSv1.2",
            infoSummary: "Client Hello"
        )
        let serverHello = makePacket(
            packetNumber: 4,
            transportHint: .tls,
            layers: ["Ethernet", "TCP", "TLSv1.3"],
            protocolSummary: "TLSv1.3",
            infoSummary: "Server Hello"
        )
        let websocket = makePacket(packetNumber: 5, transportHint: .websocket, layers: ["Ethernet", "TCP", "WebSocket"])
        let malformed = makePacket(
            packetNumber: 6,
            transportHint: .udp,
            layers: ["Ethernet", "UDP"],
            decodeStatus: PacketDecodeStatus(kind: .malformed, reason: "Bad length")
        )

        #expect(service.matches(httpOverTCP, selection: PacketQuickFilterSelection(selectedIDs: [.tcp])))
        #expect(service.matches(httpOverTCP, selection: PacketQuickFilterSelection(selectedIDs: [.http])))
        #expect(!service.matches(httpOverTCP, selection: PacketQuickFilterSelection(selectedIDs: [.udp])))
        #expect(service.matches(dnsOverUDP, selection: PacketQuickFilterSelection(selectedIDs: [.udp])))
        #expect(service.matches(dnsOverUDP, selection: PacketQuickFilterSelection(selectedIDs: [.dns])))
        #expect(service.matches(clientHello, selection: PacketQuickFilterSelection(selectedIDs: [.tls])))
        #expect(service.matches(clientHello, selection: PacketQuickFilterSelection(selectedIDs: [.clientHello])))
        #expect(service.matches(serverHello, selection: PacketQuickFilterSelection(selectedIDs: [.serverHello])))
        #expect(service.matches(websocket, selection: PacketQuickFilterSelection(selectedIDs: [.websocket])))
        #expect(service.matches(malformed, selection: PacketQuickFilterSelection(selectedIDs: [.errors])))
    }

    private func makePacket(
        packetNumber: UInt64,
        transportHint: TransportProtocolHint,
        layers: [String],
        protocolSummary: String? = nil,
        infoSummary: String? = nil,
        decodeStatus: PacketDecodeStatus = PacketDecodeStatus(kind: .complete),
        isTruncated: Bool = false
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 128,
            capturedLength: 128,
            infoSummary: infoSummary ?? "Packet \(packetNumber)",
            layers: layers.map { PacketLayer(name: $0) },
            decodeStatus: decodeStatus,
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: isTruncated)
        )
    }
}
