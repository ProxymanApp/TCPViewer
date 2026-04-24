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
}

protocol PacketMetadataEnriching: AnyObject {
    func reset()
    func enrich(_ packets: [PacketSummary], source: CaptureSource) -> PacketMetadataEnrichmentResult
}

protocol PacketClientResolving: AnyObject {
    func reset()
    func client(for packet: PacketSummary) -> PacketClient?
}

final class PacketMetadataEnrichmentService: PacketMetadataEnriching {
    private struct FlowMetadata {
        var sniDomainName: String?
        var client: PacketClient?
        var packetIDs: [PacketSummary.ID] = []
    }

    private let maxCachedFlows: Int
    private let clientResolver: any PacketClientResolving
    private var flowMetadataByStreamID: [UInt32: FlowMetadata] = [:]
    private var flowOrder: [UInt32] = []

    init(
        maxCachedFlows: Int = 100_000,
        clientResolver: any PacketClientResolving = MacOSPacketClientResolver()
    ) {
        self.maxCachedFlows = max(maxCachedFlows, 1)
        self.clientResolver = clientResolver
    }

    // Reset flow and process caches when packet lineage changes.
    func reset() {
        flowMetadataByStreamID.removeAll(keepingCapacity: true)
        flowOrder.removeAll(keepingCapacity: true)
        clientResolver.reset()
    }

    // Enrich the incoming batch and emit flow updates for packets already stored.
    func enrich(_ packets: [PacketSummary], source: CaptureSource) -> PacketMetadataEnrichmentResult {
        var enrichedPackets: [PacketSummary] = []
        var updates: [PacketMetadataUpdate] = []
        enrichedPackets.reserveCapacity(packets.count)

        for packet in packets {
            guard let streamID = packet.streamID else {
                let client = source == .live ? clientResolver.client(for: packet) : nil
                enrichedPackets.append(packet.packetryApplying(sniDomainName: packet.sniDomainName, client: client))
                continue
            }

            var metadata = metadataForFlow(streamID)
            var shouldBackfill = false

            if let sniDomainName = packet.sniDomainName, !sniDomainName.isEmpty, metadata.sniDomainName != sniDomainName {
                metadata.sniDomainName = sniDomainName
                shouldBackfill = true
            }

            if source == .live, metadata.client == nil, let client = clientResolver.client(for: packet) {
                metadata.client = client
                shouldBackfill = true
            }

            if shouldBackfill, !metadata.packetIDs.isEmpty {
                updates.append(PacketMetadataUpdate(
                    packetIDs: metadata.packetIDs,
                    sniDomainName: metadata.sniDomainName,
                    client: metadata.client
                ))
            }

            let enrichedPacket = packet.packetryApplying(
                sniDomainName: metadata.sniDomainName ?? packet.sniDomainName,
                client: metadata.client
            )
            metadata.packetIDs.append(packet.id)
            flowMetadataByStreamID[streamID] = metadata
            enrichedPackets.append(enrichedPacket)
        }

        return PacketMetadataEnrichmentResult(packets: enrichedPackets, updates: updates)
    }

    private func metadataForFlow(_ streamID: UInt32) -> FlowMetadata {
        if let metadata = flowMetadataByStreamID[streamID] {
            return metadata
        }

        flowOrder.append(streamID)
        if flowOrder.count > maxCachedFlows {
            let removedStreamID = flowOrder.removeFirst()
            flowMetadataByStreamID.removeValue(forKey: removedStreamID)
        }

        let metadata = FlowMetadata()
        flowMetadataByStreamID[streamID] = metadata
        return metadata
    }
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

    private let snapshotTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private var snapshotDate: Date?
    private var clientsBySocketKey: [SocketKey: PacketClient] = [:]
    private var clientsByLocalEndpointKey: [LocalEndpointKey: PacketClient] = [:]
    private var clientsByLocalPortKey: [LocalPortKey: PacketClient] = [:]
    private var clientsByPID: [pid_t: PacketClient] = [:]
    private var negativeLookups: [PacketLookupKey: Date] = [:]

    init(snapshotTTL: TimeInterval = 0.5, negativeTTL: TimeInterval = 0.5) {
        self.snapshotTTL = snapshotTTL
        self.negativeTTL = negativeTTL
    }

    // Clear process snapshots between live capture sessions.
    func reset() {
        snapshotDate = nil
        clientsBySocketKey.removeAll(keepingCapacity: true)
        clientsByLocalEndpointKey.removeAll(keepingCapacity: true)
        clientsByLocalPortKey.removeAll(keepingCapacity: true)
        clientsByPID.removeAll(keepingCapacity: true)
        negativeLookups.removeAll(keepingCapacity: true)
    }

    // Resolve a packet to the current macOS process that owns its local socket.
    func client(for packet: PacketSummary) -> PacketClient? {
        guard let lookupKey = PacketLookupKey(packet: packet) else {
            return nil
        }

        let now = Date()
        if let negativeDate = negativeLookups[lookupKey], now.timeIntervalSince(negativeDate) < negativeTTL {
            return nil
        }

        refreshSnapshotIfNeeded(now: now)

        if let client = client(for: lookupKey) {
            negativeLookups.removeValue(forKey: lookupKey)
            return client
        }

        negativeLookups[lookupKey] = now
        return nil
    }

    private func client(for lookupKey: PacketLookupKey) -> PacketClient? {
        if let client = clientsBySocketKey[SocketKey(
            transport: lookupKey.transport,
            local: lookupKey.source,
            remote: lookupKey.destination
        )] {
            return client
        }

        if let client = clientsBySocketKey[SocketKey(
            transport: lookupKey.transport,
            local: lookupKey.destination,
            remote: lookupKey.source
        )] {
            return client
        }

        if let client = clientsByLocalEndpointKey[LocalEndpointKey(transport: lookupKey.transport, endpoint: lookupKey.source)] {
            return client
        }

        if let client = clientsByLocalEndpointKey[LocalEndpointKey(transport: lookupKey.transport, endpoint: lookupKey.destination)] {
            return client
        }

        return clientsByLocalPortKey[LocalPortKey(transport: lookupKey.transport, port: lookupKey.source.port)] ??
            clientsByLocalPortKey[LocalPortKey(transport: lookupKey.transport, port: lookupKey.destination.port)]
    }

    private func refreshSnapshotIfNeeded(now: Date) {
        if let snapshotDate, now.timeIntervalSince(snapshotDate) < snapshotTTL {
            return
        }

        snapshotDate = now
        clientsBySocketKey.removeAll(keepingCapacity: true)
        clientsByLocalEndpointKey.removeAll(keepingCapacity: true)
        clientsByLocalPortKey.removeAll(keepingCapacity: true)

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

    private func client(for pid: pid_t) -> PacketClient? {
        if let client = clientsByPID[pid] {
            return client
        }

        let name = processName(for: pid)
        let executablePath = processPath(for: pid)
        let bundleURL = executablePath.flatMap(appBundleURL(for:))
        let bundle = bundleURL.flatMap(Bundle.init(url:))
        let displayName = bundleDisplayName(bundle) ??
            executablePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ??
            name

        let client = PacketClient(
            pid: pid,
            name: name,
            displayName: displayName,
            executablePath: executablePath,
            bundleIdentifier: bundle?.bundleIdentifier,
            bundlePath: bundleURL?.path
        )
        clientsByPID[pid] = client
        return client
    }

    private func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return "PID \(pid)"
        }
        return String(cString: buffer)
    }

    private func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private func bundleDisplayName(_ bundle: Bundle?) -> String? {
        guard let bundle else {
            return nil
        }

        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
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
    func packetryApplying(sniDomainName: String? = nil, client: PacketClient? = nil) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: packetNumber,
            timestamp: timestamp,
            source: source,
            interfaceID: interfaceID,
            transportHint: transportHint,
            endpoints: endpoints,
            originalLength: originalLength,
            capturedLength: capturedLength,
            streamID: streamID,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName ?? self.sniDomainName,
            client: client ?? self.client
        )
    }
}
