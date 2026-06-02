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
