//
//  InterfaceSelectionHistoryStoreTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct InterfaceSelectionHistoryStoreTests {
    @Test func startsEmptyAndPersistsRecordedInterfaceInUserDefaults() {
        let defaults = Self.makeUserDefaults()
        let store = InterfaceSelectionHistoryStore(defaults: defaults)

        #expect(store.lastUsedInterfaceIDs.isEmpty)

        let history = store.recordInterfaceUsage("en1")

        #expect(history == ["en1"])
        #expect(store.lastUsedInterfaceIDs == ["en1"])
        #expect(defaults.stringArray(forKey: InterfaceSelectionHistoryStore.storageKey) == ["en1"])
    }

    @Test func promotesDuplicatesAndCapsHistoryAtFiveInterfaces() {
        let defaults = Self.makeUserDefaults()
        let store = InterfaceSelectionHistoryStore(defaults: defaults)

        store.replaceHistory(with: ["en0", "en2", "en3", "en4", "en5", "en6"])

        let history = store.recordInterfaceUsage("en2")

        #expect(history == ["en2", "en0", "en3", "en4", "en5"])
    }

    @Test func trimsEmptyAndDuplicateValuesWhenReplacingHistory() {
        let defaults = Self.makeUserDefaults()
        let store = InterfaceSelectionHistoryStore(defaults: defaults)

        let history = store.replaceHistory(with: [" en0 ", "", "en1", "en0", "   ", "en2"])

        #expect(history == ["en0", "en1", "en2"])
        #expect(defaults.stringArray(forKey: InterfaceSelectionHistoryStore.storageKey) == history)
    }

    @Test func appConfigurationExposesUserDefaultsBackedInterfaceHistory() {
        let defaults = Self.makeUserDefaults()
        let configuration = AppConfiguration(defaults: defaults)

        configuration.interfaceSelectionHistory.recordInterfaceUsage("en1")

        let reloadedConfiguration = AppConfiguration(defaults: defaults)
        #expect(reloadedConfiguration.interfaceSelectionHistory.lastUsedInterfaceIDs == ["en1"])
    }

    @Test func appConfigurationResetClearsInterfaceHistory() {
        let defaults = Self.makeUserDefaults()
        let configuration = AppConfiguration(defaults: defaults)
        configuration.interfaceSelectionHistory.recordInterfaceUsage("en1")

        configuration.resetToDefaults()

        #expect(configuration.interfaceSelectionHistory.lastUsedInterfaceIDs.isEmpty)
        #expect(defaults.stringArray(forKey: InterfaceSelectionHistoryStore.storageKey) == nil)
    }

    private static func makeUserDefaults() -> UserDefaults {
        let suiteName = "InterfaceSelectionHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
