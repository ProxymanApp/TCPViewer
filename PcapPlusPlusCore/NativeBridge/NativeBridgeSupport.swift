import Foundation
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
            .tcp
        case 5:
            .udp
        case 6:
            .dns
        case 7:
            .http1
        case 8:
            .tls
        case 9:
            .websocket
        case 10:
            .payload
        case 11:
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
        CaptureInterfaceSummary(
            id: descriptor.identifier,
            technicalName: descriptor.technicalName,
            displayName: descriptor.displayName,
            friendlyName: descriptor.friendlyName,
            interfaceDescription: descriptor.interfaceDescription,
            isLoopback: descriptor.loopback,
            addresses: descriptor.addresses.map(address),
            linkType: linkType(descriptor.linkType),
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
            length: descriptor.length
        )
    }

    static func detailNodeKind(_ rawValue: String) -> PacketDetailNodeKind {
        PacketDetailNodeKind(rawValue: rawValue.lowercased()) ?? .field
    }

    static func packetDetailNode(_ descriptor: PCPPNativePacketDetailNodeDescriptor) -> PacketDetailNode {
        PacketDetailNode(
            id: descriptor.identifier,
            name: descriptor.name,
            value: descriptor.value,
            kind: detailNodeKind(descriptor.kind),
            byteRange: packetByteRange(descriptor.byteRange),
            jumpTargetPacketID: descriptor.jumpTargetPacketIdentifier?.uint64Value,
            children: descriptor.children.map(packetDetailNode)
        )
    }

    static func packetInspection(_ descriptor: PCPPNativePacketInspectionDescriptor) -> PacketInspection {
        PacketInspection(
            packetID: descriptor.packetIdentifier,
            packetNumber: descriptor.packetNumber,
            rawBytes: descriptor.rawBytes,
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
            endpoints: PacketEndpoints(
                source: packetEndpoint(descriptor.sourceEndpoint),
                destination: packetEndpoint(descriptor.destinationEndpoint)
            ),
            originalLength: descriptor.originalLength,
            capturedLength: descriptor.capturedLength,
            streamID: descriptor.streamIdentifier?.uint32Value,
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
