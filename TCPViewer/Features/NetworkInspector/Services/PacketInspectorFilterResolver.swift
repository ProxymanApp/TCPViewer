//
//  PacketInspectorFilterResolver.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation

struct PacketInspectorFilterRequest: Equatable, Sendable {
    let displayFilterExpression: String?
    let nativeFilter: PacketStructuredFilter?

    init?(displayFilterExpression: String?, nativeFilter: PacketStructuredFilter?) {
        let normalizedExpression = displayFilterExpression?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let activeNativeFilter = nativeFilter?.isActive == true ? nativeFilter : nil
        guard normalizedExpression != nil || activeNativeFilter != nil else {
            return nil
        }

        self.displayFilterExpression = normalizedExpression
        self.nativeFilter = activeNativeFilter
    }
}

enum PacketInspectorFilterResolver {
    // Prefer Wireshark's exact row expression, while retaining one accurate PacketSummary fallback when available.
    static func resolve(
        displayFilterExpression: String?,
        fieldName: String?,
        value: String?,
        rawValue _: String?
    ) -> PacketInspectorFilterRequest? {
        PacketInspectorFilterRequest(
            displayFilterExpression: displayFilterExpression,
            nativeFilter: nativeFilter(fieldName: fieldName, value: value)
        )
    }

    private static func nativeFilter(fieldName: String?, value: String?) -> PacketStructuredFilter? {
        guard let fieldName = fieldName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty else {
            return nil
        }

        switch fieldName {
        case "ip.src", "ipv6.src", "arp.src.proto_ipv4":
            return exactFilter(query: .source, value: value)
        case "ip.dst", "ipv6.dst", "arp.dst.proto_ipv4":
            return exactFilter(query: .destination, value: value)
        case "tcp.srcport", "udp.srcport":
            return exactNumericFilter(query: .sourcePort, value: value)
        case "tcp.dstport", "udp.dstport":
            return exactNumericFilter(query: .destinationPort, value: value)
        case "tcp.stream", "udp.stream":
            // Wireshark stream indexes differ from TCPViewer's endpoint-derived stream ID.
            return nil
        case "tcp.len":
            return exactNumericFilter(query: .tcpPayload, value: value)
        case "frame.cap_len":
            return exactNumericFilter(query: .length, value: value)
        case "frame.interface", "frame.interface_name":
            return exactInterfaceFilter(value: value)
        case "frame.interface_id":
            return nil
        case "tls.handshake.extensions_server_name":
            return exactFilter(query: .urlDomain, value: value)
        case "dns.qry.name", "dns.resp.name":
            return nil
        case "_ws.col.info":
            return exactFilter(query: .summary, value: value)
        case "http.request.method":
            return summaryTokenFilter(value: value, position: .first)
        case "http.request.uri":
            return summaryTokenFilter(value: value, position: .second)
        case "http.request.version":
            return summaryTokenFilter(value: value, position: .last)
        case "tcp.flags":
            return tcpFlagsFilter(value: value)
        case let name where name.hasPrefix("tcp.flags."):
            return tcpFlagFilter(fieldName: name, value: value)
        case "tcpviewer.client":
            return exactFilter(query: .client, value: value)
        case "tcpviewer.pid":
            return exactNumericFilter(query: .pid, value: value)
        case "tcpviewer.bundle_identifier":
            return exactFilter(query: .bundleIdentifier, value: value)
        case "tcpviewer.direction":
            return exactFilter(query: .direction, value: value)
        case "tcpviewer.decode_status",
             "tcpviewer.warning.malformed",
             "tcpviewer.warning.unsupported":
            return exactFilter(query: .decodeStatus, value: value)
        case "tcpviewer.warning.decode":
            return nil
        case "tcpviewer.summary":
            return exactFilter(query: .summary, value: value)
        case "tcpviewer.tags":
            return exactFilter(query: .tags, value: value)
        case "tcpviewer.interface":
            return exactInterfaceFilter(value: value)
        default:
            guard let protocolName = protocolName(for: fieldName) else {
                return nil
            }
            return exactFilter(query: .protocol, value: protocolName)
        }
    }

    private static func exactFilter(query: PacketStructuredFilterQuery, value: String?) -> PacketStructuredFilter? {
        guard let value = normalizedValue(value) else {
            return nil
        }

        return PacketStructuredFilter(
            query: query,
            condition: .matchesRegex,
            text: "^\(NSRegularExpression.escapedPattern(for: value))$"
        )
    }

    private static func exactNumericFilter(query: PacketStructuredFilterQuery, value: String?) -> PacketStructuredFilter? {
        guard let value = firstUnsignedInteger(in: value) else {
            return nil
        }

        return PacketStructuredFilter(query: query, condition: .matchesRegex, text: "^\(value)$")
    }

    private static func exactInterfaceFilter(value: String?) -> PacketStructuredFilter? {
        guard let value = normalizedValue(value), value.caseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        return exactFilter(query: .interface, value: value)
    }

    private enum SummaryTokenPosition {
        case first
        case second
        case last
    }

    private static func summaryTokenFilter(value: String?, position: SummaryTokenPosition) -> PacketStructuredFilter? {
        guard let value = normalizedValue(value) else {
            return nil
        }

        let escapedValue = NSRegularExpression.escapedPattern(for: value)
        let pattern: String
        switch position {
        case .first:
            pattern = "^\(escapedValue)(?:\\s|$)"
        case .second:
            pattern = "^\\S+\\s+\(escapedValue)(?:\\s|$)"
        case .last:
            pattern = "(?:^|\\s)\(escapedValue)$"
        }
        return PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: pattern)
    }

    private static func tcpFlagsFilter(value: String?) -> PacketStructuredFilter? {
        guard let value = normalizedValue(value),
              let maskToken = value.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first,
              maskToken.lowercased().hasPrefix("0x"),
              let mask = UInt64(maskToken.dropFirst(2), radix: 16) else {
            return nil
        }

        if mask == 0 {
            return PacketStructuredFilter(query: .tcpFlags, condition: .matchesRegex, text: "^$")
        }

        guard let openParenthesis = value.lastIndex(of: "("),
              let closeParenthesis = value.lastIndex(of: ")"),
              openParenthesis < closeParenthesis else {
            return nil
        }
        let supportedNames = Set(["CWR", "ECE", "URG", "ACK", "PSH", "RST", "SYN", "FIN"])
        let names = value[value.index(after: openParenthesis)..<closeParenthesis]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard !names.isEmpty, names.allSatisfy(supportedNames.contains) else {
            // PacketSummary does not retain AE, ACE, or reserved bits.
            return nil
        }
        return exactFilter(query: .tcpFlags, value: names.joined(separator: ", "))
    }

    private static func tcpFlagFilter(fieldName: String, value: String?) -> PacketStructuredFilter? {
        guard let fieldSuffix = fieldName.split(separator: ".").last.map(String.init)?.lowercased(),
              let value = normalizedValue(value)?.lowercased() else {
            return nil
        }
        let flagName = ["push": "PSH", "reset": "RST"][fieldSuffix] ?? fieldSuffix.uppercased()
        guard ["CWR", "ECE", "URG", "ACK", "PSH", "RST", "SYN", "FIN"].contains(flagName) else {
            return nil
        }

        switch value {
        case "set", "true", "1":
            break
        case "not set", "false", "0":
            // PacketSummary cannot distinguish an absent TCP field from a flag that is not set.
            return nil
        default:
            return nil
        }

        let pattern = "(?:^|,\\s*)\(flagName)(?:\\s*,|$)"
        return PacketStructuredFilter(query: .tcpFlags, condition: .matchesRegex, text: pattern)
    }

    private static func protocolName(for fieldName: String) -> String? {
        switch fieldName {
        case "eth": "Ethernet"
        case "arp": "ARP"
        case "ip": "IPv4"
        case "ipv6": "IPv6"
        case "icmp": "ICMP"
        case "icmpv6": "ICMPv6"
        case "tcp": "TCP"
        case "udp": "UDP"
        case "dns": "DNS"
        case "http": "HTTP"
        case "http2": "HTTP2"
        case "tls": "TLS"
        case "websocket": "WebSocket"
        default: nil
        }
    }

    private static func normalizedValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func firstUnsignedInteger(in value: String?) -> String? {
        guard let value else {
            return nil
        }

        var digits = ""
        var didStart = false
        for character in value {
            if character.isNumber {
                digits.append(character)
                didStart = true
            } else if didStart, character == "," || character == "_" {
                continue
            } else if didStart {
                break
            }
        }

        guard !digits.isEmpty, let number = UInt64(digits) else {
            return nil
        }
        return String(number)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
