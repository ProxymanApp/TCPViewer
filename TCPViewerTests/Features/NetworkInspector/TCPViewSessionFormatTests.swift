//
//  TCPViewSessionFormatTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/6/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

@Suite(.serialized)
struct TCPViewSessionFormatTests {

    @Test func sessionStateRoundTripsDocumentLocalData() throws {
        let packet = Self.makePacket(
            id: 42,
            packetNumber: 7,
            client: Self.client,
            packetComment: "packet note"
        )
        let fileID = ImportedCaptureFileID(rawValue: "file-a")
        let importedFile = ImportedCaptureFile(
            id: fileID,
            url: URL(fileURLWithPath: "/tmp/source-a.pcapng"),
            displayName: "source-a.pcapng",
            packetIDs: [packet.id]
        )
        let structuredGroup = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(
                    id: "structured-row",
                    query: .urlDomain,
                    condition: .contains,
                    text: "example.com",
                    isEnabled: true
                ),
            ],
            operator: .or
        )
        let pin = PacketPin(
            id: PacketPinID(rawValue: "domain:example.com"),
            kind: .domain,
            title: "example.com",
            createdAt: Self.fixedDate,
            domain: "example.com",
            ipAddress: nil,
            clientKey: nil,
            clientDisplayName: nil,
            clientIconFilePath: nil
        )
        let savedRecord = SavedPacketRecord(
            id: "saved-1",
            savedAt: Self.fixedDate,
            backingIdentity: "backing-a",
            packet: packet
        )
        let customFilter = PacketCustomFilter(
            id: "custom-1",
            name: "Example",
            createdAt: Self.fixedDate,
            updatedAt: Self.fixedDate,
            group: structuredGroup
        )
        let layout = PacketTableColumnLayout(columns: [
            PacketTableColumnLayout.Column(identifier: "protocol", isVisible: true, width: 120),
            PacketTableColumnLayout.Column(identifier: "length", isVisible: false, width: 72),
        ])
        let selectedSource = PacketSourceListSelection.fileAppDomain(
            fileID,
            PacketSourceClientKey(rawValue: "client-key"),
            PacketSourceDomainKey(rawValue: "example.com", isMissingDomain: false)
        )
        let snapshot = Self.makeSnapshot(
            packets: [packet],
            importedFiles: [importedFile],
            importedPacketReferenceByID: [
                packet.id: ImportedPacketReference(fileID: fileID, originalPacketID: 1),
            ],
            pins: [pin],
            savedPackets: [savedRecord],
            customFilters: [customFilter],
            quickFilterSelection: PacketQuickFilterSelection(selectedIDs: [.tcp, .dns]),
            structuredFilterGroup: structuredGroup,
            selectedPacketID: packet.id,
            selectedSourceListSelection: selectedSource,
            tableColumnLayout: layout
        )

        let decoded = try Self.decode(TCPViewSessionState.self, from: Self.encode(snapshot.state))

        #expect(decoded == snapshot.state)
        #expect(decoded.importedCaptureFiles == [importedFile])
        #expect(decoded.importedPacketReferenceByID[packet.id]?.originalPacketID == 1)
        #expect(decoded.selectedSourceListSelection?.selection() == selectedSource)
        #expect(decoded.importedFileProvenance != nil)
    }

    @Test func annotationsRoundTripReservedCommentAndColorFields() throws {
        let annotations = TCPViewSessionAnnotations(annotations: [
            TCPViewSessionPacketAnnotation(
                packetID: 9,
                packetComment: "pcapng comment",
                customComment: "custom comment",
                colorHex: "#4A90E2"
            ),
        ])

        let decoded = try Self.decode(TCPViewSessionAnnotations.self, from: Self.encode(annotations))

        #expect(decoded == annotations)
    }

    @Test func clientStoreDeduplicatesTwentyThousandPacketsAndRestoresClients() {
        let packets = (1...20_000).map {
            Self.makePacket(id: UInt64($0), packetNumber: UInt64($0), client: Self.client)
        }
        let iconID = TCPViewSessionClientStoreBuilder.stableIconID(for: "/bin/ls")

        let result = TCPViewSessionClientStoreBuilder.buildClientStore(
            packets: packets,
            iconIDForClient: { _ in iconID }
        )
        let restoredPackets = TCPViewSessionClientStoreBuilder.rehydratePackets(
            records: result.records,
            clients: result.clients
        )

        #expect(result.records.count == 20_000)
        #expect(result.clients.clients.count == 1)
        #expect(result.clients.clients.first?.iconID == iconID)
        #expect(result.records.allSatisfy { $0.clientID == result.clients.clients.first?.id })
        #expect(result.records.allSatisfy { $0.packet.client == nil })
        #expect(restoredPackets.count == packets.count)
        #expect(restoredPackets[12_345].client == Self.client)
    }

    @Test func exportWritesInspectablePackageAndImportRestoresSidecars() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("capture-source.pcapng")
        try Data("pcapng-placeholder".utf8).write(to: captureURL)
        let destinationURL = directory.appendingPathComponent("sample.tcpviewsession")
        let packets = [
            Self.makePacket(id: 10, packetNumber: 1, client: Self.client, packetComment: "first comment"),
            Self.makePacket(id: 11, packetNumber: 2, client: Self.client),
        ]
        let snapshot = Self.makeSnapshot(
            packets: packets,
            importedFiles: [
                ImportedCaptureFile(
                    id: ImportedCaptureFileID(rawValue: "source"),
                    url: URL(fileURLWithPath: "/tmp/source.pcapng"),
                    displayName: "source.pcapng",
                    packetIDs: packets.map(\.id)
                ),
            ],
            importedPacketReferenceByID: [
                10: ImportedPacketReference(fileID: ImportedCaptureFileID(rawValue: "source"), originalPacketID: 1),
                11: ImportedPacketReference(fileID: ImportedCaptureFileID(rawValue: "source"), originalPacketID: 2),
            ]
        )
        var progressValues: [Double] = []
        let exportService = TCPViewSessionExportService(now: { Self.fixedDate })

        try exportService.writePackage(
            snapshot: snapshot,
            captureFileURL: captureURL,
            to: destinationURL,
            progress: { progress in progressValues.append(progress.fractionCompleted) },
            shouldCancel: nil
        )
        let contents = try TCPViewSessionImportService().loadPackage(at: destinationURL)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }
        let packetsSidecarURL = contents.packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.packetsPath)
        let jsonl = try String(contentsOf: packetsSidecarURL, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(contents.manifest.magic == TCPViewSessionFormat.magic)
        #expect(contents.manifest.packetCount == packets.count)
        #expect(contents.packetRecords.map(\.captureOrdinal) == [0, 1])
        #expect(contents.clientStore.clients.count == 1)
        #expect(contents.packets.map(\.client) == [Self.client, Self.client])
        #expect(contents.annotations.annotations.first?.packetComment == "first comment")
        #expect(contents.state.importedCaptureFiles.first?.displayName == "source.pcapng")
        #expect(jsonl.split(separator: "\n").count == packets.count)
        #expect(Self.zipPackageContainsRequiredFiles(contents.packageDirectoryURL))
        #expect(progressValues == progressValues.sorted())
    }

    @Test func cancellationLeavesExistingDestinationUntouched() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("capture-source.pcapng")
        let destinationURL = directory.appendingPathComponent("existing.tcpviewsession")
        let existingData = Data("existing-session".utf8)
        try Data("pcapng-placeholder".utf8).write(to: captureURL)
        try existingData.write(to: destinationURL)
        let snapshot = Self.makeSnapshot(packets: [Self.makePacket(id: 1, packetNumber: 1, client: Self.client)])
        let exportService = TCPViewSessionExportService(now: { Self.fixedDate })
        var checks = 0

        do {
            try exportService.writePackage(
                snapshot: snapshot,
                captureFileURL: captureURL,
                to: destinationURL,
                progress: nil,
                shouldCancel: {
                    checks += 1
                    return checks > 1
                }
            )
            Issue.record("Expected cancellation to throw.")
        } catch let error as TCPViewerCoreError {
            #expect(error.code == .operationCancelled)
        }

        let finalData = try Data(contentsOf: destinationURL)
        #expect(finalData == existingData)
    }

    @Test func importRejectsUnsupportedSchema() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let packageURL = directory.appendingPathComponent(TCPViewSessionFormat.packageDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data("pcapng-placeholder".utf8).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.capturePath))
        try Data().write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.packetsPath))
        try Self.encode(TCPViewSessionClientStore(clients: [])).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.clientsPath))
        try Self.encode(TCPViewSessionAnnotations(annotations: [])).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.annotationsPath))
        try Self.encode(Self.makeSnapshot(packets: []).state).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.statePath))
        var manifest = TCPViewSessionManifest(
            createdAt: Self.fixedDate,
            applicationName: "TCPViewer",
            applicationVersion: "1.0",
            applicationBuild: "1",
            packetCount: 0
        )
        manifest.schemaVersion = TCPViewSessionFormat.schemaVersion + 1
        try Self.encode(manifest).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.manifestPath))

        let sessionURL = directory.appendingPathComponent("unsupported.tcpviewsession")
        try Self.zipKeepingParent(packageURL, to: sessionURL)

        do {
            _ = try TCPViewSessionImportService().loadPackage(at: sessionURL)
            Issue.record("Expected unsupported schema to be rejected.")
        } catch let error as TCPViewerCoreError {
            #expect(error.code == .offlineFileOpenFailed)
            #expect(error.message.contains("unsupported schema"))
        }
    }

    @Test func documentScopedServicesDoNotMutatePersistentStorage() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pinURL = directory.appendingPathComponent("Pins.json")
        let savedURL = directory.appendingPathComponent("Saved.json")
        let filterURL = directory.appendingPathComponent("Filters.json")
        let persistentPacket = Self.makePacket(id: 1, packetNumber: 1, client: nil)
        let documentPacket = Self.makePacket(id: 2, packetNumber: 2, client: Self.client)
        let pinService = PacketPinService(storageURL: pinURL)
        let savedService = SavedPacketService(storageURL: savedURL)
        let filterService = PacketCustomFilterService(storageURL: filterURL)

        try pinService.upsertDomainPin(
            PacketSourceDomainIdentity(
                key: PacketSourceDomainKey(rawValue: "persistent.example", isMissingDomain: false),
                displayName: "persistent.example"
            ),
            now: Self.fixedDate
        )
        try savedService.save([persistentPacket], backingIdentity: "persistent", now: Self.fixedDate)
        try filterService.save(name: "Persistent", group: .default, now: Self.fixedDate)
        let persistentPinsData = try Data(contentsOf: pinURL)
        let persistentSavedData = try Data(contentsOf: savedURL)
        let persistentFiltersData = try Data(contentsOf: filterURL)

        pinService.useDocumentPins([
            PacketPin(
                id: PacketPinID(rawValue: "domain:document.example"),
                kind: .domain,
                title: "document.example",
                createdAt: Self.fixedDate,
                domain: "document.example",
                ipAddress: nil,
                clientKey: nil,
                clientDisplayName: nil,
                clientIconFilePath: nil
            ),
        ])
        savedService.useDocumentRecords([
            SavedPacketRecord(id: "document-saved", savedAt: Self.fixedDate, backingIdentity: "document", packet: documentPacket),
        ])
        filterService.useDocumentFilters([
            PacketCustomFilter(id: "document-filter", name: "Document", createdAt: Self.fixedDate, updatedAt: Self.fixedDate, group: .default),
        ])

        try pinService.upsertDomainPin(
            PacketSourceDomainIdentity(
                key: PacketSourceDomainKey(rawValue: "document-added.example", isMissingDomain: false),
                displayName: "document-added.example"
            ),
            now: Self.fixedDate
        )
        try savedService.save([documentPacket], backingIdentity: "document", now: Self.fixedDate)
        try filterService.save(name: "Document Added", group: .default, now: Self.fixedDate)

        let finalPinsData = try Data(contentsOf: pinURL)
        let finalSavedData = try Data(contentsOf: savedURL)
        let finalFiltersData = try Data(contentsOf: filterURL)
        #expect(finalPinsData == persistentPinsData)
        #expect(finalSavedData == persistentSavedData)
        #expect(finalFiltersData == persistentFiltersData)

        pinService.reloadPersistentPins()
        savedService.reloadPersistentRecords()
        filterService.reloadPersistentFilters()

        #expect(pinService.pins().map(\.title) == ["persistent.example"])
        #expect(savedService.records().map(\.packet.id) == [persistentPacket.id])
        #expect(filterService.filters().map(\.name) == ["Persistent"])
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)

    private static let client = PacketClient(
        pid: 1234,
        name: "Sample",
        displayName: "Sample App",
        executablePath: "/bin/ls",
        bundleIdentifier: "com.example.Sample",
        bundlePath: "/Applications/Sample.app"
    )

    private static func makeSnapshot(
        packets: [PacketSummary],
        importedFiles: [ImportedCaptureFile] = [],
        importedPacketReferenceByID: [PacketSummary.ID: ImportedPacketReference] = [:],
        pins: [PacketPin] = [],
        savedPackets: [SavedPacketRecord] = [],
        customFilters: [PacketCustomFilter] = [],
        quickFilterSelection: PacketQuickFilterSelection = .all,
        structuredFilterGroup: PacketStructuredFilterGroup = .default,
        selectedPacketID: PacketSummary.ID? = nil,
        selectedSourceListSelection: PacketSourceListSelection = .allPackets,
        tableColumnLayout: PacketTableColumnLayout? = nil
    ) -> TCPViewSessionExportSnapshot {
        TCPViewSessionExportSnapshot(
            packets: packets,
            source: .offline,
            backingIdentity: "backing-a",
            importedFiles: importedFiles,
            importedPacketReferenceByID: importedPacketReferenceByID,
            pins: pins,
            savedPackets: savedPackets,
            customFilters: customFilters,
            quickFilterSelection: quickFilterSelection,
            structuredFilterGroup: structuredFilterGroup,
            displayFilterText: "tcp",
            sourceListFilterText: "example",
            selectedPacketID: selectedPacketID,
            selectedSourceListSelection: selectedSourceListSelection,
            workspaceMode: .packets,
            inspectorTab: .detail,
            inspectorPlacement: .bottom,
            isInspectorVisible: true,
            isStructuredFilterVisible: true,
            tableColumnLayout: tableColumnLayout,
            sourceMetadata: TCPViewSessionSourceMetadata(
                fileName: "source.pcapng",
                filePath: "/tmp/source.pcapng",
                format: "pcapng",
                packetCount: packets.count
            )
        )
    }

    private static func makePacket(
        id: UInt64,
        packetNumber: UInt64,
        client: PacketClient?,
        packetComment: String? = nil
    ) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: .offline,
            transportHint: .tcp,
            protocolSummary: "TCP",
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "93.184.216.34", port: 443)
            ),
            originalLength: 128,
            capturedLength: 96,
            streamID: 7,
            direction: .outbound,
            tcpFlags: "SYN",
            tcpPayloadLength: 0,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "IPv4"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false, packetComment: packetComment),
            sniDomainName: "example.com",
            client: client
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewSessionFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func zipPackageContainsRequiredFiles(_ packageURL: URL) -> Bool {
        [
            TCPViewSessionFormat.manifestPath,
            TCPViewSessionFormat.capturePath,
            TCPViewSessionFormat.packetsPath,
            TCPViewSessionFormat.clientsPath,
            TCPViewSessionFormat.annotationsPath,
            TCPViewSessionFormat.statePath,
        ].allSatisfy { FileManager.default.fileExists(atPath: packageURL.appendingPathComponent($0).path) }
    }

    private static func zipKeepingParent(_ packageURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", packageURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
