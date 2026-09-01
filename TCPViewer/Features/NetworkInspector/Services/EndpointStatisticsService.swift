//
//  EndpointStatisticsService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Darwin
import Foundation
import PcapPlusPlusCore

struct EndpointStatisticsIngestCursor: Equatable, Sendable {
    let packetRevision: UInt64
    let packetLineageRevision: UInt64
    let totalPacketCount: Int
}

struct EndpointStatisticsIngestUpdate: Sendable {
    enum Kind: Sendable {
        case replace([PacketSummary])
        case append([PacketSummary])
        case appendWithMetadata(newPackets: [PacketSummary], updatedPackets: [PacketSummary])
        case metadata([PacketSummary])
    }

    let packetRevision: UInt64
    let previousPacketRevision: UInt64?
    let packetLineageRevision: UInt64
    let totalPacketCount: Int
    let kind: Kind

    var cursor: EndpointStatisticsIngestCursor {
        EndpointStatisticsIngestCursor(
            packetRevision: packetRevision,
            packetLineageRevision: packetLineageRevision,
            totalPacketCount: totalPacketCount
        )
    }

    init(
        packetRevision: UInt64,
        packetLineageRevision: UInt64,
        totalPacketCount: Int,
        kind: Kind,
        previousPacketRevision: UInt64? = nil
    ) {
        self.packetRevision = packetRevision
        if case .replace = kind {
            self.previousPacketRevision = nil
        } else {
            self.previousPacketRevision = previousPacketRevision ?? packetRevision &- 1
        }
        self.packetLineageRevision = packetLineageRevision
        self.totalPacketCount = totalPacketCount
        self.kind = kind
    }

    // Copy only the changed packet values when the caller has forwarded the preceding state.
    init(ingestState: PacketIngestState, previousPacketCount: Int?) {
        packetRevision = ingestState.packetRevision
        packetLineageRevision = ingestState.packetLineageRevision
        totalPacketCount = ingestState.packets.count

        switch ingestState.lastMutation {
        case .append(let range) where Self.canCopy(range, from: ingestState, previousPacketCount: previousPacketCount):
            kind = .append(Array(ingestState.packets[range]))
        case .appendWithMetadataUpdates(let range, let packetIDs)
            where Self.canCopy(range, from: ingestState, previousPacketCount: previousPacketCount):
            kind = .appendWithMetadata(
                newPackets: Array(ingestState.packets[range]),
                updatedPackets: Self.packets(withIDs: packetIDs, in: ingestState)
            )
        case .metadataUpdate(let packetIDs) where previousPacketCount == ingestState.packets.count:
            kind = .metadata(Self.packets(withIDs: packetIDs, in: ingestState))
        case .none, .reset, .replace, .append, .appendWithMetadataUpdates, .metadataUpdate:
            kind = .replace(ingestState.packets)
        }
        if case .replace = kind {
            previousPacketRevision = nil
        } else {
            previousPacketRevision = packetRevision &- 1
        }
    }

    // A small cursor lets callers detect skipped revisions before dispatching work to another queue.
    init(ingestState: PacketIngestState, previousCursor: EndpointStatisticsIngestCursor?) {
        guard let previousCursor else {
            self = .replacement(from: ingestState)
            return
        }
        if previousCursor.packetRevision == ingestState.packetRevision,
           previousCursor.packetLineageRevision == ingestState.packetLineageRevision,
           previousCursor.totalPacketCount == ingestState.packets.count {
            self.init(
                packetRevision: ingestState.packetRevision,
                packetLineageRevision: ingestState.packetLineageRevision,
                totalPacketCount: ingestState.packets.count,
                kind: .metadata([])
            )
            return
        }
        guard previousCursor.packetLineageRevision == ingestState.packetLineageRevision,
              ingestState.packetRevision == previousCursor.packetRevision &+ 1 else {
            self = .replacement(from: ingestState)
            return
        }
        self.init(ingestState: ingestState, previousPacketCount: previousCursor.totalPacketCount)
    }

    static func replacement(from ingestState: PacketIngestState) -> EndpointStatisticsIngestUpdate {
        EndpointStatisticsIngestUpdate(
            packetRevision: ingestState.packetRevision,
            packetLineageRevision: ingestState.packetLineageRevision,
            totalPacketCount: ingestState.packets.count,
            kind: .replace(ingestState.packets)
        )
    }

    private static func canCopy(
        _ range: Range<Int>,
        from ingestState: PacketIngestState,
        previousPacketCount: Int?
    ) -> Bool {
        previousPacketCount == range.lowerBound &&
            range.lowerBound >= 0 &&
            range.lowerBound < range.upperBound &&
            range.upperBound == ingestState.packets.count
    }

    private static func packets(
        withIDs packetIDs: [PacketSummary.ID],
        in ingestState: PacketIngestState
    ) -> [PacketSummary] {
        var seenPacketIDs = Set<PacketSummary.ID>()
        return packetIDs.compactMap { packetID in
            guard seenPacketIDs.insert(packetID).inserted else {
                return nil
            }
            return ingestState.packet(withID: packetID)
        }
    }
}

extension EndpointStatisticsRowID {
    func matches(_ packet: PacketSummary) -> Bool {
        EndpointStatisticsClassifier.matches(packet, rowID: self)
    }
}

enum EndpointStatisticsClassifier {
    static func matches(_ packet: PacketSummary, rowID: EndpointStatisticsRowID) -> Bool {
        switch rowID.group {
        case .apps:
            return PacketSourceListClassifier.clientIdentity(for: packet)?.key.rawValue == rowID.key
        case .domains:
            return canonicalDomain(packet.domainName) == rowID.key
        case .ipv4, .ipv6:
            return canonicalEndpoints(for: packet).contains { endpoint in
                endpoint.group == rowID.group && endpoint.address == rowID.key
            }
        case .tcp, .udp:
            guard transportGroup(for: packet) == rowID.group else {
                return false
            }
            return canonicalEndpoints(for: packet).contains { endpoint in
                endpoint.port.map { transportKey(address: endpoint.address, port: $0) } == rowID.key
            }
        }
    }

    static func rowIDs(for packet: PacketSummary) -> Set<EndpointStatisticsRowID> {
        let metadata = metadata(for: packet)
        let endpoints = canonicalEndpoints(for: packet)
        var rowIDs = Set<EndpointStatisticsRowID>()

        if let client = metadata.client {
            rowIDs.insert(EndpointStatisticsRowID(group: .apps, key: client.key))
        }
        if let domain = metadata.domain {
            rowIDs.insert(EndpointStatisticsRowID(group: .domains, key: domain))
        }
        for endpoint in endpoints {
            rowIDs.insert(EndpointStatisticsRowID(group: endpoint.group, key: endpoint.address))
        }
        if let transportGroup = transportGroup(for: packet) {
            for endpoint in endpoints {
                guard let port = endpoint.port else {
                    continue
                }
                rowIDs.insert(EndpointStatisticsRowID(
                    group: transportGroup,
                    key: transportKey(address: endpoint.address, port: port)
                ))
            }
        }

        return rowIDs
    }

    fileprivate static func metadata(for packet: PacketSummary) -> PacketStatisticsMetadata {
        let clientIdentity = PacketSourceListClassifier.clientIdentity(for: packet).map {
            PacketStatisticsClient(key: $0.key.rawValue, displayName: $0.displayName)
        }
        return PacketStatisticsMetadata(
            client: clientIdentity,
            domain: canonicalDomain(packet.domainName),
            direction: packet.direction,
            protocolName: protocolName(for: packet)
        )
    }

    fileprivate static func canonicalEndpoints(for packet: PacketSummary) -> [PacketStatisticsEndpoint] {
        [
            canonicalEndpoint(packet.endpoints.source, role: .source),
            canonicalEndpoint(packet.endpoints.destination, role: .destination),
        ].compactMap { $0 }
    }

    fileprivate static func transportGroup(for packet: PacketSummary) -> EndpointStatisticsGroup? {
        if packet.layers.contains(where: { $0.name.localizedCaseInsensitiveCompare("TCP") == .orderedSame }) {
            return .tcp
        }
        if packet.layers.contains(where: { $0.name.localizedCaseInsensitiveCompare("UDP") == .orderedSame }) {
            return .udp
        }

        switch packet.transportHint {
        case .tcp, .http1, .tls, .websocket:
            return .tcp
        case .udp:
            return .udp
        default:
            return nil
        }
    }

    fileprivate static func transportKey(address: String, port: UInt16) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    private static func canonicalEndpoint(
        _ endpoint: PacketEndpoint,
        role: PacketStatisticsEndpoint.Role
    ) -> PacketStatisticsEndpoint? {
        guard let canonicalAddress = canonicalIPAddress(endpoint.address) else {
            return nil
        }
        return PacketStatisticsEndpoint(
            address: canonicalAddress.address,
            port: endpoint.port,
            group: canonicalAddress.group,
            role: role
        )
    }

    private static func canonicalDomain(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard let normalized, !normalized.isEmpty, normalized.utf8.count <= 253 else {
            return nil
        }
        return normalized
    }

    private static func canonicalIPAddress(_ rawValue: String?) -> (address: String, group: EndpointStatisticsGroup)? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.first == "[", let closingBracket = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<closingBracket])
        }
        if let zoneIndex = value.firstIndex(of: "%") {
            value = String(value[..<zoneIndex])
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return (String(cString: buffer), .ipv4)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return (String(cString: buffer), .ipv6)
        }
        return nil
    }

    private static func protocolName(for packet: PacketSummary) -> String {
        switch packet.transportHint {
        case .ethernet: return "Ethernet"
        case .arp: return "ARP"
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        case .icmp: return "ICMP"
        case .tcp: return "TCP"
        case .udp: return "UDP"
        case .dns: return "DNS"
        case .http1: return "HTTP"
        case .tls: return "TLS"
        case .websocket: return "WebSocket"
        case .payload: return trimmed(packet.protocolSummary) ?? "Payload"
        case .unknown: return trimmed(packet.protocolSummary) ?? "Unknown"
        @unknown default: return trimmed(packet.protocolSummary) ?? "Unknown"
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

#if DEBUG
struct EndpointStatisticsDebugSnapshot: Equatable {
    let fullRebuildCount: Int
    let processedPacketCount: Int
    let appendedPacketCount: Int
    let metadataPacketCount: Int
    let unchangedSnapshotCount: Int
    let rowMaterializationCountByGroup: [EndpointStatisticsGroup: Int]
    let materializedRowCount: Int
}
#endif

final class EndpointStatisticsService {
    private var bucketsByGroup: [EndpointStatisticsGroup: [EndpointStatisticsRowID: PacketStatisticsBucket]] = [:]
    private var metadataByPacketID: [PacketSummary.ID: PacketStatisticsMetadata] = [:]
    private var footerTotals = EndpointStatisticsTotals.zero
    private var packetRevision: UInt64?
    private var packetLineageRevision: UInt64?
    private var sourcePacketCount = 0
    private var cachedSnapshot: EndpointStatisticsSnapshot? = .empty
    private var cachedRowsByGroup: [EndpointStatisticsGroup: [EndpointStatisticsRow]] = [:]
    private var dirtyGroups = Set<EndpointStatisticsGroup>()

    #if DEBUG
    private var fullRebuildCount = 0
    private var processedPacketCount = 0
    private var appendedPacketCount = 0
    private var metadataPacketCount = 0
    private var unchangedSnapshotCount = 0
    private var rowMaterializationCountByGroup: [EndpointStatisticsGroup: Int] = [:]
    private var materializedRowCount = 0
    #endif

    @discardableResult
    func rebuild(from packets: [PacketSummary]) -> EndpointStatisticsSnapshot {
        packetRevision = nil
        packetLineageRevision = nil
        _ = rebuildStorage(from: packets)
        return currentSnapshot()
    }

    func snapshot(for ingestState: PacketIngestState) -> EndpointStatisticsSnapshot {
        consume(ingestState)
        return currentSnapshot()
    }

    // Consume every ingest mutation cheaply so a window can materialize rows at a slower cadence.
    func consume(_ ingestState: PacketIngestState) {
        guard packetRevision != ingestState.packetRevision else {
            #if DEBUG
            unchangedSnapshotCount += 1
            #endif
            return
        }
        let previousCursor = packetRevision.map {
            EndpointStatisticsIngestCursor(
                packetRevision: $0,
                packetLineageRevision: packetLineageRevision ?? 0,
                totalPacketCount: sourcePacketCount
            )
        }
        let update = EndpointStatisticsIngestUpdate(
            ingestState: ingestState,
            previousCursor: previousCursor
        )
        if !consume(update) {
            _ = consume(.replacement(from: ingestState))
        }
    }

    // Return false when a queued update skipped a revision and the caller must send a replacement.
    @discardableResult
    func consume(_ update: EndpointStatisticsIngestUpdate) -> Bool {
        consumeUpdate(update, cancellationToken: nil) == .consumed
    }

    @discardableResult
    func consume(
        _ update: EndpointStatisticsIngestUpdate,
        cancellationToken: EndpointStatisticsCancellationToken
    ) -> EndpointStatisticsConsumeResult {
        consumeUpdate(update, cancellationToken: cancellationToken)
    }

    private func consumeUpdate(
        _ update: EndpointStatisticsIngestUpdate,
        cancellationToken: EndpointStatisticsCancellationToken?
    ) -> EndpointStatisticsConsumeResult {
        guard cancellationToken?.isCancelled() != true else {
            return .cancelled
        }
        guard packetRevision != update.packetRevision else {
            #if DEBUG
            unchangedSnapshotCount += 1
            #endif
            return .consumed
        }

        if case .replace(let packets) = update.kind {
            guard packets.count == update.totalPacketCount else {
                return .rejected
            }
            guard rebuildStorage(from: packets, cancellationToken: cancellationToken) else {
                return .cancelled
            }
            storeState(for: update)
            return .consumed
        }

        guard packetLineageRevision == update.packetLineageRevision,
              let packetRevision,
              update.previousPacketRevision == packetRevision else {
            return .rejected
        }

        switch update.kind {
        case .append(let packets):
            guard sourcePacketCount + packets.count == update.totalPacketCount else {
                return .rejected
            }
            guard applyNewPackets(
                packets,
                countsAsAppend: true,
                cancellationToken: cancellationToken
            ) else {
                reset()
                return .cancelled
            }
        case .appendWithMetadata(let newPackets, let updatedPackets):
            guard sourcePacketCount + newPackets.count == update.totalPacketCount else {
                return .rejected
            }
            guard applyNewPackets(
                newPackets,
                countsAsAppend: true,
                cancellationToken: cancellationToken
            ), applyMetadataUpdates(updatedPackets, cancellationToken: cancellationToken) else {
                reset()
                return .cancelled
            }
        case .metadata(let packets):
            guard sourcePacketCount == update.totalPacketCount else {
                return .rejected
            }
            guard applyMetadataUpdates(packets, cancellationToken: cancellationToken) else {
                reset()
                return .cancelled
            }
        case .replace:
            break
        }
        storeState(for: update)
        return .consumed
    }

    func currentSnapshot() -> EndpointStatisticsSnapshot {
        if dirtyGroups.isEmpty, let cachedSnapshot {
            return cachedSnapshot
        }
        let snapshot = makeSnapshot()
        cachedSnapshot = snapshot
        return snapshot
    }

    // Materialize only the visible protocol group; tab counts come directly from the accumulator dictionaries.
    func currentSnapshot(for group: EndpointStatisticsGroup) -> EndpointStatisticsGroupSnapshot {
        EndpointStatisticsGroupSnapshot(
            group: group,
            rows: materializedRows(for: group),
            endpointCounts: makeEndpointCounts(),
            footerTotals: footerTotals
        )
    }

    func currentSnapshot(
        for group: EndpointStatisticsGroup,
        cancellationToken: EndpointStatisticsCancellationToken
    ) -> EndpointStatisticsGroupSnapshot? {
        guard let rows = materializedRows(for: group, cancellationToken: cancellationToken) else {
            return nil
        }
        return EndpointStatisticsGroupSnapshot(
            group: group,
            rows: rows,
            endpointCounts: makeEndpointCounts(),
            footerTotals: footerTotals
        )
    }

    func reset() {
        bucketsByGroup.removeAll(keepingCapacity: false)
        metadataByPacketID.removeAll(keepingCapacity: false)
        footerTotals = .zero
        packetRevision = nil
        packetLineageRevision = nil
        sourcePacketCount = 0
        cachedSnapshot = .empty
        cachedRowsByGroup.removeAll(keepingCapacity: false)
        dirtyGroups.removeAll(keepingCapacity: false)
    }

    #if DEBUG
    func debugSnapshot() -> EndpointStatisticsDebugSnapshot {
        EndpointStatisticsDebugSnapshot(
            fullRebuildCount: fullRebuildCount,
            processedPacketCount: processedPacketCount,
            appendedPacketCount: appendedPacketCount,
            metadataPacketCount: metadataPacketCount,
            unchangedSnapshotCount: unchangedSnapshotCount,
            rowMaterializationCountByGroup: rowMaterializationCountByGroup,
            materializedRowCount: materializedRowCount
        )
    }
    #endif

    private func rebuildStorage(
        from packets: [PacketSummary],
        cancellationToken: EndpointStatisticsCancellationToken? = nil
    ) -> Bool {
        bucketsByGroup.removeAll(keepingCapacity: true)
        metadataByPacketID.removeAll(keepingCapacity: true)
        footerTotals = .zero
        sourcePacketCount = 0
        #if DEBUG
        fullRebuildCount += 1
        #endif
        guard applyNewPackets(
            packets,
            countsAsAppend: false,
            cancellationToken: cancellationToken
        ) else {
            reset()
            return false
        }
        markRowsDirty()
        return true
    }

    private func applyNewPackets<Packets: Collection>(
        _ packets: Packets,
        countsAsAppend: Bool,
        cancellationToken: EndpointStatisticsCancellationToken? = nil
    ) -> Bool
    where Packets.Element == PacketSummary {
        metadataByPacketID.reserveCapacity(metadataByPacketID.count + packets.count)
        for (index, packet) in packets.enumerated() {
            if index.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return false
            }
            let metadata = EndpointStatisticsClassifier.metadata(for: packet)
            add(packet, metadata: metadata)
            metadataByPacketID[packet.id] = metadata
        }
        sourcePacketCount += packets.count
        #if DEBUG
        processedPacketCount += packets.count
        if countsAsAppend {
            appendedPacketCount += packets.count
        }
        #endif
        return cancellationToken?.isCancelled() != true
    }

    // Metadata updates reclassify only the listed packets and leave immutable endpoint totals alone.
    private func applyMetadataUpdates(
        _ packets: [PacketSummary],
        cancellationToken: EndpointStatisticsCancellationToken? = nil
    ) -> Bool {
        var seenPacketIDs = Set<PacketSummary.ID>()
        for (index, packet) in packets.enumerated() {
            if index.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return false
            }
            guard seenPacketIDs.insert(packet.id).inserted else {
                continue
            }
            #if DEBUG
            metadataPacketCount += 1
            #endif
            let newMetadata = EndpointStatisticsClassifier.metadata(for: packet)
            guard let oldMetadata = metadataByPacketID[packet.id] else {
                continue
            }
            guard oldMetadata != newMetadata else {
                continue
            }
            remove(packet, metadata: oldMetadata)
            add(packet, metadata: newMetadata)
            metadataByPacketID[packet.id] = newMetadata
        }
        return cancellationToken?.isCancelled() != true
    }

    private func add(_ packet: PacketSummary, metadata: PacketStatisticsMetadata) {
        apply(packet, metadata: metadata, operation: .add)
    }

    private func remove(_ packet: PacketSummary, metadata: PacketStatisticsMetadata) {
        apply(packet, metadata: metadata, operation: .remove)
    }

    // Build at most six row contributions per packet and merge identical source/destination keys.
    private func apply(
        _ packet: PacketSummary,
        metadata: PacketStatisticsMetadata,
        operation: PacketStatisticsOperation
    ) {
        let bytes = UInt64(max(packet.originalLength, 0))
        operation.apply(directionalTotals(bytes: bytes, direction: metadata.direction), to: &footerTotals)

        let endpoints = EndpointStatisticsClassifier.canonicalEndpoints(for: packet)
        let remoteValues = remoteEndpointValues(endpoints, direction: metadata.direction)
        if let client = metadata.client {
            applyContribution(
                id: EndpointStatisticsRowID(group: .apps, key: client.key),
                identity: PacketStatisticsIdentity(),
                related: PacketStatisticsRelatedValues(
                    addresses: remoteValues.addresses,
                    ports: remoteValues.ports,
                    protocolNames: [metadata.protocolName],
                    clients: [client.displayName],
                    domains: metadata.domain.map { [$0] } ?? []
                ),
                totals: directionalTotals(bytes: bytes, direction: metadata.direction),
                operation: operation
            )
        }
        if let domain = metadata.domain {
            applyContribution(
                id: EndpointStatisticsRowID(group: .domains, key: domain),
                identity: PacketStatisticsIdentity(domain: domain),
                related: PacketStatisticsRelatedValues(
                    addresses: remoteValues.addresses,
                    ports: remoteValues.ports,
                    protocolNames: [metadata.protocolName],
                    clients: metadata.client.map { [$0.displayName] } ?? []
                ),
                totals: directionalTotals(bytes: bytes, direction: metadata.direction, reversesDirection: true),
                operation: operation
            )
        }

        applyEndpointContributions(
            endpoints,
            group: nil,
            bytes: bytes,
            metadata: metadata,
            operation: operation
        )
        if let transportGroup = EndpointStatisticsClassifier.transportGroup(for: packet) {
            applyEndpointContributions(
                endpoints.filter { $0.port != nil },
                group: transportGroup,
                bytes: bytes,
                metadata: metadata,
                operation: operation
            )
        }
    }

    private func applyEndpointContributions(
        _ endpoints: [PacketStatisticsEndpoint],
        group transportGroup: EndpointStatisticsGroup?,
        bytes: UInt64,
        metadata: PacketStatisticsMetadata,
        operation: PacketStatisticsOperation
    ) {
        let source = endpoints.first { $0.role == .source }
        let destination = endpoints.first { $0.role == .destination }
        let sourceID = source.map { endpointRowID($0, transportGroup: transportGroup) }
        let destinationID = destination.map { endpointRowID($0, transportGroup: transportGroup) }

        if let source, let sourceID, let destination, sourceID == destinationID {
            applyContribution(
                id: sourceID,
                identity: endpointIdentity(source, transportGroup: transportGroup),
                related: endpointRelatedValues([source, destination], metadata: metadata, transportGroup: transportGroup),
                totals: endpointTotals(bytes: bytes, isSource: true, isDestination: true),
                operation: operation
            )
            return
        }

        if let source, let sourceID {
            applyContribution(
                id: sourceID,
                identity: endpointIdentity(source, transportGroup: transportGroup),
                related: endpointRelatedValues([source], metadata: metadata, transportGroup: transportGroup),
                totals: endpointTotals(bytes: bytes, isSource: true, isDestination: false),
                operation: operation
            )
        }
        if let destination, let destinationID {
            applyContribution(
                id: destinationID,
                identity: endpointIdentity(destination, transportGroup: transportGroup),
                related: endpointRelatedValues([destination], metadata: metadata, transportGroup: transportGroup),
                totals: endpointTotals(bytes: bytes, isSource: false, isDestination: true),
                operation: operation
            )
        }
    }

    private func endpointRowID(
        _ endpoint: PacketStatisticsEndpoint,
        transportGroup: EndpointStatisticsGroup?
    ) -> EndpointStatisticsRowID {
        if let transportGroup, let port = endpoint.port {
            return EndpointStatisticsRowID(
                group: transportGroup,
                key: EndpointStatisticsClassifier.transportKey(address: endpoint.address, port: port)
            )
        }
        return EndpointStatisticsRowID(group: endpoint.group, key: endpoint.address)
    }

    private func endpointIdentity(
        _ endpoint: PacketStatisticsEndpoint,
        transportGroup: EndpointStatisticsGroup?
    ) -> PacketStatisticsIdentity {
        PacketStatisticsIdentity(
            address: endpoint.address,
            port: transportGroup == nil ? nil : endpoint.port.map(String.init)
        )
    }

    private func endpointRelatedValues(
        _ endpoints: [PacketStatisticsEndpoint],
        metadata: PacketStatisticsMetadata,
        transportGroup: EndpointStatisticsGroup?
    ) -> PacketStatisticsRelatedValues {
        PacketStatisticsRelatedValues(
            ports: transportGroup == nil ? unique(endpoints.compactMap { $0.port.map(String.init) }) : [],
            protocolNames: [metadata.protocolName],
            clients: metadata.client.map { [$0.displayName] } ?? [],
            domains: metadata.domain.map { [$0] } ?? []
        )
    }

    private func applyContribution(
        id: EndpointStatisticsRowID,
        identity: PacketStatisticsIdentity,
        related: PacketStatisticsRelatedValues,
        totals: EndpointStatisticsTotals,
        operation: PacketStatisticsOperation
    ) {
        switch operation {
        case .add:
            // Mutate the stored bucket in place so high-cardinality related values do not copy their dictionaries per packet.
            bucketsByGroup[id.group, default: [:]][
                id,
                default: PacketStatisticsBucket(id: id, identity: identity)
            ].add(totals: totals, related: related)
        case .remove:
            // Removing the value first gives the bucket unique ownership before its related-value counts change.
            guard var bucket = bucketsByGroup[id.group]?.removeValue(forKey: id) else {
                return
            }
            bucket.remove(totals: totals, related: related)
            if bucket.totals.packets > 0 {
                bucketsByGroup[id.group, default: [:]][id] = bucket
            }
        }
    }

    private func storeState(for update: EndpointStatisticsIngestUpdate) {
        packetRevision = update.packetRevision
        packetLineageRevision = update.packetLineageRevision
        sourcePacketCount = update.totalPacketCount
        markRowsDirty()
    }

    private func makeSnapshot() -> EndpointStatisticsSnapshot {
        var rowsByGroup: [EndpointStatisticsGroup: [EndpointStatisticsRow]] = [:]
        for group in EndpointStatisticsGroup.allCases {
            rowsByGroup[group] = materializedRows(for: group)
        }
        return EndpointStatisticsSnapshot(rowsByGroup: rowsByGroup, footerTotals: footerTotals)
    }

    private func materializedRows(for group: EndpointStatisticsGroup) -> [EndpointStatisticsRow] {
        materializedRows(for: group, cancellationToken: nil) ?? []
    }

    private func materializedRows(
        for group: EndpointStatisticsGroup,
        cancellationToken: EndpointStatisticsCancellationToken?
    ) -> [EndpointStatisticsRow]? {
        guard cancellationToken?.isCancelled() != true else {
            return nil
        }
        if !dirtyGroups.contains(group), let cachedRows = cachedRowsByGroup[group] {
            return cachedRows
        }
        let buckets = bucketsByGroup[group] ?? [:]
        var rows: [EndpointStatisticsRow] = []
        rows.reserveCapacity(buckets.count)
        for (index, bucket) in buckets.values.enumerated() {
            if index.isMultiple(of: 256), cancellationToken?.isCancelled() == true {
                return nil
            }
            rows.append(bucket.row)
        }
        guard cancellationToken?.isCancelled() != true else {
            return nil
        }
        cachedRowsByGroup[group] = rows
        dirtyGroups.remove(group)
        #if DEBUG
        rowMaterializationCountByGroup[group, default: 0] += 1
        materializedRowCount += rows.count
        #endif
        return rows
    }

    private func makeEndpointCounts() -> [EndpointStatisticsGroup: Int] {
        Dictionary(uniqueKeysWithValues: EndpointStatisticsGroup.allCases.map { group in
            (group, bucketsByGroup[group]?.count ?? 0)
        })
    }

    private func markRowsDirty() {
        dirtyGroups.formUnion(EndpointStatisticsGroup.allCases)
        cachedSnapshot = nil
    }

    private func directionalTotals(
        bytes: UInt64,
        direction: PacketDirection?,
        reversesDirection: Bool = false
    ) -> EndpointStatisticsTotals {
        var totals = EndpointStatisticsTotals.zero
        totals.packets = 1
        totals.bytes = bytes
        switch direction {
        case .outbound:
            if reversesDirection {
                totals.rxPackets = 1
                totals.rxBytes = bytes
            } else {
                totals.txPackets = 1
                totals.txBytes = bytes
            }
        case .inbound:
            if reversesDirection {
                totals.txPackets = 1
                totals.txBytes = bytes
            } else {
                totals.rxPackets = 1
                totals.rxBytes = bytes
            }
        case .local, .unknown, nil:
            totals.unclassifiedPackets = 1
            totals.unclassifiedBytes = bytes
        @unknown default:
            totals.unclassifiedPackets = 1
            totals.unclassifiedBytes = bytes
        }
        return totals
    }

    // Count endpoint occurrences so Packets and Bytes stay equal to their Tx and Rx columns.
    private func endpointTotals(
        bytes: UInt64,
        isSource: Bool,
        isDestination: Bool
    ) -> EndpointStatisticsTotals {
        let endpointOccurrenceCount = UInt64((isSource ? 1 : 0) + (isDestination ? 1 : 0))
        return EndpointStatisticsTotals(
            packets: endpointOccurrenceCount,
            bytes: bytes * endpointOccurrenceCount,
            txPackets: isSource ? 1 : 0,
            txBytes: isSource ? bytes : 0,
            rxPackets: isDestination ? 1 : 0,
            rxBytes: isDestination ? bytes : 0,
            unclassifiedPackets: 0,
            unclassifiedBytes: 0
        )
    }

    private func remoteEndpointValues(
        _ endpoints: [PacketStatisticsEndpoint],
        direction: PacketDirection?
    ) -> (addresses: [String], ports: [String]) {
        let remoteEndpoints: [PacketStatisticsEndpoint]
        switch direction {
        case .outbound:
            remoteEndpoints = endpoints.filter { $0.role == .destination }
        case .inbound:
            remoteEndpoints = endpoints.filter { $0.role == .source }
        case .local, .unknown, nil:
            remoteEndpoints = endpoints
        @unknown default:
            remoteEndpoints = endpoints
        }
        return (
            unique(remoteEndpoints.map(\.address)),
            unique(remoteEndpoints.compactMap { $0.port.map(String.init) })
        )
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private enum PacketStatisticsOperation {
    case add
    case remove

    func apply(_ value: EndpointStatisticsTotals, to totals: inout EndpointStatisticsTotals) {
        switch self {
        case .add:
            totals.add(value)
        case .remove:
            totals.remove(value)
        }
    }
}

private struct PacketStatisticsClient: Equatable {
    let key: String
    let displayName: String
}

fileprivate struct PacketStatisticsMetadata: Equatable {
    let client: PacketStatisticsClient?
    let domain: String?
    let direction: PacketDirection?
    let protocolName: String
}

fileprivate struct PacketStatisticsEndpoint {
    enum Role {
        case source
        case destination
    }

    let address: String
    let port: UInt16?
    let group: EndpointStatisticsGroup
    let role: Role
}

private struct PacketStatisticsIdentity {
    var address: String?
    var port: String?
    var protocolName: String?
    var client: String?
    var domain: String?

    init(
        address: String? = nil,
        port: String? = nil,
        protocolName: String? = nil,
        client: String? = nil,
        domain: String? = nil
    ) {
        self.address = address
        self.port = port
        self.protocolName = protocolName
        self.client = client
        self.domain = domain
    }
}

private struct PacketStatisticsRelatedValues {
    var addresses: [String] = []
    var ports: [String] = []
    var protocolNames: [String] = []
    var clients: [String] = []
    var domains: [String] = []
}

private struct PacketStatisticsValueCounts {
    private var counts: [String: UInt64] = [:]

    var displayValue: String? {
        if counts.count > 1 {
            return EndpointStatisticsRow.multipleValue
        }
        return counts.keys.first
    }

    var isMultiple: Bool {
        counts.count > 1
    }

    mutating func add(_ values: [String]) {
        for value in values {
            counts[value, default: 0] += 1
        }
    }

    mutating func remove(_ values: [String]) {
        for value in values {
            guard let count = counts[value] else {
                continue
            }
            if count > 1 {
                counts[value] = count - 1
            } else {
                counts.removeValue(forKey: value)
            }
        }
    }
}

private struct PacketStatisticsBucket {
    let id: EndpointStatisticsRowID
    let identity: PacketStatisticsIdentity
    var totals = EndpointStatisticsTotals.zero
    private var addresses = PacketStatisticsValueCounts()
    private var ports = PacketStatisticsValueCounts()
    private var protocolNames = PacketStatisticsValueCounts()
    private var clients = PacketStatisticsValueCounts()
    private var domains = PacketStatisticsValueCounts()

    init(id: EndpointStatisticsRowID, identity: PacketStatisticsIdentity) {
        self.id = id
        self.identity = identity
    }

    var row: EndpointStatisticsRow {
        EndpointStatisticsRow(
            id: id,
            address: identity.address ?? addresses.displayValue,
            port: identity.port ?? ports.displayValue,
            protocolName: identity.protocolName ?? protocolNames.displayValue,
            client: identity.client ?? clients.displayValue,
            domain: identity.domain ?? domains.displayValue,
            isAddressMultiple: identity.address == nil && addresses.isMultiple,
            isPortMultiple: identity.port == nil && ports.isMultiple,
            isProtocolMultiple: identity.protocolName == nil && protocolNames.isMultiple,
            isClientMultiple: identity.client == nil && clients.isMultiple,
            isDomainMultiple: identity.domain == nil && domains.isMultiple,
            packets: totals.packets,
            bytes: totals.bytes,
            txPackets: totals.txPackets,
            txBytes: totals.txBytes,
            rxPackets: totals.rxPackets,
            rxBytes: totals.rxBytes,
            unclassifiedPackets: totals.unclassifiedPackets,
            unclassifiedBytes: totals.unclassifiedBytes
        )
    }

    mutating func add(totals: EndpointStatisticsTotals, related: PacketStatisticsRelatedValues) {
        self.totals.add(totals)
        addresses.add(related.addresses)
        ports.add(related.ports)
        protocolNames.add(related.protocolNames)
        clients.add(related.clients)
        domains.add(related.domains)
    }

    mutating func remove(totals: EndpointStatisticsTotals, related: PacketStatisticsRelatedValues) {
        self.totals.remove(totals)
        addresses.remove(related.addresses)
        ports.remove(related.ports)
        protocolNames.remove(related.protocolNames)
        clients.remove(related.clients)
        domains.remove(related.domains)
    }
}

private extension EndpointStatisticsTotals {
    mutating func add(_ value: EndpointStatisticsTotals) {
        packets += value.packets
        bytes += value.bytes
        txPackets += value.txPackets
        txBytes += value.txBytes
        rxPackets += value.rxPackets
        rxBytes += value.rxBytes
        unclassifiedPackets += value.unclassifiedPackets
        unclassifiedBytes += value.unclassifiedBytes
    }

    mutating func remove(_ value: EndpointStatisticsTotals) {
        packets -= value.packets
        bytes -= value.bytes
        txPackets -= value.txPackets
        txBytes -= value.txBytes
        rxPackets -= value.rxPackets
        rxBytes -= value.rxBytes
        unclassifiedPackets -= value.unclassifiedPackets
        unclassifiedBytes -= value.unclassifiedBytes
    }
}
