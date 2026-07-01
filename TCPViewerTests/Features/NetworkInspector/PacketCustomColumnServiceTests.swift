//
//  PacketCustomColumnServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/7/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
struct PacketCustomColumnServiceTests {
    @Test func createsColumnFromProtocolFieldAndRejectsInvalidField() {
        let service = PacketCustomColumnService()

        let result = service.createColumn(from: PacketCustomColumnRequest(
            fieldName: " TCP.SrcPort ",
            title: "Source Port",
            packetID: 1,
            sampleValue: "443"
        ))
        let column = result.column

        #expect(result.didCreate)
        #expect(column?.identifier == "custom.field.tcp.srcport")
        #expect(column?.fieldName == "tcp.srcport")
        #expect(column?.title == "Source Port")
        #expect(service.value(columnIdentifier: "custom.field.tcp.srcport", packetID: 1) == "443")
        #expect(service.createColumn(from: PacketCustomColumnRequest(
            fieldName: "   ",
            title: "Blank",
            packetID: nil,
            sampleValue: nil
        )) == .invalid)
    }

    @Test func duplicateProtocolFieldRevealsExistingColumn() throws {
        let service = PacketCustomColumnService()
        let first = try #require(service.createColumn(from: PacketCustomColumnRequest(
            fieldName: "ip.src",
            title: "Source Address",
            packetID: nil,
            sampleValue: nil
        )).column)

        let duplicate = service.createColumn(from: PacketCustomColumnRequest(
            fieldName: "IP.SRC",
            title: "Different Title",
            packetID: nil,
            sampleValue: nil
        ))

        #expect(duplicate == .existing(first))
        #expect(service.columns == [first])
    }

    @Test func resolvedValueWalksChildrenAndUsesDisplayValueBeforeRawValue() {
        let inspection = Self.inspection(detailNodes: [
            PacketDetailNode(id: "frame", name: "Frame", fieldName: "frame", children: [
                PacketDetailNode(id: "ip", name: "IP", fieldName: "ip", children: [
                    PacketDetailNode(
                        id: "ip.src",
                        name: "Source Address",
                        fieldName: "ip.src",
                        value: "10.0.0.1",
                        rawValue: "0a000001"
                    ),
                ]),
            ]),
        ])

        #expect(PacketCustomColumnService.resolvedValue(fieldName: "IP.SRC", in: inspection) == "10.0.0.1")
    }

    @Test func resolvedValueFallsBackToRawValueAndMissingFieldIsEmpty() {
        let inspection = Self.inspection(detailNodes: [
            PacketDetailNode(
                id: "tcp.flags.syn",
                name: "Syn",
                fieldName: "tcp.flags.syn",
                value: nil,
                rawValue: "02"
            ),
        ])

        #expect(PacketCustomColumnService.resolvedValue(fieldName: "tcp.flags.syn", in: inspection) == "02")
        #expect(PacketCustomColumnService.resolvedValue(fieldName: "tls.handshake.type", in: inspection) == "")
    }

    @Test func cacheStoresEmptyValuesAndCanReset() throws {
        let service = PacketCustomColumnService()
        let column = try #require(service.createColumn(from: PacketCustomColumnRequest(
            fieldName: "dns.qry.name",
            title: "Name",
            packetID: nil,
            sampleValue: nil
        )).column)

        #expect(!service.hasResolvedValue(columnIdentifier: column.identifier, packetID: 7))

        service.storeValue("", columnIdentifier: column.identifier, packetID: 7)
        #expect(service.hasResolvedValue(columnIdentifier: column.identifier, packetID: 7))
        #expect(service.value(columnIdentifier: column.identifier, packetID: 7) == "")

        service.reset()
        #expect(service.columns.isEmpty)
        #expect(!service.hasResolvedValue(columnIdentifier: column.identifier, packetID: 7))
    }

    @Test func unresolvedPacketIDsUsePreferredVisibleRowsFirst() {
        let column = PacketCustomColumn(identifier: "custom.field.ip.src", fieldName: "ip.src", title: "Source")
        let service = PacketCustomColumnService(columns: [column])
        let rows = [1, 2, 3, 4].map { PacketTableRow(packet: Self.packet(packetNumber: UInt64($0))) }

        service.storeValue("cached", columnIdentifier: column.identifier, packetID: 3)

        let unresolvedIDs = service.unresolvedPacketIDs(
            for: column,
            rows: rows,
            preferredPacketIDs: [4, 2, 99, 4]
        )

        #expect(unresolvedIDs == [4, 2, 1])
    }

    private static func packet(packetNumber: UInt64) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 64,
            capturedLength: 64,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }

    private static func inspection(detailNodes: [PacketDetailNode]) -> PacketInspection {
        PacketInspection(
            packetID: 1,
            packetNumber: 1,
            rawBytes: Data(),
            detailNodes: detailNodes,
            decodeStatus: PacketDecodeStatus(kind: .complete)
        )
    }
}
