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

struct PacketSourceIPAddressKey: Hashable, Sendable {
    let rawValue: String
}

enum PacketSourceListSelection: Hashable, Sendable {
    case allPackets
    case pinned
    case pinnedItem(PacketPinID)
    case saved
    case apps
    case app(PacketSourceClientKey)
    case domains
    case domain(PacketSourceDomainKey)
    case ipAddress(PacketSourceIPAddressKey)
}

enum PacketSourceListItemKind: Hashable, Sendable {
    case group
    case favorite
    case folder
    case app
    case domain
    case pin
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

    static let empty = PacketSourceListSnapshot(
        roots: PacketSourceListTreeBuilder.makeRoots(
            appBuckets: [],
            domainBuckets: [],
            ipAddressBuckets: [],
            pinnedBuckets: [],
            savedPacketCount: 0
        )
    )

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

struct PacketSourceIPAddressIdentity: Hashable, Sendable {
    let key: PacketSourceIPAddressKey
    let displayName: String
}

enum PacketSourceListDeletionAction: Equatable, Sendable {
    case none
    case deletePin(PacketPinID)
    case deletePackets(PacketSourceListSelection)

    var isEnabled: Bool {
        self != .none
    }
}

enum PacketSourceListExportPolicy {
    static func selection(for item: PacketSourceListItem?) -> PacketSourceListSelection? {
        guard let item,
              let selection = item.selection,
              item.count ?? 0 > 0 else {
            return nil
        }

        switch selection {
        case .pinned, .pinnedItem, .saved, .apps, .app, .domains, .domain, .ipAddress:
            return selection
        case .allPackets:
            return nil
        }
    }
}

enum PacketSourceListDeletionPolicy {
    static func action(for item: PacketSourceListItem?) -> PacketSourceListDeletionAction {
        guard let selection = item?.selection else {
            return .none
        }

        switch selection {
        case .pinnedItem(let pinID):
            return .deletePin(pinID)
        case .app, .ipAddress:
            return .deletePackets(selection)
        case .domain(let key) where !key.isMissingDomain:
            return .deletePackets(selection)
        default:
            return .none
        }
    }
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
            iconFilePath: PacketClientIconPathResolver.iconFilePath(for: client)
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

    static func ipAddressIdentities(for packet: PacketSummary) -> [PacketSourceIPAddressIdentity] {
        guard domainIdentity(for: packet).key.isMissingDomain else {
            return []
        }

        var seenKeys = Set<PacketSourceIPAddressKey>()
        return [
            trimmed(packet.endpoints.destination.address),
            trimmed(packet.endpoints.source.address),
        ].compactMap { address in
            guard let address else {
                return nil
            }

            let key = PacketSourceIPAddressKey(rawValue: address.lowercased())
            guard seenKeys.insert(key).inserted else {
                return nil
            }

            return PacketSourceIPAddressIdentity(
                key: key,
                displayName: address
            )
        }
    }

    static func matches(_ packet: PacketSummary, selection: PacketSourceListSelection) -> Bool {
        switch selection {
        case .allPackets:
            return true
        case .pinned, .pinnedItem, .saved:
            return false
        case .apps:
            return clientIdentity(for: packet) != nil
        case .app(let key):
            return clientIdentity(for: packet)?.key == key
        case .domains:
            return true
        case .domain(let key):
            return domainIdentity(for: packet).key == key
        case .ipAddress(let key):
            return ipAddressIdentities(for: packet).contains { $0.key == key }
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
    private var ipAddressBuckets: [PacketSourceIPAddressKey: PacketSourceListTreeBuilder.IPAddressBucket] = [:]
    private var ipAddressOrder: [PacketSourceIPAddressKey] = []
    private var pinnedItems: [PacketPin] = []
    private var savedPacketCount = 0

    func reset() {
        packetRevision = nil
        packetLineageRevision = nil
        sourcePacketCount = 0
        cachedSnapshot = .empty
        appBuckets.removeAll(keepingCapacity: false)
        appOrder.removeAll(keepingCapacity: false)
        domainBuckets.removeAll(keepingCapacity: false)
        domainOrder.removeAll(keepingCapacity: false)
        ipAddressBuckets.removeAll(keepingCapacity: false)
        ipAddressOrder.removeAll(keepingCapacity: false)
        pinnedItems = []
        savedPacketCount = 0
    }

    #if DEBUG
    func debugMemorySnapshot() -> PacketSourceListDebugSnapshot {
        PacketSourceListDebugSnapshot(
            appBucketCount: appBuckets.count,
            domainBucketCount: domainBuckets.count
        )
    }
    #endif

    // Keep the tree in sync with packet mutations, using append when packet lineage is unchanged.
    func snapshot(
        for ingestState: PacketIngestState,
        pinnedItems: [PacketPin] = [],
        savedPacketCount: Int = 0
    ) -> PacketSourceListSnapshot {
        guard packetRevision != ingestState.packetRevision ||
                self.pinnedItems != pinnedItems ||
                self.savedPacketCount != savedPacketCount else {
            return cachedSnapshot
        }

        self.pinnedItems = pinnedItems
        self.savedPacketCount = savedPacketCount

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
        ipAddressBuckets = [:]
        ipAddressOrder = []
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

                appBuckets[clientIdentity.key]?.packetCount += 1
            }

            let domainIdentity = PacketSourceListClassifier.domainIdentity(for: packet)
            if domainBuckets[domainIdentity.key] == nil {
                domainOrder.append(domainIdentity.key)
                domainBuckets[domainIdentity.key] = PacketSourceListTreeBuilder.DomainBucket(identity: domainIdentity)
            }

            domainBuckets[domainIdentity.key]?.packetCount += 1

            for ipAddressIdentity in PacketSourceListClassifier.ipAddressIdentities(for: packet) {
                if ipAddressBuckets[ipAddressIdentity.key] == nil {
                    ipAddressOrder.append(ipAddressIdentity.key)
                    ipAddressBuckets[ipAddressIdentity.key] = PacketSourceListTreeBuilder.IPAddressBucket(identity: ipAddressIdentity)
                }

                ipAddressBuckets[ipAddressIdentity.key]?.packetCount += 1
            }
        }
    }

    private func storeSnapshot(for ingestState: PacketIngestState) -> PacketSourceListSnapshot {
        packetRevision = ingestState.packetRevision
        packetLineageRevision = ingestState.packetLineageRevision
        sourcePacketCount = ingestState.packets.count
        cachedSnapshot = PacketSourceListTreeBuilder.makeSnapshot(
            appBuckets: appOrder.compactMap { appBuckets[$0] },
            domainBuckets: domainOrder.compactMap { domainBuckets[$0] },
            ipAddressBuckets: ipAddressOrder.compactMap { ipAddressBuckets[$0] },
            pinnedBuckets: pinnedItems.map { pin in
                PacketSourceListTreeBuilder.PinnedBucket(
                    pin: pin,
                    packetCount: ingestState.packets.reduce(into: 0) { count, packet in
                        if PacketPinMatcher.matches(packet, pin: pin) {
                            count += 1
                        }
                    }
                )
            },
            savedPacketCount: savedPacketCount
        )
        return cachedSnapshot
    }
}

#if DEBUG
struct PacketSourceListDebugSnapshot: Equatable {
    let appBucketCount: Int
    let domainBucketCount: Int
}
#endif

enum PacketSourceListTreeBuilder {
    struct AppBucket: Equatable, Sendable {
        let identity: PacketSourceClientIdentity
        var packetCount = 0
    }

    struct DomainBucket: Equatable, Sendable {
        let identity: PacketSourceDomainIdentity
        var packetCount = 0
    }

    struct IPAddressBucket: Equatable, Sendable {
        let identity: PacketSourceIPAddressIdentity
        var packetCount = 0
    }

    struct PinnedBucket: Equatable, Sendable {
        let pin: PacketPin
        var packetCount = 0
    }

    static let favoritesGroupID = "group:favorites"
    static let allGroupID = "group:all"
    static let pinnedFolderID = "favorite:pinned"
    static let appsFolderID = "folder:apps"
    static let domainsFolderID = "folder:domains"

    static let defaultExpandedItemIDs: Set<String> = [
        favoritesGroupID,
        allGroupID,
        pinnedFolderID,
        appsFolderID,
        domainsFolderID,
    ]

    static func makeSnapshot(
        appBuckets: [AppBucket],
        domainBuckets: [DomainBucket],
        ipAddressBuckets: [IPAddressBucket] = [],
        pinnedBuckets: [PinnedBucket] = [],
        savedPacketCount: Int = 0
    ) -> PacketSourceListSnapshot {
        PacketSourceListSnapshot(
            roots: makeRoots(
                appBuckets: appBuckets,
                domainBuckets: domainBuckets,
                ipAddressBuckets: ipAddressBuckets,
                pinnedBuckets: pinnedBuckets,
                savedPacketCount: savedPacketCount
            )
        )
    }

    static func makeRoots(
        appBuckets: [AppBucket],
        domainBuckets: [DomainBucket],
        ipAddressBuckets: [IPAddressBucket] = [],
        pinnedBuckets: [PinnedBucket] = [],
        savedPacketCount: Int = 0
    ) -> [PacketSourceListItem] {
        let appItems = appBuckets.map { bucket in
            PacketSourceListItem(
                id: "app:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                systemImageName: "app",
                iconFilePath: bucket.identity.iconFilePath,
                count: bucket.packetCount,
                kind: .app,
                selection: .app(bucket.identity.key),
                children: []
            )
        }
        let ipAddressItems = ipAddressBuckets.map { bucket in
            PacketSourceListItem(
                id: "ip:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                systemImageName: "network",
                iconFilePath: nil,
                count: bucket.packetCount,
                kind: .domain,
                selection: .ipAddress(bucket.identity.key),
                children: []
            )
        }
        let domainItems = domainBuckets.map { bucket in
            PacketSourceListItem(
                id: "domain:\(bucket.identity.key.rawValue)",
                title: bucket.identity.displayName,
                systemImageName: "network",
                iconFilePath: nil,
                count: bucket.packetCount,
                kind: .domain,
                selection: .domain(bucket.identity.key),
                children: bucket.identity.key.isMissingDomain ? ipAddressItems : []
            )
        }
        let pinnedItems = pinnedBuckets.map { bucket in
            PacketSourceListItem(
                id: "pin:\(bucket.pin.id.rawValue)",
                title: bucket.pin.title,
                systemImageName: systemImageName(for: bucket.pin),
                iconFilePath: PacketClientIconPathResolver.iconFilePath(
                    bundlePath: bucket.pin.clientIconFilePath,
                    executablePath: nil
                ),
                count: bucket.packetCount,
                kind: .pin,
                selection: .pinnedItem(bucket.pin.id),
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
                        id: pinnedFolderID,
                        title: "Pinned",
                        systemImageName: "pin.fill",
                        iconFilePath: nil,
                        count: pinnedBuckets.reduce(0) { $0 + $1.packetCount },
                        kind: .folder,
                        selection: .pinned,
                        children: pinnedItems
                    ),
                    PacketSourceListItem(
                        id: "favorite:saved",
                        title: "Saved",
                        systemImageName: "tray.and.arrow.down",
                        iconFilePath: nil,
                        count: savedPacketCount,
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
                        count: appBuckets.reduce(0) { $0 + $1.packetCount },
                        kind: .folder,
                        selection: .apps,
                        children: appItems
                    ),
                    PacketSourceListItem(
                        id: domainsFolderID,
                        title: "Domains",
                        systemImageName: "globe",
                        iconFilePath: nil,
                        count: domainBuckets.reduce(0) { $0 + $1.packetCount },
                        kind: .folder,
                        selection: .domains,
                        children: domainItems
                    ),
                ]
            ),
        ]
    }

    private static func systemImageName(for pin: PacketPin) -> String {
        switch pin.kind {
        case .domain:
            return "globe"
        case .ip:
            return "network"
        case .client:
            return "app"
        }
    }
}
