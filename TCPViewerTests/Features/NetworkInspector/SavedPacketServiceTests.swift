//
//  SavedPacketServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
struct SavedPacketServiceTests {

    @Test func savesReloadsUpsertsAndDeletesPacketSummaryRecords() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("Saved.json")
        let service = SavedPacketService(storageURL: storageURL)
        let first = makePacket(packetNumber: 1, infoSummary: "First")
        let second = makePacket(packetNumber: 2, infoSummary: "Second")

        try service.save([first, second], backingIdentity: "backing-a", now: Date(timeIntervalSince1970: 20))
        #expect(service.records().map { $0.packet.id } == [first.id, second.id])
        #expect(service.records().map(\.backingIdentity) == ["backing-a", "backing-a"])

        let reloaded = SavedPacketService(storageURL: storageURL)
        #expect(reloaded.records().map { $0.packet.infoSummary } == ["First", "Second"])
        #expect(reloaded.records().map(\.backingIdentity) == ["backing-a", "backing-a"])

        let updatedFirst = makePacket(packetNumber: 1, infoSummary: "Updated")
        try reloaded.save([updatedFirst], backingIdentity: "backing-b", now: Date(timeIntervalSince1970: 30))
        #expect(reloaded.records().count == 2)
        #expect(reloaded.records().first?.packet.infoSummary == "Updated")
        #expect(reloaded.records().first?.backingIdentity == "backing-b")

        try reloaded.deletePacketIDs([first.id])
        #expect(reloaded.records().map { $0.packet.id } == [second.id])
    }

    @Test func staysEmptyUntilPacketsAreManuallySaved() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("Saved.json")
        let service = SavedPacketService(storageURL: storageURL)
        let incomingPacket = makePacket(packetNumber: 1)

        #expect(service.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storageURL.path))

        try service.save([incomingPacket])

        #expect(service.records().map { $0.packet.id } == [incomingPacket.id])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePacket(packetNumber: UInt64, infoSummary: String? = nil) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            transportHint: .udp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 53)
            ),
            originalLength: 96,
            capturedLength: 96,
            streamID: nil,
            infoSummary: infoSummary ?? "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "UDP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }
}
