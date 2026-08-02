//
//  PacketTextStyle.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 26/7/26.
//

import Foundation

public enum PacketHighlightColor: String, CaseIterable, Sendable, Codable, Hashable {
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case indigo
    case purple
    case pink
    case brown
    case gray
}

public struct PacketTextStyle: Sendable, Codable, Hashable {
    public let highlightColor: PacketHighlightColor?
    public let isStrikethrough: Bool

    public static let plain = PacketTextStyle()

    public init(highlightColor: PacketHighlightColor? = nil, isStrikethrough: Bool = false) {
        self.highlightColor = highlightColor
        self.isStrikethrough = isStrikethrough
    }

    public var isPlain: Bool {
        highlightColor == nil && !isStrikethrough
    }

    public func withHighlightColor(_ color: PacketHighlightColor?) -> PacketTextStyle {
        PacketTextStyle(highlightColor: color, isStrikethrough: isStrikethrough)
    }

    public func togglingStrikethrough() -> PacketTextStyle {
        PacketTextStyle(highlightColor: highlightColor, isStrikethrough: !isStrikethrough)
    }
}

public enum PacketTextStyleMutation: Sendable, Hashable {
    case setHighlightColor(PacketHighlightColor)
    case toggleStrikethrough
    case reset
    case replace(PacketTextStyle)

    // Resolve the next style without coupling callers to where packets are stored.
    public func applying(to currentStyle: PacketTextStyle) -> PacketTextStyle {
        switch self {
        case .setHighlightColor(let color):
            return currentStyle.withHighlightColor(color)
        case .toggleStrikethrough:
            return currentStyle.togglingStrikethrough()
        case .reset:
            return .plain
        case .replace(let style):
            return style
        }
    }
}

public struct PacketExportMetadata: Sendable {
    public let textStylesByPacketID: [PacketSummary.ID: PacketTextStyle]
    public let commentsByPacketID: [PacketSummary.ID: String]

    public static let empty = PacketExportMetadata()

    public init(
        textStylesByPacketID: [PacketSummary.ID: PacketTextStyle] = [:],
        commentsByPacketID: [PacketSummary.ID: String] = [:]
    ) {
        self.textStylesByPacketID = textStylesByPacketID
        self.commentsByPacketID = commentsByPacketID
    }
}

public extension PacketSummary {
    // Return a packet copy with only its presentation style changed.
    func applying(textStyle: PacketTextStyle) -> PacketSummary {
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
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName,
            dnsDomainName: dnsDomainName,
            dnsResolutions: dnsResolutions,
            client: client,
            textStyle: textStyle,
            customComment: customComment
        )
    }

    // Return a packet copy with a sanitized TCP Viewer comment override.
    func applying(customComment: String) -> PacketSummary {
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
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName,
            dnsDomainName: dnsDomainName,
            dnsResolutions: dnsResolutions,
            client: client,
            textStyle: textStyle,
            customComment: customComment
        )
    }
}
