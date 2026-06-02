//
//  PacketCustomFilterServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/6/26.
//

import Foundation
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct PacketCustomFilterServiceTests {
    @Test func missingFileLoadsEmptyFilters() {
        let storageURL = temporaryDirectory().appendingPathComponent("CustomFilters.json")
        let service = PacketCustomFilterService(storageURL: storageURL)

        #expect(service.filters().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storageURL.path))
    }

    @Test func savesTrimsReloadsMultipleFiltersAndAllowsDuplicateNames() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("CustomFilters.json")
        let service = PacketCustomFilterService(storageURL: storageURL)
        let firstGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp", isEnabled: true),
                PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "443", isEnabled: false),
            ],
            operator: .or
        )
        let secondGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "GET|POST", isEnabled: true),
            ],
            operator: .and
        )

        let first = try service.save(name: "  API Traffic  ", group: firstGroup, now: Date(timeIntervalSince1970: 10))
        let second = try service.save(name: "API Traffic", group: secondGroup, now: Date(timeIntervalSince1970: 20))

        #expect(first.name == "API Traffic")
        #expect(second.name == "API Traffic")
        #expect(first.id != second.id)

        let reloaded = PacketCustomFilterService(storageURL: storageURL)
        let filters = reloaded.filters()
        #expect(filters.map(\.name) == ["API Traffic", "API Traffic"])
        #expect(filters[0].group == firstGroup)
        #expect(filters[0].group.operator == .or)
        #expect(filters[0].group.filters[1].isEnabled == false)
        #expect(filters[0].group.filters[1].text == "443")
        #expect(filters[1].group == secondGroup)
    }

    @Test func rejectsEmptyAndTooLongNames() throws {
        let service = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))

        expectValidationError(.emptyName) {
            _ = try service.save(name: "   ", group: .default)
        }

        expectValidationError(.nameTooLong(maxLength: PacketCustomFilterService.maxNameLength)) {
            _ = try service.save(name: String(repeating: "a", count: PacketCustomFilterService.maxNameLength + 1), group: .default)
        }

        #expect(service.filters().isEmpty)
    }

    @Test func failedSaveDoesNotKeepUnsavedFilterInMemory() throws {
        let blockedParentURL = temporaryDirectory().appendingPathComponent("BlockedParent")
        try "not a directory".write(to: blockedParentURL, atomically: true, encoding: .utf8)
        let service = PacketCustomFilterService(storageURL: blockedParentURL.appendingPathComponent("CustomFilters.json"))

        do {
            _ = try service.save(name: "Unsaved", group: .default)
            Issue.record("Expected save to fail when the storage parent is a file.")
        } catch {
            #expect(service.filters().isEmpty)
        }
    }

    @Test func renameAndDeletePersistChanges() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("CustomFilters.json")
        let service = PacketCustomFilterService(storageURL: storageURL)
        let saved = try service.save(
            name: "Original",
            group: PacketStructuredFilterGroup(filters: [PacketStructuredFilter(query: .client, text: "Safari")]),
            now: Date(timeIntervalSince1970: 10)
        )

        try service.rename(id: saved.id, name: "  Renamed  ", now: Date(timeIntervalSince1970: 30))

        let renamed = try #require(PacketCustomFilterService(storageURL: storageURL).filter(id: saved.id))
        #expect(renamed.name == "Renamed")
        #expect(renamed.createdAt == Date(timeIntervalSince1970: 10))
        #expect(renamed.updatedAt == Date(timeIntervalSince1970: 30))
        #expect(renamed.group == saved.group)

        try service.delete(id: saved.id)
        #expect(PacketCustomFilterService(storageURL: storageURL).filters().isEmpty)
    }

    @Test func updateGroupKeepsNameAndIdentityButPersistsNewPayload() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("CustomFilters.json")
        let service = PacketCustomFilterService(storageURL: storageURL)
        let originalGroup = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .client, condition: .contains, text: "Safari")],
            operator: .and
        )
        let replacementGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "udp", isEnabled: true),
                PacketStructuredFilter(query: .summary, condition: .notContains, text: "DNS", isEnabled: false),
            ],
            operator: .or
        )
        let saved = try service.save(name: "Traffic", group: originalGroup, now: Date(timeIntervalSince1970: 10))

        try service.updateGroup(id: saved.id, group: replacementGroup, now: Date(timeIntervalSince1970: 40))

        let updated = try #require(PacketCustomFilterService(storageURL: storageURL).filter(id: saved.id))
        #expect(updated.id == saved.id)
        #expect(updated.name == "Traffic")
        #expect(updated.createdAt == Date(timeIntervalSince1970: 10))
        #expect(updated.updatedAt == Date(timeIntervalSince1970: 40))
        #expect(updated.group == replacementGroup)
    }

    @Test func duplicatePersistsCopyNextToSourceWithSameNameAndGroup() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("CustomFilters.json")
        let service = PacketCustomFilterService(storageURL: storageURL)
        let firstGroup = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp")],
            operator: .and
        )
        let secondGroup = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "GET|POST")],
            operator: .or
        )
        let first = try service.save(name: "Traffic", group: firstGroup, now: Date(timeIntervalSince1970: 10))
        let second = try service.save(name: "Methods", group: secondGroup, now: Date(timeIntervalSince1970: 20))

        let duplicated = try #require(try service.duplicate(id: first.id, now: Date(timeIntervalSince1970: 30)))

        #expect(duplicated.id != first.id)
        #expect(duplicated.name == first.name)
        #expect(duplicated.group == first.group)
        #expect(duplicated.createdAt == Date(timeIntervalSince1970: 30))
        #expect(duplicated.updatedAt == Date(timeIntervalSince1970: 30))

        let reloadedFilters = PacketCustomFilterService(storageURL: storageURL).filters()
        #expect(reloadedFilters.map(\.id) == [first.id, duplicated.id, second.id])
        #expect(reloadedFilters.map(\.name) == ["Traffic", "Traffic", "Methods"])
    }

    private func expectValidationError(
        _ expectedError: PacketCustomFilterValidationError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected validation error \(expectedError).")
        } catch let error as PacketCustomFilterValidationError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Expected validation error \(expectedError), got \(error).")
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
