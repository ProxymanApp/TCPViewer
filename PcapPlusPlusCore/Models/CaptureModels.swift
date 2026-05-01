//
//  CaptureModels.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import Foundation

public enum CaptureFileFormat: String, Sendable, Codable, CaseIterable {
    case pcap
    case pcapng

    public static let defaultExportFormat: CaptureFileFormat = .pcapng

    public init(exportRawValue rawValue: String?) {
        guard let rawValue,
              let format = CaptureFileFormat(rawValue: rawValue.lowercased()) else {
            self = Self.defaultExportFormat
            return
        }

        self = format
    }
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
