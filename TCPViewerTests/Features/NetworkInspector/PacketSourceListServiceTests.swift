//
//  PacketSourceListServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

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
        let sourceIPKey = PacketSourceIPAddressKey(rawValue: "10.0.0.1")
        let destinationIPKey = PacketSourceIPAddressKey(rawValue: "10.0.0.2")

        #expect(snapshot.item(for: .domains)?.children.map(\.title) == ["IP Addresses"])
        #expect(domain?.count == 2)
        #expect(domain?.children.map(\.title) == ["10.0.0.2", "10.0.0.1"])
        #expect(snapshot.item(for: .ipAddress(destinationIPKey))?.count == 2)
        #expect(snapshot.item(for: .ipAddress(sourceIPKey))?.count == 2)
    }

    @Test func appRowsNestScopedDomainsAndIPAddresses() throws {
        let chrome = makeClient(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")
        let tcpviewer = makeClient(displayName: "TCP Viewer", bundleIdentifier: "com.proxyman.tcpviewer")
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: chrome),
            makePacket(packetNumber: 2, sniDomainName: "api.example.com", client: chrome),
            makePacket(packetNumber: 3, sniDomainName: nil, client: chrome, sourceAddress: "10.0.0.3", destinationAddress: "10.0.0.4"),
            makePacket(packetNumber: 4, sniDomainName: "api.example.com", client: tcpviewer),
            makePacket(packetNumber: 5, sniDomainName: nil, client: tcpviewer, sourceAddress: "10.0.0.5", destinationAddress: "10.0.0.6"),
        ], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state)
        let chromeKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.google.Chrome")
        let tcpviewerKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.proxyman.tcpviewer")
        let apiKey = domainKey("api.example.com")
        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.4")

        let chromeItem = try #require(snapshot.item(for: .app(chromeKey)))
        #expect(chromeItem.children.map(\.title) == ["api.example.com", "IP Addresses"])
        #expect(snapshot.item(for: .appDomain(chromeKey, apiKey))?.count == 2)
        #expect(snapshot.item(for: .appDomain(tcpviewerKey, apiKey))?.count == 1)
        #expect(snapshot.item(for: .appDomain(chromeKey, .ipAddresses))?.count == 1)
        #expect(snapshot.item(for: .appDomain(chromeKey, .ipAddresses))?.children.map(\.title) == ["10.0.0.4", "10.0.0.3"])
        #expect(snapshot.item(for: .appIPAddress(chromeKey, ipKey))?.count == 1)
    }

    @Test func deletionPolicyOnlyAllowsDeletableLeafItems() {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let pinID = PacketPinID(rawValue: "domain:api.example.com")
        let pin = PacketPin(
            id: pinID,
            kind: .domain,
            title: "api.example.com",
            createdAt: Date(timeIntervalSince1970: 10),
            domain: "api.example.com",
            ipAddress: nil,
            clientKey: nil,
            clientDisplayName: nil,
            clientIconFilePath: nil
        )
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: client),
            makePacket(packetNumber: 2, sniDomainName: nil),
        ], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state, pinnedItems: [pin])
        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.app")
        let domainKey = PacketSourceDomainKey(rawValue: "api.example.com", isMissingDomain: false)
        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.2")

        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .pinned)) == .none)
        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .pinnedItem(pinID))) == .deletePin(pinID))
        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .apps)) == .none)
        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .app(appKey))) == .deletePackets(.app(appKey)))
        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .domains)) == .none)
        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .domain(domainKey))) == .deletePackets(.domain(domainKey)))
        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .domain(.ipAddresses))) == .none)
        #expect(PacketSourceListDeletionPolicy.action(for: snapshot.item(for: .ipAddress(ipKey))) == .deletePackets(.ipAddress(ipKey)))
    }

    @Test func exportPolicyAllowsNonEmptyExportableFoldersAndLeaves() {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let pinID = PacketPinID(rawValue: "domain:api.example.com")
        let pin = PacketPin(
            id: pinID,
            kind: .domain,
            title: "api.example.com",
            createdAt: Date(timeIntervalSince1970: 10),
            domain: "api.example.com",
            ipAddress: nil,
            clientKey: nil,
            clientDisplayName: nil,
            clientIconFilePath: nil
        )
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: client),
            makePacket(packetNumber: 2, sniDomainName: nil),
        ], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state, pinnedItems: [pin], savedPacketCount: 1)
        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.app")
        let domainKey = PacketSourceDomainKey(rawValue: "api.example.com", isMissingDomain: false)

        #expect(PacketSourceListExportPolicy.selection(for: snapshot.item(for: .pinned)) == .pinned)
        #expect(PacketSourceListExportPolicy.selection(for: snapshot.item(for: .pinnedItem(pinID))) == .pinnedItem(pinID))
        #expect(PacketSourceListExportPolicy.selection(for: snapshot.item(for: .saved)) == .saved)
        #expect(PacketSourceListExportPolicy.selection(for: snapshot.item(for: .apps)) == .apps)
        #expect(PacketSourceListExportPolicy.selection(for: snapshot.item(for: .app(appKey))) == .app(appKey))
        #expect(PacketSourceListExportPolicy.selection(for: snapshot.item(for: .domains)) == .domains)
        #expect(PacketSourceListExportPolicy.selection(for: snapshot.item(for: .domain(domainKey))) == .domain(domainKey))
        #expect(PacketSourceListExportPolicy.selection(for: PacketSourceListSnapshot.empty.item(for: .saved)) == nil)
    }

    @Test func finderPolicyRevealsOnlyAppBackedRowsWithAbsolutePaths() throws {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let clientPin = makeClientPin(displayName: "Example", key: "bundleIdentifier:com.example.app")
        var state = PacketIngestState.empty
        state.append([makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: client)], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state, pinnedItems: [clientPin])
        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.app")
        let domainKey = PacketSourceDomainKey(rawValue: "api.example.com", isMissingDomain: false)
        let relativeAppItem = PacketSourceListItem(
            id: "app:relative",
            title: "Relative",
            systemImageName: "app",
            iconFilePath: "Applications/Relative.app",
            count: 1,
            kind: .app,
            selection: .app(PacketSourceClientKey(rawValue: "relative")),
            children: []
        )

        #expect(PacketSourceListFinderPolicy.fileURL(for: snapshot.item(for: .app(appKey)))?.path == "/Applications/Example.app")
        #expect(PacketSourceListFinderPolicy.fileURL(for: snapshot.item(for: .pinnedItem(clientPin.id)))?.path == "/Applications/Example.app")
        #expect(PacketSourceListFinderPolicy.fileURL(for: snapshot.item(for: .appDomain(appKey, domainKey))) == nil)
        #expect(PacketSourceListFinderPolicy.fileURL(for: relativeAppItem) == nil)
    }

    @Test func pinPolicyExtractsOnlyAppAndRealDomainTargets() throws {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: client),
            makePacket(packetNumber: 2, sniDomainName: nil),
        ], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state)
        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.app")
        let domainKey = PacketSourceDomainKey(rawValue: "api.example.com", isMissingDomain: false)
        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.2")
        let items = [
            try #require(snapshot.item(for: .apps)),
            try #require(snapshot.item(for: .app(appKey))),
            try #require(snapshot.item(for: .domains)),
            try #require(snapshot.item(for: .domain(domainKey))),
            try #require(snapshot.item(for: .domain(.ipAddresses))),
            try #require(snapshot.item(for: .ipAddress(ipKey))),
        ]

        let targets = PacketSourceListPinPolicy.targets(for: items)

        #expect(targets == [
            .client(PacketSourceClientIdentity(
                key: appKey,
                displayName: "Example",
                iconFilePath: "/Applications/Example.app"
            )),
            .domain(PacketSourceDomainIdentity(
                key: domainKey,
                displayName: "api.example.com"
            )),
        ])
    }

    @Test func pinnedCountsUpdateForAppendsAndMetadataChanges() {
        let service = PacketSourceListService()
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let appPin = makeClientPin(displayName: "Example", key: "bundleIdentifier:com.example.app")
        let domainPin = makeDomainPin("api.example.com")
        var state = PacketIngestState.empty
        let unresolved = makePacket(packetNumber: 1)
        state.append([unresolved], source: .live)

        var snapshot = service.snapshot(for: state, pinnedItems: [appPin, domainPin])
        #expect(snapshot.item(for: .pinnedItem(appPin.id))?.count == 0)
        #expect(snapshot.item(for: .pinnedItem(domainPin.id))?.count == 0)

        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [unresolved.id],
                sniDomainName: "api.example.com",
                client: client,
                direction: .outbound
            )
        ])
        snapshot = service.snapshot(for: state, pinnedItems: [appPin, domainPin])
        #expect(snapshot.item(for: .pinnedItem(appPin.id))?.count == 1)
        #expect(snapshot.item(for: .pinnedItem(domainPin.id))?.count == 1)

        state.append([makePacket(packetNumber: 2, sniDomainName: "api.example.com", client: client)], source: .live)
        snapshot = service.snapshot(for: state, pinnedItems: [appPin, domainPin])
        #expect(snapshot.item(for: .pinnedItem(appPin.id))?.count == 2)
        #expect(snapshot.item(for: .pinnedItem(domainPin.id))?.count == 2)
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

    @Test func clientIdentityKeepsKeyButUsesResolvedIconPath() throws {
        let executablePath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/123.0.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let client = makeClient(
            displayName: "Google Chrome Helper",
            name: "Google Chrome Helper",
            bundleIdentifier: "com.google.Chrome.helper",
            bundlePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/123.0.0/Helpers/Google Chrome Helper.app",
            executablePath: executablePath
        )
        let packet = makePacket(packetNumber: 1, client: client)

        let identity = try #require(PacketSourceListClassifier.clientIdentity(for: packet))

        #expect(identity.key.rawValue == "bundleIdentifier:com.google.Chrome.helper")
        #expect(identity.iconFilePath == "/Applications/Google Chrome.app")
    }

    @Test func pinnedClientRowsNormalizeStoredNestedIconPath() {
        let pinID = PacketPinID(rawValue: "client:bundleIdentifier:com.google.Chrome.helper")
        let pin = PacketPin(
            id: pinID,
            kind: .client,
            title: "Google Chrome Helper",
            createdAt: Date(timeIntervalSince1970: 10),
            domain: nil,
            ipAddress: nil,
            clientKey: "bundleIdentifier:com.google.Chrome.helper",
            clientDisplayName: "Google Chrome Helper",
            clientIconFilePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/123.0.0/Helpers/Google Chrome Helper.app"
        )

        let snapshot = PacketSourceListService().snapshot(for: .empty, pinnedItems: [pin])

        #expect(snapshot.item(for: .pinnedItem(pinID))?.iconFilePath == "/Applications/Google Chrome.app")
    }

    @Test func pinnedClientRowsMirrorScopedAppChildren() throws {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let pin = makeClientPin(displayName: "Example", key: "bundleIdentifier:com.example.app")
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: client),
            makePacket(packetNumber: 2, sniDomainName: nil, client: client, sourceAddress: "10.0.0.3", destinationAddress: "10.0.0.4"),
        ], source: .live)

        let snapshot = PacketSourceListService().snapshot(for: state, pinnedItems: [pin])
        let pinItem = try #require(snapshot.item(for: .pinnedItem(pin.id)))
        let apiKey = domainKey("api.example.com")
        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.4")

        #expect(pinItem.children.map(\.title) == ["api.example.com", "IP Addresses"])
        #expect(snapshot.item(for: .pinnedItemDomain(pin.id, apiKey))?.count == 1)
        #expect(snapshot.item(for: .pinnedItemDomain(pin.id, .ipAddresses))?.children.map(\.title) == ["10.0.0.4", "10.0.0.3"])
        #expect(snapshot.item(for: .pinnedItemIPAddress(pin.id, ipKey))?.count == 1)
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
            PacketMetadataUpdate(packetIDs: [packet.id], sniDomainName: "api.example.com", client: client, direction: .outbound)
        ])
        snapshot = service.snapshot(for: state)
        #expect(snapshot.item(for: .apps)?.children.map(\.title) == ["Example"])
        #expect(snapshot.item(for: .domains)?.children.map(\.title) == ["api.example.com"])

        state.replace(with: [], source: .live)
        snapshot = service.snapshot(for: state)
        #expect(snapshot.item(for: .apps)?.children.isEmpty == true)
        #expect(snapshot.item(for: .domains)?.children.isEmpty == true)
    }

    @Test func metadataUpdateMovesPacketBetweenDomainBucketsWithoutFullRebuild() {
        let service = PacketSourceListService()
        var state = PacketIngestState.empty
        let unresolved = makePacket(packetNumber: 1)
        let alreadyResolved = makePacket(packetNumber: 2, sniDomainName: "stable.example.com")
        state.append([unresolved, alreadyResolved], source: .live)

        var snapshot = service.snapshot(for: state)
        #expect(snapshot.item(for: .domain(.ipAddresses))?.count == 1)
        #expect(snapshot.item(for: .domain(domainKey("stable.example.com")))?.count == 1)

        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [unresolved.id],
                sniDomainName: "api.example.com",
                client: nil,
                direction: nil
            )
        ])
        snapshot = service.snapshot(for: state)

        // The previously-unresolved packet leaves the IP-Addresses bucket and joins a new domain
        // bucket; the unrelated packet's bucket count stays put.
        #expect(snapshot.item(for: .domain(.ipAddresses)) == nil)
        #expect(snapshot.item(for: .domain(domainKey("api.example.com")))?.count == 1)
        #expect(snapshot.item(for: .domain(domainKey("stable.example.com")))?.count == 1)
    }

    @Test func metadataUpdateMovesPacketIntoAppBucketIncrementally() {
        let service = PacketSourceListService()
        var state = PacketIngestState.empty
        let firstUnresolved = makePacket(packetNumber: 1)
        let secondUnresolved = makePacket(packetNumber: 2)
        state.append([firstUnresolved, secondUnresolved], source: .live)

        _ = service.snapshot(for: state)

        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [firstUnresolved.id],
                sniDomainName: nil,
                client: client,
                direction: .outbound
            )
        ])
        let snapshot = service.snapshot(for: state)

        #expect(snapshot.item(for: .apps)?.children.map(\.title) == ["Example"])
        #expect(snapshot.item(for: .apps)?.children.first?.count == 1)
    }

    @Test func metadataUpdateMovesPacketBetweenScopedAppBucketsIncrementally() {
        let service = PacketSourceListService()
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.app")
        var state = PacketIngestState.empty
        let unresolved = makePacket(packetNumber: 1, sniDomainName: nil, client: client)
        let stable = makePacket(packetNumber: 2, sniDomainName: "stable.example.com", client: client)
        state.append([unresolved, stable], source: .live)

        var snapshot = service.snapshot(for: state)
        #expect(snapshot.item(for: .appDomain(appKey, .ipAddresses))?.count == 1)
        #expect(snapshot.item(for: .appDomain(appKey, domainKey("stable.example.com")))?.count == 1)

        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [unresolved.id],
                sniDomainName: "api.example.com",
                client: client,
                direction: .outbound
            )
        ])
        snapshot = service.snapshot(for: state)

        #expect(snapshot.item(for: .appDomain(appKey, .ipAddresses)) == nil)
        #expect(snapshot.item(for: .appDomain(appKey, domainKey("api.example.com")))?.count == 1)
        #expect(snapshot.item(for: .appDomain(appKey, domainKey("stable.example.com")))?.count == 1)
    }

    @Test func appendAfterMetadataResolutionPicksUpResolvedBucketsWithoutDoubleCounting() {
        let service = PacketSourceListService()
        var state = PacketIngestState.empty
        let firstPacket = makePacket(packetNumber: 1)
        state.append([firstPacket], source: .live)
        _ = service.snapshot(for: state)

        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        state.applyMetadataUpdates([
            PacketMetadataUpdate(
                packetIDs: [firstPacket.id],
                sniDomainName: "api.example.com",
                client: client,
                direction: .outbound
            )
        ])
        _ = service.snapshot(for: state)

        let secondPacket = makePacket(packetNumber: 2, sniDomainName: "api.example.com", client: client)
        state.append([secondPacket], source: .live)
        let snapshot = service.snapshot(for: state)

        #expect(snapshot.item(for: .domain(domainKey("api.example.com")))?.count == 2)
        #expect(snapshot.item(for: .apps)?.children.first?.count == 2)
    }

    private func domainKey(_ name: String) -> PacketSourceDomainKey {
        PacketSourceDomainKey(rawValue: name.lowercased(), isMissingDomain: false)
    }

    private func makeDomainPin(_ domain: String) -> PacketPin {
        PacketPin(
            id: PacketPinID(rawValue: "domain:\(domain)"),
            kind: .domain,
            title: domain,
            createdAt: Date(timeIntervalSince1970: 10),
            domain: domain,
            ipAddress: nil,
            clientKey: nil,
            clientDisplayName: nil,
            clientIconFilePath: nil
        )
    }

    private func makeClientPin(displayName: String, key: String) -> PacketPin {
        PacketPin(
            id: PacketPinID(rawValue: "client:\(key)"),
            kind: .client,
            title: displayName,
            createdAt: Date(timeIntervalSince1970: 10),
            domain: nil,
            ipAddress: nil,
            clientKey: key,
            clientDisplayName: displayName,
            clientIconFilePath: "/Applications/\(displayName).app"
        )
    }

    @Test func filteringKeepsMatchingDescendantsAndAncestors() {
        var state = PacketIngestState.empty
        state.append([
            makePacket(packetNumber: 1, sniDomainName: "api.example.com", client: makeClient(displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")),
            makePacket(packetNumber: 2, sniDomainName: "openai.com", client: makeClient(displayName: "TCP Viewer", bundleIdentifier: "com.proxyman.tcpviewer")),
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
        client: PacketClient? = nil,
        sourceAddress: String = "10.0.0.1",
        destinationAddress: String = "10.0.0.2"
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: 1234),
                destination: PacketEndpoint(address: destinationAddress, port: 443)
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
