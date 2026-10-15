//
//  CaptureOverviewCardLayoutStoreTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct CaptureOverviewCardLayoutStoreTests {
    @Test func newOverviewShowsTheDefaultCardsAndHidesTheRest() {
        let store = CaptureOverviewCardLayoutStore(defaults: makeDefaults())

        #expect(store.cards == CaptureOverviewCard.defaults)
        #expect(!store.cards.contains(.conversations))
        #expect(!store.cards.contains(.services))
        #expect(!store.cards.contains(.packetLengths))
    }

    @Test func showingAppendsAndHidingRemoves() {
        let defaults = makeDefaults()
        let store = CaptureOverviewCardLayoutStore(defaults: defaults)

        store.setVisible(.protocols, false)
        store.setVisible(.packetLengths, true)
        let cards = store.setVisible(.protocols, true)

        #expect(cards == [.packets, .throughput, .topApps, .topDestinations, .tcpAnalysis, .packetLengths, .protocols])
        #expect(CaptureOverviewCardLayoutStore(defaults: defaults).cards == cards)
    }

    @Test func aStaleWindowRepeatingAChangeCannotInvertIt() {
        let defaults = makeDefaults()
        let firstWindow = CaptureOverviewCardLayoutStore(defaults: defaults)
        let staleWindow = CaptureOverviewCardLayoutStore(defaults: defaults)

        firstWindow.setVisible(.protocols, false)
        // The stale window still shows Protocols checked, so its click asks to hide it again.
        let cards = staleWindow.setVisible(.protocols, false)

        #expect(!cards.contains(.protocols))
        #expect(firstWindow.cards == cards)
    }

    @Test func hidingEveryCardIsKeptAndRestoreDefaultsBringsThemBack() {
        let store = CaptureOverviewCardLayoutStore(defaults: makeDefaults())
        for card in CaptureOverviewCard.defaults {
            store.setVisible(card, false)
        }
        #expect(store.cards.isEmpty)

        store.restoreDefaults()
        #expect(store.cards == CaptureOverviewCard.defaults)
    }

    @Test func unknownAndDuplicateStoredNamesAreSkipped() {
        let defaults = makeDefaults()
        defaults.set(["services", "futureCard", "packets", "services"], forKey: CaptureOverviewCardLayoutStore.storageKey)

        #expect(CaptureOverviewCardLayoutStore(defaults: defaults).cards == [.services, .packets])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CaptureOverviewCardLayoutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
