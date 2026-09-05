//
//  FollowStream.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import Foundation

public enum FollowStreamProtocol: String, Sendable, Codable, Hashable {
    case tcp
    case udp

    public var displayName: String { rawValue.uppercased() }
    public var menuTitle: String { "Follow \(displayName) Stream" }
}

// Wireshark numbers TCP and UDP independently, so every follow index includes the protocol.
public struct FollowStreamID: Sendable, Codable, Hashable {
    public let streamProtocol: FollowStreamProtocol
    public let streamID: UInt32

    public init(streamProtocol: FollowStreamProtocol, streamID: UInt32) {
        self.streamProtocol = streamProtocol
        self.streamID = streamID
    }

    // The C bridge packs the protocol above the 32-bit Wireshark stream number.
    init(wiresharkValue: UInt64) {
        streamProtocol = wiresharkValue >> 32 == 0 ? .tcp : .udp
        streamID = UInt32(truncatingIfNeeded: wiresharkValue)
    }
}

public enum FollowStreamDirection: String, Sendable, Codable, Hashable {
    case clientToServer
    case serverToClient
}

public struct FollowStreamRecord: Sendable, Codable, Hashable {
    public let direction: FollowStreamDirection
    public let packetID: PacketSummary.ID
    public let timestamp: Date
    public let sequenceNumber: UInt32?
    public let data: Data

    public init(
        direction: FollowStreamDirection,
        packetID: PacketSummary.ID,
        timestamp: Date,
        sequenceNumber: UInt32?,
        data: Data
    ) {
        self.direction = direction
        self.packetID = packetID
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.data = data
    }
}

public struct FollowStream: Sendable, Codable, Hashable {
    public let streamProtocol: FollowStreamProtocol
    public let client: PacketEndpoint
    public let server: PacketEndpoint
    public let records: [FollowStreamRecord]
    public let clientByteCount: Int
    public let serverByteCount: Int
    public let capturedThroughPacketID: PacketSummary.ID
    public let capturedAt: Date
    public let isTruncated: Bool

    public init(
        streamProtocol: FollowStreamProtocol = .tcp,
        client: PacketEndpoint,
        server: PacketEndpoint,
        records: [FollowStreamRecord],
        clientByteCount: Int,
        serverByteCount: Int,
        capturedThroughPacketID: PacketSummary.ID,
        capturedAt: Date,
        isTruncated: Bool
    ) {
        self.streamProtocol = streamProtocol
        self.client = client
        self.server = server
        self.records = records
        self.clientByteCount = clientByteCount
        self.serverByteCount = serverByteCount
        self.capturedThroughPacketID = capturedThroughPacketID
        self.capturedAt = capturedAt
        self.isTruncated = isTruncated
    }
}

public struct FollowStreamLimits: Sendable, Equatable, Hashable {
    public let maximumCandidatePacketCount: Int
    public let maximumPayloadBytes: Int
    public let maximumRecordCount: Int
    public let includedDirection: FollowStreamDirection?

    public init(
        maximumCandidatePacketCount: Int = 250_000,
        maximumPayloadBytes: Int = 64 * 1_024 * 1_024,
        maximumRecordCount: Int = 100_000,
        includedDirection: FollowStreamDirection? = nil
    ) {
        self.maximumCandidatePacketCount = max(maximumCandidatePacketCount, 1)
        self.maximumPayloadBytes = max(maximumPayloadBytes, 1)
        self.maximumRecordCount = max(maximumRecordCount, 1)
        self.includedDirection = includedDirection
    }

    public static let `default` = FollowStreamLimits()
}

public struct FollowStreamProgress: Sendable, Equatable {
    public let processedPacketCount: Int
    public let totalPacketCount: Int

    public init(processedPacketCount: Int, totalPacketCount: Int) {
        self.processedPacketCount = processedPacketCount
        self.totalPacketCount = totalPacketCount
    }

    public var fractionCompleted: Double {
        guard totalPacketCount > 0 else {
            return 0
        }
        return min(max(Double(processedPacketCount) / Double(totalPacketCount), 0), 1)
    }
}

public typealias FollowStreamProgressHandler = (FollowStreamProgress) -> Void
public typealias FollowStreamCancellationCheck = () -> Bool

public protocol StreamFollowing: AnyObject {
    func followStream(
        containing packetID: PacketSummary.ID,
        streamProtocol: FollowStreamProtocol?,
        limits: FollowStreamLimits,
        progress: FollowStreamProgressHandler?,
        shouldCancel: FollowStreamCancellationCheck?,
        completion: @escaping TCPViewerCompletion<FollowStream>
    )
}

public extension StreamFollowing {
    func followStream(
        containing packetID: PacketSummary.ID,
        streamProtocol: FollowStreamProtocol? = nil,
        limits: FollowStreamLimits,
        progress: FollowStreamProgressHandler?,
        shouldCancel: FollowStreamCancellationCheck?,
        completion: @escaping TCPViewerCompletion<FollowStream>
    ) {
        completion(.failure(TCPViewerCoreError(
            code: .unavailableFeature,
            message: "Follow Stream is unavailable for this capture source."
        )))
    }

    func followStream(
        containing packetID: PacketSummary.ID,
        streamProtocol: FollowStreamProtocol? = nil,
        completion: @escaping TCPViewerCompletion<FollowStream>
    ) {
        followStream(
            containing: packetID,
            streamProtocol: streamProtocol,
            limits: .default,
            progress: nil,
            shouldCancel: nil,
            completion: completion
        )
    }
}
