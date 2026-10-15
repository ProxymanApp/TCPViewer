//
//  CaptureOverviewCardLayoutStoreTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Foundation
import Testing
@testable import TCPViewer

// macOS keeps a suite's plist even after removePersistentDomain, so every test reuses one fixed suite,
// cleared before it runs, instead of leaving a new file behind per test.
@Suite(.serialized)
struct CaptureOverviewCardLayoutStoreTests {
    private static let suiteName = "com.proxyman.tcpviewer.tests.CaptureOverviewCardLayoutStore"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    @Test func newOverviewShowsTheDefaultCardsAndHidesTheRest() {
        let store = CaptureOverviewCardLayoutStore(defaults: defaults)

        #expect(store.cards == CaptureOverviewCard.defaults)
        #expect(!store.cards.contains(.conversations))
        #expect(!store.cards.contains(.services))
        #expect(!store.cards.contains(.packetLengths))
    }

    @Test func showingAppendsAndHidingRemoves() {
        let store = CaptureOverviewCardLayoutStore(defaults: defaults)

        store.setVisible(.protocols, false)
        store.setVisible(.packetLengths, true)
        let cards = store.setVisible(.protocols, true)

        #expect(cards == [.packets, .throughput, .topApps, .topDestinations, .tcpAnalysis, .packetLengths, .protocols])
        #expect(CaptureOverviewCardLayoutStore(defaults: defaults).cards == cards)
    }

    @Test func aStaleWindowRepeatingAChangeCannotInvertIt() {
        let firstWindow = CaptureOverviewCardLayoutStore(defaults: defaults)
        let staleWindow = CaptureOverviewCardLayoutStore(defaults: defaults)

        firstWindow.setVisible(.protocols, false)
        // The stale window still shows Protocols checked, so its click asks to hide it again.
        let cards = staleWindow.setVisible(.protocols, false)

        #expect(!cards.contains(.protocols))
        #expect(firstWindow.cards == cards)
    }

    @Test func hidingEveryCardIsKeptAndRestoreDefaultsBringsThemBack() {
        let store = CaptureOverviewCardLayoutStore(defaults: defaults)
        for card in CaptureOverviewCard.defaults {
            store.setVisible(card, false)
        }
        #expect(store.cards.isEmpty)

        store.restoreDefaults()
        #expect(store.cards == CaptureOverviewCard.defaults)
    }

    @Test func unknownAndDuplicateStoredNamesAreSkipped() {
        defaults.set(["services", "futureCard", "packets", "services"], forKey: CaptureOverviewCardLayoutStore.storageKey)

        #expect(CaptureOverviewCardLayoutStore(defaults: defaults).cards == [.services, .packets])
    }
}
