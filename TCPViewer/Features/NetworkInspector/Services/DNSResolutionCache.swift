//
//  DNSResolutionCache.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/8/26.
//

import Darwin
import Foundation
import PcapPlusPlusCore

struct DNSResolutionCache {
    struct DebugSnapshot: Equatable {
        let ipAddressCount: Int
        let candidateCount: Int
    }

    private struct Entry {
        let domainName: String
        let observedAt: Date
        let expiresAt: Date
    }

    private let maximumIPAddressCount: Int
    private let maximumDomainsPerIPAddress: Int
    private let maximumRetention: TimeInterval
    private var entriesByIPAddress: [String: [Entry]] = [:]
    private var insertionOrder: [String] = []
    private var evictionIndex = 0

    init(
        maximumIPAddressCount: Int = 50_000,
        maximumDomainsPerIPAddress: Int = 4,
        maximumRetention: TimeInterval = 86_400
    ) {
        self.maximumIPAddressCount = max(maximumIPAddressCount, 1)
        self.maximumDomainsPerIPAddress = max(maximumDomainsPerIPAddress, 1)
        self.maximumRetention = max(maximumRetention, 0)
    }

    // Store bounded DNS evidence and honor the shorter of the record TTL and retention limit.
    mutating func observe(_ observations: [DNSResolutionObservation], at timestamp: Date) {
        for observation in observations {
            guard observation.timeToLive > 0,
                  maximumRetention > 0,
                  let ipAddress = Self.normalizedIPAddress(observation.ipAddress),
                  let domainName = Self.normalizedDomain(observation.domainName) else {
                continue
            }

            let lifetime = min(TimeInterval(observation.timeToLive), maximumRetention)
            let entry = Entry(
                domainName: domainName,
                observedAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(lifetime)
            )
            var entries = entriesByIPAddress[ipAddress, default: []]
            entries.removeAll { $0.expiresAt <= timestamp || $0.domainName == domainName }
            entries.append(entry)
            if entries.count > maximumDomainsPerIPAddress {
                entries.removeFirst(entries.count - maximumDomainsPerIPAddress)
            }

            if entriesByIPAddress[ipAddress] == nil {
                insertionOrder.append(ipAddress)
            }
            entriesByIPAddress[ipAddress] = entries
        }

        evictIfNeeded()
    }

    // Return the newest unexpired observation for an IP in average O(1) time.
    mutating func domain(forIPAddress address: String, at timestamp: Date) -> String? {
        guard let ipAddress = Self.normalizedIPAddress(address),
              var entries = entriesByIPAddress[ipAddress] else {
            return nil
        }

        entries.removeAll { $0.expiresAt <= timestamp }
        guard !entries.isEmpty else {
            // Keep the bounded key slot so reinsertion cannot create duplicate FIFO entries.
            entriesByIPAddress[ipAddress] = []
            return nil
        }
        entriesByIPAddress[ipAddress] = entries
        return entries.max { $0.observedAt < $1.observedAt }?.domainName
    }

    mutating func reset() {
        entriesByIPAddress.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
        evictionIndex = 0
    }

    func debugSnapshot() -> DebugSnapshot {
        DebugSnapshot(
            ipAddressCount: entriesByIPAddress.count,
            candidateCount: entriesByIPAddress.values.reduce(0) { $0 + $1.count }
        )
    }

    private mutating func evictIfNeeded() {
        while entriesByIPAddress.count > maximumIPAddressCount, evictionIndex < insertionOrder.count {
            let ipAddress = insertionOrder[evictionIndex]
            evictionIndex += 1
            entriesByIPAddress.removeValue(forKey: ipAddress)
        }

        if evictionIndex > 4_096, evictionIndex * 2 > insertionOrder.count {
            insertionOrder.removeFirst(evictionIndex)
            evictionIndex = 0
        }
    }

    private static func normalizedDomain(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 253 else {
            return nil
        }
        return normalized
    }

    private static func normalizedIPAddress(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
        return nil
    }
}
