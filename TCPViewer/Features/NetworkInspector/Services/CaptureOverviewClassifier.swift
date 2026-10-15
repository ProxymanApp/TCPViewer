//
//  CaptureOverviewClassifier.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Foundation
import PcapPlusPlusCore

// Wireshark TCP expert flags grouped for the Overview, most severe first so one packet counts once.
enum CaptureOverviewTCPIssueKind: Int, CaseIterable, Sendable {
    case malformed
    case lostSegment
    case retransmission
    case outOfOrder
    case zeroWindow
    case duplicateAck
    case reset
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
        case .zeroWindow: "The receiver's buffer was full: zero window or window full."
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

// A conversation is direction-independent: the server side is the endpoint with the lower (service) port.
struct CaptureOverviewConversationKey: Hashable, Sendable {
    let transport: CaptureOverviewTransport
    let clientAddress: String
    let clientPort: UInt16
    let serverAddress: String
    let serverPort: UInt16
}

enum CaptureOverviewClassifier {
    // Wireshark's Statistics › Packet Lengths ranges; the ranges below 80 bytes are merged.
    static let packetLengthUpperBounds = [80, 160, 320, 640, 1_280, 2_560]
    static let packetLengthBucketCount = packetLengthUpperBounds.count + 1

    static func packetLengthBucket(for length: Int) -> Int {
        packetLengthUpperBounds.firstIndex { length < $0 } ?? packetLengthUpperBounds.count
    }

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

    // Wireshark's TCP analysis prepends fenced markers such as "[TCP Retransmission] " to the Info column.
    static func tcpIssue(for packet: PacketSummary, isTCP: Bool) -> CaptureOverviewTCPIssueKind? {
        let info = packet.infoSummary
        // Wireshark appends "[Malformed Packet]" or "[Malformed Packet: reason]" to the Info column.
        if packet.decodeStatus.kind == .malformed ||
            (info.hasSuffix("]") && info.suffix(160).contains("[Malformed Packet")) {
            return .malformed
        }
        guard isTCP else {
            return nil
        }
        if info.hasPrefix("[TCP ") {
            // Only the leading markers matter, so long Info text is never scanned.
            let markers = info.prefix(200)
            if markers.contains("segment not captured") ||
                markers.contains("unseen segment") ||
                markers.contains("segment lost") {
                return .lostSegment
            }
            if markers.contains("Retransmission]") {
                return .retransmission
            }
            if markers.contains("[TCP Out-Of-Order]") {
                return .outOfOrder
            }
            if markers.contains("[TCP ZeroWindow") || markers.contains("[TCP Window Full]") {
                return .zeroWindow
            }
            if markers.contains("[TCP Dup ACK") {
                return .duplicateAck
            }
        }
        if packet.tcpFlags?.contains("RST") == true {
            return .reset
        }
        return nil
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

    static func conversationKey(for packet: PacketSummary, isTCP: Bool) -> CaptureOverviewConversationKey? {
        guard let sourceAddress = packet.endpoints.source.address, !sourceAddress.isEmpty,
              let destinationAddress = packet.endpoints.destination.address, !destinationAddress.isEmpty,
              let sourcePort = packet.endpoints.source.port,
              let destinationPort = packet.endpoints.destination.port else {
            return nil
        }
        let sourceIsServer = (sourcePort, sourceAddress) < (destinationPort, destinationAddress)
        return CaptureOverviewConversationKey(
            transport: isTCP ? .tcp : .udp,
            clientAddress: sourceIsServer ? destinationAddress : sourceAddress,
            clientPort: sourceIsServer ? destinationPort : sourcePort,
            serverAddress: sourceIsServer ? sourceAddress : destinationAddress,
            serverPort: sourceIsServer ? sourcePort : destinationPort
        )
    }

    // IPv6 literals need brackets before the port.
    static func endpointText(address: String, port: UInt16) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    static func serviceName(for key: CaptureOverviewServiceKey) -> String? {
        if key.transport == .udp, key.port == 443 {
            return "QUIC"
        }
        return wellKnownServiceNames[key.port]
    }

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
            return "tcp.analysis.zero_window || tcp.analysis.window_full"
        case .duplicateAck:
            return "tcp.analysis.duplicate_ack"
        case .reset:
            return "tcp.flags.reset == 1"
        }
    }

    static func displayFilter(for key: CaptureOverviewServiceKey) -> String {
        "\(portField(for: key.transport)) == \(key.port)"
    }

    // Addresses come from capture data, so only plain IPv4/IPv6 literals become filter text.
    static func displayFilter(for key: CaptureOverviewConversationKey) -> String? {
        guard isFilterSafeAddress(key.clientAddress), isFilterSafeAddress(key.serverAddress) else {
            return nil
        }
        let addressField = key.serverAddress.contains(":") ? "ipv6.addr" : "ip.addr"
        let portField = portField(for: key.transport)
        return "\(addressField) == \(key.clientAddress) && \(portField) == \(key.clientPort) && " +
            "\(addressField) == \(key.serverAddress) && \(portField) == \(key.serverPort)"
    }

    static func isFilterSafeAddress(_ address: String) -> Bool {
        !address.isEmpty && address.utf8.count <= 45 && address.unicodeScalars.allSatisfy {
            filterSafeAddressCharacters.contains($0)
        }
    }

    private static let filterSafeAddressCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")

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
