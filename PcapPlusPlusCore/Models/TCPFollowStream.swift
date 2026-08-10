//
//  TCPFollowStream.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import Foundation

public enum TCPFollowDirection: String, Sendable, Codable, Hashable {
    case clientToServer
    case serverToClient
}

public struct TCPFollowRecord: Sendable, Codable, Hashable {
    public let direction: TCPFollowDirection
    public let packetID: PacketSummary.ID
    public let timestamp: Date
    public let sequenceNumber: UInt32
    public let data: Data

    public init(
        direction: TCPFollowDirection,
        packetID: PacketSummary.ID,
        timestamp: Date,
        sequenceNumber: UInt32,
        data: Data
    ) {
        self.direction = direction
        self.packetID = packetID
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.data = data
    }
}

public struct TCPFollowStream: Sendable, Codable, Hashable {
    public let client: PacketEndpoint
    public let server: PacketEndpoint
    public let records: [TCPFollowRecord]
    public let clientByteCount: Int
    public let serverByteCount: Int
    public let capturedThroughPacketID: PacketSummary.ID
    public let capturedAt: Date
    public let isTruncated: Bool

    public init(
        client: PacketEndpoint,
        server: PacketEndpoint,
        records: [TCPFollowRecord],
        clientByteCount: Int,
        serverByteCount: Int,
        capturedThroughPacketID: PacketSummary.ID,
        capturedAt: Date,
        isTruncated: Bool
    ) {
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

public struct TCPFollowLimits: Sendable, Equatable, Hashable {
    public let maximumCandidatePacketCount: Int
    public let maximumPayloadBytes: Int
    public let maximumRecordCount: Int

    public init(
        maximumCandidatePacketCount: Int = 250_000,
        maximumPayloadBytes: Int = 64 * 1_024 * 1_024,
        maximumRecordCount: Int = 100_000
    ) {
        self.maximumCandidatePacketCount = max(maximumCandidatePacketCount, 1)
        self.maximumPayloadBytes = max(maximumPayloadBytes, 1)
        self.maximumRecordCount = max(maximumRecordCount, 1)
    }

    public static let `default` = TCPFollowLimits()
}

public struct TCPFollowProgress: Sendable, Equatable {
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

public typealias TCPFollowProgressHandler = (TCPFollowProgress) -> Void
public typealias TCPFollowCancellationCheck = () -> Bool

public protocol TCPStreamFollowing: AnyObject {
    func followTCPStream(
        containing packetID: PacketSummary.ID,
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?,
        completion: @escaping TCPViewerCompletion<TCPFollowStream>
    )
}

public extension TCPStreamFollowing {
    func followTCPStream(
        containing packetID: PacketSummary.ID,
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?,
        completion: @escaping TCPViewerCompletion<TCPFollowStream>
    ) {
        completion(.failure(TCPViewerCoreError(
            code: .unavailableFeature,
            message: "Follow TCP Stream is unavailable for this capture source."
        )))
    }

    func followTCPStream(
        containing packetID: PacketSummary.ID,
        completion: @escaping TCPViewerCompletion<TCPFollowStream>
    ) {
        followTCPStream(
            containing: packetID,
            limits: .default,
            progress: nil,
            shouldCancel: nil,
            completion: completion
        )
    }
}
