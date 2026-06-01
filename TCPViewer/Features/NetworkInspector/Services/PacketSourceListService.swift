//
//  PacketSourceListService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

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
    case pinnedItemDomain(PacketPinID, PacketSourceDomainKey)
    case pinnedItemIPAddress(PacketPinID, PacketSourceIPAddressKey)
    case saved
    case apps
    case app(PacketSourceClientKey)
    case appDomain(PacketSourceClientKey, PacketSourceDomainKey)
    case appIPAddress(PacketSourceClientKey, PacketSourceIPAddressKey)
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

enum PacketSourceListPinTarget: Hashable, Sendable {
    case client(PacketSourceClientIdentity)
    case domain(PacketSourceDomainIdentity)
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
        case .pinned, .pinnedItem, .pinnedItemDomain, .pinnedItemIPAddress,
                .saved, .apps, .app, .appDomain, .appIPAddress, .domains, .domain, .ipAddress:
            return selection
        case .allPackets:
            return nil
        }
    }
}

enum PacketSourceListPinPolicy {
    static func targets(for items: [PacketSourceListItem]) -> [PacketSourceListPinTarget] {
        var seenTargets = Set<PacketSourceListPinTarget>()
        var targets: [PacketSourceListPinTarget] = []

        for item in items {
            guard let target = target(for: item),
                  seenTargets.insert(target).inserted else {
                continue
            }
            targets.append(target)
        }

        return targets
    }

    static func target(for item: PacketSourceListItem?) -> PacketSourceListPinTarget? {
        guard let item else {
            return nil
        }

        switch item.selection {
        case .app(let key):
            return .client(PacketSourceClientIdentity(
                key: key,
                displayName: item.title,
                iconFilePath: item.iconFilePath
            ))
        case .appDomain(_, let key) where !key.isMissingDomain:
            return .domain(PacketSourceDomainIdentity(
                key: key,
                displayName: item.title
            ))
        case .domain(let key) where !key.isMissingDomain:
            return .domain(PacketSourceDomainIdentity(
                key: key,
                displayName: item.title
            ))
        default:
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
        case .app, .appIPAddress, .pinnedItemIPAddress, .ipAddress:
            return .deletePackets(selection)
        case .appDomain(_, let key) where !key.isMissingDomain:
            return .deletePackets(selection)
        case .pinnedItemDomain(_, let key) where !key.isMissingDomain:
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
        case .appDomain(let clientKey, let domainKey):
            return clientIdentity(for: packet)?.key == clientKey &&
                domainIdentity(for: packet).key == domainKey
        case .appIPAddress(let clientKey, let ipAddressKey):
            return clientIdentity(for: packet)?.key == clientKey &&
                ipAddressIdentities(for: packet).contains { $0.key == ipAddressKey }
        case .domains:
            return true
        case .domain(let key):
            return domainIdentity(for: packet).key == key
        case .ipAddress(let key):
            return ipAddressIdentities(for: packet).contains { $0.key == key }
        case .pinnedItemDomain, .pinnedItemIPAddress:
            return false
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

enum PacketSourceListPacketMatcher {
    static func matches(
        _ packet: PacketSummary,
        selection: PacketSourceListSelection,
        pinnedItems: [PacketPin]
    ) -> Bool {
        switch selection {
        case .pinned:
            return pinnedItems.contains { PacketPinMatcher.matches(packet, pin: $0) }
        case .pinnedItem(let pinID):
            guard let pin = pinnedItems.first(where: { $0.id == pinID }) else {
                return false
            }
            return PacketPinMatcher.matches(packet, pin: pin)
        case .pinnedItemDomain(let pinID, let domainKey):
            guard let pin = pinnedItems.first(where: { $0.id == pinID }),
                  pin.kind == .client else {
                return false
            }
            return PacketPinMatcher.matches(packet, pin: pin) &&
                PacketSourceListClassifier.matches(packet, selection: .domain(domainKey))
        case .pinnedItemIPAddress(let pinID, let ipAddressKey):
            guard let pin = pinnedItems.first(where: { $0.id == pinID }),
                  pin.kind == .client else {
                return false
            }
            return PacketPinMatcher.matches(packet, pin: pin) &&
                PacketSourceListClassifier.matches(packet, selection: .ipAddress(ipAddressKey))
        case .saved:
            return true
        default:
            return PacketSourceListClassifier.matches(packet, selection: selection)
        }
    }
}

final class PacketSourceListService {
    fileprivate struct PacketBucketAssignment: Equatable {
        var appIdentity: PacketSourceClientIdentity?
        var domainIdentity: PacketSourceDomainIdentity
        var ipAddressIdentities: [PacketSourceIPAddressIdentity]
        var pinIPAddresses: Set<String>
    }

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
    private var packetAssignmentsByID: [PacketSummary.ID: PacketBucketAssignment] = [:]
    private var pinnedItems: [PacketPin] = []
    private var pinnedPacketCountsByID: [PacketPinID: Int] = [:]
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
        packetAssignmentsByID.removeAll(keepingCapacity: false)
        pinnedItems = []
        pinnedPacketCountsByID.removeAll(keepingCapacity: false)
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
        let didChangePinnedItems = self.pinnedItems != pinnedItems
        guard packetRevision != ingestState.packetRevision ||
                didChangePinnedItems ||
                self.savedPacketCount != savedPacketCount else {
            return cachedSnapshot
        }

        self.pinnedItems = pinnedItems
        self.savedPacketCount = savedPacketCount

        if packetLineageRevision == ingestState.packetLineageRevision,
           sourcePacketCount <= ingestState.packets.count {
            if didChangePinnedItems {
                rebuildPinnedCountsFromAssignments()
            }
            switch ingestState.lastMutation {
            case .append:
                return appendSnapshot(from: ingestState)
            case .appendWithMetadataUpdates(_, let updatedPacketIDs):
                appendPackets(Array(ingestState.packets[sourcePacketCount...]))
                applyMetadataUpdates(packetIDs: updatedPacketIDs, in: ingestState)
                return storeSnapshot(for: ingestState)
            case .metadataUpdate(let packetIDs):
                applyMetadataUpdates(packetIDs: packetIDs, in: ingestState)
                return storeSnapshot(for: ingestState)
            default:
                break
            }
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
        packetAssignmentsByID.removeAll(keepingCapacity: true)
        pinnedPacketCountsByID.removeAll(keepingCapacity: true)
        appendPackets(ingestState.packets)
        return storeSnapshot(for: ingestState)
    }

    private func appendSnapshot(from ingestState: PacketIngestState) -> PacketSourceListSnapshot {
        appendPackets(Array(ingestState.packets[sourcePacketCount...]))
        return storeSnapshot(for: ingestState)
    }

    private func appendPackets(_ packets: [PacketSummary]) {
        for packet in packets {
            let assignment = makeAssignment(for: packet)
            increment(for: assignment)
            packetAssignmentsByID[packet.id] = assignment
        }
    }

    private func makeAssignment(for packet: PacketSummary) -> PacketBucketAssignment {
        PacketBucketAssignment(
            appIdentity: PacketSourceListClassifier.clientIdentity(for: packet),
            domainIdentity: PacketSourceListClassifier.domainIdentity(for: packet),
            ipAddressIdentities: PacketSourceListClassifier.ipAddressIdentities(for: packet),
            pinIPAddresses: Self.pinIPAddresses(for: packet)
        )
    }

    // Apply only the assignments that actually changed for the affected packets. Each packet costs
    // a constant number of dictionary ops, regardless of total packet count.
    private func applyMetadataUpdates(packetIDs: [PacketSummary.ID], in ingestState: PacketIngestState) {
        for packetID in packetIDs {
            guard let updatedPacket = ingestState.packet(withID: packetID) else {
                continue
            }
            let newAssignment = makeAssignment(for: updatedPacket)
            if let oldAssignment = packetAssignmentsByID[packetID] {
                guard oldAssignment != newAssignment else {
                    continue
                }
                decrement(for: oldAssignment)
            }
            increment(for: newAssignment)
            packetAssignmentsByID[packetID] = newAssignment
        }
    }

    private func increment(for assignment: PacketBucketAssignment) {
        if let appIdentity = assignment.appIdentity {
            var appBucket: PacketSourceListTreeBuilder.AppBucket
            if let existingBucket = appBuckets[appIdentity.key] {
                appBucket = existingBucket
            } else {
                appOrder.append(appIdentity.key)
                appBucket = PacketSourceListTreeBuilder.AppBucket(identity: appIdentity)
            }
            appBucket.increment(
                domainIdentity: assignment.domainIdentity,
                ipAddressIdentities: assignment.ipAddressIdentities
            )
            appBuckets[appIdentity.key] = appBucket
        }

        let domainIdentity = assignment.domainIdentity
        if domainBuckets[domainIdentity.key] == nil {
            domainOrder.append(domainIdentity.key)
            domainBuckets[domainIdentity.key] = PacketSourceListTreeBuilder.DomainBucket(identity: domainIdentity)
        }
        domainBuckets[domainIdentity.key]?.packetCount += 1

        for ipAddressIdentity in assignment.ipAddressIdentities {
            if ipAddressBuckets[ipAddressIdentity.key] == nil {
                ipAddressOrder.append(ipAddressIdentity.key)
                ipAddressBuckets[ipAddressIdentity.key] = PacketSourceListTreeBuilder.IPAddressBucket(identity: ipAddressIdentity)
            }
            ipAddressBuckets[ipAddressIdentity.key]?.packetCount += 1
        }

        incrementPinnedCounts(for: assignment)
    }

    private func decrement(for assignment: PacketBucketAssignment) {
        if let appIdentity = assignment.appIdentity, var bucket = appBuckets[appIdentity.key] {
            bucket.decrement(
                domainIdentity: assignment.domainIdentity,
                ipAddressIdentities: assignment.ipAddressIdentities
            )
            if bucket.packetCount <= 0 {
                appBuckets.removeValue(forKey: appIdentity.key)
                appOrder.removeAll { $0 == appIdentity.key }
            } else {
                appBuckets[appIdentity.key] = bucket
            }
        }

        let domainKey = assignment.domainIdentity.key
        if var bucket = domainBuckets[domainKey] {
            bucket.packetCount -= 1
            if bucket.packetCount <= 0 {
                domainBuckets.removeValue(forKey: domainKey)
                domainOrder.removeAll { $0 == domainKey }
            } else {
                domainBuckets[domainKey] = bucket
            }
        }

        for ipAddressIdentity in assignment.ipAddressIdentities {
            let key = ipAddressIdentity.key
            if var bucket = ipAddressBuckets[key] {
                bucket.packetCount -= 1
                if bucket.packetCount <= 0 {
                    ipAddressBuckets.removeValue(forKey: key)
                    ipAddressOrder.removeAll { $0 == key }
                } else {
                    ipAddressBuckets[key] = bucket
                }
            }
        }

        decrementPinnedCounts(for: assignment)
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
                let pinnedAppBucket = pin.clientKey.map { PacketSourceClientKey(rawValue: $0) }.flatMap { appBuckets[$0] }
                return PacketSourceListTreeBuilder.PinnedBucket(
                    pin: pin,
                    packetCount: pinnedPacketCountsByID[pin.id, default: 0],
                    domainBuckets: pinnedAppBucket?.orderedDomainBuckets ?? [],
                    ipAddressBuckets: pinnedAppBucket?.orderedIPAddressBuckets ?? []
                )
            },
            savedPacketCount: savedPacketCount
        )
        return cachedSnapshot
    }

    private func rebuildPinnedCountsFromAssignments() {
        pinnedPacketCountsByID.removeAll(keepingCapacity: true)
        for assignment in packetAssignmentsByID.values {
            incrementPinnedCounts(for: assignment)
        }
    }

    private func incrementPinnedCounts(for assignment: PacketBucketAssignment) {
        guard !pinnedItems.isEmpty else {
            return
        }

        for pin in pinnedItems where matches(assignment, pin: pin) {
            pinnedPacketCountsByID[pin.id, default: 0] += 1
        }
    }

    private func decrementPinnedCounts(for assignment: PacketBucketAssignment) {
        guard !pinnedItems.isEmpty else {
            return
        }

        for pin in pinnedItems where matches(assignment, pin: pin) {
            let updatedCount = pinnedPacketCountsByID[pin.id, default: 0] - 1
            if updatedCount > 0 {
                pinnedPacketCountsByID[pin.id] = updatedCount
            } else {
                pinnedPacketCountsByID.removeValue(forKey: pin.id)
            }
        }
    }

    private func matches(_ assignment: PacketBucketAssignment, pin: PacketPin) -> Bool {
        switch pin.kind {
        case .domain:
            return assignment.domainIdentity.key.rawValue == pin.domain
        case .ip:
            guard let ipAddress = pin.ipAddress?.lowercased() else {
                return false
            }
            return assignment.pinIPAddresses.contains(ipAddress)
        case .client:
            return assignment.appIdentity?.key.rawValue == pin.clientKey
        }
    }

    private static func pinIPAddresses(for packet: PacketSummary) -> Set<String> {
        [
            packet.endpoints.source.address,
            packet.endpoints.destination.address,
        ].reduce(into: Set<String>()) { result, address in
            guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !address.isEmpty else {
                return
            }
            result.insert(address.lowercased())
        }
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
        private var domainBuckets: [PacketSourceDomainKey: DomainBucket] = [:]
        private var domainOrder: [PacketSourceDomainKey] = []
        private var ipAddressBuckets: [PacketSourceIPAddressKey: IPAddressBucket] = [:]
        private var ipAddressOrder: [PacketSourceIPAddressKey] = []

        init(identity: PacketSourceClientIdentity) {
            self.identity = identity
        }

        var orderedDomainBuckets: [DomainBucket] {
            domainOrder.compactMap { domainBuckets[$0] }
        }

        var orderedIPAddressBuckets: [IPAddressBucket] {
            ipAddressOrder.compactMap { ipAddressBuckets[$0] }
        }

        mutating func increment(
            domainIdentity: PacketSourceDomainIdentity,
            ipAddressIdentities: [PacketSourceIPAddressIdentity]
        ) {
            packetCount += 1
            incrementDomain(domainIdentity)
            for ipAddressIdentity in ipAddressIdentities {
                incrementIPAddress(ipAddressIdentity)
            }
        }

        mutating func decrement(
            domainIdentity: PacketSourceDomainIdentity,
            ipAddressIdentities: [PacketSourceIPAddressIdentity]
        ) {
            packetCount -= 1
            decrementDomain(domainIdentity.key)
            for ipAddressIdentity in ipAddressIdentities {
                decrementIPAddress(ipAddressIdentity.key)
            }
        }

        private mutating func incrementDomain(_ identity: PacketSourceDomainIdentity) {
            if domainBuckets[identity.key] == nil {
                domainOrder.append(identity.key)
                domainBuckets[identity.key] = DomainBucket(identity: identity)
            }
            domainBuckets[identity.key]?.packetCount += 1
        }

        private mutating func decrementDomain(_ key: PacketSourceDomainKey) {
            guard var bucket = domainBuckets[key] else {
                return
            }
            bucket.packetCount -= 1
            if bucket.packetCount <= 0 {
                domainBuckets.removeValue(forKey: key)
                domainOrder.removeAll { $0 == key }
            } else {
                domainBuckets[key] = bucket
            }
        }

        private mutating func incrementIPAddress(_ identity: PacketSourceIPAddressIdentity) {
            if ipAddressBuckets[identity.key] == nil {
                ipAddressOrder.append(identity.key)
                ipAddressBuckets[identity.key] = IPAddressBucket(identity: identity)
            }
            ipAddressBuckets[identity.key]?.packetCount += 1
        }

        private mutating func decrementIPAddress(_ key: PacketSourceIPAddressKey) {
            guard var bucket = ipAddressBuckets[key] else {
                return
            }
            bucket.packetCount -= 1
            if bucket.packetCount <= 0 {
                ipAddressBuckets.removeValue(forKey: key)
                ipAddressOrder.removeAll { $0 == key }
            } else {
                ipAddressBuckets[key] = bucket
            }
        }
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
        var domainBuckets: [DomainBucket] = []
        var ipAddressBuckets: [IPAddressBucket] = []
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
                children: makeDomainItems(
                    domainBuckets: bucket.orderedDomainBuckets,
                    ipAddressBuckets: bucket.orderedIPAddressBuckets,
                    idPrefix: "app:\(bucket.identity.key.rawValue)",
                    domainSelection: { .appDomain(bucket.identity.key, $0) },
                    ipAddressSelection: { .appIPAddress(bucket.identity.key, $0) }
                )
            )
        }
        let domainItems = makeDomainItems(
            domainBuckets: domainBuckets,
            ipAddressBuckets: ipAddressBuckets,
            idPrefix: nil,
            domainSelection: { .domain($0) },
            ipAddressSelection: { .ipAddress($0) }
        )
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
                children: makeDomainItems(
                    domainBuckets: bucket.domainBuckets,
                    ipAddressBuckets: bucket.ipAddressBuckets,
                    idPrefix: "pin:\(bucket.pin.id.rawValue)",
                    domainSelection: { .pinnedItemDomain(bucket.pin.id, $0) },
                    ipAddressSelection: { .pinnedItemIPAddress(bucket.pin.id, $0) }
                )
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

    private static func makeDomainItems(
        domainBuckets: [DomainBucket],
        ipAddressBuckets: [IPAddressBucket],
        idPrefix: String?,
        domainSelection: (PacketSourceDomainKey) -> PacketSourceListSelection,
        ipAddressSelection: (PacketSourceIPAddressKey) -> PacketSourceListSelection
    ) -> [PacketSourceListItem] {
        let ipAddressItems = ipAddressBuckets.map { bucket in
            PacketSourceListItem(
                id: itemID(prefix: idPrefix, kind: "ip", key: bucket.identity.key.rawValue),
                title: bucket.identity.displayName,
                systemImageName: "network",
                iconFilePath: nil,
                count: bucket.packetCount,
                kind: .domain,
                selection: ipAddressSelection(bucket.identity.key),
                children: []
            )
        }

        return domainBuckets.map { bucket in
            PacketSourceListItem(
                id: itemID(prefix: idPrefix, kind: "domain", key: bucket.identity.key.rawValue),
                title: bucket.identity.displayName,
                systemImageName: "network",
                iconFilePath: nil,
                count: bucket.packetCount,
                kind: .domain,
                selection: domainSelection(bucket.identity.key),
                children: bucket.identity.key.isMissingDomain ? ipAddressItems : []
            )
        }
    }

    private static func itemID(prefix: String?, kind: String, key: String) -> String {
        if let prefix {
            return "\(prefix):\(kind):\(key)"
        }

        return "\(kind):\(key)"
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
