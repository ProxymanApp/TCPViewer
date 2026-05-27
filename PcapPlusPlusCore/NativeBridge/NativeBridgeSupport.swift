//
//  NativeBridgeSupport.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import Foundation
import SystemConfiguration
@_implementationOnly import TCPViewerNativeBridge

final class EventCallbackBox<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var eventHandler: ((Result<Element, Error>) -> Void)?

    var handler: ((Result<Element, Error>) -> Void)? {
        get {
            lock.lock()
            let handler = eventHandler
            lock.unlock()
            return handler
        }
        set {
            lock.lock()
            eventHandler = newValue
            lock.unlock()
        }
    }

    func yield(_ element: Element) {
        lock.lock()
        let handler = eventHandler
        lock.unlock()

        handler?(.success(element))
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        let handler = eventHandler
        eventHandler = nil
        lock.unlock()

        if let error {
            handler?(.failure(error))
        }
    }
}

enum NativeBridgeMapper {
    static func interfaceAvailability(_ availability: PCPPNativeInterfaceAvailability) -> CaptureInterfaceAvailability {
        switch availability.rawValue {
        case 0:
            .available
        case 1:
            .hidden
        case 2:
            .unavailable
        case 3:
            .unsupported
        default:
            .unsupported
        }
    }

    static func addressFamily(_ family: PCPPNativeAddressFamily) -> NetworkAddressFamily {
        switch family.rawValue {
        case 0:
            .ipv4
        case 1:
            .ipv6
        case 2:
            .linkLayer
        case 3:
            .unknown
        default:
            .unknown
        }
    }

    static func linkType(_ linkType: PCPPNativeLinkType) -> CaptureLinkType {
        switch linkType.rawValue {
        case 0:
            .ethernet
        case 1:
            .loopback
        case 2:
            .raw
        case 3:
            .unknown
        default:
            .unknown
        }
    }

    static func transportHint(_ transportHint: PCPPNativeTransportHint) -> TransportProtocolHint {
        switch transportHint.rawValue {
        case 0:
            .ethernet
        case 1:
            .arp
        case 2:
            .ipv4
        case 3:
            .ipv6
        case 4:
            .icmp
        case 5:
            .tcp
        case 6:
            .udp
        case 7:
            .dns
        case 8:
            .http1
        case 9:
            .tls
        case 10:
            .websocket
        case 11:
            .payload
        case 12:
            .unknown
        default:
            .unknown
        }
    }

    static func decodeStatusKind(_ kind: PCPPNativeDecodeStatusKind) -> PacketDecodeStatus.Kind {
        switch kind.rawValue {
        case 0:
            .complete
        case 1:
            .partial
        case 2:
            .malformed
        case 3:
            .unsupported
        default:
            .unsupported
        }
    }

    static func livePhase(_ phase: PCPPNativeLiveSessionPhase) -> LiveCaptureSessionPhase {
        switch phase.rawValue {
        case 0:
            .ready
        case 1:
            .starting
        case 2:
            .running
        case 3:
            .paused
        case 4:
            .stopping
        case 5:
            .stopped
        case 6:
            .failed
        default:
            .failed
        }
    }

    static func address(_ descriptor: PCPPNativeAddressDescriptor) -> CaptureInterfaceAddress {
        CaptureInterfaceAddress(
            family: addressFamily(descriptor.family),
            value: descriptor.value
        )
    }

    static func activityPreview(_ descriptor: PCPPNativeActivityPreviewDescriptor) -> CaptureInterfaceActivityPreview {
        CaptureInterfaceActivityPreview(
            packetsPerSecond: descriptor.packetsPerSecond?.doubleValue,
            observedAt: descriptor.observedAt
        )
    }

    static func interfaceSummary(_ descriptor: PCPPNativeInterfaceDescriptor) -> CaptureInterfaceSummary {
        let mappedLinkType = linkType(descriptor.linkType)
        let friendlyName = friendlyInterfaceName(
            technicalName: descriptor.technicalName,
            pcapDescription: descriptor.friendlyName ?? descriptor.interfaceDescription,
            isLoopback: descriptor.loopback,
            linkType: mappedLinkType,
            systemInterfaceName: SystemNetworkInterfaceNameResolver.friendlyName(for: descriptor.technicalName)
        )

        return CaptureInterfaceSummary(
            id: descriptor.identifier,
            technicalName: descriptor.technicalName,
            displayName: friendlyName,
            friendlyName: friendlyName,
            interfaceDescription: descriptor.interfaceDescription,
            isLoopback: descriptor.loopback,
            addresses: descriptor.addresses.map(address),
            linkType: mappedLinkType,
            availability: interfaceAvailability(descriptor.availability),
            availabilityReason: descriptor.availabilityReason,
            activityPreview: activityPreview(descriptor.activityPreview),
            capabilities: CaptureInterfaceCapabilities(
                canCapture: descriptor.canCapture,
                supportsPromiscuousMode: descriptor.supportsPromiscuousMode,
                requiresBPFPermissionSetup: descriptor.requiresBPFPermissionSetup,
                providesMacOSMetadata: descriptor.providesMacOSMetadata
            )
        )
    }

    static func friendlyInterfaceName(
        technicalName: String,
        pcapDescription: String?,
        isLoopback: Bool,
        linkType: CaptureLinkType,
        systemInterfaceName: String? = nil
    ) -> String {
        // Prefer the macOS service/interface name, then fall back to packet-capture metadata and known BSD prefixes.
        let normalizedTechnicalName = technicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = [
            SystemNetworkInterfaceNameResolver.normalizedName(systemInterfaceName, technicalName: normalizedTechnicalName),
            SystemNetworkInterfaceNameResolver.normalizedName(pcapDescription, technicalName: normalizedTechnicalName),
        ]
            .compactMap { $0 }
            .first ?? fallbackInterfaceBaseName(
                technicalName: normalizedTechnicalName,
                isLoopback: isLoopback,
                linkType: linkType
            )

        guard !normalizedTechnicalName.isEmpty else {
            return baseName
        }

        if baseName.localizedCaseInsensitiveContains(normalizedTechnicalName) {
            return baseName
        }

        return "\(baseName) (\(normalizedTechnicalName))"
    }

    private static func fallbackInterfaceBaseName(
        technicalName: String,
        isLoopback: Bool,
        linkType: CaptureLinkType
    ) -> String {
        // Translate common macOS BSD interface prefixes into readable capture-picker names.
        let lowercasedName = technicalName.localizedLowercase
        if isLoopback || lowercasedName.hasPrefix("lo") {
            return "Loopback"
        }

        if lowercasedName == "any" || lowercasedName.hasPrefix("pktap") {
            return "All Interfaces"
        }

        if lowercasedName.hasPrefix("bridge") {
            return "Bridge"
        }

        if lowercasedName.hasPrefix("utun") {
            return "VPN Tunnel"
        }

        if lowercasedName.hasPrefix("ipsec") {
            return "IPsec Tunnel"
        }

        if lowercasedName.hasPrefix("gif") {
            return "Generic Tunnel"
        }

        if lowercasedName.hasPrefix("stf") {
            return "IPv6 Tunnel"
        }

        if lowercasedName.hasPrefix("awdl") {
            return "Apple Wireless Direct Link"
        }

        if lowercasedName.hasPrefix("llw") {
            return "Low-Latency Wi-Fi"
        }

        switch linkType {
        case .ethernet:
            return "Ethernet"
        case .loopback:
            return "Loopback"
        case .raw:
            return "Raw IP"
        case .unknown:
            return "Interface"
        }
    }

    static func packetEndpoint(_ descriptor: PCPPNativePacketEndpointDescriptor) -> PacketEndpoint {
        PacketEndpoint(
            address: descriptor.address,
            port: descriptor.port?.uint16Value
        )
    }

    static func packetLayer(_ descriptor: PCPPNativePacketLayerDescriptor) -> PacketLayer {
        PacketLayer(name: descriptor.name, detailSummary: descriptor.detailSummary)
    }

    static func packetCaptureMetadata(_ descriptor: PCPPNativePacketCaptureMetadataDescriptor) -> PacketCaptureMetadata {
        PacketCaptureMetadata(
            linkType: linkType(descriptor.linkType),
            isTruncated: descriptor.truncated,
            packetComment: descriptor.packetComment,
            interfaceName: descriptor.interfaceName
        )
    }

    static func decodeStatus(_ descriptor: PCPPNativeDecodeStatusDescriptor) -> PacketDecodeStatus {
        PacketDecodeStatus(
            kind: decodeStatusKind(descriptor.kind),
            reason: descriptor.reason
        )
    }

    static func packetByteRange(_ descriptor: PCPPNativePacketByteRangeDescriptor?) -> PacketByteRange? {
        guard let descriptor else {
            return nil
        }

        return PacketByteRange(
            offset: descriptor.offset,
            length: descriptor.length,
            bitOffset: descriptor.bitOffset,
            bitLength: descriptor.bitLength,
            hasBitRange: descriptor.hasBitRange,
            sourceID: descriptor.sourceIdentifier
        )
    }

    static func packetByteView(_ descriptor: PCPPNativePacketByteViewDescriptor) -> PacketByteView {
        PacketByteView(
            id: descriptor.identifier,
            label: descriptor.label,
            bytes: descriptor.bytes
        )
    }

    static func detailNodeKind(_ rawValue: String) -> PacketDetailNodeKind {
        PacketDetailNodeKind(rawValue: rawValue.lowercased()) ?? .field
    }

    static func detailNodeSeverity(_ rawValue: String) -> PacketDetailNodeSeverity {
        PacketDetailNodeSeverity(rawValue: rawValue.lowercased()) ?? .normal
    }

    static func packetDetailNode(_ descriptor: PCPPNativePacketDetailNodeDescriptor) -> PacketDetailNode {
        PacketDetailNode(
            id: descriptor.identifier,
            name: descriptor.name,
            fieldName: descriptor.fieldName,
            value: descriptor.value,
            rawValue: descriptor.rawValue,
            kind: detailNodeKind(descriptor.kind),
            severity: detailNodeSeverity(descriptor.severity),
            byteRange: packetByteRange(descriptor.byteRange),
            jumpTargetPacketID: descriptor.jumpTargetPacketIdentifier?.uint64Value,
            children: descriptor.children.map(packetDetailNode)
        )
    }

    static func packetInspection(_ descriptor: PCPPNativePacketInspectionDescriptor) -> PacketInspection {
        if let bugMessage = descriptor.wiresharkDissectorBugMessage {
            // Surface libwireshark DissectorError messages (e.g. "Unregistered hf!") to the
            // developer console without polluting the Packet Detail panel with a fallback node.
            print("[TCPViewer] Wireshark dissector error (packet #\(descriptor.packetNumber)): \(bugMessage)")
        }

        return PacketInspection(
            packetID: descriptor.packetIdentifier,
            packetNumber: descriptor.packetNumber,
            rawBytes: descriptor.rawBytes,
            byteViews: descriptor.byteViews.map(packetByteView),
            detailNodes: descriptor.detailNodes.map(packetDetailNode),
            decodeStatus: decodeStatus(descriptor.decodeStatus)
        )
    }

    static func packetSummary(
        _ descriptor: PCPPNativePacketSummaryDescriptor,
        source: CaptureSource
    ) -> PacketSummary {
        PacketSummary(
            id: descriptor.identifier,
            packetNumber: descriptor.packetNumber,
            timestamp: descriptor.timestamp,
            source: source,
            interfaceID: descriptor.interfaceIdentifier,
            transportHint: transportHint(descriptor.transportHint),
            protocolSummary: descriptor.protocolSummary,
            endpoints: PacketEndpoints(
                source: packetEndpoint(descriptor.sourceEndpoint),
                destination: packetEndpoint(descriptor.destinationEndpoint)
            ),
            originalLength: descriptor.originalLength,
            capturedLength: descriptor.capturedLength,
            streamID: descriptor.streamIdentifier?.uint32Value,
            tcpFlags: descriptor.tcpFlags,
            tcpPayloadLength: descriptor.tcpPayloadLength?.intValue,
            infoSummary: descriptor.infoSummary,
            layers: descriptor.layers.map(packetLayer),
            decodeStatus: decodeStatus(descriptor.decodeStatus),
            captureMetadata: packetCaptureMetadata(descriptor.captureMetadata),
            sniDomainName: descriptor.sniDomainName
        )
    }

    static func healthSnapshot(_ descriptor: PCPPNativeCaptureHealthDescriptor) -> CaptureHealthSnapshot {
        CaptureHealthSnapshot(
            packetsReceived: descriptor.packetsReceived,
            packetsDropped: descriptor.packetsDropped,
            packetsDroppedByInterface: descriptor.packetsDroppedByInterface,
            packetsObserved: descriptor.packetsObserved,
            lastUpdated: descriptor.lastUpdated,
            statusMessage: descriptor.statusMessage
        )
    }

    static func documentMetadata(_ descriptor: PCPPNativeCaptureDocumentMetadataDescriptor) -> CaptureDocumentMetadata {
        CaptureDocumentMetadata(
            format: captureFileFormat(descriptor.format) ?? .pcapng,
            operatingSystem: descriptor.operatingSystem,
            hardware: descriptor.hardware,
            captureApplication: descriptor.captureApplication,
            fileComment: descriptor.fileComment
        )
    }

    static func filterValidation(_ descriptor: PCPPNativeFilterValidationDescriptor) -> CaptureFilterValidation {
        let disposition: CaptureFilterValidation.Disposition
        switch descriptor.disposition.lowercased() {
        case "valid":
            disposition = .valid
        case "invalid":
            disposition = .invalid
        default:
            disposition = .unavailable
        }

        return CaptureFilterValidation(
            disposition: disposition,
            normalizedExpression: descriptor.normalizedExpression,
            message: descriptor.message
        )
    }

    static func loadProgressPhase(_ rawValue: String) -> PacketLoadProgress.Phase {
        PacketLoadProgress.Phase(rawValue: rawValue.lowercased()) ?? .failed
    }

    static func loadProgress(_ descriptor: PCPPNativePacketLoadProgressDescriptor) -> PacketLoadProgress {
        PacketLoadProgress(
            phase: loadProgressPhase(descriptor.phase),
            loadedPacketCount: Int(descriptor.loadedPacketCount),
            processedBytes: descriptor.processedBytes?.uint64Value,
            totalBytes: descriptor.totalBytes?.uint64Value,
            isPartialResult: descriptor.isPartialResult,
            message: descriptor.message
        )
    }

    static func nativeCaptureOptions(_ options: CaptureOptions) -> PCPPNativeCaptureOptionsDescriptor {
        let stopMode: String
        let stopValue: UInt64
        switch options.stopCondition {
        case .manual:
            stopMode = "manual"
            stopValue = 0
        case .packetCount(let count):
            stopMode = "packetCount"
            stopValue = count
        case .durationMilliseconds(let duration):
            stopMode = "durationMilliseconds"
            stopValue = duration
        }

        return PCPPNativeCaptureOptionsDescriptor(
            promiscuousMode: options.promiscuousMode,
            snapshotLength: options.snapshotLength,
            kernelBufferSizeBytes: options.kernelBufferSizeBytes,
            readTimeoutMilliseconds: options.readTimeoutMilliseconds,
            captureFilterExpression: options.captureFilterExpression,
            stopMode: stopMode,
            stopValue: stopValue,
            fileWritingMode: options.fileWriting.mode.rawValue,
            captureDirectoryURL: options.fileWriting.directoryURL,
            fileNameStem: options.fileWriting.fileNameStem,
            fileFormat: options.fileWriting.format?.rawValue,
            maxFileSizeBytes: options.fileWriting.maxFileSizeBytes ?? 0,
            ringFileCount: UInt(options.fileWriting.ringFileCount ?? 0)
        )
    }

    static func captureFileFormat(_ rawValue: String?) -> CaptureFileFormat? {
        guard let rawValue else {
            return nil
        }

        return CaptureFileFormat(rawValue: rawValue.lowercased())
    }

    static func sortedInterfaces(_ interfaces: [CaptureInterfaceSummary]) -> [CaptureInterfaceSummary] {
        interfaces.sorted {
            sortKey(for: $0) < sortKey(for: $1)
        }
    }

    static func packetBatch(
        _ descriptors: [PCPPNativePacketSummaryDescriptor],
        source: CaptureSource
    ) -> [PacketSummary] {
        descriptors.map { packetSummary($0, source: source) }
    }

    static func coreError(_ error: Error, defaultCode: TCPViewerCoreError.Code) -> TCPViewerCoreError {
        if let error = error as? TCPViewerCoreError {
            return error
        }

        let nsError = error as NSError
        let message = nsError.localizedDescription.isEmpty ? String(describing: error) : nsError.localizedDescription
        let code: TCPViewerCoreError.Code
        switch nsError.code {
        case 1001:
            code = .unsupportedInterface
        case 1003:
            code = .liveSessionStartFailed
        case 1004, 1005, 1006:
            code = .liveSessionControlFailed
        case 1007:
            code = .offlineFileOpenFailed
        case 1008:
            code = .offlineFileSaveFailed
        case 1009:
            code = .invalidCaptureOptions
        case 1010:
            code = .invalidCaptureFilter
        case 1011:
            code = .operationCancelled
        default:
            code = defaultCode
        }
        return TCPViewerCoreError(code: code, message: message)
    }

    private static func sortKey(for interface: CaptureInterfaceSummary) -> (Int, Int, String, String) {
        let primaryBucket: Int
        if interface.isSelectable && !interface.isLoopback {
            primaryBucket = 0
        } else if interface.isSelectable && interface.isLoopback {
            primaryBucket = 1
        } else {
            primaryBucket = 2
        }

        let availabilityBucket: Int
        switch interface.availability {
        case .available:
            availabilityBucket = 0
        case .hidden:
            availabilityBucket = 1
        case .unavailable:
            availabilityBucket = 2
        case .unsupported:
            availabilityBucket = 3
        }

        return (
            primaryBucket,
            availabilityBucket,
            interface.displayName.localizedLowercase,
            interface.technicalName.localizedLowercase
        )
    }
}

private enum SystemNetworkInterfaceNameResolver {
    static func friendlyName(for technicalName: String) -> String? {
        // Resolve user-facing macOS network service names such as Wi-Fi for BSD names such as en0.
        let normalizedTechnicalName = technicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTechnicalName.isEmpty else {
            return nil
        }

        if let serviceName = networkServiceName(for: normalizedTechnicalName) {
            return serviceName
        }

        return hardwareInterfaceName(for: normalizedTechnicalName)
    }

    static func normalizedName(_ name: String?, technicalName: String) -> String? {
        // Filter empty or purely technical labels so the caller can keep looking for a better name.
        guard let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedName.isEmpty else {
            return nil
        }

        let lowercasedName = trimmedName.localizedLowercase
        if lowercasedName == technicalName.localizedLowercase ||
            lowercasedName == "no description available" {
            return nil
        }

        return trimmedName
    }

    private static func networkServiceName(for technicalName: String) -> String? {
        guard let preferences = SCPreferencesCreate(nil, "TCP Viewer" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return nil
        }

        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let interface = SCNetworkServiceGetInterface(service),
                  Self.interface(interface, matches: technicalName),
                  let serviceName = normalizedName(SCNetworkServiceGetName(service) as String?, technicalName: technicalName) else {
                continue
            }

            return serviceName
        }

        return nil
    }

    private static func hardwareInterfaceName(for technicalName: String) -> String? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return nil
        }

        for interface in interfaces {
            guard Self.interface(interface, matches: technicalName),
                  let displayName = normalizedName(
                    SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                    technicalName: technicalName
                  ) else {
                continue
            }

            return displayName
        }

        return nil
    }

    private static func interface(_ interface: SCNetworkInterface, matches technicalName: String) -> Bool {
        // Match only the BSD device itself so parent services do not rename their underlying interface.
        guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
            return false
        }

        return bsdName.caseInsensitiveCompare(technicalName) == .orderedSame
    }
}

#if DEBUG
struct NativeLivePacketDiskStoreSnapshot: Equatable {
    let packetCount: Int
    let backingFileSize: UInt64
    let backingFileExists: Bool
    let backingFilePath: String
}

final class NativeLivePacketDiskStoreTestHarness {
    private let probe: PCPPNativeLivePacketStoreTestProbe

    init() {
        self.probe = PCPPNativeLivePacketStoreTestProbe()
    }

    var snapshot: NativeLivePacketDiskStoreSnapshot {
        NativeLivePacketDiskStoreSnapshot(
            packetCount: Int(probe.packetCount),
            backingFileSize: UInt64(probe.backingFileSize),
            backingFileExists: probe.backingFileExists,
            backingFilePath: probe.backingFilePath
        )
    }

    // Append synthetic packet bytes through the same native disk store used by live capture.
    func appendPacket(
        identifier: UInt64,
        rawBytes: Data,
        timestamp: Date,
        linkLayerType: Int = 1,
        originalLength: Int? = nil
    ) throws {
        try probe.appendPacket(
            identifier: identifier,
            rawBytes: rawBytes,
            timestamp: timestamp,
            linkLayerType: linkLayerType,
            originalLength: originalLength ?? rawBytes.count
        )
    }

    func inspectPacket(identifier: UInt64) throws -> PacketInspection {
        try NativeBridgeMapper.packetInspection(probe.inspectPacket(identifier: identifier))
    }

    func reanalyzePacketSummaries(upTo identifier: UInt64 = 0) throws -> [PacketSummary] {
        try probe.reanalyzePacketSummaries(upTo: identifier).map {
            NativeBridgeMapper.packetSummary($0, source: .live)
        }
    }

    func offset(identifier: UInt64) throws -> UInt64 {
        try probe.offset(identifier: identifier).uint64Value
    }

    func cleanup() {
        probe.cleanup()
    }
}
#endif

extension CaptureOptions {
    func normalizedForLiveCapture() -> CaptureOptions {
        let normalizedFileWriting: CaptureFileWriting
        switch fileWriting.mode {
        case .disabled:
            normalizedFileWriting = fileWriting
        case .single:
            normalizedFileWriting = fileWriting
        case .rotating, .ring:
            normalizedFileWriting = CaptureFileWriting(
                mode: fileWriting.mode,
                directoryURL: fileWriting.directoryURL,
                fileNameStem: fileWriting.fileNameStem,
                format: fileWriting.format ?? .pcapng,
                maxFileSizeBytes: fileWriting.maxFileSizeBytes,
                ringFileCount: fileWriting.ringFileCount
            )
        }

        return CaptureOptions(
            promiscuousMode: promiscuousMode,
            snapshotLength: snapshotLength,
            kernelBufferSizeBytes: kernelBufferSizeBytes,
            readTimeoutMilliseconds: readTimeoutMilliseconds,
            captureFilterExpression: captureFilterExpression?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            stopCondition: stopCondition,
            fileWriting: normalizedFileWriting
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
