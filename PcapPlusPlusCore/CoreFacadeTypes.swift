import Foundation

public struct PacketryCoreError: Error, Sendable, Codable, Hashable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable {
        case integrationMisconfigured
        case capturePermissionDenied
        case invalidCaptureFilter
        case malformedCapture
        case unsupportedInterface
        case operationCancelled
        case unavailableFeature
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        "\(code.rawValue): \(message)"
    }
}

public enum CaptureFileFormat: String, Sendable, Codable, CaseIterable {
    case pcap
    case pcapng
}

public enum CaptureSource: String, Sendable, Codable {
    case live
    case offline
}

public enum CaptureLinkType: String, Sendable, Codable {
    case ethernet
    case loopback
    case raw
    case unknown
}

public enum CaptureInterfaceAvailability: String, Sendable, Codable {
    case available
    case hidden
    case unavailable
    case unsupported
}

public enum NetworkAddressFamily: String, Sendable, Codable {
    case ipv4
    case ipv6
    case linkLayer
    case unknown
}

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

public struct CaptureInterfaceCapabilities: Sendable, Codable, Hashable {
    public let canCapture: Bool
    public let supportsPromiscuousMode: Bool
    public let requiresBPFPermissionSetup: Bool
    public let providesMacOSMetadata: Bool

    public init(
        canCapture: Bool,
        supportsPromiscuousMode: Bool,
        requiresBPFPermissionSetup: Bool,
        providesMacOSMetadata: Bool
    ) {
        self.canCapture = canCapture
        self.supportsPromiscuousMode = supportsPromiscuousMode
        self.requiresBPFPermissionSetup = requiresBPFPermissionSetup
        self.providesMacOSMetadata = providesMacOSMetadata
    }
}

public struct CaptureInterfaceAddress: Sendable, Codable, Hashable {
    public let family: NetworkAddressFamily
    public let value: String

    public init(family: NetworkAddressFamily, value: String) {
        self.family = family
        self.value = value
    }
}

public struct CaptureInterfaceSummary: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let displayName: String
    public let friendlyName: String?
    public let addresses: [CaptureInterfaceAddress]
    public let linkType: CaptureLinkType
    public let availability: CaptureInterfaceAvailability
    public let capabilities: CaptureInterfaceCapabilities

    public init(
        id: String,
        displayName: String,
        friendlyName: String? = nil,
        addresses: [CaptureInterfaceAddress],
        linkType: CaptureLinkType,
        availability: CaptureInterfaceAvailability,
        capabilities: CaptureInterfaceCapabilities
    ) {
        self.id = id
        self.displayName = displayName
        self.friendlyName = friendlyName
        self.addresses = addresses
        self.linkType = linkType
        self.availability = availability
        self.capabilities = capabilities
    }
}

public struct PacketEndpoint: Sendable, Codable, Hashable {
    public let host: String?
    public let port: UInt16?

    public init(host: String? = nil, port: UInt16? = nil) {
        self.host = host
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
    public let layers: [PacketLayer]
    public let decodeStatus: PacketDecodeStatus

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
        layers: [PacketLayer],
        decodeStatus: PacketDecodeStatus
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
        self.layers = layers
        self.decodeStatus = decodeStatus
    }
}

public struct CaptureFilterValidation: Sendable, Codable, Hashable {
    public enum Disposition: String, Sendable, Codable {
        case valid
        case invalid
        case unavailable
    }

    public let disposition: Disposition
    public let normalizedExpression: String?
    public let message: String?

    public init(
        disposition: Disposition,
        normalizedExpression: String? = nil,
        message: String? = nil
    ) {
        self.disposition = disposition
        self.normalizedExpression = normalizedExpression
        self.message = message
    }
}

public protocol CaptureInterfaceProviding: Sendable {
    func listInterfaces() async throws -> [CaptureInterfaceSummary]
}

public protocol CaptureFilterValidating: Sendable {
    func validateCaptureFilter(_ expression: String) async -> CaptureFilterValidation
}

public protocol OfflineCaptureProviding: Sendable {
    func supportedOfflineFormats() -> [CaptureFileFormat]
    func loadPacketSummaries(from fileURL: URL) async throws -> [PacketSummary]
}

public protocol PacketryCoreProviding:
    CaptureInterfaceProviding,
    CaptureFilterValidating,
    OfflineCaptureProviding {}

public struct UnconfiguredPacketryCore: PacketryCoreProviding {
    public init() {}

    public func listInterfaces() async throws -> [CaptureInterfaceSummary] {
        throw PacketryCoreError(
            code: .integrationMisconfigured,
            message: "Native interface discovery is not wired into PcapPlusPlusCore yet."
        )
    }

    public func validateCaptureFilter(_ expression: String) async -> CaptureFilterValidation {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return CaptureFilterValidation(
                disposition: .invalid,
                normalizedExpression: nil,
                message: "Capture filters cannot be empty."
            )
        }

        return CaptureFilterValidation(
            disposition: .unavailable,
            normalizedExpression: trimmed,
            message: "Filter compilation will be provided by the native core in a later ticket."
        )
    }

    public func supportedOfflineFormats() -> [CaptureFileFormat] {
        CaptureFileFormat.allCases
    }

    public func loadPacketSummaries(from fileURL: URL) async throws -> [PacketSummary] {
        throw PacketryCoreError(
            code: .integrationMisconfigured,
            message: "Offline packet loading is not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent)."
        )
    }
}
