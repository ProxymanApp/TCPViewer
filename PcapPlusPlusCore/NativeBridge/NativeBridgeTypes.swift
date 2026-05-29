//
//  NativeBridgeTypes.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 28/5/26.
//

import Foundation

enum PCPPNativeInterfaceAvailability: Int {
    case available = 0
    case hidden = 1
    case unavailable = 2
    case unsupported = 3
}

enum PCPPNativeAddressFamily: Int {
    case ipv4 = 0
    case ipv6 = 1
    case linkLayer = 2
    case unknown = 3
}

enum PCPPNativeLinkType: Int {
    case ethernet = 0
    case loopback = 1
    case raw = 2
    case unknown = 3
}

enum PCPPNativeTransportHint: Int {
    case ethernet = 0
    case arp = 1
    case ipv4 = 2
    case ipv6 = 3
    case icmp = 4
    case tcp = 5
    case udp = 6
    case dns = 7
    case http1 = 8
    case tls = 9
    case websocket = 10
    case payload = 11
    case unknown = 12
}

enum PCPPNativeDecodeStatusKind: Int {
    case complete = 0
    case partial = 1
    case malformed = 2
    case unsupported = 3
}

enum PCPPNativeLiveSessionPhase: Int {
    case ready = 0
    case starting = 1
    case running = 2
    case paused = 3
    case stopping = 4
    case stopped = 5
    case failed = 6
}

final class PCPPNativeAddressDescriptor {
    let family: PCPPNativeAddressFamily
    let value: String

    init(family: PCPPNativeAddressFamily, value: String) {
        self.family = family
        self.value = value
    }
}

final class PCPPNativeActivityPreviewDescriptor {
    let packetsPerSecond: NSNumber?
    let observedAt: Date?

    init(packetsPerSecond: NSNumber?, observedAt: Date?) {
        self.packetsPerSecond = packetsPerSecond
        self.observedAt = observedAt
    }
}

final class PCPPNativeInterfaceDescriptor {
    let identifier: String
    let technicalName: String
    let displayName: String
    let friendlyName: String?
    let interfaceDescription: String?
    let loopback: Bool
    let availability: PCPPNativeInterfaceAvailability
    let availabilityReason: String?
    let linkType: PCPPNativeLinkType
    let addresses: [PCPPNativeAddressDescriptor]
    let activityPreview: PCPPNativeActivityPreviewDescriptor
    let canCapture: Bool
    let supportsPromiscuousMode: Bool
    let requiresBPFPermissionSetup: Bool
    let providesMacOSMetadata: Bool

    init(
        identifier: String,
        technicalName: String,
        displayName: String,
        friendlyName: String?,
        interfaceDescription: String?,
        loopback: Bool,
        availability: PCPPNativeInterfaceAvailability,
        availabilityReason: String?,
        linkType: PCPPNativeLinkType,
        addresses: [PCPPNativeAddressDescriptor],
        activityPreview: PCPPNativeActivityPreviewDescriptor,
        canCapture: Bool,
        supportsPromiscuousMode: Bool,
        requiresBPFPermissionSetup: Bool,
        providesMacOSMetadata: Bool
    ) {
        self.identifier = identifier
        self.technicalName = technicalName
        self.displayName = displayName
        self.friendlyName = friendlyName
        self.interfaceDescription = interfaceDescription
        self.loopback = loopback
        self.availability = availability
        self.availabilityReason = availabilityReason
        self.linkType = linkType
        self.addresses = addresses
        self.activityPreview = activityPreview
        self.canCapture = canCapture
        self.supportsPromiscuousMode = supportsPromiscuousMode
        self.requiresBPFPermissionSetup = requiresBPFPermissionSetup
        self.providesMacOSMetadata = providesMacOSMetadata
    }
}

final class PCPPNativePacketEndpointDescriptor {
    let address: String?
    let port: NSNumber?

    init(address: String?, port: NSNumber?) {
        self.address = address
        self.port = port
    }
}

final class PCPPNativePacketLayerDescriptor {
    let name: String
    let detailSummary: String?

    init(name: String, detailSummary: String?) {
        self.name = name
        self.detailSummary = detailSummary
    }
}

final class PCPPNativePacketByteViewDescriptor {
    let identifier: String
    let label: String
    let bytes: Data

    init(identifier: String, label: String, bytes: Data) {
        self.identifier = identifier
        self.label = label
        self.bytes = bytes
    }
}

final class PCPPNativePacketCaptureMetadataDescriptor {
    let linkType: PCPPNativeLinkType
    let truncated: Bool
    let packetComment: String?
    let interfaceName: String?

    init(linkType: PCPPNativeLinkType, truncated: Bool, packetComment: String?, interfaceName: String?) {
        self.linkType = linkType
        self.truncated = truncated
        self.packetComment = packetComment
        self.interfaceName = interfaceName
    }
}

final class PCPPNativeDecodeStatusDescriptor {
    let kind: PCPPNativeDecodeStatusKind
    let reason: String?

    init(kind: PCPPNativeDecodeStatusKind, reason: String?) {
        self.kind = kind
        self.reason = reason
    }
}

final class PCPPNativePacketSummaryUpdateDescriptor {
    let packetIdentifier: UInt64
    let protocolSummary: String?
    let infoSummary: String

    init(packetIdentifier: UInt64, protocolSummary: String?, infoSummary: String) {
        self.packetIdentifier = packetIdentifier
        self.protocolSummary = protocolSummary
        self.infoSummary = infoSummary
    }
}

final class PCPPNativePacketSummaryDescriptor {
    let identifier: UInt64
    let packetNumber: UInt64
    let timestamp: Date
    let interfaceIdentifier: String?
    let transportHint: PCPPNativeTransportHint
    let protocolSummary: String?
    let sourceEndpoint: PCPPNativePacketEndpointDescriptor
    let destinationEndpoint: PCPPNativePacketEndpointDescriptor
    let originalLength: Int
    let capturedLength: Int
    let streamIdentifier: NSNumber?
    let tcpFlags: String?
    let tcpPayloadLength: NSNumber?
    let infoSummary: String
    let layers: [PCPPNativePacketLayerDescriptor]
    let decodeStatus: PCPPNativeDecodeStatusDescriptor
    let captureMetadata: PCPPNativePacketCaptureMetadataDescriptor
    let sniDomainName: String?

    init(
        identifier: UInt64,
        packetNumber: UInt64,
        timestamp: Date,
        interfaceIdentifier: String?,
        transportHint: PCPPNativeTransportHint,
        protocolSummary: String?,
        sourceEndpoint: PCPPNativePacketEndpointDescriptor,
        destinationEndpoint: PCPPNativePacketEndpointDescriptor,
        originalLength: Int,
        capturedLength: Int,
        streamIdentifier: NSNumber?,
        tcpFlags: String?,
        tcpPayloadLength: NSNumber?,
        infoSummary: String,
        layers: [PCPPNativePacketLayerDescriptor],
        decodeStatus: PCPPNativeDecodeStatusDescriptor,
        captureMetadata: PCPPNativePacketCaptureMetadataDescriptor,
        sniDomainName: String?
    ) {
        self.identifier = identifier
        self.packetNumber = packetNumber
        self.timestamp = timestamp
        self.interfaceIdentifier = interfaceIdentifier
        self.transportHint = transportHint
        self.protocolSummary = protocolSummary
        self.sourceEndpoint = sourceEndpoint
        self.destinationEndpoint = destinationEndpoint
        self.originalLength = originalLength
        self.capturedLength = capturedLength
        self.streamIdentifier = streamIdentifier
        self.tcpFlags = tcpFlags
        self.tcpPayloadLength = tcpPayloadLength
        self.infoSummary = infoSummary
        self.layers = layers
        self.decodeStatus = decodeStatus
        self.captureMetadata = captureMetadata
        self.sniDomainName = sniDomainName
    }
}

final class PCPPNativeCaptureHealthDescriptor {
    let packetsReceived: UInt64
    let packetsDropped: UInt64
    let packetsDroppedByInterface: UInt64
    let packetsObserved: UInt64
    let lastUpdated: Date?
    let statusMessage: String?

    init(
        packetsReceived: UInt64,
        packetsDropped: UInt64,
        packetsDroppedByInterface: UInt64,
        packetsObserved: UInt64,
        lastUpdated: Date?,
        statusMessage: String?
    ) {
        self.packetsReceived = packetsReceived
        self.packetsDropped = packetsDropped
        self.packetsDroppedByInterface = packetsDroppedByInterface
        self.packetsObserved = packetsObserved
        self.lastUpdated = lastUpdated
        self.statusMessage = statusMessage
    }
}

final class PCPPNativeCaptureDocumentMetadataDescriptor {
    let format: String
    let operatingSystem: String?
    let hardware: String?
    let captureApplication: String?
    let fileComment: String?

    init(format: String, operatingSystem: String?, hardware: String?, captureApplication: String?, fileComment: String?) {
        self.format = format
        self.operatingSystem = operatingSystem
        self.hardware = hardware
        self.captureApplication = captureApplication
        self.fileComment = fileComment
    }
}

final class PCPPNativeFilterValidationDescriptor {
    let disposition: String
    let normalizedExpression: String?
    let message: String?

    init(disposition: String, normalizedExpression: String?, message: String?) {
        self.disposition = disposition
        self.normalizedExpression = normalizedExpression
        self.message = message
    }
}

final class PCPPNativeCaptureOptionsDescriptor {
    let promiscuousMode: Bool
    let snapshotLength: Int
    let kernelBufferSizeBytes: Int
    let readTimeoutMilliseconds: Int
    let captureFilterExpression: String?
    let stopMode: String
    let stopValue: UInt64
    let fileWritingMode: String
    let captureDirectoryURL: URL?
    let fileNameStem: String?
    let fileFormat: String?
    let maxFileSizeBytes: UInt64
    let ringFileCount: UInt

    init(
        promiscuousMode: Bool,
        snapshotLength: Int,
        kernelBufferSizeBytes: Int,
        readTimeoutMilliseconds: Int,
        captureFilterExpression: String?,
        stopMode: String,
        stopValue: UInt64,
        fileWritingMode: String,
        captureDirectoryURL: URL?,
        fileNameStem: String?,
        fileFormat: String?,
        maxFileSizeBytes: UInt64,
        ringFileCount: UInt
    ) {
        self.promiscuousMode = promiscuousMode
        self.snapshotLength = snapshotLength
        self.kernelBufferSizeBytes = kernelBufferSizeBytes
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.captureFilterExpression = captureFilterExpression
        self.stopMode = stopMode
        self.stopValue = stopValue
        self.fileWritingMode = fileWritingMode
        self.captureDirectoryURL = captureDirectoryURL
        self.fileNameStem = fileNameStem
        self.fileFormat = fileFormat
        self.maxFileSizeBytes = maxFileSizeBytes
        self.ringFileCount = ringFileCount
    }
}

final class PCPPNativePacketByteRangeDescriptor {
    let offset: Int
    let length: Int
    let bitOffset: Int
    let bitLength: Int
    let hasBitRange: Bool
    let sourceIdentifier: String

    init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
        self.bitOffset = 0
        self.bitLength = 0
        self.hasBitRange = false
        self.sourceIdentifier = "frame"
    }

    init(offset: Int, length: Int, bitOffset: Int, bitLength: Int, hasBitRange: Bool, sourceIdentifier: String) {
        self.offset = offset
        self.length = length
        self.bitOffset = bitOffset
        self.bitLength = bitLength
        self.hasBitRange = hasBitRange
        self.sourceIdentifier = sourceIdentifier
    }
}

final class PCPPNativePacketDetailNodeDescriptor {
    let identifier: String
    let name: String
    let fieldName: String
    let value: String?
    let rawValue: String?
    let kind: String
    let severity: String
    let byteRange: PCPPNativePacketByteRangeDescriptor?
    let jumpTargetPacketIdentifier: NSNumber?
    let children: [PCPPNativePacketDetailNodeDescriptor]

    init(
        identifier: String,
        name: String,
        fieldName: String,
        value: String?,
        rawValue: String?,
        kind: String,
        severity: String,
        byteRange: PCPPNativePacketByteRangeDescriptor?,
        jumpTargetPacketIdentifier: NSNumber?,
        children: [PCPPNativePacketDetailNodeDescriptor]
    ) {
        self.identifier = identifier
        self.name = name
        self.fieldName = fieldName
        self.value = value
        self.rawValue = rawValue
        self.kind = kind
        self.severity = severity
        self.byteRange = byteRange
        self.jumpTargetPacketIdentifier = jumpTargetPacketIdentifier
        self.children = children
    }
}

final class PCPPNativePacketInspectionDescriptor {
    let packetIdentifier: UInt64
    let packetNumber: UInt64
    let rawBytes: Data
    let byteViews: [PCPPNativePacketByteViewDescriptor]
    let detailNodes: [PCPPNativePacketDetailNodeDescriptor]
    let decodeStatus: PCPPNativeDecodeStatusDescriptor

    init(
        packetIdentifier: UInt64,
        packetNumber: UInt64,
        rawBytes: Data,
        byteViews: [PCPPNativePacketByteViewDescriptor],
        detailNodes: [PCPPNativePacketDetailNodeDescriptor],
        decodeStatus: PCPPNativeDecodeStatusDescriptor
    ) {
        self.packetIdentifier = packetIdentifier
        self.packetNumber = packetNumber
        self.rawBytes = rawBytes
        self.byteViews = byteViews
        self.detailNodes = detailNodes
        self.decodeStatus = decodeStatus
    }
}

final class PCPPNativePacketLoadProgressDescriptor {
    let phase: String
    let loadedPacketCount: UInt64
    let processedBytes: NSNumber?
    let totalBytes: NSNumber?
    let isPartialResult: Bool
    let message: String

    init(
        phase: String,
        loadedPacketCount: UInt64,
        processedBytes: NSNumber?,
        totalBytes: NSNumber?,
        partialResult: Bool,
        message: String
    ) {
        self.phase = phase
        self.loadedPacketCount = loadedPacketCount
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.isPartialResult = partialResult
        self.message = message
    }
}

let TCPViewerNativeErrorDomain = "com.proxyman.tcpviewer.NativeBridge"

enum TCPViewerNativeErrorCode: Int {
    case interfaceDiscoveryFailed = 1000
    case unsupportedInterface = 1001
    case openFailed = 1002
    case captureStartFailed = 1003
    case capturePauseFailed = 1004
    case captureResumeFailed = 1005
    case captureStopFailed = 1006
    case fileReadFailed = 1007
    case fileWriteFailed = 1008
    case invalidOptions = 1009
    case invalidFilter = 1010
    case operationCancelled = 1011
    case unavailableFeature = 1012
}

func NativeNSError(_ code: TCPViewerNativeErrorCode, _ message: String) -> NSError {
    NSError(domain: TCPViewerNativeErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
}
