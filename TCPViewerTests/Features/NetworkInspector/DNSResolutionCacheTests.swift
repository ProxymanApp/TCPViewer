//
//  DNSResolutionCacheTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/8/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

struct DNSResolutionCacheTests {

    @Test func storesAndLooksUpIPv4Address() {
        var cache = DNSResolutionCache()
        cache.observe([observation("spotify.com", "35.186.224.34", ttl: 60)], at: time(0))

        #expect(cache.domain(forIPAddress: "35.186.224.34", at: time(1)) == "spotify.com")
    }

    @Test func canonicalizesIPv6LookupAddress() {
        var cache = DNSResolutionCache()
        cache.observe([observation("ipv6.example", "2001:0db8:0:0:0:0:0:1", ttl: 60)], at: time(0))

        #expect(cache.domain(forIPAddress: "2001:db8::1", at: time(1)) == "ipv6.example")
    }

    @Test func normalizesDomainCaseAndTrailingDot() {
        var cache = DNSResolutionCache()
        cache.observe([observation(" Spotify.COM. ", "192.0.2.1", ttl: 60)], at: time(0))

        #expect(cache.domain(forIPAddress: "192.0.2.1", at: time(1)) == "spotify.com")
    }

    @Test func returnsNilForUnknownAddress() {
        var cache = DNSResolutionCache()

        #expect(cache.domain(forIPAddress: "192.0.2.99", at: time(0)) == nil)
    }

    @Test func expiresEntryAtDNSRecordTTL() {
        var cache = DNSResolutionCache()
        cache.observe([observation("short.example", "192.0.2.2", ttl: 5)], at: time(10))

        #expect(cache.domain(forIPAddress: "192.0.2.2", at: time(14)) == "short.example")
        #expect(cache.domain(forIPAddress: "192.0.2.2", at: time(15)) == nil)
    }

    @Test func capsEntryLifetimeAtConfiguredRetention() {
        var cache = DNSResolutionCache(maximumRetention: 10)
        cache.observe([observation("long.example", "192.0.2.3", ttl: 3_600)], at: time(0))

        #expect(cache.domain(forIPAddress: "192.0.2.3", at: time(9)) == "long.example")
        #expect(cache.domain(forIPAddress: "192.0.2.3", at: time(10)) == nil)
    }

    @Test func ignoresZeroTTLObservations() {
        var cache = DNSResolutionCache()
        cache.observe([observation("zero.example", "192.0.2.4", ttl: 0)], at: time(0))

        #expect(cache.domain(forIPAddress: "192.0.2.4", at: time(0)) == nil)
    }

    @Test func newestDomainWinsForSharedIPAddress() {
        var cache = DNSResolutionCache()
        cache.observe([observation("old.example", "192.0.2.5", ttl: 60)], at: time(0))
        cache.observe([observation("new.example", "192.0.2.5", ttl: 60)], at: time(1))

        #expect(cache.domain(forIPAddress: "192.0.2.5", at: time(2)) == "new.example")
    }

    @Test func capsCandidatesPerIPAddress() {
        var cache = DNSResolutionCache(maximumDomainsPerIPAddress: 2)
        cache.observe([observation("one.example", "192.0.2.6", ttl: 60)], at: time(0))
        cache.observe([observation("two.example", "192.0.2.6", ttl: 60)], at: time(1))
        cache.observe([observation("three.example", "192.0.2.6", ttl: 60)], at: time(2))

        #expect(cache.debugSnapshot().candidateCount == 2)
        #expect(cache.domain(forIPAddress: "192.0.2.6", at: time(3)) == "three.example")
    }

    @Test func evictsOldestIPAddressAtGlobalLimit() {
        var cache = DNSResolutionCache(maximumIPAddressCount: 2)
        cache.observe([observation("one.example", "192.0.2.1", ttl: 60)], at: time(0))
        cache.observe([observation("two.example", "192.0.2.2", ttl: 60)], at: time(1))
        cache.observe([observation("three.example", "192.0.2.3", ttl: 60)], at: time(2))

        #expect(cache.domain(forIPAddress: "192.0.2.1", at: time(3)) == nil)
        #expect(cache.domain(forIPAddress: "192.0.2.2", at: time(3)) == "two.example")
        #expect(cache.domain(forIPAddress: "192.0.2.3", at: time(3)) == "three.example")
    }

    @Test func rejectsInvalidAddressesAndDomains() {
        var cache = DNSResolutionCache()
        cache.observe([
            observation("", "192.0.2.1", ttl: 60),
            observation("invalid.example", "not-an-ip", ttl: 60),
        ], at: time(0))

        #expect(cache.debugSnapshot() == .init(ipAddressCount: 0, candidateCount: 0))
    }

    @Test func resetRemovesAllObservations() {
        var cache = DNSResolutionCache()
        cache.observe([observation("reset.example", "192.0.2.7", ttl: 60)], at: time(0))

        cache.reset()

        #expect(cache.domain(forIPAddress: "192.0.2.7", at: time(1)) == nil)
        #expect(cache.debugSnapshot() == .init(ipAddressCount: 0, candidateCount: 0))
    }

    private func observation(_ domain: String, _ address: String, ttl: UInt32) -> DNSResolutionObservation {
        DNSResolutionObservation(domainName: domain, ipAddress: address, timeToLive: ttl)
    }

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
