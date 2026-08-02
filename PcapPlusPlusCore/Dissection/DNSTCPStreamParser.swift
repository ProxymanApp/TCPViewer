//
//  DNSTCPStreamParser.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/8/26.
//

import Foundation

struct DNSTCPStreamSegment {
    let payloadSequenceNumber: UInt32
    let payload: [UInt8]
    let resetsStream: Bool
    let endsStream: Bool
}

struct DNSTCPStreamParser {
    private static let maximumMessageLength = Int(UInt16.max)
    private static let maximumMessagesPerPacket = 32
    private static let maximumObservationsPerPacket = 64

    private struct StreamKey: Hashable {
        let sourceAddress: String
        let sourcePort: UInt16
        let destinationAddress: String
        let destinationPort: UInt16
    }

    private struct StreamState {
        var nextSequenceNumber: UInt32
        var bufferedBytes: [UInt8]
        var lastObservedAt: Date
    }

    private let maximumStreamCount: Int
    private let idleTimeout: TimeInterval
    private var streams: [StreamKey: StreamState] = [:]

    // Configure small per-session bounds because DNS/TCP is uncommon but capture input is untrusted.
    init(maximumStreamCount: Int = 256, idleTimeout: TimeInterval = 120) {
        self.maximumStreamCount = max(maximumStreamCount, 1)
        self.idleTimeout = max(idleTimeout, 0)
    }

    // Parse every complete length-prefixed DNS message in one TCP payload.
    static func resolutions(inCompletePayload payload: [UInt8]) -> [DNSResolutionObservation] {
        var bufferedBytes = payload
        return drainCompleteMessages(from: &bufferedBytes)
    }

    // Reassemble sequential DNS/TCP payload bytes and return observations on the completing packet.
    mutating func resolutions(for packet: AnalyzedPacket, at timestamp: Date) -> [DNSResolutionObservation] {
        guard let segment = packet.dnsTCPStreamSegment,
              let sourceAddress = packet.sourceAddress,
              let sourcePort = packet.sourcePort,
              let destinationAddress = packet.destinationAddress,
              let destinationPort = packet.destinationPort else {
            return []
        }

        let key = StreamKey(
            sourceAddress: sourceAddress,
            sourcePort: sourcePort,
            destinationAddress: destinationAddress,
            destinationPort: destinationPort
        )
        if segment.resetsStream {
            streams.removeValue(forKey: key)
            return []
        }

        guard !segment.payload.isEmpty else {
            if segment.endsStream {
                streams.removeValue(forKey: key)
            }
            return []
        }

        var state = streams.removeValue(forKey: key)
        if let lastObservedAt = state?.lastObservedAt {
            let age = timestamp.timeIntervalSince(lastObservedAt)
            if age > idleTimeout {
                state = nil
            }
        }
        if state == nil {
            evictStreamIfNeeded()
            state = StreamState(
                nextSequenceNumber: segment.payloadSequenceNumber,
                bufferedBytes: [],
                lastObservedAt: timestamp
            )
        }

        guard var current = state else {
            return []
        }
        let relativeSequence = Int64(Int32(bitPattern: segment.payloadSequenceNumber &- current.nextSequenceNumber))
        if relativeSequence > 0 {
            // A capture gap loses the framing boundary, so restart from the newest segment instead of mixing bytes.
            current.bufferedBytes.removeAll(keepingCapacity: true)
            current.nextSequenceNumber = segment.payloadSequenceNumber
        }

        let repeatedByteCount = relativeSequence < 0 ? Int(min(-relativeSequence, Int64(segment.payload.count))) : 0
        let newBytes = segment.payload.dropFirst(repeatedByteCount)
        guard newBytes.count <= Self.maximumMessageLength + 2 else {
            return []
        }
        current.bufferedBytes.append(contentsOf: newBytes)
        current.nextSequenceNumber = current.nextSequenceNumber &+ UInt32(newBytes.count)
        current.lastObservedAt = timestamp

        let observations = Self.drainCompleteMessages(from: &current.bufferedBytes)
        if current.bufferedBytes.count > Self.maximumMessageLength + 2 {
            current.bufferedBytes.removeAll(keepingCapacity: false)
        }
        if segment.endsStream {
            streams.removeValue(forKey: key)
        } else {
            streams[key] = current
        }
        return observations
    }

    // Drop all partial streams when a capture lineage is cleared.
    mutating func reset() {
        streams.removeAll(keepingCapacity: false)
    }

    // Consume complete frames once so repeated Data removals cannot amplify work on hostile payloads.
    private static func drainCompleteMessages(from bufferedBytes: inout [UInt8]) -> [DNSResolutionObservation] {
        var observations: [DNSResolutionObservation] = []
        var seen: Set<DNSResolutionObservation> = []
        var cursor = 0
        var messageCount = 0

        while cursor + 2 <= bufferedBytes.count, messageCount < maximumMessagesPerPacket {
            let messageLength = Int(UInt16(bufferedBytes[cursor]) << 8 | UInt16(bufferedBytes[cursor + 1]))
            if messageLength == 0 {
                cursor += 2
                messageCount += 1
                continue
            }
            let messageEnd = cursor + 2 + messageLength
            guard messageEnd <= bufferedBytes.count else {
                break
            }

            let message = Data(bufferedBytes[(cursor + 2)..<messageEnd])
            for observation in DNSMessageParser(data: message).resolutions()
            where observations.count < maximumObservationsPerPacket && seen.insert(observation).inserted {
                observations.append(observation)
            }
            cursor = messageEnd
            messageCount += 1
        }

        if cursor > 0 {
            bufferedBytes.removeFirst(cursor)
        }
        if messageCount == maximumMessagesPerPacket || observations.count == maximumObservationsPerPacket {
            bufferedBytes.removeAll(keepingCapacity: false)
        }
        return observations
    }

    // Evict one bounded slot in average O(1); idle validation separately protects tuple reuse.
    private mutating func evictStreamIfNeeded() {
        guard streams.count >= maximumStreamCount, let streamToEvict = streams.keys.first else {
            return
        }
        streams.removeValue(forKey: streamToEvict)
    }
}
