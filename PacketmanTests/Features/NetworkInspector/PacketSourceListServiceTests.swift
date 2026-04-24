import Foundation
import Testing
import PcapPlusPlusCore
@testable import Packetman

@Suite(.serialized)
struct PacketSourceListServiceTests {

    @Test func emptyTreeHasFavoriteAndAllFolders() {
        let service = PacketSourceListService()
        let snapshot = service.snapshot(for: .empty)

        #expect(snapshot.roots.map(\.title) == ["Favorites", "All"])
        #expect(snapshot.roots[0].children.map(\.title) == ["Pinned", "Saved"])
        #expect(snapshot.roots[1].children.map(\.title) == ["Apps", "Domains"])
        #expect(snapshot.item(for: .apps)?.children.isEmpty == true)
        #expect(snapshot.item(for: .domains)?.children.isEmpty == true)
    }

    @Test func appendingPacketsCreatesAppAndDomainFolders() {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packets = [
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: client),
            makePacket(packetNumber: 2, sniDomainName: "openai.com", client: client),
        ]
        var state = PacketIngestState.empty
        state.append(packets, source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state)

        #expect(snapshot.item(for: .apps)?.count == 2)
        #expect(snapshot.item(for: .apps)?.children.map(\.title) == ["Example"])
        #expect(snapshot.item(for: .apps)?.children.first?.count == 2)
        #expect(snapshot.item(for: .domains)?.children.map(\.title) == ["api.example.com", "openai.com"])
    }

    @Test func duplicateClientsAndDomainsMergeAndCountPackets() {
        let client = makeClient(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "example.com", client: client),
            makePacket(packetNumber: 2, sniDomainName: "example.com", client: client),
            makePacket(packetNumber: 3, sniDomainName: "EXAMPLE.com", client: client),
        ], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state)

        #expect(snapshot.item(for: .apps)?.children.count == 1)
        #expect(snapshot.item(for: .apps)?.children.first?.count == 3)
        #expect(snapshot.item(for: .domains)?.children.count == 1)
        #expect(snapshot.item(for: .domains)?.children.first?.title == "example.com")
        #expect(snapshot.item(for: .domains)?.children.first?.count == 3)
    }

    @Test func missingDomainsUseIPAddressesPlaceholder() {
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: nil),
            makePacket(packetNumber: 2, sniDomainName: "   "),
        ], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state)
        let domain = snapshot.item(for: .domain(.ipAddresses))

        #expect(snapshot.item(for: .domains)?.children.map(\.title) == ["IP Addresses"])
        #expect(domain?.count == 2)
    }

    @Test func clientIdentityFallsBackThroughAvailableFields() {
        let clients = [
            makeClient(displayName: "Bundle", bundleIdentifier: "com.example.bundle", bundlePath: "/Applications/Bundle.app", executablePath: "/Applications/Bundle.app/Contents/MacOS/Bundle"),
            makeClient(displayName: "Bundle Path", bundleIdentifier: nil, bundlePath: "/Applications/Path.app", executablePath: "/Applications/Path.app/Contents/MacOS/Path"),
            makeClient(displayName: "Executable", bundleIdentifier: nil, bundlePath: nil, executablePath: "/usr/local/bin/example"),
            makeClient(displayName: "Display Only", name: "display-helper", bundleIdentifier: nil, bundlePath: nil, executablePath: nil),
        ]
        var state = PacketIngestState.empty
        state.append(clients.enumerated().map { offset, client in
            makePacket(packetNumber: UInt64(offset + 1), client: client)
        }, source: .live)

        let apps = PacketSourceListService().snapshot(for: state).item(for: .apps)?.children ?? []
        let rawKeys = apps.compactMap { item -> String? in
            guard case .app(let key) = item.selection else {
                return nil
            }
            return key.rawValue
        }

        #expect(apps.map(\.title) == ["Bundle", "Bundle Path", "Executable", "Display Only"])
        #expect(rawKeys == [
            "bundleIdentifier:com.example.bundle",
            "bundlePath:/Applications/Path.app",
            "executablePath:/usr/local/bin/example",
            "displayName:Display Only",
        ])
    }

    @Test func resetReplaceAndMetadataUpdatesRebuildTree() {
        let service = PacketSourceListService()
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        var state = PacketIngestState.empty
        let packet = makePacket(packetNumber: 1)
        state.append([packet], source: .live)

        var snapshot = service.snapshot(for: state)
        #expect(snapshot.item(for: .apps)?.children.isEmpty == true)
        #expect(snapshot.item(for: .domain(.ipAddresses))?.count == 1)

        state.applyMetadataUpdates([
            PacketMetadataUpdate(packetIDs: [packet.id], sniDomainName: "api.example.com", client: client)
        ])
        snapshot = service.snapshot(for: state)
        #expect(snapshot.item(for: .apps)?.children.map(\.title) == ["Example"])
        #expect(snapshot.item(for: .domains)?.children.map(\.title) == ["api.example.com"])

        state.replace(with: [], source: .live)
        snapshot = service.snapshot(for: state)
        #expect(snapshot.item(for: .apps)?.children.isEmpty == true)
        #expect(snapshot.item(for: .domains)?.children.isEmpty == true)
    }

    @Test func filteringKeepsMatchingDescendantsAndAncestors() {
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: makeClient(displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")),
            makePacket(packetNumber: 2, sniDomainName: "openai.com", client: makeClient(displayName: "Packetman", bundleIdentifier: "com.proxyman.Packetman")),
        ], source: .live)

        let filtered = PacketSourceListService()
            .snapshot(for: state)
            .filtered(matching: "chrome")

        #expect(filtered.roots.map(\.title) == ["All"])
        #expect(filtered.roots.first?.children.map(\.title) == ["Apps"])
        #expect(filtered.roots.first?.children.first?.children.map(\.title) == ["Google Chrome"])
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

    private func makeClient(
        displayName: String,
        name: String = "Example",
        bundleIdentifier: String?,
        bundlePath: String? = "/Applications/Example.app",
        executablePath: String? = "/Applications/Example.app/Contents/MacOS/Example"
    ) -> PacketClient {
        PacketClient(
            pid: 123,
            name: name,
            displayName: displayName,
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath
        )
    }
}
