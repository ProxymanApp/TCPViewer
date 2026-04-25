import Foundation
import PcapPlusPlusCore

struct PacketSourceClientKey: Hashable, Sendable {
    let rawValue: String
}

struct PacketSourceDomainKey: Hashable, Sendable {
    let rawValue: String
    let isMissingDomain: Bool

    static let ipAddresses = PacketSourceDomainKey(rawValue: "ip-addresses", isMissingDomain: true)
}

enum PacketSourceListSelection: Hashable, Sendable {
    case allPackets
    case pinned
    case saved
    case apps
    case app(PacketSourceClientKey)
    case domains
    case domain(PacketSourceDomainKey)
}

enum PacketSourceListItemKind: Hashable, Sendable {
    case group
    case favorite
    case folder
    case app
    case domain
}

struct PacketSourceListItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemImageName: String?
    let iconFilePath: String?
    let count: Int?
    let kind: PacketSourceListItemKind
    let selection: PacketSourceListSelection?
    let children: [PacketSourceListItem]

    var isGroup: Bool {
        kind == .group
    }

    var countText: String? {
        guard let count, count > 0 else {
            return nil
        }

        return "\(count)"
    }
}

struct PacketSourceListSnapshot: Equatable, Sendable {
    let roots: [PacketSourceListItem]

    static let empty = PacketSourceListSnapshot(roots: PacketSourceListTreeBuilder.makeRoots(
        appBuckets: [],
        domainBuckets: []
    ))

    // Return a display-only filtered tree while preserving ancestors for matching children.
    func filtered(matching filterText: String) -> PacketSourceListSnapshot {
        let normalizedFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFilter.isEmpty else {
            return self
        }

        return PacketSourceListSnapshot(roots: roots.compactMap { item in
            Self.filtered(item: item, matching: normalizedFilter)
        })
    }

    func contains(selection: PacketSourceListSelection) -> Bool {
        if selection == .allPackets {
            return true
        }

        return item(for: selection) != nil
    }

    func item(for selection: PacketSourceListSelection) -> PacketSourceListItem? {
        firstItem { $0.selection == selection }
    }

    func firstItem(where matches: (PacketSourceListItem) -> Bool) -> PacketSourceListItem? {
        for root in roots {
            if let item = root.firstItem(where: matches) {
                return item
            }
        }

        return nil
    }

    private static func filtered(item: PacketSourceListItem, matching filterText: String) -> PacketSourceListItem? {
        if item.title.localizedCaseInsensitiveContains(filterText) {
            return item
        }

        let filteredChildren = item.children.compactMap { child in
            filtered(item: child, matching: filterText)
        }
        guard !filteredChildren.isEmpty else {
            return nil
        }

        return PacketSourceListItem(
            id: item.id,
            title: item.title,
            systemImageName: item.systemImageName,
            iconFilePath: item.iconFilePath,
            count: item.count,
            kind: item.kind,
            selection: item.selection,
            children: filteredChildren
        )
    }
}

extension PacketSourceListItem {
    func firstItem(where matches: (PacketSourceListItem) -> Bool) -> PacketSourceListItem? {
        if matches(self) {
            return self
        }

        for child in children {
            if let item = child.firstItem(where: matches) {
                return item
            }
        }

        return nil
    }
}

struct PacketSourceClientIdentity: Hashable, Sendable {
    let key: PacketSourceClientKey
    let displayName: String
    let iconFilePath: String?
}

struct PacketSourceDomainIdentity: Hashable, Sendable {
    let key: PacketSourceDomainKey
    let displayName: String
}

enum PacketSourceListClassifier {
    static func clientIdentity(for packet: PacketSummary) -> PacketSourceClientIdentity? {
        guard let client = packet.client else {
            return nil
        }

        guard let identityValue = firstNonEmpty([
            client.bundleIdentifier,
            client.bundlePath,
            client.executablePath,
            client.displayName,
            client.name,
        ]) else {
            return nil
        }

        guard let displayName = firstNonEmpty([client.displayName, client.name, identityValue]) else {
            return nil
        }

        let keyPrefix: String
        if trimmed(client.bundleIdentifier) != nil {
            keyPrefix = "bundleIdentifier"
        } else if trimmed(client.bundlePath) != nil {
            keyPrefix = "bundlePath"
        } else if trimmed(client.executablePath) != nil {
            keyPrefix = "executablePath"
        } else if trimmed(client.displayName) != nil {
            keyPrefix = "displayName"
        } else {
            keyPrefix = "name"
        }

        return PacketSourceClientIdentity(
            key: PacketSourceClientKey(rawValue: "\(keyPrefix):\(identityValue)"),
            displayName: displayName,
            iconFilePath: firstNonEmpty([client.bundlePath, client.executablePath])
        )
    }

    static func domainIdentity(for packet: PacketSummary) -> PacketSourceDomainIdentity {
        guard let domainName = trimmed(packet.sniDomainName) else {
            return PacketSourceDomainIdentity(key: .ipAddresses, displayName: "IP Addresses")
        }

        return PacketSourceDomainIdentity(
            key: PacketSourceDomainKey(rawValue: domainName.lowercased(), isMissingDomain: false),
            displayName: domainName
        )
    }

    static func matches(_ packet: PacketSummary, selection: PacketSourceListSelection) -> Bool {
        switch selection {
        case .allPackets:
            return true
        case .pinned, .saved:
            return false
        case .apps:
            return clientIdentity(for: packet) != nil
        case .app(let key):
            return clientIdentity(for: packet)?.key == key
        case .domains:
            return true
        case .domain(let key):
            return domainIdentity(for: packet).key == key
        }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.lazy.compactMap(trimmed).first
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

final class PacketSourceListService {
    private var packetRevision: UInt64?
    private var packetLineageRevision: UInt64?
    private var sourcePacketCount = 0
    private var cachedSnapshot = PacketSourceListSnapshot.empty
    private var appBuckets: [PacketSourceClientKey: PacketSourceListTreeBuilder.AppBucket] = [:]
    private var appOrder: [PacketSourceClientKey] = []
    private var domainBuckets: [PacketSourceDomainKey: PacketSourceListTreeBuilder.DomainBucket] = [:]
    private var domainOrder: [PacketSourceDomainKey] = []

    // Keep the tree in sync with packet mutations, using append when packet lineage is unchanged.
    func snapshot(for ingestState: PacketIngestState) -> PacketSourceListSnapshot {
        guard packetRevision != ingestState.packetRevision else {
            return cachedSnapshot
        }

        if packetLineageRevision == ingestState.packetLineageRevision,
           sourcePacketCount <= ingestState.packets.count,
           case .append = ingestState.lastMutation {
            return appendSnapshot(from: ingestState)
        }

        return rebuildSnapshot(from: ingestState)
    }

    private func rebuildSnapshot(from ingestState: PacketIngestState) -> PacketSourceListSnapshot {
        appBuckets = [:]
        appOrder = []
        domainBuckets = [:]
        domainOrder = []
        appendPackets(ingestState.packets)
        return storeSnapshot(for: ingestState)
    }

    private func appendSnapshot(from ingestState: PacketIngestState) -> PacketSourceListSnapshot {
        appendPackets(Array(ingestState.packets[sourcePacketCount...]))
        return storeSnapshot(for: ingestState)
    }

    private func appendPackets(_ packets: [PacketSummary]) {
        for packet in packets {
            if let clientIdentity = PacketSourceListClassifier.clientIdentity(for: packet) {
                if appBuckets[clientIdentity.key] == nil {
                    appOrder.append(clientIdentity.key)
                    appBuckets[clientIdentity.key] = PacketSourceListTreeBuilder.AppBucket(identity: clientIdentity)
                }

                appBuckets[clientIdentity.key]?.packetIDs.append(packet.id)
            }

            let domainIdentity = PacketSourceListClassifier.domainIdentity(for: packet)
            if domainBuckets[domainIdentity.key] == nil {
                domainOrder.append(domainIdentity.key)
                domainBuckets[domainIdentity.key] = PacketSourceListTreeBuilder.DomainBucket(identity: domainIdentity)
            }

            domainBuckets[domainIdentity.key]?.packetIDs.append(packet.id)
        }
    }

    private func storeSnapshot(for ingestState: PacketIngestState) -> PacketSourceListSnapshot {
        packetRevision = ingestState.packetRevision
        packetLineageRevision = ingestState.packetLineageRevision
        sourcePacketCount = ingestState.packets.count
        cachedSnapshot = PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: appOrder.compactMap { appBuckets[$0] },
            domainBuckets: domainOrder.compactMap { domainBuckets[$0] }
        )
        return cachedSnapshot
    }
}

enum PacketSourceListTreeBuilder {
    struct AppBucket: Equatable, Sendable {
        let identity: PacketSourceClientIdentity
        var packetIDs: [PacketSummary.ID] = []
    }

    struct DomainBucket: Equatable, Sendable {
        let identity: PacketSourceDomainIdentity
        var packetIDs: [PacketSummary.ID] = []
    }

    static let favoritesGroupID = "group:favorites"
    static let allGroupID = "group:all"
    static let appsFolderID = "folder:apps"
    static let domainsFolderID = "folder:domains"

    static let defaultExpandedItemIDs: Set<String> = [
        favoritesGroupID,
        allGroupID,
        appsFolderID,
        domainsFolderID,
    ]

    static func makeSnapshot(appBuckets: [AppBucket], domainBuckets: [DomainBucket]) -> PacketSourceListSnapshot {
        PacketSourceListSnapshot(roots: makeRoots(appBuckets: appBuckets, domainBuckets: domainBuckets))
    }

    static func makeRoots(appBuckets: [AppBucket], domainBuckets: [DomainBucket]) -> [PacketSourceListItem] {
        let appItems = appBuckets.map { bucket in
            PacketSourceListItem(
                id: "app:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                systemImageName: "app",
                iconFilePath: bucket.identity.iconFilePath,
                count: bucket.packetIDs.count,
                kind: .app,
                selection: .app(bucket.identity.key),
                children: []
            )
        }
        let domainItems = domainBuckets.map { bucket in
            PacketSourceListItem(
                id: "domain:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                systemImageName: "network",
                iconFilePath: nil,
                count: bucket.packetIDs.count,
                kind: .domain,
                selection: .domain(bucket.identity.key),
                children: []
            )
        }

        return [
            PacketSourceListItem(
                id: favoritesGroupID,
                title: "Favorites",
                systemImageName: nil,
                iconFilePath: nil,
                count: nil,
                kind: .group,
                selection: nil,
                children: [
                    PacketSourceListItem(
                        id: "favorite:pinned",
                        title: "Pinned",
                        systemImageName: "pin.fill",
                        iconFilePath: nil,
                        count: nil,
                        kind: .favorite,
                        selection: .pinned,
                        children: []
                    ),
                    PacketSourceListItem(
                        id: "favorite:saved",
                        title: "Saved",
                        systemImageName: "tray.and.arrow.down",
                        iconFilePath: nil,
                        count: nil,
                        kind: .favorite,
                        selection: .saved,
                        children: []
                    ),
                ]
            ),
            PacketSourceListItem(
                id: allGroupID,
                title: "All",
                systemImageName: nil,
                iconFilePath: nil,
                count: nil,
                kind: .group,
                selection: nil,
                children: [
                    PacketSourceListItem(
                        id: appsFolderID,
                        title: "Apps",
                        systemImageName: "folder.fill",
                        iconFilePath: nil,
                        count: appBuckets.reduce(0) { $0 + $1.packetIDs.count },
                        kind: .folder,
                        selection: .apps,
                        children: appItems
                    ),
                    PacketSourceListItem(
                        id: domainsFolderID,
                        title: "Domains",
                        systemImageName: "globe",
                        iconFilePath: nil,
                        count: domainBuckets.reduce(0) { $0 + $1.packetIDs.count },
                        kind: .folder,
                        selection: .domains,
                        children: domainItems
                    ),
                ]
            ),
        ]
    }
}
