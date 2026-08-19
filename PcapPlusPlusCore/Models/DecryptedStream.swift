//
//  DecryptedStream.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 19/8/26.
//

import Foundation

public enum DecryptedStreamProtocol: String, Sendable, Codable, Hashable {
    case tls = "TLS"
    case dtls = "DTLS"
    case quic = "QUIC"
}

public struct DecryptedStreamPayload: Sendable, Codable, Hashable {
    public let data: Data
    public let observedByteCount: Int
    public let isTruncated: Bool

    public init(data: Data, observedByteCount: Int, isTruncated: Bool) {
        self.data = data
        self.observedByteCount = observedByteCount
        self.isTruncated = isTruncated
    }
}

public struct DecryptedStreamResult: Sendable, Codable, Hashable {
    public let protocolName: DecryptedStreamProtocol
    public let client: PacketEndpoint
    public let server: PacketEndpoint
    public let request: DecryptedStreamPayload
    public let response: DecryptedStreamPayload

    public init(
        protocolName: DecryptedStreamProtocol,
        client: PacketEndpoint,
        server: PacketEndpoint,
        request: DecryptedStreamPayload,
        response: DecryptedStreamPayload
    ) {
        self.protocolName = protocolName
        self.client = client
        self.server = server
        self.request = request
        self.response = response
    }
}

public struct DecryptedStreamLimits: Sendable, Equatable, Hashable {
    public let maximumCandidatePacketCount: Int
    public let maximumBytesPerDirection: Int
    public let maximumRecordCount: Int

    public init(
        maximumCandidatePacketCount: Int = 250_000,
        maximumBytesPerDirection: Int = 8 * 1_024 * 1_024,
        maximumRecordCount: Int = 100_000
    ) {
        self.maximumCandidatePacketCount = max(maximumCandidatePacketCount, 1)
        self.maximumBytesPerDirection = max(maximumBytesPerDirection, 1)
        self.maximumRecordCount = max(maximumRecordCount, 1)
    }

    public static let `default` = DecryptedStreamLimits()
}

public protocol DecryptedStreamLoading: AnyObject {
    func loadDecryptedStream(
        containing packetID: PacketSummary.ID,
        limits: DecryptedStreamLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?,
        completion: @escaping TCPViewerCompletion<DecryptedStreamResult>
    )
}

public extension DecryptedStreamLoading {
    func loadDecryptedStream(
        containing packetID: PacketSummary.ID,
        limits: DecryptedStreamLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?,
        completion: @escaping TCPViewerCompletion<DecryptedStreamResult>
    ) {
        completion(.failure(TCPViewerCoreError(
            code: .unavailableFeature,
            message: "TLS stream decryption is unavailable for this capture source."
        )))
    }
}
