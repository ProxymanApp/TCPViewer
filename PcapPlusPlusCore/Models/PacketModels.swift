import Foundation

public enum TransportProtocolHint: String, Sendable, Codable {
    case ethernet
    case arp
    case ipv4
    case ipv6
    case tcp
    case udp
    case dns
    case http1
    case tls
    case websocket
    case payload
    case unknown
}

public enum PacketDetailNodeKind: String, Sendable, Codable {
    case layer
    case field
    case warning
}

public enum PacketBatchDisposition: String, Sendable, Codable {
    case append
    case replace
}

public struct PacketByteRange: Sendable, Codable, Hashable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }

    public var upperBound: Int {
        offset + length
    }
}

public struct PacketDetailNode: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let name: String
    public let value: String?
    public let kind: PacketDetailNodeKind
    public let byteRange: PacketByteRange?
    public let jumpTargetPacketID: UInt64?
    public let children: [PacketDetailNode]

    public init(
        id: String,
        name: String,
        value: String? = nil,
        kind: PacketDetailNodeKind = .field,
        byteRange: PacketByteRange? = nil,
        jumpTargetPacketID: UInt64? = nil,
        children: [PacketDetailNode] = []
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.kind = kind
        self.byteRange = byteRange
        self.jumpTargetPacketID = jumpTargetPacketID
        self.children = children
    }
}

public struct PacketInspection: Sendable, Codable, Hashable {
    public let packetID: UInt64
    public let packetNumber: UInt64
    public let rawBytes: Data
    public let detailNodes: [PacketDetailNode]
    public let decodeStatus: PacketDecodeStatus

    public init(
        packetID: UInt64,
        packetNumber: UInt64,
        rawBytes: Data,
        detailNodes: [PacketDetailNode],
        decodeStatus: PacketDecodeStatus
    ) {
        self.packetID = packetID
        self.packetNumber = packetNumber
        self.rawBytes = rawBytes
        self.detailNodes = detailNodes
        self.decodeStatus = decodeStatus
    }
}

public struct PacketLoadProgress: Sendable, Codable, Hashable {
    public enum Phase: String, Sendable, Codable {
        case idle
        case loading
        case completed
        case cancelled
        case failed
    }

    public let phase: Phase
    public let loadedPacketCount: Int
    public let processedBytes: UInt64?
    public let totalBytes: UInt64?
    public let isPartialResult: Bool
    public let message: String

    public init(
        phase: Phase,
        loadedPacketCount: Int,
        processedBytes: UInt64? = nil,
        totalBytes: UInt64? = nil,
        isPartialResult: Bool = false,
        message: String
    ) {
        self.phase = phase
        self.loadedPacketCount = loadedPacketCount
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.isPartialResult = isPartialResult
        self.message = message
    }

    public var fractionCompleted: Double? {
        guard let processedBytes, let totalBytes, totalBytes > 0 else {
            return nil
        }

        return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
    }

    public static let idle = PacketLoadProgress(
        phase: .idle,
        loadedPacketCount: 0,
        processedBytes: nil,
        totalBytes: nil,
        isPartialResult: false,
        message: "No offline capture is loading."
    )
}

public struct PacketEndpoint: Sendable, Codable, Hashable {
    public let address: String?
    public let port: UInt16?

    public init(address: String? = nil, port: UInt16? = nil) {
        self.address = address
        self.port = port
    }
}

public struct PacketEndpoints: Sendable, Codable, Hashable {
    public let source: PacketEndpoint
    public let destination: PacketEndpoint

    public init(source: PacketEndpoint, destination: PacketEndpoint) {
        self.source = source
        self.destination = destination
    }
}

public struct PacketLayer: Sendable, Codable, Hashable {
    public let name: String
    public let detailSummary: String?

    public init(name: String, detailSummary: String? = nil) {
        self.name = name
        self.detailSummary = detailSummary
    }
}

public struct PacketDecodeStatus: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case complete
        case partial
        case malformed
        case unsupported
    }

    public let kind: Kind
    public let reason: String?

    public init(kind: Kind, reason: String? = nil) {
        self.kind = kind
        self.reason = reason
    }
}

public struct PacketCaptureMetadata: Sendable, Codable, Hashable {
    public let linkType: CaptureLinkType
    public let isTruncated: Bool
    public let packetComment: String?
    public let interfaceName: String?

    public init(
        linkType: CaptureLinkType,
        isTruncated: Bool,
        packetComment: String? = nil,
        interfaceName: String? = nil
    ) {
        self.linkType = linkType
        self.isTruncated = isTruncated
        self.packetComment = packetComment
        self.interfaceName = interfaceName
    }
}

public struct PacketClient: Sendable, Codable, Hashable {
    public let pid: Int32
    public let name: String
    public let displayName: String
    public let executablePath: String?
    public let bundleIdentifier: String?
    public let bundlePath: String?

    public init(
        pid: Int32,
        name: String,
        displayName: String,
        executablePath: String? = nil,
        bundleIdentifier: String? = nil,
        bundlePath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.displayName = displayName
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
    }
}

public struct PacketSummary: Identifiable, Sendable, Codable, Hashable {
    public let id: UInt64
    public let packetNumber: UInt64
    public let timestamp: Date
    public let source: CaptureSource
    public let interfaceID: String?
    public let transportHint: TransportProtocolHint
    public let endpoints: PacketEndpoints
    public let originalLength: Int
    public let capturedLength: Int
    public let streamID: UInt32?
    public let infoSummary: String
    public let layers: [PacketLayer]
    public let decodeStatus: PacketDecodeStatus
    public let captureMetadata: PacketCaptureMetadata
    public let sniDomainName: String?
    public let client: PacketClient?

    public init(
        id: UInt64? = nil,
        packetNumber: UInt64,
        timestamp: Date,
        source: CaptureSource,
        interfaceID: String? = nil,
        transportHint: TransportProtocolHint,
        endpoints: PacketEndpoints,
        originalLength: Int,
        capturedLength: Int,
        streamID: UInt32? = nil,
        infoSummary: String,
        layers: [PacketLayer],
        decodeStatus: PacketDecodeStatus,
        captureMetadata: PacketCaptureMetadata,
        sniDomainName: String? = nil,
        client: PacketClient? = nil
    ) {
        self.id = id ?? packetNumber
        self.packetNumber = packetNumber
        self.timestamp = timestamp
        self.source = source
        self.interfaceID = interfaceID
        self.transportHint = transportHint
        self.endpoints = endpoints
        self.originalLength = originalLength
        self.capturedLength = capturedLength
        self.streamID = streamID
        self.infoSummary = infoSummary
        self.layers = layers
        self.decodeStatus = decodeStatus
        self.captureMetadata = captureMetadata
        self.sniDomainName = sniDomainName
        self.client = client
    }
}

public enum PacketIngestEvent: Sendable, Equatable {
    case liveStateChanged(phase: LiveCaptureSessionPhase, message: String)
    case documentStateChanged(phase: OfflineCaptureDocumentPhase, message: String)
    case packetBatch([PacketSummary], disposition: PacketBatchDisposition)
    case loadProgressChanged(PacketLoadProgress)
    case healthChanged(CaptureHealthSnapshot)
    case documentMetadataChanged(CaptureDocumentMetadata)
}
