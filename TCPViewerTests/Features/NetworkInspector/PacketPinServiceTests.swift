import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
struct PacketPinServiceTests {

    @Test func persistsCriteriaOnlyAndReloadsWithoutPackets() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("Pins.json")
        let service = PacketPinService(storageURL: storageURL)
        let packet = makePacket(packetNumber: 1, sniDomainName: "API.Example.com")

        let pin = try service.upsertPin(from: packet, kind: .domain, clickedColumn: .domain, now: Date(timeIntervalSince1970: 10))
        let reloaded = PacketPinService(storageURL: storageURL)
        let rawJSON = try String(contentsOf: storageURL)

        #expect(pin.id.rawValue == "domain:api.example.com")
        #expect(reloaded.pins().map(\.id) == [pin.id])
        #expect(reloaded.matchingPackets(in: [], for: .pinnedItem(pin.id)).isEmpty)
        #expect(!rawJSON.contains("Packet 1"))
        #expect(!rawJSON.contains("capturedLength"))
        #expect(!rawJSON.contains("10.0.0.1"))
    }

    @Test func duplicateDomainUpsertReusesExistingPinAndMatchesFuturePackets() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("Pins.json")
        let service = PacketPinService(storageURL: storageURL)
        let first = makePacket(packetNumber: 1, sniDomainName: "Example.com")
        let second = makePacket(packetNumber: 2, sniDomainName: "example.COM")
        let future = makePacket(packetNumber: 3, sniDomainName: "example.com")

        let firstPin = try service.upsertPin(from: first, kind: .domain, clickedColumn: .domain)
        let secondPin = try service.upsertPin(from: second, kind: .domain, clickedColumn: .domain)

        #expect(firstPin.id == secondPin.id)
        #expect(service.pins().count == 1)
        #expect(service.matchingPackets(in: [future], for: .pinnedItem(firstPin.id)).map(\.id) == [future.id])
    }

    @Test func ipPinUsesClickedEndpointThenFallsBackToDestination() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("Pins.json")
        let service = PacketPinService(storageURL: storageURL)
        let packet = makePacket(packetNumber: 1)

        let sourcePin = try service.upsertPin(from: packet, kind: .ip, clickedColumn: .source)
        let destinationPin = try service.upsertPin(from: packet, kind: .ip, clickedColumn: .summary)

        #expect(sourcePin.ipAddress == "10.0.0.1")
        #expect(destinationPin.ipAddress == "10.0.0.2")
    }

    @Test func clientPinUsesSourceListClientIdentity() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("Pins.json")
        let service = PacketPinService(storageURL: storageURL)
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packet = makePacket(packetNumber: 1, client: client)

        let pin = try service.upsertPin(from: packet, kind: .client, clickedColumn: .client)

        #expect(pin.title == "Example")
        #expect(pin.clientKey == "bundleIdentifier:com.example.app")
        #expect(service.matchingPackets(in: [packet], for: .pinned).map(\.id) == [packet.id])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePacket(
        packetNumber: UInt64,
        sniDomainName: String? = nil,
        client: PacketClient? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: nil,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: sniDomainName,
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
