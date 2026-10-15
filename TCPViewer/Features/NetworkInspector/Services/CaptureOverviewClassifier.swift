//
//  CaptureOverviewClassifier.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Foundation
import PcapPlusPlusCore

// Wireshark expert flags grouped for the Overview, most severe first. Each maps to one display filter.
enum CaptureOverviewTCPIssueKind: Int, CaseIterable, Sendable {
    case malformed
    case lostSegment
    case retransmission
    case outOfOrder
    case zeroWindow
    case duplicateAck
    case reset
}

// The flags of one packet; a packet can carry several, e.g. a duplicate ACK of an unseen segment.
struct CaptureOverviewTCPIssueSet: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ kind: CaptureOverviewTCPIssueKind) {
        rawValue = 1 << UInt8(kind.rawValue)
    }

    // Malformed packets can be any protocol, so only the other flags count as TCP issues.
    var hasTCPIssue: Bool {
        !subtracting(CaptureOverviewTCPIssueSet(.malformed)).isEmpty
    }
}

extension CaptureOverviewTCPIssueKind {
    var title: String {
        switch self {
        case .malformed: "Malformed Packets"
        case .lostSegment: "Lost Segments"
        case .retransmission: "Retransmissions"
        case .outOfOrder: "Out-of-Order"
        case .zeroWindow: "Zero Window"
        case .duplicateAck: "Duplicate ACKs"
        case .reset: "Resets (RST)"
        }
    }

    var explanation: String {
        switch self {
        case .malformed: "Packets Wireshark could not fully dissect."
        case .lostSegment: "A previous segment was not captured, or an ACK covers data that was never seen."
        case .retransmission: "Segments sent again, including fast and spurious retransmissions."
        case .outOfOrder: "Segments that arrived after a later segment."
        case .zeroWindow: "The receiver's buffer was full: zero window, window probes or window full."
        case .duplicateAck: "Repeated ACKs, usually a sign of loss or reordering."
        case .reset: "Connections closed abruptly with the RST flag."
        }
    }
}

enum CaptureOverviewTransport: String, Hashable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

struct CaptureOverviewServiceKey: Hashable, Sendable {
    let transport: CaptureOverviewTransport
    let port: UInt16
}

// The two sides of a conversation as shown in the Overview.
struct CaptureOverviewConversationEndpoints: Hashable, Sendable {
    let transport: CaptureOverviewTransport
    let clientAddress: String
    let clientPort: UInt16
    let serverAddress: String
    let serverPort: UInt16
}

// Wireshark's stream index tells apart connections that reuse the same ports; packets it hasn't indexed yet
// fall back to their direction-independent address and port pair.
enum CaptureOverviewConversationKey: Hashable, Sendable {
    case stream(FollowStreamID)
    case endpoints(CaptureOverviewConversationEndpoints)
}

// One packet's view of its conversation: the identity to group by and the sides to display.
struct CaptureOverviewConversationSample: Sendable {
    let key: CaptureOverviewConversationKey
    let endpoints: CaptureOverviewConversationEndpoints
    // True when a SYN shows which side opened the connection, rather than guessing from the ports.
    let isClientConfirmed: Bool
}

enum CaptureOverviewClassifier {
    // Wireshark's Statistics › Packet Lengths ranges; the ranges below 80 bytes are merged.
    static let packetLengthUpperBounds = [80, 160, 320, 640, 1_280, 2_560]
    static let packetLengthBucketCount = packetLengthUpperBounds.count + 1

    // Index of the Packet Lengths range that holds a frame of this length.
    static func packetLengthBucket(for length: Int) -> Int {
        packetLengthUpperBounds.firstIndex { length < $0 } ?? packetLengthUpperBounds.count
    }

    // Full range label for tooltips and the Markdown report.
    static func packetLengthTitle(forBucket index: Int) -> String {
        let lowerBound = index == 0 ? 0 : packetLengthUpperBounds[index - 1]
        guard index < packetLengthUpperBounds.count else {
            return "\(lowerBound) bytes or more"
        }
        return "\(lowerBound)–\(packetLengthUpperBounds[index] - 1) bytes"
    }

    // Short lower-bound labels keep seven bars readable on a narrow card.
    static func packetLengthAxisTitle(forBucket index: Int) -> String {
        index == 0 ? "<\(packetLengthUpperBounds[0])" : "\(packetLengthUpperBounds[index - 1])+"
    }

    // TCP flags are the most reliable sign; the transport hint covers packets the dissector summarized.
    static func isTCP(_ packet: PacketSummary) -> Bool {
        if packet.tcpFlags != nil {
            return true
        }
        switch packet.transportHint {
        case .tcp, .tls, .http1, .websocket:
            return true
        default:
            return false
        }
    }

    // The Info column text Wireshark's TCP analysis prepends for each flag (epan/dissectors/packet-tcp.c).
    // The EPAN summary pass exposes these flags only as text; a unit test pins every marker to the vendored
    // Wireshark sources, so an upgrade that rewords one fails loudly instead of silently zeroing a row.
    static let tcpInfoMarkers: [(kind: CaptureOverviewTCPIssueKind, markers: [String])] = [
        (.lostSegment, ["[TCP Previous segment not captured]", "[TCP ACKed unseen segment]"]),
        (.retransmission, ["[TCP Retransmission]", "[TCP Fast Retransmission]", "[TCP Spurious Retransmission]"]),
        (.outOfOrder, ["[TCP Out-Of-Order]"]),
        (.zeroWindow, ["[TCP ZeroWindow]", "[TCP ZeroWindowProbe]", "[TCP ZeroWindowProbeAck]", "[TCP Window Full]"]),
        (.duplicateAck, ["[TCP Dup ACK "]),
    ]
    // Appended by epan/show_exception.c whenever it also sets _ws.malformed.
    static let malformedInfoMarker = "[Malformed Packet"

    // Read the markers Wireshark writes to the Info column; each flag matches its row's display filter.
    static func tcpIssues(for packet: PacketSummary, isTCP: Bool) -> CaptureOverviewTCPIssueSet {
        let info = packet.infoSummary
        var issues: CaptureOverviewTCPIssueSet = []
        if info.hasSuffix("]"), info.suffix(160).contains(malformedInfoMarker) {
            issues.insert(CaptureOverviewTCPIssueSet(.malformed))
        }
        guard isTCP else {
            return issues
        }
        // TCP markers are fenced at the start of the column, so long Info text is never scanned.
        if info.hasPrefix("[TCP ") {
            let leadingText = info.prefix(200)
            for (kind, markers) in tcpInfoMarkers where markers.contains(where: { leadingText.contains($0) }) {
                issues.insert(CaptureOverviewTCPIssueSet(kind))
            }
        }
        if packet.tcpFlags?.contains("RST") == true {
            issues.insert(CaptureOverviewTCPIssueSet(.reset))
        }
        return issues
    }

    // The lower port of a TCP or UDP packet is almost always the server's service port.
    static func serviceKey(for packet: PacketSummary, isTCP: Bool) -> CaptureOverviewServiceKey? {
        guard let sourcePort = packet.endpoints.source.port,
              let destinationPort = packet.endpoints.destination.port,
              sourcePort > 0, destinationPort > 0 else {
            return nil
        }
        return CaptureOverviewServiceKey(
            transport: isTCP ? .tcp : .udp,
            port: min(sourcePort, destinationPort)
        )
    }

    // Group by Wireshark's stream index when present; a SYN, when seen, decides which side is the client.
    static func conversation(for packet: PacketSummary, isTCP: Bool) -> CaptureOverviewConversationSample? {
        guard let sourceAddress = packet.endpoints.source.address, !sourceAddress.isEmpty,
              let destinationAddress = packet.endpoints.destination.address, !destinationAddress.isEmpty,
              let sourcePort = packet.endpoints.source.port,
              let destinationPort = packet.endpoints.destination.port else {
            return nil
        }
        let transport: CaptureOverviewTransport = isTCP ? .tcp : .udp
        let source = (address: sourceAddress, port: sourcePort)
        let destination = (address: destinationAddress, port: destinationPort)
        // Without a handshake, the endpoint with the lower port is almost always the server.
        let sourceIsServer = (sourcePort, sourceAddress) < (destinationPort, destinationAddress)
        let guessed = endpoints(transport, client: sourceIsServer ? destination : source, server: sourceIsServer ? source : destination)

        // tcpFlags reads like "SYN, ACK"; no other flag name contains "SYN" or "ACK".
        let displayed: CaptureOverviewConversationEndpoints
        let isClientConfirmed: Bool
        if isTCP, let flags = packet.tcpFlags, flags.contains("SYN") {
            // The SYN comes from the client and the SYN-ACK from the server.
            displayed = flags.contains("ACK")
                ? endpoints(transport, client: destination, server: source)
                : endpoints(transport, client: source, server: destination)
            isClientConfirmed = true
        } else {
            displayed = guessed
            isClientConfirmed = false
        }
        let key: CaptureOverviewConversationKey = packet.followStreamID.map { .stream($0) } ?? .endpoints(guessed)
        return CaptureOverviewConversationSample(key: key, endpoints: displayed, isClientConfirmed: isClientConfirmed)
    }

    // Endpoints with the given client and server sides.
    private static func endpoints(
        _ transport: CaptureOverviewTransport,
        client: (address: String, port: UInt16),
        server: (address: String, port: UInt16)
    ) -> CaptureOverviewConversationEndpoints {
        CaptureOverviewConversationEndpoints(
            transport: transport,
            clientAddress: client.address,
            clientPort: client.port,
            serverAddress: server.address,
            serverPort: server.port
        )
    }

    // Stable text identity for presentation rows and ForEach.
    static func identifier(for key: CaptureOverviewConversationKey) -> String {
        switch key {
        case .stream(let stream):
            return "\(stream.streamProtocol.rawValue).stream:\(stream.streamID)"
        case .endpoints(let endpoints):
            return "\(endpoints.transport.rawValue)|\(endpoints.clientAddress)|\(endpoints.clientPort)|" +
                "\(endpoints.serverAddress)|\(endpoints.serverPort)"
        }
    }

    // Common port names; UDP 443 is QUIC rather than HTTPS.
    static func serviceName(for key: CaptureOverviewServiceKey) -> String? {
        if key.transport == .udp, key.port == 443 {
            return "QUIC"
        }
        return wellKnownServiceNames[key.port]
    }

    // The Wireshark filter that shows exactly the packets counted for this flag.
    static func displayFilter(for issue: CaptureOverviewTCPIssueKind) -> String {
        switch issue {
        case .malformed:
            return "_ws.malformed"
        case .lostSegment:
            return "tcp.analysis.lost_segment || tcp.analysis.ack_lost_segment"
        case .retransmission:
            return "tcp.analysis.retransmission || tcp.analysis.fast_retransmission || tcp.analysis.spurious_retransmission"
        case .outOfOrder:
            return "tcp.analysis.out_of_order"
        case .zeroWindow:
            return "tcp.analysis.zero_window || tcp.analysis.zero_window_probe || " +
                "tcp.analysis.zero_window_probe_ack || tcp.analysis.window_full"
        case .duplicateAck:
            return "tcp.analysis.duplicate_ack"
        case .reset:
            return "tcp.flags.reset == 1"
        }
    }

    // Every TCP or UDP packet to or from this port.
    static func displayFilter(for key: CaptureOverviewServiceKey) -> String {
        "\(portField(for: key.transport)) == \(key.port)"
    }

    // A stream index filters one connection exactly; addresses come from capture data, so only plain
    // IPv4/IPv6 literals become filter text.
    static func displayFilter(for key: CaptureOverviewConversationKey) -> String? {
        switch key {
        case .stream(let stream):
            return "\(stream.streamProtocol == .udp ? "udp" : "tcp").stream eq \(stream.streamID)"
        case .endpoints(let endpoints):
            guard isFilterSafeAddress(endpoints.clientAddress), isFilterSafeAddress(endpoints.serverAddress) else {
                return nil
            }
            let addressField = endpoints.serverAddress.contains(":") ? "ipv6.addr" : "ip.addr"
            let portField = portField(for: endpoints.transport)
            return "\(addressField) == \(endpoints.clientAddress) && \(portField) == \(endpoints.clientPort) && " +
                "\(addressField) == \(endpoints.serverAddress) && \(portField) == \(endpoints.serverPort)"
        }
    }

    // Only hex digits, dots and colons, so capture data can't inject filter syntax.
    static func isFilterSafeAddress(_ address: String) -> Bool {
        !address.isEmpty && address.utf8.count <= 45 && address.unicodeScalars.allSatisfy {
            filterSafeAddressCharacters.contains($0)
        }
    }

    private static let filterSafeAddressCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")

    // Wireshark's port field for the transport.
    private static func portField(for transport: CaptureOverviewTransport) -> String {
        transport == .tcp ? "tcp.port" : "udp.port"
    }

    private static let wellKnownServiceNames: [UInt16: String] = [
        20: "FTP Data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP",
        80: "HTTP", 88: "Kerberos", 110: "POP3", 123: "NTP", 137: "NetBIOS", 138: "NetBIOS", 139: "NetBIOS",
        143: "IMAP", 161: "SNMP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS", 500: "IKE",
        514: "Syslog", 546: "DHCPv6", 547: "DHCPv6", 548: "AFP", 587: "SMTP", 636: "LDAPS", 853: "DNS over TLS",
        993: "IMAPS", 995: "POP3S", 1194: "OpenVPN", 1900: "SSDP", 3306: "MySQL", 3389: "RDP",
        3478: "STUN", 4500: "IPsec NAT-T", 5223: "Apple Push", 5228: "Google Play", 5353: "mDNS",
        5355: "LLMNR", 5432: "PostgreSQL", 5900: "VNC", 6379: "Redis", 7000: "AirPlay", 8080: "HTTP Alt",
        8443: "HTTPS Alt", 27017: "MongoDB", 51820: "WireGuard", 62078: "iPhone Sync",
    ]
}
