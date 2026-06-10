//
//  PacketMetadataEnrichmentService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import AppKit
import Darwin
import Foundation
import PcapPlusPlusCore

struct PacketMetadataEnrichmentResult {
    let packets: [PacketSummary]
    let updates: [PacketMetadataUpdate]
}

struct PacketMetadataUpdate {
    let packetIDs: [PacketSummary.ID]
    let sniDomainName: String?
    let client: PacketClient?
    let direction: PacketDirection?
}

#if DEBUG
struct PacketClientResolverDebugSnapshot: Equatable {
    let socketKeyCount: Int
    let localEndpointKeyCount: Int
    let localPortKeyCount: Int
    let pidClientCount: Int
    let negativeLookupCount: Int
    let processIdentityCacheCount: Int
    let bundleIdentityCacheCount: Int

    static let empty = PacketClientResolverDebugSnapshot(
        socketKeyCount: 0,
        localEndpointKeyCount: 0,
        localPortKeyCount: 0,
        pidClientCount: 0,
        negativeLookupCount: 0,
        processIdentityCacheCount: 0,
        bundleIdentityCacheCount: 0
    )
}

struct PacketMetadataEnrichmentDebugSnapshot: Equatable {
    let flowCount: Int
    let flowOrderCount: Int
    let pendingPacketIDCount: Int
    let clientResolver: PacketClientResolverDebugSnapshot

    static let empty = PacketMetadataEnrichmentDebugSnapshot(
        flowCount: 0,
        flowOrderCount: 0,
        pendingPacketIDCount: 0,
        clientResolver: .empty
    )
}
#endif

protocol PacketMetadataEnriching: AnyObject {
    func reset()
    func enrich(_ packets: [PacketSummary], source: CaptureSource) -> PacketMetadataEnrichmentResult
    #if DEBUG
    func debugMemorySnapshot() -> PacketMetadataEnrichmentDebugSnapshot
    #endif
}

protocol PacketClientResolving: AnyObject {
    func reset()
    func client(for packet: PacketSummary) -> PacketClient?
    func resolution(for packet: PacketSummary) -> PacketClientResolution?
    #if DEBUG
    func debugMemorySnapshot() -> PacketClientResolverDebugSnapshot
    #endif
}

struct PacketClientResolution {
    let client: PacketClient
    let direction: PacketDirection?
}

extension PacketClientResolving {
    func resolution(for packet: PacketSummary) -> PacketClientResolution? {
        client(for: packet).map { PacketClientResolution(client: $0, direction: nil) }
    }
}

#if DEBUG
extension PacketClientResolving {
    func debugMemorySnapshot() -> PacketClientResolverDebugSnapshot {
        .empty
    }
}
#endif

final class PacketMetadataEnrichmentService: PacketMetadataEnriching {
    private struct FlowMetadata {
        var sniDomainName: String?
        var client: PacketClient?
        var direction: PacketDirection?
        var pendingPacketIDs: [PacketSummary.ID] = []
        var lastSeen: Date
    }

    private let maxCachedFlows: Int
    private let flowIdleTimeout: TimeInterval
    private let maxPendingPacketIDsPerFlow: Int
    private let clientResolver: any PacketClientResolving
    private var flowMetadataByStreamID: [UInt32: FlowMetadata] = [:]
    private var flowOrder: [UInt32] = []

    init(
        maxCachedFlows: Int = 100_000,
        flowIdleTimeout: TimeInterval = 600,
        maxPendingPacketIDsPerFlow: Int = 128,
        clientResolver: any PacketClientResolving = MacOSPacketClientResolver()
    ) {
        self.maxCachedFlows = max(maxCachedFlows, 1)
        self.flowIdleTimeout = max(flowIdleTimeout, 0)
        self.maxPendingPacketIDsPerFlow = max(maxPendingPacketIDsPerFlow, 1)
        self.clientResolver = clientResolver
    }

    // Reset flow and process caches when packet lineage changes.
    func reset() {
        flowMetadataByStreamID.removeAll(keepingCapacity: false)
        flowOrder.removeAll(keepingCapacity: false)
        clientResolver.reset()
    }

    #if DEBUG
    func debugMemorySnapshot() -> PacketMetadataEnrichmentDebugSnapshot {
        PacketMetadataEnrichmentDebugSnapshot(
            flowCount: flowMetadataByStreamID.count,
            flowOrderCount: flowOrder.count,
            pendingPacketIDCount: flowMetadataByStreamID.values.reduce(0) { $0 + $1.pendingPacketIDs.count },
            clientResolver: clientResolver.debugMemorySnapshot()
        )
    }
    #endif

    // Enrich the incoming batch and emit flow updates for packets already stored.
    func enrich(_ packets: [PacketSummary], source: CaptureSource) -> PacketMetadataEnrichmentResult {
        var enrichedPackets: [PacketSummary] = []
        var updates: [PacketMetadataUpdate] = []
        enrichedPackets.reserveCapacity(packets.count)

        for packet in packets {
            guard let streamID = packet.streamID else {
                let resolution = source == .live ? clientResolver.resolution(for: packet) : nil
                enrichedPackets.append(packet.tcpviewerApplying(
                    sniDomainName: packet.sniDomainName,
                    client: resolution?.client,
                    direction: resolution?.direction
                ))
                continue
            }

            var metadata = metadataForFlow(streamID, packet: packet)
            var shouldBackfill = false

            if let sniDomainName = packet.sniDomainName, !sniDomainName.isEmpty, metadata.sniDomainName != sniDomainName {
                metadata.sniDomainName = sniDomainName
                shouldBackfill = true
            }

            if source == .live, metadata.client == nil, let resolution = clientResolver.resolution(for: packet) {
                metadata.client = resolution.client
                metadata.direction = resolution.direction
                shouldBackfill = true
            }

            if shouldBackfill, !metadata.pendingPacketIDs.isEmpty {
                updates.append(PacketMetadataUpdate(
                    packetIDs: metadata.pendingPacketIDs,
                    sniDomainName: metadata.sniDomainName,
                    client: metadata.client,
                    direction: metadata.direction
                ))
            }

            let enrichedPacket = packet.tcpviewerApplying(
                sniDomainName: metadata.sniDomainName ?? packet.sniDomainName,
                client: metadata.client,
                direction: metadata.direction
            )
            rememberPendingBackfillIfNeeded(packet.id, packet: packet, source: source, metadata: &metadata)
            metadata.lastSeen = packet.timestamp
            flowMetadataByStreamID[streamID] = packet.tcpviewerEndsTCPConnection
                ? FlowMetadata(lastSeen: packet.timestamp)
                : metadata
            enrichedPackets.append(enrichedPacket)
        }

        return PacketMetadataEnrichmentResult(packets: enrichedPackets, updates: updates)
    }

    private func metadataForFlow(_ streamID: UInt32, packet: PacketSummary) -> FlowMetadata {
        if let metadata = flowMetadataByStreamID[streamID] {
            if shouldStartNewFlow(packet: packet, existingMetadata: metadata) {
                return FlowMetadata(lastSeen: packet.timestamp)
            }

            return metadata
        }

        flowOrder.append(streamID)
        if flowOrder.count > maxCachedFlows {
            let removedStreamID = flowOrder.removeFirst()
            flowMetadataByStreamID.removeValue(forKey: removedStreamID)
        }

        let metadata = FlowMetadata(lastSeen: packet.timestamp)
        flowMetadataByStreamID[streamID] = metadata
        return metadata
    }

    private func shouldStartNewFlow(packet: PacketSummary, existingMetadata: FlowMetadata) -> Bool {
        packet.tcpviewerStartsNewTCPConnection ||
            packet.timestamp.timeIntervalSince(existingMetadata.lastSeen) > flowIdleTimeout
    }

    private func rememberPendingBackfillIfNeeded(
        _ packetID: PacketSummary.ID,
        packet: PacketSummary,
        source: CaptureSource,
        metadata: inout FlowMetadata
    ) {
        let waitsForSNI = packet.tcpviewerUsesTCP && metadata.sniDomainName == nil
        let waitsForClient = source == .live && metadata.client == nil
        guard waitsForSNI || waitsForClient else {
            metadata.pendingPacketIDs.removeAll(keepingCapacity: true)
            return
        }

        metadata.pendingPacketIDs.append(packetID)
        if metadata.pendingPacketIDs.count > maxPendingPacketIDsPerFlow {
            metadata.pendingPacketIDs.removeFirst(metadata.pendingPacketIDs.count - maxPendingPacketIDsPerFlow)
        }
    }
}

struct MacOSBundleIdentity {
    let displayName: String?
    let bundleIdentifier: String?
}

struct MacOSProcessClientResolverEnvironment {
    let processName: (pid_t) -> String
    let processPath: (pid_t) -> String?
    let bundleIdentity: (URL) -> MacOSBundleIdentity

    static let live = MacOSProcessClientResolverEnvironment(
        processName: { pid in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else {
                return "PID \(pid)"
            }
            return String(cString: buffer)
        },
        processPath: { pid in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else {
                return nil
            }
            return String(cString: buffer)
        },
        bundleIdentity: { bundleURL in
            let bundle = Bundle(url: bundleURL)
            let displayName = bundle.flatMap { bundle in
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            }
            return MacOSBundleIdentity(
                displayName: displayName,
                bundleIdentifier: bundle?.bundleIdentifier
            )
        }
    )
}

final class MacOSPacketClientResolver: PacketClientResolving {
    fileprivate enum SocketTransport: Hashable {
        case tcp
        case udp
    }

    fileprivate struct SocketEndpoint: Hashable {
        let address: String
        let port: UInt16
    }

    private struct SocketKey: Hashable {
        let transport: SocketTransport
        let local: SocketEndpoint
        let remote: SocketEndpoint
    }

    private struct LocalEndpointKey: Hashable {
        let transport: SocketTransport
        let endpoint: SocketEndpoint
    }

    private struct LocalPortKey: Hashable {
        let transport: SocketTransport
        let port: UInt16
    }

    private struct PacketLookupKey: Hashable {
        let transport: SocketTransport
        let source: SocketEndpoint
        let destination: SocketEndpoint

        init?(packet: PacketSummary) {
            guard let transport = SocketTransport(packet: packet),
                  let source = SocketEndpoint(packet.endpoints.source),
                  let destination = SocketEndpoint(packet.endpoints.destination) else {
                return nil
            }

            self.transport = transport
            self.source = source
            self.destination = destination
        }
    }

    private struct ProcessIdentityCacheEntry {
        let executablePath: String?
        let client: PacketClient
    }

    private let snapshotTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private let maxNegativeLookups: Int
    private let maxProcessIdentityCacheEntries: Int
    private let maxBundleIdentityCacheEntries: Int
    private let environment: MacOSProcessClientResolverEnvironment
    private var snapshotDate: Date?
    private var clientsBySocketKey: [SocketKey: PacketClient] = [:]
    private var clientsByLocalEndpointKey: [LocalEndpointKey: PacketClient] = [:]
    private var clientsByLocalPortKey: [LocalPortKey: PacketClient] = [:]
    private var clientsByPID: [pid_t: PacketClient] = [:]
    private var negativeLookups: [PacketLookupKey: Date] = [:]
    private var processIdentityCacheByPID: [pid_t: ProcessIdentityCacheEntry] = [:]
    private var processIdentityOrder: [pid_t] = []
    private var bundleIdentityByPath: [String: MacOSBundleIdentity] = [:]
    private var bundleIdentityOrder: [String] = []

    init(
        snapshotTTL: TimeInterval = 0.5,
        negativeTTL: TimeInterval = 0.5,
        maxNegativeLookups: Int = 10_000,
        maxProcessIdentityCacheEntries: Int = 2_048,
        maxBundleIdentityCacheEntries: Int = 512,
        environment: MacOSProcessClientResolverEnvironment = .live
    ) {
        self.snapshotTTL = snapshotTTL
        self.negativeTTL = negativeTTL
        self.maxNegativeLookups = max(maxNegativeLookups, 1)
        self.maxProcessIdentityCacheEntries = max(maxProcessIdentityCacheEntries, 1)
        self.maxBundleIdentityCacheEntries = max(maxBundleIdentityCacheEntries, 1)
        self.environment = environment
    }

    // Clear process snapshots between live capture sessions.
    func reset() {
        snapshotDate = nil
        clientsBySocketKey.removeAll(keepingCapacity: false)
        clientsByLocalEndpointKey.removeAll(keepingCapacity: false)
        clientsByLocalPortKey.removeAll(keepingCapacity: false)
        clientsByPID.removeAll(keepingCapacity: false)
        negativeLookups.removeAll(keepingCapacity: false)
        processIdentityCacheByPID.removeAll(keepingCapacity: false)
        processIdentityOrder.removeAll(keepingCapacity: false)
        bundleIdentityByPath.removeAll(keepingCapacity: false)
        bundleIdentityOrder.removeAll(keepingCapacity: false)
    }

    #if DEBUG
    func debugMemorySnapshot() -> PacketClientResolverDebugSnapshot {
        PacketClientResolverDebugSnapshot(
            socketKeyCount: clientsBySocketKey.count,
            localEndpointKeyCount: clientsByLocalEndpointKey.count,
            localPortKeyCount: clientsByLocalPortKey.count,
            pidClientCount: clientsByPID.count,
            negativeLookupCount: negativeLookups.count,
            processIdentityCacheCount: processIdentityCacheByPID.count,
            bundleIdentityCacheCount: bundleIdentityByPath.count
        )
    }
    #endif

    // Resolve a packet to the current macOS process that owns its local socket.
    func client(for packet: PacketSummary) -> PacketClient? {
        resolution(for: packet)?.client
    }

    func resolution(for packet: PacketSummary) -> PacketClientResolution? {
        guard let lookupKey = PacketLookupKey(packet: packet) else {
            return nil
        }

        let now = Date()
        if let negativeDate = negativeLookups[lookupKey], now.timeIntervalSince(negativeDate) < negativeTTL {
            return nil
        }

        refreshSnapshotIfNeeded(now: now)

        if let resolution = resolution(for: lookupKey) {
            negativeLookups.removeValue(forKey: lookupKey)
            return resolution
        }

        rememberNegativeLookup(lookupKey, now: now)
        return nil
    }

    private func resolution(for lookupKey: PacketLookupKey) -> PacketClientResolution? {
        if let client = clientsBySocketKey[SocketKey(
            transport: lookupKey.transport,
            local: lookupKey.source,
            remote: lookupKey.destination
        )] {
            return PacketClientResolution(client: client, direction: .outbound)
        }

        if let client = clientsBySocketKey[SocketKey(
            transport: lookupKey.transport,
            local: lookupKey.destination,
            remote: lookupKey.source
        )] {
            return PacketClientResolution(client: client, direction: .inbound)
        }

        let sourceClient = clientsByLocalEndpointKey[LocalEndpointKey(transport: lookupKey.transport, endpoint: lookupKey.source)]
        let destinationClient = clientsByLocalEndpointKey[LocalEndpointKey(transport: lookupKey.transport, endpoint: lookupKey.destination)]
        if let sourceClient, destinationClient != nil {
            return PacketClientResolution(client: sourceClient, direction: .local)
        }

        if let sourceClient {
            return PacketClientResolution(client: sourceClient, direction: .outbound)
        }

        if let destinationClient {
            return PacketClientResolution(client: destinationClient, direction: .inbound)
        }

        if let client = clientsByLocalPortKey[LocalPortKey(transport: lookupKey.transport, port: lookupKey.source.port)] {
            return PacketClientResolution(client: client, direction: .outbound)
        }

        if let client = clientsByLocalPortKey[LocalPortKey(transport: lookupKey.transport, port: lookupKey.destination.port)] {
            return PacketClientResolution(client: client, direction: .inbound)
        }

        return nil
    }

    private func refreshSnapshotIfNeeded(now: Date) {
        if let snapshotDate, now.timeIntervalSince(snapshotDate) < snapshotTTL {
            return
        }

        snapshotDate = now
        clientsBySocketKey.removeAll(keepingCapacity: true)
        clientsByLocalEndpointKey.removeAll(keepingCapacity: true)
        clientsByLocalPortKey.removeAll(keepingCapacity: true)
        clientsByPID.removeAll(keepingCapacity: true)
        pruneNegativeLookups(now: now)

        let pidBufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidBufferSize > 0 else {
            return
        }

        var pids = [pid_t](repeating: 0, count: Int(pidBufferSize) / MemoryLayout<pid_t>.stride)
        let actualPIDBytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        let pidCount = max(0, Int(actualPIDBytes) / MemoryLayout<pid_t>.stride)

        for pid in pids.prefix(pidCount) where pid > 0 {
            registerSockets(for: pid)
        }
    }

    private func rememberNegativeLookup(_ lookupKey: PacketLookupKey, now: Date) {
        if negativeLookups.count >= maxNegativeLookups {
            pruneNegativeLookups(now: now)
            if negativeLookups.count >= maxNegativeLookups {
                negativeLookups.removeAll(keepingCapacity: true)
            }
        }

        negativeLookups[lookupKey] = now
    }

    private func pruneNegativeLookups(now: Date) {
        negativeLookups = negativeLookups.filter { _, date in
            now.timeIntervalSince(date) < negativeTTL
        }
    }

    private func registerSockets(for pid: pid_t) {
        let fdBufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard fdBufferSize > 0 else {
            return
        }

        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBufferSize) / MemoryLayout<proc_fdinfo>.stride)
        let actualFDBytes = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        let fdCount = max(0, Int(actualFDBytes) / MemoryLayout<proc_fdinfo>.stride)

        for fd in fds.prefix(fdCount) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInfo = socket_fdinfo()
            let socketInfoSize = proc_pidfdinfo(
                pid,
                fd.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &socketInfo,
                Int32(MemoryLayout<socket_fdinfo>.stride)
            )
            guard socketInfoSize == Int32(MemoryLayout<socket_fdinfo>.stride),
                  let client = client(for: pid) else {
                continue
            }

            registerSocket(socketInfo.psi, client: client)
        }
    }

    private func registerSocket(_ socketInfo: socket_info, client: PacketClient) {
        switch socketInfo.soi_kind {
        case Int32(SOCKINFO_TCP):
            let info = socketInfo.soi_proto.pri_tcp.tcpsi_ini
            registerInternetSocket(info, transport: .tcp, client: client)
        case Int32(SOCKINFO_IN) where socketInfo.soi_protocol == Int32(IPPROTO_UDP):
            registerInternetSocket(socketInfo.soi_proto.pri_in, transport: .udp, client: client)
        default:
            break
        }
    }

    private func registerInternetSocket(_ info: in_sockinfo, transport: SocketTransport, client: PacketClient) {
        guard let local = localEndpoint(from: info), local.port > 0 else {
            return
        }

        clientsByLocalEndpointKey[LocalEndpointKey(transport: transport, endpoint: local)] = client
        clientsByLocalPortKey[LocalPortKey(transport: transport, port: local.port)] = client

        guard let remote = remoteEndpoint(from: info), remote.port > 0 else {
            return
        }

        clientsBySocketKey[SocketKey(transport: transport, local: local, remote: remote)] = client
    }

    func client(for pid: pid_t) -> PacketClient? {
        let executablePath = environment.processPath(pid)
        if let client = clientsByPID[pid],
           let cachedIdentity = processIdentityCacheByPID[pid],
           cachedIdentity.executablePath == executablePath {
            return client
        }

        if let cachedIdentity = processIdentityCacheByPID[pid],
           cachedIdentity.executablePath == executablePath {
            clientsByPID[pid] = cachedIdentity.client
            return cachedIdentity.client
        }

        let name = environment.processName(pid)
        let bundleURL = executablePath.flatMap(appBundleURL(for:))
        let bundleIdentity = bundleURL.flatMap(cachedBundleIdentity(for:))
        let displayName = bundleIdentity?.displayName ??
            executablePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ??
            name

        let client = PacketClient(
            pid: pid,
            name: name,
            displayName: displayName,
            executablePath: executablePath,
            bundleIdentifier: bundleIdentity?.bundleIdentifier,
            bundlePath: bundleURL?.path
        )
        clientsByPID[pid] = client
        rememberProcessIdentity(pid: pid, executablePath: executablePath, client: client)
        return client
    }

    private func rememberProcessIdentity(pid: pid_t, executablePath: String?, client: PacketClient) {
        if processIdentityCacheByPID[pid] == nil {
            processIdentityOrder.append(pid)
        }

        processIdentityCacheByPID[pid] = ProcessIdentityCacheEntry(executablePath: executablePath, client: client)
        while processIdentityOrder.count > maxProcessIdentityCacheEntries {
            let removedPID = processIdentityOrder.removeFirst()
            processIdentityCacheByPID.removeValue(forKey: removedPID)
        }
    }

    private func cachedBundleIdentity(for bundleURL: URL) -> MacOSBundleIdentity {
        let path = bundleURL.path
        if let identity = bundleIdentityByPath[path] {
            return identity
        }

        let identity = environment.bundleIdentity(bundleURL)
        bundleIdentityByPath[path] = identity
        bundleIdentityOrder.append(path)
        while bundleIdentityOrder.count > maxBundleIdentityCacheEntries {
            let removedPath = bundleIdentityOrder.removeFirst()
            bundleIdentityByPath.removeValue(forKey: removedPath)
        }
        return identity
    }

    private func appBundleURL(for executablePath: String) -> URL? {
        var url = URL(fileURLWithPath: executablePath)
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func localEndpoint(from info: in_sockinfo) -> SocketEndpoint? {
        endpoint(address: localAddress(from: info), port: info.insi_lport)
    }

    private func remoteEndpoint(from info: in_sockinfo) -> SocketEndpoint? {
        endpoint(address: remoteAddress(from: info), port: info.insi_fport)
    }

    private func endpoint(address: String?, port: Int32) -> SocketEndpoint? {
        guard let address else {
            return nil
        }

        let hostPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: port))
        return SocketEndpoint(address: address.lowercased(), port: hostPort)
    }

    private func localAddress(from info: in_sockinfo) -> String? {
        if (Int32(info.insi_vflag) & INI_IPV4) != 0 {
            return ipv4String(info.insi_laddr.ina_46.i46a_addr4)
        }

        if (Int32(info.insi_vflag) & INI_IPV6) != 0 {
            return ipv6String(info.insi_laddr.ina_6)
        }

        return nil
    }

    private func remoteAddress(from info: in_sockinfo) -> String? {
        if (Int32(info.insi_vflag) & INI_IPV4) != 0 {
            return ipv4String(info.insi_faddr.ina_46.i46a_addr4)
        }

        if (Int32(info.insi_vflag) & INI_IPV6) != 0 {
            return ipv6String(info.insi_faddr.ina_6)
        }

        return nil
    }

    private func ipv4String(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    private func ipv6String(_ address: in6_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }
}

private extension MacOSPacketClientResolver.SocketEndpoint {
    init?(_ endpoint: PacketEndpoint) {
        guard let address = endpoint.address, let port = endpoint.port else {
            return nil
        }

        self.init(address: address.lowercased(), port: port)
    }
}

private extension MacOSPacketClientResolver.SocketTransport {
    init?(packet: PacketSummary) {
        let layerNames = Set(packet.layers.map { $0.name.lowercased() })
        if layerNames.contains("tcp") {
            self = .tcp
            return
        }

        if layerNames.contains("udp") {
            self = .udp
            return
        }

        switch packet.transportHint {
        case .tcp, .http1, .tls, .websocket:
            self = .tcp
        case .udp:
            self = .udp
        default:
            return nil
        }
    }
}

extension PacketSummary {
    func tcpviewerApplying(summaryUpdate: PacketSummaryUpdate) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: packetNumber,
            timestamp: timestamp,
            source: source,
            interfaceID: interfaceID,
            transportHint: transportHint,
            protocolSummary: summaryUpdate.protocolSummary,
            endpoints: endpoints,
            originalLength: originalLength,
            capturedLength: capturedLength,
            streamID: streamID,
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: summaryUpdate.infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName,
            client: client
        )
    }

    func tcpviewerApplying(
        sniDomainName: String? = nil,
        client: PacketClient? = nil,
        direction: PacketDirection? = nil
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: packetNumber,
            timestamp: timestamp,
            source: source,
            interfaceID: interfaceID,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: endpoints,
            originalLength: originalLength,
            capturedLength: capturedLength,
            streamID: streamID,
            direction: direction ?? self.direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName ?? self.sniDomainName,
            client: client ?? self.client
        )
    }

    func tcpviewerRemapping(identifier: PacketSummary.ID, source: CaptureSource) -> PacketSummary {
        PacketSummary(
            id: identifier,
            packetNumber: packetNumber,
            timestamp: timestamp,
            source: source,
            interfaceID: interfaceID,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: endpoints,
            originalLength: originalLength,
            capturedLength: capturedLength,
            streamID: streamID,
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName,
            client: client
        )
    }
}

private extension PacketSummary {
    var tcpviewerUsesTCP: Bool {
        MacOSPacketClientResolver.SocketTransport(packet: self) == .tcp
    }

    var tcpviewerStartsNewTCPConnection: Bool {
        guard tcpviewerUsesTCP else {
            return false
        }

        return tcpviewerTCPSummariesContainFlag("SYN")
    }

    var tcpviewerEndsTCPConnection: Bool {
        guard tcpviewerUsesTCP else {
            return false
        }

        return tcpviewerTCPSummariesContainFlag("FIN") || tcpviewerTCPSummariesContainFlag("RST")
    }

    func tcpviewerTCPSummariesContainFlag(_ flag: String) -> Bool {
        let summaries = layers.compactMap(\.detailSummary) + [infoSummary]
        return summaries.contains { summary in
            summary.localizedCaseInsensitiveContains(flag)
        }
    }
}
