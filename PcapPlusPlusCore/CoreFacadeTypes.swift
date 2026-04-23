import Foundation

public struct PacketryCoreError: Error, Sendable, Codable, Hashable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable {
        case integrationMisconfigured
        case interfaceDiscoveryFailed
        case capturePermissionDenied
        case invalidCaptureFilter
        case invalidCaptureOptions
        case malformedCapture
        case unsupportedInterface
        case liveSessionStartFailed
        case liveSessionControlFailed
        case offlineFileOpenFailed
        case offlineFileSaveFailed
        case writerFailure
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

public enum LiveCaptureSessionPhase: String, Sendable, Codable {
    case ready
    case starting
    case running
    case paused
    case stopping
    case stopped
    case failed
}

public enum OfflineCaptureDocumentPhase: String, Sendable, Codable {
    case opening
    case loaded
    case saving
    case saved
    case reopening
    case failed
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

public struct CaptureInterfaceActivityPreview: Sendable, Codable, Hashable {
    public let packetsPerSecond: Double?
    public let observedAt: Date?

    public init(packetsPerSecond: Double? = nil, observedAt: Date? = nil) {
        self.packetsPerSecond = packetsPerSecond
        self.observedAt = observedAt
    }
}

public struct CaptureInterfaceSummary: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let technicalName: String
    public let displayName: String
    public let friendlyName: String?
    public let interfaceDescription: String?
    public let isLoopback: Bool
    public let addresses: [CaptureInterfaceAddress]
    public let linkType: CaptureLinkType
    public let availability: CaptureInterfaceAvailability
    public let availabilityReason: String?
    public let activityPreview: CaptureInterfaceActivityPreview
    public let capabilities: CaptureInterfaceCapabilities

    public init(
        id: String,
        technicalName: String,
        displayName: String,
        friendlyName: String? = nil,
        interfaceDescription: String? = nil,
        isLoopback: Bool,
        addresses: [CaptureInterfaceAddress],
        linkType: CaptureLinkType,
        availability: CaptureInterfaceAvailability,
        availabilityReason: String? = nil,
        activityPreview: CaptureInterfaceActivityPreview = CaptureInterfaceActivityPreview(),
        capabilities: CaptureInterfaceCapabilities
    ) {
        self.id = id
        self.technicalName = technicalName
        self.displayName = displayName
        self.friendlyName = friendlyName
        self.interfaceDescription = interfaceDescription
        self.isLoopback = isLoopback
        self.addresses = addresses
        self.linkType = linkType
        self.availability = availability
        self.availabilityReason = availabilityReason
        self.activityPreview = activityPreview
        self.capabilities = capabilities
    }

    public var isSelectable: Bool {
        availability == .available && capabilities.canCapture
    }
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
        captureMetadata: PacketCaptureMetadata
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
    }
}

public struct CaptureHealthSnapshot: Sendable, Codable, Hashable {
    public let packetsReceived: UInt64
    public let packetsDropped: UInt64
    public let packetsDroppedByInterface: UInt64
    public let packetsObserved: UInt64
    public let lastUpdated: Date?
    public let statusMessage: String?

    public init(
        packetsReceived: UInt64,
        packetsDropped: UInt64,
        packetsDroppedByInterface: UInt64,
        packetsObserved: UInt64,
        lastUpdated: Date? = nil,
        statusMessage: String? = nil
    ) {
        self.packetsReceived = packetsReceived
        self.packetsDropped = packetsDropped
        self.packetsDroppedByInterface = packetsDroppedByInterface
        self.packetsObserved = packetsObserved
        self.lastUpdated = lastUpdated
        self.statusMessage = statusMessage
    }

    public static let empty = CaptureHealthSnapshot(
        packetsReceived: 0,
        packetsDropped: 0,
        packetsDroppedByInterface: 0,
        packetsObserved: 0,
        lastUpdated: nil,
        statusMessage: nil
    )
}

public struct CaptureDocumentMetadata: Sendable, Codable, Hashable {
    public let format: CaptureFileFormat
    public let operatingSystem: String?
    public let hardware: String?
    public let captureApplication: String?
    public let fileComment: String?

    public init(
        format: CaptureFileFormat,
        operatingSystem: String? = nil,
        hardware: String? = nil,
        captureApplication: String? = nil,
        fileComment: String? = nil
    ) {
        self.format = format
        self.operatingSystem = operatingSystem
        self.hardware = hardware
        self.captureApplication = captureApplication
        self.fileComment = fileComment
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

public enum CaptureStopCondition: Sendable, Codable, Hashable {
    case manual
    case packetCount(UInt64)
    case durationMilliseconds(UInt64)
}

public struct CaptureFileWriting: Sendable, Codable, Hashable {
    public enum Mode: String, Sendable, Codable {
        case disabled
        case single
        case rotating
        case ring
    }

    public let mode: Mode
    public let directoryURL: URL?
    public let fileNameStem: String?
    public let format: CaptureFileFormat?
    public let maxFileSizeBytes: UInt64?
    public let ringFileCount: Int?

    public init(
        mode: Mode,
        directoryURL: URL? = nil,
        fileNameStem: String? = nil,
        format: CaptureFileFormat? = nil,
        maxFileSizeBytes: UInt64? = nil,
        ringFileCount: Int? = nil
    ) {
        self.mode = mode
        self.directoryURL = directoryURL
        self.fileNameStem = fileNameStem
        self.format = format
        self.maxFileSizeBytes = maxFileSizeBytes
        self.ringFileCount = ringFileCount
    }

    public static let disabled = CaptureFileWriting(mode: .disabled)
}

public struct CaptureOptions: Sendable, Codable, Hashable {
    public let promiscuousMode: Bool
    public let snapshotLength: Int
    public let kernelBufferSizeBytes: Int
    public let readTimeoutMilliseconds: Int
    public let captureFilterExpression: String?
    public let stopCondition: CaptureStopCondition
    public let fileWriting: CaptureFileWriting

    public init(
        promiscuousMode: Bool,
        snapshotLength: Int,
        kernelBufferSizeBytes: Int,
        readTimeoutMilliseconds: Int,
        captureFilterExpression: String? = nil,
        stopCondition: CaptureStopCondition,
        fileWriting: CaptureFileWriting = .disabled
    ) {
        self.promiscuousMode = promiscuousMode
        self.snapshotLength = snapshotLength
        self.kernelBufferSizeBytes = kernelBufferSizeBytes
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.captureFilterExpression = captureFilterExpression
        self.stopCondition = stopCondition
        self.fileWriting = fileWriting
    }

    public static func defaults(for interface: CaptureInterfaceSummary? = nil) -> CaptureOptions {
        CaptureOptions(
            promiscuousMode: !(interface?.isLoopback ?? false),
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            captureFilterExpression: nil,
            stopCondition: .manual,
            fileWriting: .disabled
        )
    }

    public func validated(for interface: CaptureInterfaceSummary? = nil) throws -> CaptureOptions {
        guard snapshotLength > 0 else {
            throw PacketryCoreError(code: .invalidCaptureOptions, message: "Snapshot length must be greater than zero.")
        }

        guard kernelBufferSizeBytes >= 0 else {
            throw PacketryCoreError(code: .invalidCaptureOptions, message: "Kernel buffer size cannot be negative.")
        }

        guard readTimeoutMilliseconds >= 0 else {
            throw PacketryCoreError(code: .invalidCaptureOptions, message: "Read timeout cannot be negative.")
        }

        switch stopCondition {
        case .manual:
            break
        case .packetCount(let count):
            guard count > 0 else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Packet-count stop conditions must be greater than zero.")
            }
        case .durationMilliseconds(let duration):
            guard duration > 0 else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Duration stop conditions must be greater than zero.")
            }
        }

        switch fileWriting.mode {
        case .disabled:
            break
        case .single:
            guard fileWriting.directoryURL != nil else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Single-file capture writing needs a directory.")
            }
            guard !(fileWriting.fileNameStem?.isEmpty ?? true) else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Single-file capture writing needs a filename stem.")
            }
            guard fileWriting.format != nil else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Single-file capture writing needs an output format.")
            }
        case .rotating:
            guard fileWriting.directoryURL != nil else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs a directory.")
            }
            guard !(fileWriting.fileNameStem?.isEmpty ?? true) else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs a filename stem.")
            }
            guard fileWriting.format != nil else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs an output format.")
            }
            guard (fileWriting.maxFileSizeBytes ?? 0) > 0 else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Rotating capture writing needs a max file size.")
            }
        case .ring:
            guard fileWriting.directoryURL != nil else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs a directory.")
            }
            guard !(fileWriting.fileNameStem?.isEmpty ?? true) else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs a filename stem.")
            }
            guard fileWriting.format != nil else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs an output format.")
            }
            guard (fileWriting.maxFileSizeBytes ?? 0) > 0 else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs a max file size.")
            }
            guard (fileWriting.ringFileCount ?? 0) > 1 else {
                throw PacketryCoreError(code: .invalidCaptureOptions, message: "Ring capture writing needs at least two files.")
            }
        }

        let defaultPromiscuous = !(interface?.isLoopback ?? false)
        if interface?.isLoopback == true && promiscuousMode != defaultPromiscuous {
            throw PacketryCoreError(code: .invalidCaptureOptions, message: "Loopback interfaces do not support promiscuous mode in Packetry.")
        }

        return self
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

public protocol CaptureInterfaceProviding: Sendable {
    func listInterfaces() async throws -> [CaptureInterfaceSummary]
}

public protocol CaptureFilterValidating: Sendable {
    func validateCaptureFilter(_ expression: String) async -> CaptureFilterValidation
}

public protocol LiveCaptureSessionProviding: Sendable {
    func events() -> AsyncThrowingStream<PacketIngestEvent, Error>
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection
    func healthSnapshot() async -> CaptureHealthSnapshot
}

public protocol OfflineCaptureDocumentProviding: Sendable {
    func events() -> AsyncThrowingStream<PacketIngestEvent, Error>
    func open() async throws -> [PacketSummary]
    func reopen() async throws -> [PacketSummary]
    func cancelLoading() async
    func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection
    func save() async throws
    func save(to url: URL, format: CaptureFileFormat) async throws
    func currentURL() async -> URL
    func currentMetadata() async -> CaptureDocumentMetadata
    func packetSummaries() async -> [PacketSummary]
    func loadProgress() async -> PacketLoadProgress
}

public protocol LiveCaptureProviding: Sendable {
    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions
    func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions) async throws -> any LiveCaptureSessionProviding
}

public protocol OfflineCaptureProviding: Sendable {
    func supportedOfflineFormats() -> [CaptureFileFormat]
    func openOfflineCaptureDocument(at fileURL: URL) async throws -> any OfflineCaptureDocumentProviding
    func loadPacketSummaries(from fileURL: URL) async throws -> [PacketSummary]
}

public protocol PacketryCoreProviding:
    CaptureInterfaceProviding,
    CaptureFilterValidating,
    LiveCaptureProviding,
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
            message: "Native capture-filter validation is not available in the unconfigured core."
        )
    }

    public func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        try options.validated(for: interface)
    }

    public func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions) async throws -> any LiveCaptureSessionProviding {
        _ = try validateCaptureOptions(options, for: nil)
        throw PacketryCoreError(
            code: .integrationMisconfigured,
            message: "Native live capture sessions are not wired into PcapPlusPlusCore yet."
        )
    }

    public func supportedOfflineFormats() -> [CaptureFileFormat] {
        CaptureFileFormat.allCases
    }

    public func openOfflineCaptureDocument(at fileURL: URL) async throws -> any OfflineCaptureDocumentProviding {
        throw PacketryCoreError(
            code: .integrationMisconfigured,
            message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent)."
        )
    }

    public func loadPacketSummaries(from fileURL: URL) async throws -> [PacketSummary] {
        let document = try await openOfflineCaptureDocument(at: fileURL)
        return try await document.open()
    }
}

public struct UnconfiguredLiveCaptureSession: LiveCaptureSessionProviding {
    public init() {}

    public func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    public func start() async throws {
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")
    }

    public func pause() async throws {
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")
    }

    public func resume() async throws {
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")
    }

    public func stop() async throws {
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Native live capture sessions are not wired into PcapPlusPlusCore yet.")
    }

    public func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        _ = id
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Packet inspection is not wired into PcapPlusPlusCore yet.")
    }

    public func healthSnapshot() async -> CaptureHealthSnapshot {
        .empty
    }
}

public struct UnconfiguredOfflineCaptureDocument: OfflineCaptureDocumentProviding {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    public func open() async throws -> [PacketSummary] {
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")
    }

    public func reopen() async throws -> [PacketSummary] {
        try await open()
    }

    public func cancelLoading() async {
    }

    public func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        _ = id
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Packet inspection is not wired into PcapPlusPlusCore yet.")
    }

    public func save() async throws {
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")
    }

    public func save(to url: URL, format: CaptureFileFormat) async throws {
        _ = url
        _ = format
        throw PacketryCoreError(code: .integrationMisconfigured, message: "Native offline capture documents are not wired into PcapPlusPlusCore yet for \(fileURL.lastPathComponent).")
    }

    public func currentURL() async -> URL {
        fileURL
    }

    public func currentMetadata() async -> CaptureDocumentMetadata {
        CaptureDocumentMetadata(format: .pcapng)
    }

    public func packetSummaries() async -> [PacketSummary] {
        []
    }

    public func loadProgress() async -> PacketLoadProgress {
        .idle
    }
}
