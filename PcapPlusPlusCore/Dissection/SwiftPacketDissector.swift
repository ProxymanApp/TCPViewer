//
//  SwiftPacketDissector.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 28/5/26.
//

import Darwin
import Foundation

private let opaquePayloadDecodeReason = "The remaining payload is encrypted, unsupported, or needs stream reassembly."

struct NativePacketRecord: Sendable {
    let identifier: UInt64
    let packetNumber: UInt64
    let timestamp: Date
    let rawBytes: Data
    let originalLength: Int
    let linkLayerType: Int32
    let interfaceIdentifier: String?
    let interfaceName: String?
    let packetComment: String?

    var capturedLength: Int {
        rawBytes.count
    }
}

struct SwiftPacketDissection {
    let summary: PCPPNativePacketSummaryDescriptor
    let inspection: PCPPNativePacketInspectionDescriptor
}

struct SwiftWiresharkRuntimeStatus: Sendable {
    let isAvailable: Bool
    let unavailableReason: String
}

struct SwiftWiresharkConsoleLogger {
    private let output: (String) -> Void

    init(output: @escaping (String) -> Void = { print($0) }) {
        self.output = output
    }

    // Print Wireshark warnings with a prominent marker so console scanning is easy.
    func warning(_ message: String) {
        log(level: "WARNING", message: message)
    }

    // Print Wireshark errors with a prominent marker so console scanning is easy.
    func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    private func log(level: String, message: String) {
        output("[TCPViewer][Wireshark] \(Self.timestamp()) ❌ \(level): \(message)")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

enum SwiftPacketDissector {
    private static let wiresharkWarningLogLock = NSLock()
    private static var loggedWiresharkWarningKeys: Set<String> = []

    static func dissect(record: NativePacketRecord, disablesWireshark: Bool) -> SwiftPacketDissection {
        dissect(
            record: record,
            disablesWireshark: disablesWireshark,
            wiresharkRuntimeStatus: SwiftWiresharkRuntime.shared.status,
            logger: SwiftWiresharkConsoleLogger()
        )
    }

    static func dissect(
        record: NativePacketRecord,
        disablesWireshark: Bool,
        wiresharkRuntimeStatus: SwiftWiresharkRuntimeStatus,
        logger: SwiftWiresharkConsoleLogger = SwiftWiresharkConsoleLogger()
    ) -> SwiftPacketDissection {
        let analyzer = PacketAnalyzer(record: record)
        let packet = analyzer.analyze()
        var nodes = packet.detailNodes
        if disablesWireshark {
            let reason = "Wireshark libwireshark backend is disabled for this capture."
            logWiresharkWarningOnce(key: "disabled", message: reason, logger: logger)
            nodes.insert(wiresharkFallbackWarning(reason), at: 0)
        } else if !wiresharkRuntimeStatus.isAvailable {
            let reason = wiresharkRuntimeStatus.unavailableReason
            logWiresharkWarningOnce(key: "unavailable:\(reason)", message: reason, logger: logger)
            nodes.insert(wiresharkFallbackWarning(reason), at: 0)
        }
        logDecodeIssueIfNeeded(packet.decodeStatus, packetNumber: record.packetNumber, logger: logger)

        let decodeDescriptor = PCPPNativeDecodeStatusDescriptor(
            kind: packet.decodeStatus.kind.nativeKind,
            reason: packet.decodeStatus.reason
        )
        let captureMetadata = PCPPNativePacketCaptureMetadataDescriptor(
            linkType: nativeLinkType(record.linkLayerType),
            truncated: record.rawBytes.count < record.originalLength,
            packetComment: record.packetComment,
            interfaceName: record.interfaceName
        )
        let summary = PCPPNativePacketSummaryDescriptor(
            identifier: record.identifier,
            packetNumber: record.packetNumber,
            timestamp: record.timestamp,
            interfaceIdentifier: record.interfaceIdentifier,
            transportHint: packet.transportHint.nativeHint,
            protocolSummary: packet.protocolSummary,
            sourceEndpoint: PCPPNativePacketEndpointDescriptor(address: packet.sourceAddress, port: packet.sourcePort.map { NSNumber(value: $0) }),
            destinationEndpoint: PCPPNativePacketEndpointDescriptor(address: packet.destinationAddress, port: packet.destinationPort.map { NSNumber(value: $0) }),
            originalLength: record.originalLength,
            capturedLength: record.rawBytes.count,
            streamIdentifier: packet.streamID.map { NSNumber(value: $0) },
            tcpFlags: packet.tcpFlags,
            tcpPayloadLength: packet.tcpPayloadLength.map { NSNumber(value: $0) },
            infoSummary: packet.infoSummary,
            layers: packet.layers.map { PCPPNativePacketLayerDescriptor(name: $0.name, detailSummary: $0.detailSummary) },
            decodeStatus: decodeDescriptor,
            captureMetadata: captureMetadata,
            sniDomainName: packet.sniDomainName
        )
        let inspection = PCPPNativePacketInspectionDescriptor(
            packetIdentifier: record.identifier,
            packetNumber: record.packetNumber,
            rawBytes: record.rawBytes,
            byteViews: [PCPPNativePacketByteViewDescriptor(identifier: "frame", label: "Frame", bytes: record.rawBytes)],
            detailNodes: nodes.map(\.descriptor),
            decodeStatus: decodeDescriptor
        )
        return SwiftPacketDissection(summary: summary, inspection: inspection)
    }

    private static func nativeLinkType(_ linkLayerType: Int32) -> PCPPNativeLinkType {
        switch linkLayerType {
        case Libpcap.dltEthernet:
            return .ethernet
        case Libpcap.dltNull:
            return .loopback
        case Libpcap.dltRaw:
            return .raw
        default:
            return .unknown
        }
    }

    private static func wiresharkFallbackWarning(_ reason: String) -> PacketDetailNode {
        PacketDetailNode(
            id: "wireshark.fallback",
            name: "Wireshark Dissector Unavailable",
            fieldName: "tcpviewer.wireshark.fallback",
            value: reason,
            kind: .warning,
            severity: .warning
        )
    }

    private static func logWiresharkWarningOnce(key: String, message: String, logger: SwiftWiresharkConsoleLogger) {
        let shouldLog = wiresharkWarningLogLock.withLock {
            if loggedWiresharkWarningKeys.contains(key) {
                return false
            }
            loggedWiresharkWarningKeys.insert(key)
            return true
        }

        if shouldLog {
            logger.warning(message)
        }
    }

    private static func logDecodeIssueIfNeeded(
        _ status: PacketDecodeStatus,
        packetNumber: UInt64,
        logger: SwiftWiresharkConsoleLogger
    ) {
        guard status.kind != .complete else {
            return
        }

        let reason = status.reason ?? "No reason provided."
        switch status.kind {
        case .complete:
            return
        case .malformed:
            logger.error("Packet #\(packetNumber) detail decode failed: \(reason)")
        case .partial, .unsupported:
            logger.warning("Packet #\(packetNumber) detail decode warning: \(reason)")
        }
    }
}

final class SwiftWiresharkRuntime {
    static let shared = SwiftWiresharkRuntime()

    private(set) var isAvailable = false
    private(set) var unavailableReason = "Wireshark libwireshark backend is unavailable. Run scripts/bootstrap-wireshark.sh, then rebuild TCP Viewer."
    private var handles: [UnsafeMutableRawPointer] = []
    private var wtapCleanup: (@convention(c) () -> Void)?
    private var epanCleanup: (@convention(c) () -> Void)?
    private var initializedWiretap = false
    private var initializedEpan = false
    private let logger = SwiftWiresharkConsoleLogger()

    var status: SwiftWiresharkRuntimeStatus {
        SwiftWiresharkRuntimeStatus(isAvailable: isAvailable, unavailableReason: unavailableReason)
    }

    private init() {
        loadRuntime()
    }

    private func loadRuntime() {
        guard let paths = loadLibrarySet() else {
            if let errorPointer = dlerror() {
                unavailableReason = String(cString: errorPointer)
            }
            logger.error("Failed to load Wireshark libraries: \(unavailableReason)")
            return
        }

        guard let wtapInit: @convention(c) (Bool) -> Void = loadSymbol("wtap_init", from: paths.wiretap),
              let wtapCleanup: @convention(c) () -> Void = loadSymbol("wtap_cleanup", from: paths.wiretap),
              let epanInit: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Bool) -> Bool = loadSymbol("epan_init", from: paths.wireshark),
              let epanLoadSettings: @convention(c) () -> UnsafeMutableRawPointer? = loadSymbol("epan_load_settings", from: paths.wireshark),
              let epanCleanup: @convention(c) () -> Void = loadSymbol("epan_cleanup", from: paths.wireshark),
              let prefsApplyAll: @convention(c) () -> Void = loadSymbol("prefs_apply_all", from: paths.wireshark) else {
            unavailableReason = "Wireshark runtime symbols could not be resolved."
            logger.error(unavailableReason)
            return
        }

        self.wtapCleanup = wtapCleanup
        self.epanCleanup = epanCleanup

        wtapInit(true)
        initializedWiretap = true

        guard epanInit(nil, nil, true) else {
            unavailableReason = "Wireshark protocol registry failed to initialize."
            logger.error(unavailableReason)
            wtapCleanup()
            initializedWiretap = false
            return
        }
        initializedEpan = true

        _ = epanLoadSettings()
        prefsApplyAll()

        isAvailable = true
        unavailableReason = ""
    }

    private func loadLibrarySet() -> (wsutil: UnsafeMutableRawPointer, wiretap: UnsafeMutableRawPointer, wireshark: UnsafeMutableRawPointer)? {
        for directory in libraryDirectories() {
            guard let wsutil = openLibrary(named: "libwsutil", majorVersion: 17, directory: directory) else {
                continue
            }
            guard let wiretap = openLibrary(named: "libwiretap", majorVersion: 16, directory: directory) else {
                dlclose(wsutil)
                continue
            }
            guard let wireshark = openLibrary(named: "libwireshark", majorVersion: 19, directory: directory) else {
                dlclose(wiretap)
                dlclose(wsutil)
                continue
            }

            handles = [wireshark, wiretap, wsutil]
            return (wsutil, wiretap, wireshark)
        }
        return nil
    }

    private func libraryDirectories() -> [URL?] {
        let frameworkBundle = Bundle(for: SwiftWiresharkRuntime.self)
        return [
            frameworkBundle.bundleURL.appendingPathComponent("Frameworks", isDirectory: true),
            Bundle.main.privateFrameworksURL,
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks", isDirectory: true),
            nil,
        ]
    }

    private func openLibrary(named baseName: String, majorVersion: Int, directory: URL?) -> UnsafeMutableRawPointer? {
        let candidateNames = [
            "\(baseName).\(majorVersion).dylib",
            "\(baseName).dylib",
        ]

        for candidateName in candidateNames {
            let candidatePath = directory?.appendingPathComponent(candidateName).path ?? candidateName
            if let handle = dlopen(candidatePath, RTLD_NOW | RTLD_LOCAL) {
                return handle
            }
        }
        return nil
    }

    private func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    deinit {
        if initializedEpan {
            epanCleanup?()
        }
        if initializedWiretap {
            wtapCleanup?()
        }
        for handle in handles {
            dlclose(handle)
        }
    }
}

struct AnalyzedPacket {
    var transportHint: TransportProtocolHint = .unknown
    var protocolSummary: String?
    var infoSummary = "Packet"
    var sourceAddress: String?
    var destinationAddress: String?
    var sourcePort: UInt16?
    var destinationPort: UInt16?
    var streamID: UInt32?
    var tcpFlags: String?
    var tcpPayloadLength: Int?
    var sniDomainName: String?
    var layers: [PacketLayer] = []
    var detailNodes: [PacketDetailNode] = []
    var decodeStatus = PacketDecodeStatus(kind: .complete)
}

final class PacketAnalyzer {
    private let record: NativePacketRecord
    private let bytes: [UInt8]

    init(record: NativePacketRecord) {
        self.record = record
        self.bytes = Array(record.rawBytes)
    }

    // Builds a stable summary plus inspector tree from captured packet bytes.
    func analyze() -> AnalyzedPacket {
        switch record.linkLayerType {
        case Libpcap.dltEthernet:
            return analyzeEthernet(offset: 0)
        case Libpcap.dltNull:
            return analyzeLoopback()
        case Libpcap.dltRaw:
            return analyzeIP(offset: 0, inheritedNodes: [], inheritedLayers: [])
        default:
            return unsupportedPacket(reason: "Unsupported link-layer type \(record.linkLayerType).")
        }
    }

    private func analyzeLoopback() -> AnalyzedPacket {
        guard bytes.count >= 4 else {
            return malformedPacket(reason: "Loopback packet is shorter than the link-layer header.")
        }

        let family = readUInt32LE(at: 0) ?? 0
        let frame = PacketDetailNode(
            id: "frame",
            name: "Frame",
            fieldName: "frame",
            value: "Frame \(record.packetNumber): \(record.capturedLength) bytes on wire",
            kind: .layer,
            byteRange: range(offset: 0, length: record.capturedLength),
            children: [
                field(id: "frame.number", name: "Frame Number", value: "\(record.packetNumber)", offset: nil, length: nil),
                field(id: "frame.interface", name: "Interface", value: record.interfaceName ?? record.interfaceIdentifier ?? "unknown", offset: nil, length: nil),
                field(id: "null.family", name: "Address Family", value: "\(family)", offset: 0, length: 4),
            ]
        )

        var analyzed = analyzeIP(offset: 4, inheritedNodes: [frame], inheritedLayers: [PacketLayer(name: "Loopback")])
        if analyzed.protocolSummary == nil {
            analyzed.protocolSummary = "Loopback"
        }
        return analyzed
    }

    private func analyzeEthernet(offset: Int) -> AnalyzedPacket {
        guard bytes.count >= offset + 14 else {
            return malformedPacket(reason: "Ethernet packet is shorter than the Ethernet header.")
        }

        let ethType = readUInt16BE(at: offset + 12) ?? 0
        let destination = macAddress(at: offset)
        let source = macAddress(at: offset + 6)
        let ethNode = PacketDetailNode(
            id: "eth",
            name: "Ethernet",
            fieldName: "eth",
            value: "Ethernet II",
            kind: .layer,
            byteRange: range(offset: offset, length: min(14, bytes.count - offset)),
            children: [
                field(id: "eth.dst", name: "Destination", fieldName: "eth.dst", value: destination, offset: offset, length: 6),
                field(id: "eth.src", name: "Source", fieldName: "eth.src", value: source, offset: offset + 6, length: 6),
                field(id: "eth.type", name: "Type", fieldName: "eth.type", value: hex16(ethType), offset: offset + 12, length: 2),
            ]
        )
        let frame = frameNode()
        let inheritedNodes = [frame, ethNode]
        let inheritedLayers = [PacketLayer(name: "Ethernet", detailSummary: "Ethernet II")]

        switch ethType {
        case 0x0806:
            return analyzeARP(offset: offset + 14, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        case 0x0800, 0x86dd:
            return analyzeIP(offset: offset + 14, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        default:
            var packet = AnalyzedPacket()
            packet.transportHint = .ethernet
            packet.protocolSummary = hex16(ethType)
            packet.infoSummary = "Ethernet II"
            packet.layers = inheritedLayers
            packet.detailNodes = inheritedNodes
            packet.decodeStatus = PacketDecodeStatus(kind: .unsupported, reason: "Unsupported EtherType \(hex16(ethType)).")
            return packet
        }
    }

    private func analyzeARP(offset: Int, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count >= offset + 28 else {
            return malformedPacket(reason: "ARP packet is truncated.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }

        let operation = readUInt16BE(at: offset + 6) ?? 0
        let senderIP = ipv4Address(at: offset + 14)
        let targetIP = ipv4Address(at: offset + 24)
        let arpNode = PacketDetailNode(
            id: "arp",
            name: "ARP",
            fieldName: "arp",
            value: operation == 1 ? "Request" : "Operation \(operation)",
            kind: .layer,
            byteRange: range(offset: offset, length: min(28, bytes.count - offset)),
            children: [
                field(id: "arp.opcode", name: "Opcode", fieldName: "arp.opcode", value: operation == 1 ? "request (1)" : "\(operation)", offset: offset + 6, length: 2),
                field(id: "arp.senderIP", name: "Sender IP address", fieldName: "arp.src.proto_ipv4", value: senderIP, offset: offset + 14, length: 4),
                field(id: "arp.targetIP", name: "Target IP address", fieldName: "arp.dst.proto_ipv4", value: targetIP, offset: offset + 24, length: 4),
            ]
        )

        var packet = AnalyzedPacket()
        packet.transportHint = .arp
        packet.protocolSummary = "ARP"
        packet.infoSummary = "Who has \(targetIP)? Tell \(senderIP)"
        packet.sourceAddress = senderIP
        packet.destinationAddress = targetIP
        packet.layers = inheritedLayers + [PacketLayer(name: "ARP", detailSummary: packet.infoSummary)]
        packet.detailNodes = inheritedNodes + [arpNode]
        return packet
    }

    private func analyzeIP(offset: Int, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count > offset else {
            return malformedPacket(reason: "IP packet is empty.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }

        let version = (bytes[offset] >> 4) & 0x0f
        switch version {
        case 4:
            return analyzeIPv4(offset: offset, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        case 6:
            return analyzeIPv6(offset: offset, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        default:
            return unsupportedPacket(reason: "Unsupported IP version \(version).", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }
    }

    private func analyzeIPv4(offset: Int, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count >= offset + 20 else {
            return malformedPacket(reason: "IPv4 packet is shorter than the base header.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }

        let ihl = Int(bytes[offset] & 0x0f) * 4
        guard ihl >= 20, bytes.count >= offset + ihl else {
            return malformedPacket(reason: "IPv4 header length is invalid.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }

        let totalLength = Int(readUInt16BE(at: offset + 2) ?? UInt16(bytes.count - offset))
        let protocolNumber = bytes[offset + 9]
        let source = ipv4Address(at: offset + 12)
        let destination = ipv4Address(at: offset + 16)
        let flagsAndFragment = readUInt16BE(at: offset + 6) ?? 0
        let payloadOffset = offset + ihl
        let payloadEnd = min(bytes.count, offset + totalLength)
        let ipv4Node = PacketDetailNode(
            id: "ipv4",
            name: "IPv4",
            fieldName: "ip",
            value: "\(source) -> \(destination)",
            kind: .layer,
            byteRange: range(offset: offset, length: min(ihl, bytes.count - offset)),
            children: [
                field(id: "ipv4.version", name: "Version", fieldName: "ip.version", value: "4", byteRange: bitRange(offset: offset, bitOffset: 0, bitLength: 4)),
                field(id: "ipv4.headerLength", name: "Header Length", fieldName: "ip.hdr_len", value: byteCount(ihl), offset: offset, length: 1),
                field(id: "ipv4.totalLength", name: "Total Length", fieldName: "ip.len", value: "\(totalLength)", offset: offset + 2, length: 2),
                field(id: "ipv4.flags.df", name: "Don't Fragment", fieldName: "ip.flags.df", value: flagsAndFragment & 0x4000 == 0 ? "Not set" : "Set", byteRange: bitRange(offset: offset + 6, bitOffset: 1, bitLength: 1)),
                field(id: "ipv4.protocol", name: "Protocol", fieldName: "ip.proto", value: ipProtocolName(protocolNumber), offset: offset + 9, length: 1),
                field(id: "ipv4.src", name: "Source Address", fieldName: "ip.src", value: source, offset: offset + 12, length: 4),
                field(id: "ipv4.dst", name: "Destination Address", fieldName: "ip.dst", value: destination, offset: offset + 16, length: 4),
            ]
        )

        return analyzeTransport(
            protocolNumber: protocolNumber,
            offset: payloadOffset,
            payloadEnd: payloadEnd,
            sourceAddress: source,
            destinationAddress: destination,
            inheritedNodes: inheritedNodes + [ipv4Node],
            inheritedLayers: inheritedLayers + [PacketLayer(name: "IPv4", detailSummary: "\(source) -> \(destination)")]
        )
    }

    private func analyzeIPv6(offset: Int, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count >= offset + 40 else {
            return malformedPacket(reason: "IPv6 packet is shorter than the base header.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }

        let payloadLength = Int(readUInt16BE(at: offset + 4) ?? 0)
        let nextHeader = bytes[offset + 6]
        let source = ipv6Address(at: offset + 8)
        let destination = ipv6Address(at: offset + 24)
        let payloadOffset = offset + 40
        let payloadEnd = min(bytes.count, payloadOffset + payloadLength)
        let ipv6Node = PacketDetailNode(
            id: "ipv6",
            name: "IPv6",
            fieldName: "ipv6",
            value: "\(source) -> \(destination)",
            kind: .layer,
            byteRange: range(offset: offset, length: min(40, bytes.count - offset)),
            children: [
                field(id: "ipv6.version", name: "Version", fieldName: "ipv6.version", value: "6", byteRange: bitRange(offset: offset, bitOffset: 0, bitLength: 4)),
                field(id: "ipv6.payloadLength", name: "Payload Length", fieldName: "ipv6.plen", value: "\(payloadLength)", offset: offset + 4, length: 2),
                field(id: "ipv6.nextHeader", name: "Next Header", fieldName: "ipv6.nxt", value: ipProtocolName(nextHeader), offset: offset + 6, length: 1),
                field(id: "ipv6.src", name: "Source Address", fieldName: "ipv6.src", value: source, offset: offset + 8, length: 16),
                field(id: "ipv6.dst", name: "Destination Address", fieldName: "ipv6.dst", value: destination, offset: offset + 24, length: 16),
            ]
        )

        return analyzeTransport(
            protocolNumber: nextHeader,
            offset: payloadOffset,
            payloadEnd: payloadEnd,
            sourceAddress: source,
            destinationAddress: destination,
            inheritedNodes: inheritedNodes + [ipv6Node],
            inheritedLayers: inheritedLayers + [PacketLayer(name: "IPv6", detailSummary: "\(source) -> \(destination)")]
        )
    }

    private func analyzeTransport(
        protocolNumber: UInt8,
        offset: Int,
        payloadEnd: Int,
        sourceAddress: String,
        destinationAddress: String,
        inheritedNodes: [PacketDetailNode],
        inheritedLayers: [PacketLayer]
    ) -> AnalyzedPacket {
        switch protocolNumber {
        case 1:
            return analyzeICMP(offset: offset, payloadEnd: payloadEnd, sourceAddress: sourceAddress, destinationAddress: destinationAddress, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        case 6:
            return analyzeTCP(offset: offset, payloadEnd: payloadEnd, sourceAddress: sourceAddress, destinationAddress: destinationAddress, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        case 17:
            return analyzeUDP(offset: offset, payloadEnd: payloadEnd, sourceAddress: sourceAddress, destinationAddress: destinationAddress, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        case 58:
            return analyzeICMPv6(offset: offset, payloadEnd: payloadEnd, sourceAddress: sourceAddress, destinationAddress: destinationAddress, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        default:
            var packet = AnalyzedPacket()
            packet.transportHint = .ipv4
            packet.protocolSummary = ipProtocolName(protocolNumber)
            packet.infoSummary = "IP payload protocol \(protocolNumber)"
            packet.sourceAddress = sourceAddress
            packet.destinationAddress = destinationAddress
            packet.layers = inheritedLayers
            packet.detailNodes = inheritedNodes
            packet.decodeStatus = PacketDecodeStatus(kind: .unsupported, reason: "Unsupported IP protocol \(protocolNumber).")
            return packet
        }
    }

    private func analyzeTCP(offset: Int, payloadEnd: Int, sourceAddress: String, destinationAddress: String, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count >= offset + 20 else {
            return malformedPacket(reason: "TCP segment is shorter than the base header.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }

        let sourcePort = readUInt16BE(at: offset) ?? 0
        let destinationPort = readUInt16BE(at: offset + 2) ?? 0
        let headerLength = Int(bytes[offset + 12] >> 4) * 4
        let flagsValue = UInt16(bytes[offset + 12] & 0x0f) << 8 | UInt16(bytes[offset + 13])
        let payloadOffset = offset + max(headerLength, 20)
        let payloadLength = max(payloadEnd - payloadOffset, 0)
        let flags = tcpFlags(flagsValue)
        var children: [PacketDetailNode] = [
            field(id: "tcp.srcPort", name: "Source Port", fieldName: "tcp.srcport", value: "\(sourcePort)", offset: offset, length: 2),
            field(id: "tcp.dstPort", name: "Destination Port", fieldName: "tcp.dstport", value: "\(destinationPort)", offset: offset + 2, length: 2),
            field(id: "tcp.sequence.raw", name: "Raw Sequence Number", fieldName: "tcp.seq_raw", value: "\(readUInt32BE(at: offset + 4) ?? 0)", offset: offset + 4, length: 4),
            field(id: "tcp.ack.raw", name: "Raw Acknowledgment Number", fieldName: "tcp.ack_raw", value: "\(readUInt32BE(at: offset + 8) ?? 0)", offset: offset + 8, length: 4),
            tcpFlagsNode(flagsValue: flagsValue, offset: offset + 12),
            field(id: "tcp.window", name: "Window", fieldName: "tcp.window_size_value", value: "\(readUInt16BE(at: offset + 14) ?? 0)", offset: offset + 14, length: 2),
            field(id: "tcp.segmentLength", name: "TCP Segment Len", fieldName: "tcp.len", value: "\(payloadLength)", offset: nil, length: nil),
        ]
        if headerLength > 20 {
            children.append(tcpOptionsNode(offset: offset + 20, length: headerLength - 20))
        }

        let tcpNode = PacketDetailNode(
            id: "tcp",
            name: "TCP",
            fieldName: "tcp",
            value: "\(sourcePort) -> \(destinationPort) \(flags.isEmpty ? "" : "[\(flags)]")".trimmingCharacters(in: .whitespaces),
            kind: .layer,
            byteRange: range(offset: offset, length: min(headerLength, bytes.count - offset)),
            children: children
        )

        var packet = AnalyzedPacket()
        packet.transportHint = .tcp
        packet.protocolSummary = "TCP"
        packet.sourceAddress = sourceAddress
        packet.destinationAddress = destinationAddress
        packet.sourcePort = sourcePort
        packet.destinationPort = destinationPort
        packet.streamID = streamIdentifier(
            protocolNumber: 6,
            sourceAddress: sourceAddress,
            sourcePort: sourcePort,
            destinationAddress: destinationAddress,
            destinationPort: destinationPort
        )
        packet.tcpFlags = flags
        packet.tcpPayloadLength = payloadLength
        packet.infoSummary = "\(sourcePort) -> \(destinationPort) \(flags.isEmpty ? "TCP" : flags)"
        packet.layers = inheritedLayers + [PacketLayer(name: "TCP", detailSummary: packet.infoSummary)]
        packet.detailNodes = inheritedNodes + [tcpNode]

        guard payloadLength > 0, payloadOffset <= bytes.count else {
            return packet
        }

        let payload = Array(bytes[payloadOffset..<min(bytes.count, payloadOffset + payloadLength)])
        if let tls = tlsNode(payload: payload, offset: payloadOffset) {
            let versionName = tls.layerName
            packet.transportHint = .tls
            packet.protocolSummary = versionName
            packet.infoSummary = tls.summary
            packet.sniDomainName = tls.sniDomainName
            packet.layers.append(PacketLayer(name: versionName, detailSummary: tls.summary))
            packet.detailNodes.append(tls.node)
        } else if let http = httpNode(payload: payload, offset: payloadOffset) {
            packet.transportHint = .http1
            packet.protocolSummary = "HTTP"
            packet.infoSummary = http.summary
            packet.layers.append(PacketLayer(name: "HTTP", detailSummary: http.summary))
            packet.detailNodes.append(http.node)
        } else if let websocket = websocketNode(payload: payload, offset: payloadOffset) {
            packet.transportHint = .websocket
            packet.protocolSummary = "WebSocket"
            packet.infoSummary = websocket.summary
            packet.layers.append(PacketLayer(name: "WebSocket", detailSummary: websocket.summary))
            packet.detailNodes.append(websocket.node)
        } else {
            packet.layers.append(PacketLayer(name: "Payload", detailSummary: byteCount(payloadLength)))
            packet.detailNodes.append(payloadNode(offset: payloadOffset, length: payloadLength))
        }
        return packet
    }

    private func analyzeUDP(offset: Int, payloadEnd: Int, sourceAddress: String, destinationAddress: String, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count >= offset + 8 else {
            return malformedPacket(reason: "UDP datagram is shorter than the header.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }

        let sourcePort = readUInt16BE(at: offset) ?? 0
        let destinationPort = readUInt16BE(at: offset + 2) ?? 0
        let udpLength = Int(readUInt16BE(at: offset + 4) ?? 0)
        let checksum = readUInt16BE(at: offset + 6) ?? 0
        let payloadOffset = offset + 8
        let payloadLength = max(min(payloadEnd, offset + udpLength) - payloadOffset, 0)
        let checksumValue = checksum == 0 ? (inheritedLayers.contains { $0.name == "IPv6" } ? "Illegal zero checksum" : "Not present") : hex16(checksum)
        let udpNode = PacketDetailNode(
            id: "udp",
            name: "UDP",
            fieldName: "udp",
            value: "\(sourcePort) -> \(destinationPort)",
            kind: .layer,
            byteRange: range(offset: offset, length: min(8, bytes.count - offset)),
            children: [
                field(id: "udp.srcPort", name: "Source Port", fieldName: "udp.srcport", value: "\(sourcePort)", offset: offset, length: 2),
                field(id: "udp.dstPort", name: "Destination Port", fieldName: "udp.dstport", value: "\(destinationPort)", offset: offset + 2, length: 2),
                field(id: "udp.length", name: "Length", fieldName: "udp.length", value: "\(udpLength)", offset: offset + 4, length: 2),
                field(id: "udp.checksum", name: "Checksum", fieldName: "udp.checksum", value: hex16(checksum), offset: offset + 6, length: 2),
                field(id: "udp.checksum.status", name: "Checksum Status", fieldName: "udp.checksum.status", value: checksumValue, offset: nil, length: nil),
                field(id: "udp.payloadLength", name: "Payload Length", fieldName: "udp.payload_length", value: byteCount(payloadLength), offset: offset + 4, length: 2),
            ]
        )

        var packet = AnalyzedPacket()
        packet.transportHint = .udp
        packet.protocolSummary = "UDP"
        packet.sourceAddress = sourceAddress
        packet.destinationAddress = destinationAddress
        packet.sourcePort = sourcePort
        packet.destinationPort = destinationPort
        packet.streamID = streamIdentifier(
            protocolNumber: 17,
            sourceAddress: sourceAddress,
            sourcePort: sourcePort,
            destinationAddress: destinationAddress,
            destinationPort: destinationPort
        )
        packet.infoSummary = "\(sourcePort) -> \(destinationPort) Len=\(udpLength)"
        packet.layers = inheritedLayers + [PacketLayer(name: "UDP", detailSummary: packet.infoSummary)]
        packet.detailNodes = inheritedNodes + [udpNode]

        if sourcePort == 53 || destinationPort == 53, let dns = dnsNode(offset: payloadOffset, length: payloadLength) {
            packet.transportHint = .dns
            packet.protocolSummary = "DNS"
            packet.infoSummary = dns.summary
            packet.layers.append(PacketLayer(name: "DNS", detailSummary: dns.summary))
            packet.detailNodes.append(dns.node)
        } else if payloadLength > 0 {
            packet.layers.append(PacketLayer(name: "Payload", detailSummary: byteCount(payloadLength)))
            packet.detailNodes.append(payloadNode(offset: payloadOffset, length: payloadLength))
        }
        return packet
    }

    private func analyzeICMP(offset: Int, payloadEnd: Int, sourceAddress: String, destinationAddress: String, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count >= offset + 4 else {
            return malformedPacket(reason: "ICMP packet is shorter than the header.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }
        let type = bytes[offset]
        let code = bytes[offset + 1]
        var children = [
            field(id: "icmp.type", name: "Type", fieldName: "icmp.type", value: icmpTypeName(type), offset: offset, length: 1),
            field(id: "icmp.code", name: "Code", fieldName: "icmp.code", value: "\(code)", offset: offset + 1, length: 1),
            field(id: "icmp.checksum", name: "Checksum", fieldName: "icmp.checksum", value: hex16(readUInt16BE(at: offset + 2) ?? 0), offset: offset + 2, length: 2),
        ]
        if bytes.count >= offset + 8 {
            children.append(field(id: "icmp.identifier", name: "Identifier", fieldName: "icmp.ident", value: "\(readUInt16BE(at: offset + 4) ?? 0)", offset: offset + 4, length: 2))
            children.append(field(id: "icmp.sequence", name: "Sequence Number", fieldName: "icmp.seq", value: "\(readUInt16BE(at: offset + 6) ?? 0)", offset: offset + 6, length: 2))
        }
        let node = PacketDetailNode(id: "icmp", name: "ICMP", fieldName: "icmp", value: icmpTypeName(type), kind: .layer, byteRange: range(offset: offset, length: min(payloadEnd - offset, bytes.count - offset)), children: children)
        return packetForICMP(sourceAddress: sourceAddress, destinationAddress: destinationAddress, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers, node: node, layerName: "ICMP")
    }

    private func analyzeICMPv6(offset: Int, payloadEnd: Int, sourceAddress: String, destinationAddress: String, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer]) -> AnalyzedPacket {
        guard bytes.count >= offset + 4 else {
            return malformedPacket(reason: "ICMPv6 packet is shorter than the header.", inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers)
        }
        let type = bytes[offset]
        let code = bytes[offset + 1]
        var children = [
            field(id: "icmpv6.type", name: "Type", fieldName: "icmpv6.type", value: icmpv6TypeName(type), offset: offset, length: 1),
            field(id: "icmpv6.code", name: "Code", fieldName: "icmpv6.code", value: "\(code)", offset: offset + 1, length: 1),
            field(id: "icmpv6.checksum", name: "Checksum", fieldName: "icmpv6.checksum", value: hex16(readUInt16BE(at: offset + 2) ?? 0), offset: offset + 2, length: 2),
        ]
        if bytes.count >= offset + 8 {
            children.append(field(id: "icmpv6.identifier", name: "Identifier", fieldName: "icmpv6.echo.identifier", value: "\(readUInt16BE(at: offset + 4) ?? 0)", offset: offset + 4, length: 2))
            children.append(field(id: "icmpv6.sequence", name: "Sequence Number", fieldName: "icmpv6.echo.sequence_number", value: "\(readUInt16BE(at: offset + 6) ?? 0)", offset: offset + 6, length: 2))
        }
        let node = PacketDetailNode(id: "icmpv6", name: "ICMPv6", fieldName: "icmpv6", value: icmpv6TypeName(type), kind: .layer, byteRange: range(offset: offset, length: min(payloadEnd - offset, bytes.count - offset)), children: children)
        return packetForICMP(sourceAddress: sourceAddress, destinationAddress: destinationAddress, inheritedNodes: inheritedNodes, inheritedLayers: inheritedLayers, node: node, layerName: "ICMPv6")
    }

    private func packetForICMP(sourceAddress: String, destinationAddress: String, inheritedNodes: [PacketDetailNode], inheritedLayers: [PacketLayer], node: PacketDetailNode, layerName: String) -> AnalyzedPacket {
        var packet = AnalyzedPacket()
        packet.transportHint = .icmp
        packet.protocolSummary = layerName
        packet.sourceAddress = sourceAddress
        packet.destinationAddress = destinationAddress
        packet.infoSummary = node.value ?? layerName
        packet.layers = inheritedLayers + [PacketLayer(name: layerName, detailSummary: packet.infoSummary)]
        packet.detailNodes = inheritedNodes + [node]
        return packet
    }

    private func tlsNode(payload: [UInt8], offset: Int) -> (node: PacketDetailNode, summary: String, layerName: String, sniDomainName: String?)? {
        guard payload.count >= 5, payload[0] >= 20, payload[0] <= 23 else {
            return nil
        }
        let version = UInt16(payload[1]) << 8 | UInt16(payload[2])
        let recordLength = Int(UInt16(payload[3]) << 8 | UInt16(payload[4]))
        guard payload.count >= 5 + recordLength else {
            return nil
        }
        let contentType = tlsContentType(payload[0])
        var effectiveVersion = version
        var sniDomainName: String?
        var handshakeNames: [String] = []
        var children: [PacketDetailNode] = [
            field(id: "tls.record.contentType", name: "Content Type", fieldName: "tls.record.content_type", value: "\(contentType) (\(payload[0]))", offset: offset, length: 1),
            field(id: "tls.record.version", name: "Version", fieldName: "tls.record.version", value: "\(tlsVersionName(version)) (\(hex16(version)))", offset: offset + 1, length: 2),
            field(id: "tls.record.length", name: "Length", fieldName: "tls.record.length", value: "\(recordLength)", offset: offset + 3, length: 2),
        ]
        if payload[0] == 22 {
            let handshake = tlsHandshakeNodes(payload: payload, recordLength: recordLength, offset: offset)
            children.append(contentsOf: handshake.children)
            handshakeNames = handshake.names
            sniDomainName = handshake.sniDomainName
            effectiveVersion = handshake.effectiveVersion ?? effectiveVersion
        } else {
            let encryptedLength = max(recordLength, 0)
            let encryptedOffset = offset + 5
            children.append(field(id: "tls.appdata", name: "Encrypted Application Data", fieldName: "tls.app_data", value: byteCount(encryptedLength), offset: encryptedOffset, length: encryptedLength))
            children.append(field(id: "tls.appdata.preview", name: "Encrypted Data Preview", fieldName: "tls.app_data.preview", value: hexBytes(offset: encryptedOffset, length: min(encryptedLength, 16)), offset: encryptedOffset, length: min(encryptedLength, 16)))
        }
        let versionName = tlsVersionName(effectiveVersion)
        let handshakeSummary = handshakeNames.isEmpty ? "" : ": \(handshakeNames.joined(separator: ", "))"
        let summary = "\(versionName), \(contentType)\(handshakeSummary)"
        let node = PacketDetailNode(
            id: "tls",
            name: "Transport Layer Security",
            fieldName: "tls",
            value: summary,
            kind: .layer,
            byteRange: range(offset: offset, length: min(5 + recordLength, bytes.count - offset)),
            children: children
        )
        return (node, summary, versionName, sniDomainName)
    }

    private func tlsHandshakeNodes(payload: [UInt8], recordLength: Int, offset: Int) -> (children: [PacketDetailNode], names: [String], sniDomainName: String?, effectiveVersion: UInt16?) {
        // Walk plain TLS handshake records enough to restore table summaries and SNI.
        let recordEnd = min(payload.count, 5 + recordLength)
        var cursor = 5
        var messageIndex = 0
        var messageNodes: [PacketDetailNode] = []
        var handshakeNames: [String] = []
        var sniDomainName: String?
        var effectiveVersion: UInt16?

        while cursor + 4 <= recordEnd {
            let messageType = payload[cursor]
            let messageLength = readUInt24BE(payload, at: cursor + 1) ?? 0
            let messageEnd = cursor + 4 + messageLength
            let boundedEnd = min(messageEnd, recordEnd)
            let messageName = tlsHandshakeTypeName(messageType)
            let messageIdentifier = "tls.handshake.\(messageIndex)"
            var children: [PacketDetailNode] = [
                field(id: "\(messageIdentifier).type", name: "Handshake Type", fieldName: "tls.handshake.type", value: "\(messageName) (\(messageType))", offset: offset + cursor, length: 1),
                field(id: "\(messageIdentifier).length", name: "Length", fieldName: "tls.handshake.length", value: byteCount(messageLength), offset: offset + cursor + 1, length: 3),
                field(id: "\(messageIdentifier).complete", name: "Complete", fieldName: "tls.handshake.complete", value: messageEnd <= recordEnd ? "Yes" : "No", offset: nil, length: nil),
            ]
            let metadata = tlsHandshakeMetadata(
                payload: payload,
                messageType: messageType,
                bodyStart: cursor + 4,
                bodyEnd: boundedEnd,
                messageIdentifier: messageIdentifier,
                offset: offset
            )
            children.append(contentsOf: metadata.children)
            sniDomainName = sniDomainName ?? metadata.sniDomainName
            effectiveVersion = metadata.effectiveVersion ?? effectiveVersion
            handshakeNames.append(messageName)
            messageNodes.append(PacketDetailNode(
                id: messageIdentifier,
                name: "Handshake Protocol: \(messageName)",
                fieldName: "tls.handshake",
                value: messageName,
                kind: .field,
                byteRange: range(offset: offset + cursor, length: max(boundedEnd - cursor, 0)),
                children: children
            ))

            guard messageEnd > cursor else { break }
            cursor = messageEnd
            messageIndex += 1
        }

        return (
            [
                field(id: "tls.handshake.count", name: "Handshake Message Count", fieldName: "tls.handshake.count", value: "\(messageNodes.count)", offset: nil, length: nil),
            ] + messageNodes,
            handshakeNames,
            sniDomainName,
            effectiveVersion
        )
    }

    private func tlsHandshakeMetadata(
        payload: [UInt8],
        messageType: UInt8,
        bodyStart: Int,
        bodyEnd: Int,
        messageIdentifier: String,
        offset: Int
    ) -> (children: [PacketDetailNode], sniDomainName: String?, effectiveVersion: UInt16?) {
        guard bodyEnd >= bodyStart + 2 else {
            return ([], nil, nil)
        }
        let handshakeVersion = readUInt16BE(payload, at: bodyStart) ?? 0
        var children: [PacketDetailNode] = [
            field(id: "\(messageIdentifier).handshakeVersion", name: "Handshake Version", fieldName: "tls.handshake.version", value: "\(tlsVersionName(handshakeVersion)) (\(hex16(handshakeVersion)))", offset: offset + bodyStart, length: 2),
        ]
        switch messageType {
        case 1:
            let clientHello = tlsClientHelloMetadata(payload: payload, bodyStart: bodyStart, bodyEnd: bodyEnd, messageIdentifier: messageIdentifier, offset: offset)
            children.append(contentsOf: clientHello.children)
            return (children, clientHello.sniDomainName, clientHello.effectiveVersion)
        case 2:
            let serverHello = tlsServerHelloMetadata(payload: payload, bodyStart: bodyStart, bodyEnd: bodyEnd, messageIdentifier: messageIdentifier, offset: offset)
            children.append(contentsOf: serverHello.children)
            return (children, nil, serverHello.effectiveVersion)
        default:
            return (children, nil, nil)
        }
    }

    private func tlsClientHelloMetadata(payload: [UInt8], bodyStart: Int, bodyEnd: Int, messageIdentifier: String, offset: Int) -> (children: [PacketDetailNode], sniDomainName: String?, effectiveVersion: UInt16?) {
        var cursor = bodyStart + 34
        guard cursor < bodyEnd else { return ([], nil, nil) }
        cursor += 1 + Int(payload[cursor])
        guard cursor + 2 <= bodyEnd else { return ([], nil, nil) }
        let cipherSuitesLength = Int(readUInt16BE(payload, at: cursor) ?? 0)
        cursor += 2 + cipherSuitesLength
        guard cursor < bodyEnd else { return ([field(id: "\(messageIdentifier).cipherSuiteCount", name: "Cipher Suites", fieldName: "tls.handshake.ciphersuites", value: "\(cipherSuitesLength / 2)", offset: nil, length: nil)], nil, nil) }
        cursor += 1 + Int(payload[cursor])
        let extensions = tlsExtensions(payload: payload, cursor: cursor, bodyEnd: bodyEnd)
        var children: [PacketDetailNode] = [
            field(id: "\(messageIdentifier).cipherSuiteCount", name: "Cipher Suites", fieldName: "tls.handshake.ciphersuites", value: "\(cipherSuitesLength / 2)", offset: nil, length: nil),
            field(id: "\(messageIdentifier).extensionCount", name: "Extensions", fieldName: "tls.handshake.extensions", value: "\(extensions.count)", offset: nil, length: nil),
        ]
        if let sni = extensions.sniDomainName {
            children.append(field(id: "\(messageIdentifier).sni", name: "Server Name Indication", fieldName: "tls.handshake.extensions_server_name", value: sni, offset: nil, length: nil))
        }
        if !extensions.supportedVersions.isEmpty {
            children.append(field(id: "\(messageIdentifier).supportedVersions", name: "Supported Versions", fieldName: "tls.handshake.extensions.supported_versions", value: extensions.supportedVersions.map(tlsVersionName).joined(separator: ", "), offset: nil, length: nil))
        }
        return (children, extensions.sniDomainName, tlsEffectiveSupportedVersion(extensions.supportedVersions))
    }

    private func tlsServerHelloMetadata(payload: [UInt8], bodyStart: Int, bodyEnd: Int, messageIdentifier: String, offset: Int) -> (children: [PacketDetailNode], effectiveVersion: UInt16?) {
        var cursor = bodyStart + 34
        guard cursor < bodyEnd else { return ([], nil) }
        cursor += 1 + Int(payload[cursor])
        guard cursor + 3 <= bodyEnd else { return ([], nil) }
        let cipherSuite = readUInt16BE(payload, at: cursor) ?? 0
        cursor += 3
        let extensions = tlsExtensions(payload: payload, cursor: cursor, bodyEnd: bodyEnd)
        var children: [PacketDetailNode] = [
            field(id: "\(messageIdentifier).cipherSuite", name: "Cipher Suite", fieldName: "tls.handshake.ciphersuite", value: hex16(cipherSuite), offset: nil, length: nil),
            field(id: "\(messageIdentifier).extensionCount", name: "Extensions", fieldName: "tls.handshake.extensions", value: "\(extensions.count)", offset: nil, length: nil),
        ]
        if !extensions.supportedVersions.isEmpty {
            children.append(field(id: "\(messageIdentifier).supportedVersions", name: "Supported Versions", fieldName: "tls.handshake.extensions.supported_versions", value: extensions.supportedVersions.map(tlsVersionName).joined(separator: ", "), offset: nil, length: nil))
        }
        return (children, extensions.supportedVersions.first)
    }

    private func tlsExtensions(payload: [UInt8], cursor: Int, bodyEnd: Int) -> (count: Int, sniDomainName: String?, supportedVersions: [UInt16]) {
        var cursor = cursor
        guard cursor + 2 <= bodyEnd else {
            return (0, nil, [])
        }
        let extensionsLength = Int(readUInt16BE(payload, at: cursor) ?? 0)
        cursor += 2
        let extensionsEnd = min(cursor + extensionsLength, bodyEnd)
        var count = 0
        var sniDomainName: String?
        var supportedVersions: [UInt16] = []
        while cursor + 4 <= extensionsEnd {
            let type = readUInt16BE(payload, at: cursor) ?? 0
            let length = Int(readUInt16BE(payload, at: cursor + 2) ?? 0)
            let dataStart = cursor + 4
            let dataEnd = min(dataStart + length, extensionsEnd)
            if type == 0 {
                sniDomainName = sniDomainName ?? tlsServerName(payload: payload, start: dataStart, end: dataEnd)
            } else if type == 43 {
                supportedVersions = tlsSupportedVersions(payload: payload, start: dataStart, end: dataEnd)
            }
            count += 1
            guard dataStart + length > cursor else { break }
            cursor = dataStart + length
        }
        return (count, sniDomainName, supportedVersions)
    }

    private func tlsServerName(payload: [UInt8], start: Int, end: Int) -> String? {
        guard start + 2 <= end else { return nil }
        var cursor = start + 2
        while cursor + 3 <= end {
            let nameType = payload[cursor]
            let nameLength = Int(readUInt16BE(payload, at: cursor + 1) ?? 0)
            let nameStart = cursor + 3
            let nameEnd = nameStart + nameLength
            if nameType == 0, nameEnd <= end {
                let hostName = String(bytes: payload[nameStart..<nameEnd], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let hostName, !hostName.isEmpty {
                    return hostName
                }
            }
            cursor = nameEnd
        }
        return nil
    }

    private func tlsSupportedVersions(payload: [UInt8], start: Int, end: Int) -> [UInt16] {
        if end - start == 2, let selected = readUInt16BE(payload, at: start) {
            return [selected]
        }
        guard start < end else { return [] }
        let listLength = min(Int(payload[start]), end - start - 1)
        var versions: [UInt16] = []
        var cursor = start + 1
        while cursor + 2 <= start + 1 + listLength {
            if let version = readUInt16BE(payload, at: cursor) {
                versions.append(version)
            }
            cursor += 2
        }
        return versions
    }

    private func tlsEffectiveSupportedVersion(_ versions: [UInt16]) -> UInt16? {
        versions.filter { (0x0301...0x0304).contains($0) }.max() ?? versions.first
    }

    private func streamIdentifier(protocolNumber: UInt8, sourceAddress: String, sourcePort: UInt16, destinationAddress: String, destinationPort: UInt16) -> UInt32 {
        let sourceKey = "\(sourceAddress.lowercased()):\(sourcePort)"
        let destinationKey = "\(destinationAddress.lowercased()):\(destinationPort)"
        let orderedEndpoints = sourceKey <= destinationKey ? [sourceKey, destinationKey] : [destinationKey, sourceKey]
        var hash: UInt32 = 2_166_136_261

        func append(_ byte: UInt8) {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }

        append(protocolNumber)
        for endpoint in orderedEndpoints {
            append(0)
            for byte in endpoint.utf8 {
                append(byte)
            }
        }

        return hash == 0 ? 1 : hash
    }

    private func httpNode(payload: [UInt8], offset: Int) -> (node: PacketDetailNode, summary: String)? {
        guard let lineEnd = payload.firstIndex(of: 0x0a) else {
            return nil
        }

        let firstLineBytes = payload[..<lineEnd].dropLastIfCarriageReturn()
        guard let firstLine = String(bytes: firstLineBytes, encoding: .utf8),
              firstLine.hasPrefix("GET ") || firstLine.hasPrefix("POST ") || firstLine.hasPrefix("PUT ") || firstLine.hasPrefix("DELETE ") || firstLine.hasPrefix("HEAD ") else {
            return nil
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            return nil
        }

        let method = parts[0]
        let uri = parts[1]
        let version = parts[2]
        let lineLength = firstLine.utf8.count
        var children: [PacketDetailNode] = [
            field(id: "http.request.\(offset).method", name: "Method", fieldName: "http.request.method", value: method, offset: offset, length: method.utf8.count),
            field(id: "http.request.\(offset).uri", name: "Request URI", fieldName: "http.request.uri", value: uri, offset: offset + method.utf8.count + 1, length: uri.utf8.count),
            field(id: "http.request.\(offset).version", name: "Version", fieldName: "http.request.version", value: version, offset: offset + lineLength - version.utf8.count, length: version.utf8.count),
        ]

        var cursor = lineEnd + 1
        var headerIndex = 0
        var completeHeader = false
        while cursor < payload.count {
            let lineStart = cursor
            let nextLineEnd = payload[cursor...].firstIndex(of: 0x0a) ?? payload.count
            let lineBytes = payload[lineStart..<nextLineEnd].dropLastIfCarriageReturn()
            if lineBytes.isEmpty {
                completeHeader = true
                break
            }
            if let colonIndex = lineBytes.firstIndex(of: 0x3a),
               let name = String(bytes: lineBytes[..<colonIndex], encoding: .utf8) {
                var valueStart = colonIndex + 1
                while valueStart < lineBytes.endIndex && (lineBytes[valueStart] == 0x20 || lineBytes[valueStart] == 0x09) {
                    valueStart += 1
                }
                var valueEnd = lineBytes.endIndex
                while valueEnd > valueStart && (lineBytes[lineBytes.index(before: valueEnd)] == 0x20 || lineBytes[lineBytes.index(before: valueEnd)] == 0x09) {
                    valueEnd = lineBytes.index(before: valueEnd)
                }
                let valueBytes = lineBytes[valueStart..<valueEnd]
                let value = String(bytes: valueBytes, encoding: .utf8) ?? ""
                let absoluteNameOffset = offset + lineStart
                let absoluteValueOffset = offset + valueStart
                children.append(field(id: "http.request.\(offset).header.\(headerIndex).name", name: "Header Name", fieldName: "http.header.name", value: name, offset: absoluteNameOffset, length: name.utf8.count))
                let fieldName = name.caseInsensitiveCompare("Host") == .orderedSame ? "http.host" : "http.header.value"
                children.append(field(id: "http.request.\(offset).header.\(headerIndex).value", name: "Header Value", fieldName: fieldName, value: value, offset: absoluteValueOffset, length: value.utf8.count))
                headerIndex += 1
            }
            cursor = nextLineEnd < payload.count ? nextLineEnd + 1 : payload.count
        }
        children.append(field(id: "http.request.\(offset).header.complete", name: "Header Complete", fieldName: "http.request.header.complete", value: completeHeader ? "Yes" : "No", offset: nil, length: nil))

        let summary = "\(method) \(uri) \(version)"
        let node = PacketDetailNode(
            id: "http.request.\(offset)",
            name: "HTTP Request",
            fieldName: "http.request",
            value: summary,
            kind: .layer,
            byteRange: range(offset: offset, length: payload.count),
            children: children
        )
        return (node, summary)
    }

    private func websocketNode(payload: [UInt8], offset: Int) -> (node: PacketDetailNode, summary: String)? {
        guard payload.count >= 2 else {
            return nil
        }

        let first = payload[0]
        let second = payload[1]
        let masked = (second & 0x80) != 0
        let opcode = first & 0x0f
        var length = Int(second & 0x7f)
        var cursor = 2
        if length == 126 {
            guard payload.count >= cursor + 2 else { return nil }
            length = Int(UInt16(payload[cursor]) << 8 | UInt16(payload[cursor + 1]))
            cursor += 2
        } else if length == 127 {
            return nil
        }
        let maskingKeyOffset = offset + cursor
        let maskingKeyLength = masked ? 4 : 0
        if masked {
            guard payload.count >= cursor + 4 else { return nil }
            cursor += 4
        }
        guard payload.count >= cursor + length else {
            return nil
        }

        let payloadOffset = offset + cursor
        let summary = "\(websocketOpcodeName(opcode)), \(byteCount(length))"
        var children = [
            field(id: "websocket.\(offset).fin", name: "FIN", fieldName: "websocket.fin", value: (first & 0x80) != 0 ? "Set" : "Not set", byteRange: bitRange(offset: offset, bitOffset: 0, bitLength: 1)),
            field(id: "websocket.\(offset).opcode", name: "Opcode", fieldName: "websocket.opcode", value: "\(websocketOpcodeName(opcode)) (\(opcode))", byteRange: bitRange(offset: offset, bitOffset: 4, bitLength: 4)),
            field(id: "websocket.\(offset).mask", name: "Mask", fieldName: "websocket.mask", value: masked ? "Set" : "Not set", byteRange: bitRange(offset: offset + 1, bitOffset: 0, bitLength: 1)),
            field(id: "websocket.\(offset).payloadLength", name: "Payload Length", fieldName: "websocket.payload_length", value: "\(length)", byteRange: bitRange(offset: offset + 1, bitOffset: 1, bitLength: 7)),
        ]
        if masked {
            children.append(field(id: "websocket.\(offset).maskingKey", name: "Masking Key", fieldName: "websocket.masking_key", value: hexBytes(offset: maskingKeyOffset, length: maskingKeyLength), offset: maskingKeyOffset, length: maskingKeyLength))
        }
        children.append(field(id: "websocket.\(offset).payload", name: "Payload", fieldName: "websocket.payload", value: hexBytes(offset: payloadOffset, length: length), offset: payloadOffset, length: length))

        let node = PacketDetailNode(
            id: "websocket.\(offset)",
            name: "WebSocket",
            fieldName: "websocket",
            value: summary,
            kind: .layer,
            byteRange: range(offset: offset, length: min(payload.count, cursor + length)),
            children: children
        )
        return (node, summary)
    }

    private func dnsNode(offset: Int, length: Int) -> (node: PacketDetailNode, summary: String)? {
        guard bytes.count >= offset + 12 else {
            return nil
        }
        let transactionID = readUInt16BE(at: offset) ?? 0
        let flags = readUInt16BE(at: offset + 2) ?? 0
        let queryCount = Int(readUInt16BE(at: offset + 4) ?? 0)
        let answerCount = Int(readUInt16BE(at: offset + 6) ?? 0)
        var cursor = offset + 12
        var children: [PacketDetailNode] = [
            field(id: "dns.id", name: "Transaction ID", fieldName: "dns.id", value: hex16(transactionID), offset: offset, length: 2),
            field(id: "dns.flags", name: "Flags", fieldName: "dns.flags", value: hex16(flags), offset: offset + 2, length: 2),
            field(id: "dns.flags.response", name: "Response", fieldName: "dns.flags.response", value: (flags & 0x8000) == 0 ? "Query" : "Response", byteRange: bitRange(offset: offset + 2, bitOffset: 0, bitLength: 1)),
            field(id: "dns.count.queries", name: "Questions", fieldName: "dns.count.queries", value: "\(queryCount)", offset: offset + 4, length: 2),
            field(id: "dns.count.answers", name: "Answer RRs", fieldName: "dns.count.answers", value: "\(answerCount)", offset: offset + 6, length: 2),
        ]
        var queryName = "DNS"

        for queryIndex in 0..<queryCount {
            guard let parsedName = dnsName(at: cursor, packetStart: offset) else {
                break
            }
            queryName = parsedName.name
            cursor = parsedName.nextOffset
            guard bytes.count >= cursor + 4 else {
                break
            }
            let type = readUInt16BE(at: cursor) ?? 0
            let queryClass = readUInt16BE(at: cursor + 2) ?? 0
            children.append(field(id: "dns.query.\(queryIndex).name", name: "Name", fieldName: "dns.qry.name", value: parsedName.name, offset: parsedName.rangeOffset, length: parsedName.rangeLength))
            children.append(field(id: "dns.query.\(queryIndex).type", name: "Type", fieldName: "dns.qry.type", value: dnsTypeName(type), offset: cursor, length: 2))
            children.append(field(id: "dns.query.\(queryIndex).class", name: "Class", fieldName: "dns.qry.class", value: "\(queryClass)", offset: cursor + 2, length: 2))
            cursor += 4
        }

        for answerIndex in 0..<answerCount {
            guard let parsedName = dnsName(at: cursor, packetStart: offset) else {
                break
            }
            cursor = parsedName.nextOffset
            guard bytes.count >= cursor + 10 else {
                break
            }
            let type = readUInt16BE(at: cursor) ?? 0
            let dataLength = Int(readUInt16BE(at: cursor + 8) ?? 0)
            let dataOffset = cursor + 10
            children.append(field(id: "dns.answer.\(answerIndex).name", name: "Name", fieldName: "dns.resp.name", value: parsedName.name, offset: parsedName.rangeOffset, length: parsedName.rangeLength))
            children.append(field(id: "dns.answer.\(answerIndex).type", name: "Type", fieldName: "dns.resp.type", value: dnsTypeName(type), offset: cursor, length: 2))
            if type == 1, dataLength == 4, bytes.count >= dataOffset + 4 {
                children.append(field(id: "dns.answer.\(answerIndex).data", name: "Address", fieldName: "dns.a", value: ipv4Address(at: dataOffset), offset: dataOffset, length: 4))
            } else {
                children.append(field(id: "dns.answer.\(answerIndex).data", name: "RDATA", fieldName: "dns.resp.data", value: hexBytes(offset: dataOffset, length: min(dataLength, bytes.count - dataOffset)), offset: dataOffset, length: min(dataLength, bytes.count - dataOffset)))
            }
            cursor = dataOffset + dataLength
        }

        let summary = (flags & 0x8000) == 0 ? "Standard query \(queryName)" : "Standard query response \(queryName)"
        let node = PacketDetailNode(
            id: "dns",
            name: "Domain Name System",
            fieldName: "dns",
            value: summary,
            kind: .layer,
            byteRange: range(offset: offset, length: min(length, bytes.count - offset)),
            children: children
        )
        return (node, summary)
    }

    private func tcpFlagsNode(flagsValue: UInt16, offset: Int) -> PacketDetailNode {
        let names = tcpFlags(flagsValue)
        return PacketDetailNode(
            id: "tcp.flags",
            name: "Flags",
            fieldName: "tcp.flags",
            value: "\(hex12(flagsValue))\(names.isEmpty ? "" : " (\(names))")",
            kind: .field,
            byteRange: range(offset: offset, length: 2),
            children: [
                field(id: "tcp.flags.cwr", name: "Congestion Window Reduced", fieldName: "tcp.flags.cwr", value: flagsValue & 0x080 != 0 ? "Set" : "Not set", byteRange: bitRange(offset: offset + 1, bitOffset: 0, bitLength: 1)),
                field(id: "tcp.flags.ece", name: "ECN-Echo", fieldName: "tcp.flags.ece", value: flagsValue & 0x040 != 0 ? "Set" : "Not set", byteRange: bitRange(offset: offset + 1, bitOffset: 1, bitLength: 1)),
                field(id: "tcp.flags.ack", name: "Acknowledgment", fieldName: "tcp.flags.ack", value: flagsValue & 0x010 != 0 ? "Set" : "Not set", byteRange: bitRange(offset: offset + 1, bitOffset: 3, bitLength: 1)),
                field(id: "tcp.flags.syn", name: "Syn", fieldName: "tcp.flags.syn", value: flagsValue & 0x002 != 0 ? "Set" : "Not set", byteRange: bitRange(offset: offset + 1, bitOffset: 6, bitLength: 1)),
                field(id: "tcp.flags.fin", name: "Fin", fieldName: "tcp.flags.fin", value: flagsValue & 0x001 != 0 ? "Set" : "Not set", byteRange: bitRange(offset: offset + 1, bitOffset: 7, bitLength: 1)),
            ]
        )
    }

    private func tcpOptionsNode(offset: Int, length: Int) -> PacketDetailNode {
        var children: [PacketDetailNode] = []
        var cursor = offset
        let end = min(offset + length, bytes.count)
        while cursor < end {
            let kind = bytes[cursor]
            if kind == 0 {
                children.append(field(id: "tcp.option.eol.\(cursor)", name: "TCP Option - End of Option List", fieldName: "tcp.options.eol", value: "End of Option List", offset: cursor, length: 1))
                cursor += 1
                continue
            }
            if kind == 1 {
                children.append(field(id: "tcp.option.nop.\(cursor)", name: "TCP Option - No-Operation", fieldName: "tcp.options.nop", value: "No-Operation", offset: cursor, length: 1))
                cursor += 1
                continue
            }
            guard cursor + 1 < end else {
                break
            }
            let optionLength = Int(bytes[cursor + 1])
            guard optionLength >= 2, cursor + optionLength <= end else {
                children.append(field(id: "tcp.option.malformed.\(cursor)", name: "TCP Option - Malformed", fieldName: "tcp.options.malformed", value: "Invalid option length", offset: cursor, length: max(1, end - cursor)))
                break
            }
            children.append(tcpOptionNode(kind: kind, offset: cursor, length: optionLength))
            cursor += optionLength
        }

        return PacketDetailNode(
            id: "tcp.options",
            name: "Options",
            fieldName: "tcp.options",
            value: byteCount(length),
            kind: .field,
            byteRange: range(offset: offset, length: length),
            children: children
        )
    }

    private func tcpOptionNode(kind: UInt8, offset: Int, length: Int) -> PacketDetailNode {
        switch kind {
        case 2:
            let mss = readUInt16BE(at: offset + 2) ?? 0
            return field(id: "tcp.option.mss.\(offset)", name: "TCP Option - Maximum segment size", fieldName: "tcp.options.mss", value: "\(mss) bytes", offset: offset, length: length)
        case 3:
            let scale = bytes[safe: offset + 2] ?? 0
            return field(id: "tcp.option.windowScale.\(offset)", name: "TCP Option - Window scale", fieldName: "tcp.options.wscale", value: "\(scale) (multiply by \(1 << Int(scale)))", offset: offset, length: length)
        case 4:
            return field(id: "tcp.option.sackPermitted.\(offset)", name: "TCP Option - SACK permitted", fieldName: "tcp.options.sack_perm", value: "Permitted", offset: offset, length: length)
        case 8:
            let tsValue = readUInt32BE(at: offset + 2) ?? 0
            let tsEcho = readUInt32BE(at: offset + 6) ?? 0
            return field(id: "tcp.option.timestamp.\(offset)", name: "TCP Option - Timestamps", fieldName: "tcp.options.timestamp", value: "TSval \(tsValue), TSecr \(tsEcho)", offset: offset, length: length)
        default:
            return field(id: "tcp.option.\(kind).\(offset)", name: "TCP Option - \(kind)", fieldName: "tcp.options", value: "\(length) bytes", offset: offset, length: length)
        }
    }

    private func payloadNode(offset: Int, length: Int) -> PacketDetailNode {
        PacketDetailNode(
            id: "payload",
            name: "Payload",
            fieldName: "data",
            value: byteCount(length),
            kind: .layer,
            byteRange: range(offset: offset, length: min(length, bytes.count - offset)),
            children: [
                field(id: "payload.length", name: "Length", fieldName: "data.len", value: byteCount(length), offset: offset, length: min(length, bytes.count - offset)),
                field(id: "payload.preview", name: "Data Preview", fieldName: "data.data", value: hexBytes(offset: offset, length: min(length, 32)), offset: offset, length: min(length, bytes.count - offset)),
                PacketDetailNode(id: "warning.decode", name: "Payload Not Decoded", fieldName: "tcpviewer.warning.decode", value: opaquePayloadDecodeReason, kind: .warning, severity: .info),
            ]
        )
    }

    private func frameNode() -> PacketDetailNode {
        var children = [
            field(id: "frame.number", name: "Frame Number", fieldName: "frame.number", value: "\(record.packetNumber)", offset: nil, length: nil),
            field(id: "frame.len", name: "Frame Length", fieldName: "frame.len", value: byteCount(record.originalLength), offset: nil, length: nil),
            field(id: "frame.cap_len", name: "Captured Length", fieldName: "frame.cap_len", value: byteCount(record.capturedLength), offset: nil, length: nil),
        ]
        if let interfaceName = record.interfaceName ?? record.interfaceIdentifier {
            children.append(field(id: "frame.interface", name: "Interface", fieldName: "frame.interface_name", value: interfaceName, offset: nil, length: nil))
        }
        return PacketDetailNode(
            id: "frame",
            name: "Frame",
            fieldName: "frame",
            value: "Frame \(record.packetNumber): \(record.capturedLength) bytes on wire",
            kind: .layer,
            byteRange: range(offset: 0, length: record.capturedLength),
            children: children
        )
    }

    private func malformedPacket(reason: String, inheritedNodes: [PacketDetailNode] = [], inheritedLayers: [PacketLayer] = []) -> AnalyzedPacket {
        var packet = AnalyzedPacket()
        packet.transportHint = .unknown
        packet.protocolSummary = "Malformed"
        packet.infoSummary = reason
        packet.layers = inheritedLayers
        packet.detailNodes = inheritedNodes + [PacketDetailNode(id: "warning.malformed", name: "Malformed Packet", fieldName: "tcpviewer.warning.malformed", value: reason, kind: .warning, severity: .error)]
        packet.decodeStatus = PacketDecodeStatus(kind: .malformed, reason: reason)
        return packet
    }

    private func unsupportedPacket(reason: String, inheritedNodes: [PacketDetailNode] = [], inheritedLayers: [PacketLayer] = []) -> AnalyzedPacket {
        var packet = AnalyzedPacket()
        packet.transportHint = .unknown
        packet.protocolSummary = "Unsupported"
        packet.infoSummary = reason
        packet.layers = inheritedLayers
        packet.detailNodes = inheritedNodes + [PacketDetailNode(id: "warning.unsupported", name: "Unsupported Packet", fieldName: "tcpviewer.warning.unsupported", value: reason, kind: .warning, severity: .warning)]
        packet.decodeStatus = PacketDecodeStatus(kind: .unsupported, reason: reason)
        return packet
    }

    private func field(id: String, name: String, fieldName: String? = nil, value: String?, offset: Int?, length: Int?) -> PacketDetailNode {
        field(id: id, name: name, fieldName: fieldName ?? id, value: value, byteRange: offset.flatMap { offset in
            guard let length else { return nil }
            return range(offset: offset, length: length)
        })
    }

    private func field(id: String, name: String, fieldName: String? = nil, value: String?, byteRange: PacketByteRange?) -> PacketDetailNode {
        PacketDetailNode(
            id: id,
            name: name,
            fieldName: fieldName ?? id,
            value: value,
            rawValue: byteRange.flatMap { rawValue(for: $0) },
            kind: .field,
            severity: byteRange.flatMap { $0.upperBound <= bytes.count ? nil : PacketDetailNodeSeverity.error } ?? .normal,
            byteRange: byteRange
        )
    }

    private func range(offset: Int, length: Int) -> PacketByteRange {
        PacketByteRange(offset: offset, length: max(length, 0))
    }

    private func bitRange(offset: Int, bitOffset: Int, bitLength: Int) -> PacketByteRange {
        PacketByteRange(offset: offset, length: 1, bitOffset: bitOffset, bitLength: bitLength, hasBitRange: true)
    }

    private func rawValue(for range: PacketByteRange) -> String? {
        guard range.offset >= 0, range.length >= 0, range.upperBound <= bytes.count else {
            return nil
        }
        return hexBytes(offset: range.offset, length: range.length)
    }

    private func readUInt16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private func readUInt16BE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private func readUInt24BE(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, offset + 3 <= bytes.count else { return nil }
        return Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
    }

    private func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset + 3]) << 24 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset])
    }

    private func macAddress(at offset: Int) -> String {
        guard offset >= 0, offset + 6 <= bytes.count else { return "" }
        return bytes[offset..<(offset + 6)].map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func ipv4Address(at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= bytes.count else { return "" }
        return bytes[offset..<(offset + 4)].map(String.init).joined(separator: ".")
    }

    private func ipv6Address(at offset: Int) -> String {
        guard offset >= 0, offset + 16 <= bytes.count else { return "" }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { destination in
            destination.copyBytes(from: bytes[offset..<(offset + 16)])
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)).map { String(cString: $0) } ?? ""
    }

    private func hexBytes(offset: Int, length: Int) -> String {
        guard offset >= 0, length > 0, offset < bytes.count else {
            return ""
        }
        return bytes[offset..<min(bytes.count, offset + length)].map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func dnsName(at offset: Int, packetStart: Int, depth: Int = 0) -> (name: String, nextOffset: Int, rangeOffset: Int, rangeLength: Int)? {
        guard depth < 8 else { return nil }
        var labels: [String] = []
        var cursor = offset
        var jumped = false
        var nextOffset = offset

        while cursor < bytes.count {
            let length = bytes[cursor]
            if length == 0 {
                if !jumped { nextOffset = cursor + 1 }
                return (labels.joined(separator: "."), nextOffset, offset, max((jumped ? nextOffset : cursor + 1) - offset, 0))
            }
            if length & 0xc0 == 0xc0 {
                guard cursor + 1 < bytes.count else { return nil }
                let pointer = Int(length & 0x3f) << 8 | Int(bytes[cursor + 1])
                if let pointed = dnsName(at: packetStart + pointer, packetStart: packetStart, depth: depth + 1) {
                    labels.append(pointed.name)
                    if !jumped { nextOffset = cursor + 2 }
                    jumped = true
                    return (labels.joined(separator: "."), nextOffset, offset, max(nextOffset - offset, 0))
                }
                return nil
            }
            cursor += 1
            guard cursor + Int(length) <= bytes.count else { return nil }
            labels.append(String(bytes: bytes[cursor..<(cursor + Int(length))], encoding: .utf8) ?? "")
            cursor += Int(length)
        }
        return nil
    }
}

private extension PacketDetailNode {
    var descriptor: PCPPNativePacketDetailNodeDescriptor {
        PCPPNativePacketDetailNodeDescriptor(
            identifier: id,
            name: name,
            fieldName: fieldName,
            value: value,
            rawValue: rawValue,
            kind: kind.rawValue,
            severity: severity.rawValue,
            byteRange: byteRange?.descriptor,
            jumpTargetPacketIdentifier: jumpTargetPacketID.map { NSNumber(value: $0) },
            children: children.map(\.descriptor)
        )
    }
}

private extension PacketByteRange {
    var descriptor: PCPPNativePacketByteRangeDescriptor {
        PCPPNativePacketByteRangeDescriptor(
            offset: offset,
            length: length,
            bitOffset: bitOffset,
            bitLength: bitLength,
            hasBitRange: hasBitRange,
            sourceIdentifier: sourceID
        )
    }
}

extension PacketDecodeStatus.Kind {
    var nativeKind: PCPPNativeDecodeStatusKind {
        switch self {
        case .complete:
            return .complete
        case .partial:
            return .partial
        case .malformed:
            return .malformed
        case .unsupported:
            return .unsupported
        }
    }
}

extension TransportProtocolHint {
    var nativeHint: PCPPNativeTransportHint {
        switch self {
        case .ethernet:
            return .ethernet
        case .arp:
            return .arp
        case .ipv4:
            return .ipv4
        case .ipv6:
            return .ipv6
        case .icmp:
            return .icmp
        case .tcp:
            return .tcp
        case .udp:
            return .udp
        case .dns:
            return .dns
        case .http1:
            return .http1
        case .tls:
            return .tls
        case .websocket:
            return .websocket
        case .payload:
            return .payload
        case .unknown:
            return .unknown
        }
    }
}

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8? {
        guard index >= 0, index < count else {
            return nil
        }
        return self[index]
    }
}

private extension ArraySlice where Element == UInt8 {
    func dropLastIfCarriageReturn() -> ArraySlice<UInt8> {
        guard last == 0x0d else {
            return self
        }
        return dropLast()
    }
}

private func byteCount(_ value: Int) -> String {
    "\(value) bytes"
}

private func hex12(_ value: UInt16) -> String {
    String(format: "0x%03x", value & 0x0fff)
}

private func hex16(_ value: UInt16) -> String {
    String(format: "0x%04x", value)
}

private func ipProtocolName(_ value: UInt8) -> String {
    switch value {
    case 1:
        return "ICMP"
    case 6:
        return "TCP"
    case 17:
        return "UDP"
    case 58:
        return "ICMPv6"
    default:
        return "\(value)"
    }
}

private func tcpFlags(_ value: UInt16) -> String {
    var names: [String] = []
    if value & 0x001 != 0 { names.append("FIN") }
    if value & 0x002 != 0 { names.append("SYN") }
    if value & 0x004 != 0 { names.append("RST") }
    if value & 0x008 != 0 { names.append("PSH") }
    if value & 0x010 != 0 { names.append("ACK") }
    if value & 0x020 != 0 { names.append("URG") }
    if value & 0x040 != 0 { names.append("ECE") }
    if value & 0x080 != 0 { names.append("CWR") }
    return names.joined(separator: ", ")
}

private func icmpTypeName(_ value: UInt8) -> String {
    switch value {
    case 0:
        return "Echo Reply (0)"
    case 8:
        return "Echo Request (8)"
    default:
        return "\(value)"
    }
}

private func icmpv6TypeName(_ value: UInt8) -> String {
    switch value {
    case 128:
        return "Echo Request (128)"
    case 129:
        return "Echo Reply (129)"
    default:
        return "\(value)"
    }
}

private func tlsVersionName(_ version: UInt16) -> String {
    switch version {
    case 0x0301:
        return "TLSv1.0"
    case 0x0302:
        return "TLSv1.1"
    case 0x0303:
        return "TLSv1.2"
    case 0x0304:
        return "TLSv1.3"
    default:
        return hex16(version)
    }
}

private func tlsContentType(_ value: UInt8) -> String {
    switch value {
    case 20:
        return "Change Cipher Spec"
    case 21:
        return "Alert"
    case 22:
        return "Handshake"
    case 23:
        return "Application Data"
    default:
        return "\(value)"
    }
}

private func tlsHandshakeTypeName(_ value: UInt8) -> String {
    switch value {
    case 0:
        return "Hello Request"
    case 1:
        return "Client Hello"
    case 2:
        return "Server Hello"
    case 4:
        return "New Session Ticket"
    case 8:
        return "Encrypted Extensions"
    case 11:
        return "Certificate"
    case 12:
        return "Server Key Exchange"
    case 13:
        return "Certificate Request"
    case 14:
        return "Server Hello Done"
    case 15:
        return "Certificate Verify"
    case 16:
        return "Client Key Exchange"
    case 20:
        return "Finished"
    default:
        return "\(value)"
    }
}

private func websocketOpcodeName(_ value: UInt8) -> String {
    switch value {
    case 1:
        return "Text"
    case 2:
        return "Binary"
    case 8:
        return "Close"
    case 9:
        return "Ping"
    case 10:
        return "Pong"
    default:
        return "\(value)"
    }
}

private func dnsTypeName(_ value: UInt16) -> String {
    switch value {
    case 1:
        return "A (1)"
    case 28:
        return "AAAA (28)"
    case 5:
        return "CNAME (5)"
    default:
        return "\(value)"
    }
}
