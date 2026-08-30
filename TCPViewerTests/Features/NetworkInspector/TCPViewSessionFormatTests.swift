//
//  TCPViewSessionFormatTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/6/26.
//

import AppKit
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
            filterMode: .wireshark,
            wiresharkExpression: "tls.handshake.extensions_server_name == \"example.com\"",
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
        #expect(decoded.filterMode == .wireshark)
        #expect(decoded.wiresharkExpression == "tls.handshake.extensions_server_name == \"example.com\"")
    }

    @Test func legacySessionWithoutWiresharkFieldsDecodesWithBuilderCompatibleDefaults() throws {
        let state = Self.makeSnapshot(packets: []).state
        var object = try #require(JSONSerialization.jsonObject(with: Self.encode(state)) as? [String: Any])
        object.removeValue(forKey: "filterMode")
        object.removeValue(forKey: "wiresharkExpression")

        let decoded = try Self.decode(
            TCPViewSessionState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.filterMode == nil)
        #expect(decoded.wiresharkExpression == nil)
    }

    @Test func annotationsRoundTripReservedCommentAndColorFields() throws {
        let annotations = TCPViewSessionAnnotations(annotations: [
            TCPViewSessionPacketAnnotation(
                packetID: 9,
                packetComment: "pcapng comment",
                customComment: "custom comment",
                colorHex: "#5E5CE6",
                textStyle: PacketTextStyle(highlightColor: .indigo, isStrikethrough: true)
            ),
        ])

        let decoded = try Self.decode(TCPViewSessionAnnotations.self, from: Self.encode(annotations))

        #expect(decoded == annotations)
    }

    @Test func packetSummaryWithoutTextStyleFieldDecodesAsPlainForOlderSessions() throws {
        let packet = Self.makePacket(id: 8, packetNumber: 8, client: nil)
        var object = try #require(JSONSerialization.jsonObject(with: Self.encode(packet)) as? [String: Any])
        object.removeValue(forKey: "textStyle")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try Self.decode(PacketSummary.self, from: legacyData)

        #expect(decoded.resolvedTextStyle == .plain)
        #expect(decoded.textStyle == nil)
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
        let firstStyle = PacketTextStyle(highlightColor: .teal, isStrikethrough: true)
        let packets = [
            Self.makePacket(id: 10, packetNumber: 1, client: Self.client, packetComment: "first comment")
                .applying(textStyle: firstStyle)
                .applying(customComment: "TCP Viewer note\nSecond line"),
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
        #expect(contents.annotations.annotations.first?.customComment == "TCP Viewer note\nSecond line")
        #expect(contents.annotations.annotations.first?.colorHex == "#40C8E0")
        #expect(contents.annotations.annotations.first?.textStyle == firstStyle)
        #expect(contents.packets.map(\.resolvedTextStyle) == [firstStyle, .plain])
        #expect(contents.packets.first?.customComment == "TCP Viewer note\nSecond line")
        #expect(contents.state.importedCaptureFiles.first?.displayName == "source.pcapng")
        #expect(jsonl.split(separator: "\n").count == packets.count)
        #expect(Self.zipPackageContainsRequiredFiles(contents.packageDirectoryURL))
        #expect(progressValues == progressValues.sorted())
    }

    @Test func exportWritesCellSizedClientIcons() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let captureURL = directory.appendingPathComponent("capture-source.pcapng")
        try Data("pcapng-placeholder".utf8).write(to: captureURL)
        let destinationURL = directory.appendingPathComponent("icons.tcpviewsession")
        let client = PacketClient(
            pid: 1234,
            name: "ls",
            displayName: "ls",
            executablePath: "/bin/ls"
        )
        let packet = Self.makePacket(id: 20, packetNumber: 1, client: client)
        let exportService = TCPViewSessionExportService(now: { Self.fixedDate })

        try exportService.writePackage(
            snapshot: Self.makeSnapshot(packets: [packet]),
            captureFileURL: captureURL,
            to: destinationURL,
            progress: nil,
            shouldCancel: nil
        )

        let contents = try TCPViewSessionImportService().loadPackage(at: destinationURL)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }
        let clientID = TCPViewSessionClientStoreBuilder.stableClientID(for: client)
        let iconPath = try #require(contents.clientIconFilePathByClientID[clientID])
        let iconData = try Data(contentsOf: URL(fileURLWithPath: iconPath))
        let iconRep = try #require(NSBitmapImageRep(data: iconData))

        #expect(iconRep.pixelsWide == 128)
        #expect(iconRep.pixelsHigh == 128)
        #expect(iconData.count < 200_000)
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

    @Test func importDeduplicatesClientStoreWithoutDroppingValidFlows() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let packet = Self.makePacket(id: 1, packetNumber: 1, client: Self.client)
        let clientID = TCPViewSessionClientStoreBuilder.stableClientID(for: Self.client)
        let sessionURL = try Self.writeSessionPackage(
            in: directory,
            packetRecords: [
                TCPViewSessionPacketRecord(
                    packetID: packet.id,
                    captureOrdinal: 0,
                    clientID: clientID,
                    packet: packet.tcpviewSessionPacketWithoutClient()
                ),
            ],
            clients: TCPViewSessionClientStore(clients: [
                TCPViewSessionClientRecord(id: clientID, client: Self.client, iconID: nil),
                TCPViewSessionClientRecord(id: clientID, client: Self.client, iconID: nil),
            ]),
            state: Self.makeSnapshot(packets: [packet]).state
        )

        let contents = try TCPViewSessionImportService().loadPackage(at: sessionURL)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }

        #expect(contents.clientStore.clients.count == 1)
        #expect(contents.packets.map(\.id) == [packet.id])
        #expect(contents.packets.first?.client == Self.client)
        #expect(contents.importReport == TCPViewSessionImportReport(importedFlowCount: 1, failedFlowCount: 0))
    }

    @Test func importSkipsMalformedPacketRowsAndReportsFailures() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstPacket = Self.makePacket(id: 1, packetNumber: 1, client: nil)
        let secondPacket = Self.makePacket(id: 2, packetNumber: 2, client: nil)
        let thirdPacket = Self.makePacket(id: 3, packetNumber: 3, client: nil)
        let sessionURL = try Self.writeSessionPackage(
            in: directory,
            packetRecords: [
                TCPViewSessionPacketRecord(packetID: firstPacket.id, captureOrdinal: 0, clientID: nil, packet: firstPacket),
                TCPViewSessionPacketRecord(packetID: secondPacket.id, captureOrdinal: 0, clientID: nil, packet: secondPacket),
                TCPViewSessionPacketRecord(packetID: 99, captureOrdinal: 1, clientID: nil, packet: firstPacket),
                TCPViewSessionPacketRecord(packetID: thirdPacket.id, captureOrdinal: 4, clientID: nil, packet: thirdPacket),
            ],
            clients: TCPViewSessionClientStore(clients: []),
            state: Self.makeSnapshot(packets: [firstPacket, secondPacket, thirdPacket]).state,
            additionalPacketSidecarLines: [Data("{bad-json}".utf8)]
        )

        let contents = try TCPViewSessionImportService().loadPackage(at: sessionURL)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }

        #expect(contents.packetRecords.map(\.packetID) == [firstPacket.id])
        #expect(contents.packets.map(\.id) == [firstPacket.id])
        #expect(contents.importReport == TCPViewSessionImportReport(importedFlowCount: 1, failedFlowCount: 4))
    }

    @Test func importSanitizesStateReferencesForSkippedFlows() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let importedPacket = Self.makePacket(id: 1, packetNumber: 1, client: nil)
        let skippedPacket = Self.makePacket(id: 2, packetNumber: 2, client: nil)
        let fileID = ImportedCaptureFileID(rawValue: "file-a")
        let importedFile = ImportedCaptureFile(
            id: fileID,
            url: URL(fileURLWithPath: "/tmp/source-a.pcapng"),
            displayName: "source-a.pcapng",
            packetIDs: [importedPacket.id, skippedPacket.id]
        )
        let state = Self.makeState(
            packets: [importedPacket, skippedPacket],
            importedFiles: [importedFile],
            importedPacketReferences: [
                TCPViewSessionImportedPacketReferenceRecord(
                    packetID: importedPacket.id,
                    reference: ImportedPacketReference(fileID: fileID, originalPacketID: 1)
                ),
                TCPViewSessionImportedPacketReferenceRecord(
                    packetID: skippedPacket.id,
                    reference: ImportedPacketReference(fileID: fileID, originalPacketID: 2)
                ),
            ],
            savedPackets: [
                SavedPacketRecord(id: "saved-imported", savedAt: Self.fixedDate, backingIdentity: "backing-a", packet: importedPacket),
                SavedPacketRecord(id: "saved-skipped", savedAt: Self.fixedDate, backingIdentity: "backing-a", packet: skippedPacket),
            ],
            selectedPacketID: skippedPacket.id
        )
        let sessionURL = try Self.writeSessionPackage(
            in: directory,
            packetRecords: [
                TCPViewSessionPacketRecord(packetID: importedPacket.id, captureOrdinal: 0, clientID: nil, packet: importedPacket),
                TCPViewSessionPacketRecord(packetID: skippedPacket.id, captureOrdinal: 0, clientID: nil, packet: skippedPacket),
            ],
            clients: TCPViewSessionClientStore(clients: []),
            state: state
        )

        let contents = try TCPViewSessionImportService().loadPackage(at: sessionURL)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }

        #expect(contents.packets.map(\.id) == [importedPacket.id])
        #expect(contents.state.importedFiles.first?.packetIDs == [importedPacket.id])
        #expect(contents.state.importedPacketReferences.map(\.packetID) == [importedPacket.id])
        #expect(contents.state.savedPackets.map(\.packet.id) == [importedPacket.id])
        #expect(contents.state.selectedPacketID == nil)
        #expect(contents.importReport == TCPViewSessionImportReport(importedFlowCount: 1, failedFlowCount: 1))
    }

    @Test func importedClientIconsFeedDocumentLocalTableAndSourceListModels() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let packet = Self.makePacket(id: 1, packetNumber: 1, client: Self.client)
        let clientID = TCPViewSessionClientStoreBuilder.stableClientID(for: Self.client)
        let iconID = TCPViewSessionClientStoreBuilder.stableIconID(for: "/Applications/Sample.app")
        let sessionURL = try Self.writeSessionPackage(
            in: directory,
            packetRecords: [
                TCPViewSessionPacketRecord(
                    packetID: packet.id,
                    captureOrdinal: 0,
                    clientID: clientID,
                    packet: packet.tcpviewSessionPacketWithoutClient()
                ),
            ],
            clients: TCPViewSessionClientStore(clients: [
                TCPViewSessionClientRecord(id: clientID, client: Self.client, iconID: iconID),
            ]),
            state: Self.makeSnapshot(packets: [packet]).state,
            icons: [iconID: Data([0x89, 0x50, 0x4E, 0x47])]
        )

        let contents = try TCPViewSessionImportService().loadPackage(at: sessionURL)
        defer { try? FileManager.default.removeItem(at: contents.extractionDirectoryURL) }
        var ingestState = PacketIngestState.empty
        ingestState.replaceSession(
            with: contents.packets,
            importedFiles: [],
            importedPacketReferenceByID: [:],
            clientIconFilePathByClientID: contents.clientIconFilePathByClientID,
            source: .offline
        )
        let importedIconPath = contents.clientIconFilePathByClientID[clientID]
        let tableRow = PacketTableRow(
            packet: contents.packets[0],
            previousVisiblePacketTimestamp: nil,
            previousVisibleStreamPacketTimestamp: nil,
            clientIconFilePath: ingestState.tcpviewSessionClientIconFilePath(for: contents.packets[0].client)
        )
        let sourceListSnapshot = PacketSourceListService().snapshot(for: ingestState)
        let appItem = sourceListSnapshot.firstItem { item in
            item.kind == .app && item.title == Self.client.displayName
        }

        #expect(importedIconPath != nil)
        #expect(tableRow.clientIconFilePath == importedIconPath)
        #expect(appItem?.iconFilePath == importedIconPath)
    }

    @Test func offlineSessionDocumentMapsPacketsByCaptureOrdinalAfterSkippedRows() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionPacket = Self.makePacket(id: 1, packetNumber: 1, client: nil)
        let innerFirstPacket = Self.makePacket(id: 100, packetNumber: 100, client: nil)
        let innerSecondPacket = Self.makePacket(id: 101, packetNumber: 101, client: nil)
        let record = TCPViewSessionPacketRecord(
            packetID: sessionPacket.id,
            captureOrdinal: 1,
            clientID: nil,
            packet: sessionPacket
        )
        let contents = TCPViewSessionPackageContents(
            sourceURL: directory.appendingPathComponent("sample.tcpviewsession"),
            extractionDirectoryURL: directory,
            packageDirectoryURL: directory.appendingPathComponent(TCPViewSessionFormat.packageDirectoryName, isDirectory: true),
            captureFileURL: directory.appendingPathComponent(TCPViewSessionFormat.capturePath),
            manifest: TCPViewSessionManifest(
                createdAt: Self.fixedDate,
                applicationName: "TCPViewer",
                applicationVersion: "1.0",
                applicationBuild: "1",
                packetCount: 2
            ),
            packetRecords: [record],
            clientStore: TCPViewSessionClientStore(clients: []),
            annotations: TCPViewSessionAnnotations(annotations: []),
            state: Self.makeSnapshot(packets: [sessionPacket]).state,
            packets: [sessionPacket],
            clientIconFilePathByClientID: [:],
            importReport: TCPViewSessionImportReport(importedFlowCount: 1, failedFlowCount: 1)
        )
        let innerDocument = SessionImportFakeOfflineDocument(
            url: contents.captureFileURL,
            packets: [innerFirstPacket, innerSecondPacket],
            inspections: [
                innerSecondPacket.id: Self.makeInspection(for: innerSecondPacket),
            ]
        )
        let document = TCPViewSessionOfflineDocument(
            contents: contents,
            core: SessionImportFakeCore(document: innerDocument)
        )
        let exportURL = directory.appendingPathComponent("export.pcapng")

        let openedPackets = try Self.waitForResult { completion in
            document.open(completion: completion)
        }
        let inspection = try Self.waitForResult { completion in
            document.inspectPacket(id: sessionPacket.id, completion: completion)
        }
        try Self.waitForVoid { completion in
            document.exportPackets(withIDs: [sessionPacket.id], to: exportURL, format: .pcapng, completion: completion)
        }

        #expect(openedPackets.map(\.id) == [sessionPacket.id])
        #expect(document.packetSummaries().map(\.id) == [sessionPacket.id])
        #expect(inspection.packetID == sessionPacket.id)
        #expect(inspection.rawBytes == Data(repeating: UInt8(innerSecondPacket.packetNumber), count: 64))
        #expect(innerDocument.exportRequests.first?.0 == [innerSecondPacket.id])
        #expect(document.importReport == TCPViewSessionImportReport(importedFlowCount: 1, failedFlowCount: 1))
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
        filterMode: PacketFilterMode? = nil,
        wiresharkExpression: String? = nil,
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
            filterMode: filterMode,
            wiresharkExpression: wiresharkExpression,
            tableColumnLayout: tableColumnLayout,
            sourceMetadata: TCPViewSessionSourceMetadata(
                fileName: "source.pcapng",
                filePath: "/tmp/source.pcapng",
                format: "pcapng",
                packetCount: packets.count
            )
        )
    }

    private static func makeState(
        packets: [PacketSummary],
        importedFiles: [ImportedCaptureFile],
        importedPacketReferences: [TCPViewSessionImportedPacketReferenceRecord],
        savedPackets: [SavedPacketRecord] = [],
        selectedPacketID: PacketSummary.ID? = nil
    ) -> TCPViewSessionState {
        TCPViewSessionState(
            source: CaptureSource.offline.rawValue,
            backingIdentity: "backing-a",
            importedFiles: importedFiles.map(TCPViewSessionImportedFileRecord.init),
            importedPacketReferences: importedPacketReferences,
            pins: [],
            savedPackets: savedPackets,
            customFilters: [],
            quickFilterSelection: .all,
            structuredFilterGroup: .default,
            displayFilterText: "",
            sourceListFilterText: "",
            selectedPacketID: selectedPacketID,
            selectedSourceListSelection: TCPViewSessionSourceListSelectionRecord(selection: .allPackets),
            workspaceMode: NetworkInspectorWorkspaceMode.packets.rawValue,
            inspectorTab: PacketInspectorTab.summary.rawValue,
            inspectorPlacement: NetworkInspectorPlacement.trailing.rawValue,
            isInspectorVisible: true,
            isStructuredFilterVisible: false,
            tableColumnLayout: nil,
            importedFileProvenance: importedFiles.isEmpty ? nil : "Imported capture grouping is preserved for TCPViewer source-list reconstruction.",
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

    private static func makeInspection(for packet: PacketSummary) -> PacketInspection {
        PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: UInt8(packet.packetNumber), count: 64),
            detailNodes: [
                PacketDetailNode(
                    id: "frame",
                    name: "Frame",
                    value: "Packet \(packet.packetNumber)",
                    kind: .layer
                ),
            ],
            decodeStatus: packet.decodeStatus
        )
    }

    private static func waitForResult<Value>(
        _ body: (@escaping TCPViewerCompletion<Value>) -> Void
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedResult: Result<Value, Error>?
        body { result in
            capturedResult = result
            semaphore.signal()
        }
        semaphore.wait()
        return try capturedResult!.get()
    }

    private static func waitForVoid(
        _ body: (@escaping TCPViewerVoidCompletion) -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedResult: Result<Void, Error>?
        body { result in
            capturedResult = result
            semaphore.signal()
        }
        semaphore.wait()
        try capturedResult!.get()
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

    private static func writeSessionPackage(
        in directory: URL,
        packetRecords: [TCPViewSessionPacketRecord],
        clients: TCPViewSessionClientStore,
        state: TCPViewSessionState,
        annotations: TCPViewSessionAnnotations = TCPViewSessionAnnotations(annotations: []),
        icons: [String: Data] = [:],
        additionalPacketSidecarLines: [Data] = [],
        manifestPacketCount: Int? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packageURL = directory.appendingPathComponent(TCPViewSessionFormat.packageDirectoryName, isDirectory: true)
        let iconsURL = packageURL.appendingPathComponent(TCPViewSessionFormat.iconsDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)
        try Data("pcapng-placeholder".utf8).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.capturePath))

        var packetSidecarData = Data()
        for record in packetRecords {
            packetSidecarData.append(try Self.encode(record))
            packetSidecarData.append(0x0A)
        }
        for line in additionalPacketSidecarLines {
            packetSidecarData.append(line)
            packetSidecarData.append(0x0A)
        }
        try packetSidecarData.write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.packetsPath))
        try Self.encode(clients).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.clientsPath))
        try Self.encode(annotations).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.annotationsPath))
        try Self.encode(state).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.statePath))
        try Self.encode(TCPViewSessionManifest(
            createdAt: fixedDate,
            applicationName: "TCPViewer",
            applicationVersion: "1.0",
            applicationBuild: "1",
            packetCount: manifestPacketCount ?? packetRecords.count
        )).write(to: packageURL.appendingPathComponent(TCPViewSessionFormat.manifestPath))
        for (iconID, data) in icons {
            try data.write(to: iconsURL.appendingPathComponent("\(iconID).png"))
        }

        let sessionURL = directory.appendingPathComponent("sample-\(UUID().uuidString).tcpviewsession")
        try Self.zipKeepingParent(packageURL, to: sessionURL)
        return sessionURL
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

private final class SessionImportFakeCore: TCPViewerCoreProviding, @unchecked Sendable {
    private let document: any OfflineCaptureDocumentProviding

    init(document: any OfflineCaptureDocumentProviding) {
        self.document = document
    }

    func listInterfaces(completion: @escaping TCPViewerCompletion<[CaptureInterfaceSummary]>) {
        completion(.success([]))
    }

    func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void) {
        completion(CaptureFilterValidation(disposition: .valid, normalizedExpression: expression))
    }

    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        options
    }

    func makeLiveCaptureSession(
        interfaceID: String,
        options: CaptureOptions,
        completion: @escaping TCPViewerCompletion<any LiveCaptureSessionProviding>
    ) {
        completion(.failure(TCPViewerCoreError(code: .integrationMisconfigured, message: "Live capture is not used by this test.")))
    }

    func supportedOfflineFormats() -> [CaptureFileFormat] {
        CaptureFileFormat.allCases
    }

    func openOfflineCaptureDocument(
        at fileURL: URL,
        completion: @escaping TCPViewerCompletion<any OfflineCaptureDocumentProviding>
    ) {
        completion(.success(document))
    }

    func loadPacketSummaries(from fileURL: URL, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        completion(.success(document.packetSummaries()))
    }
}

private final class SessionImportFakeOfflineDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    var eventHandler: PacketIngestEventHandler?

    private let url: URL
    private let packets: [PacketSummary]
    private let inspections: [PacketSummary.ID: PacketInspection]
    private(set) var exportRequests: [([PacketSummary.ID], URL, CaptureFileFormat)] = []

    init(
        url: URL,
        packets: [PacketSummary],
        inspections: [PacketSummary.ID: PacketInspection]
    ) {
        self.url = url
        self.packets = packets
        self.inspections = inspections
    }

    func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        completion(.success(packets))
    }

    func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        completion(.success(packets))
    }

    func cancelLoading(completion: (() -> Void)?) {
        completion?()
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        guard let inspection = inspections[id] else {
            completion(.failure(TCPViewerCoreError(code: .offlineFileOpenFailed, message: "Missing test inspection.")))
            return
        }

        completion(.success(inspection))
    }

    func save(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        exportRequests.append((identifiers, url, format))
        progress?(PacketExportProgress(exportedPacketCount: identifiers.count, totalPacketCount: identifiers.count))
        completion(.success(()))
    }

    func currentURL() -> URL {
        url
    }

    func currentMetadata() -> CaptureDocumentMetadata {
        CaptureDocumentMetadata(format: .pcapng, captureApplication: "TCPViewerTests")
    }

    func packetSummaries() -> [PacketSummary] {
        packets
    }

    func loadProgress() -> PacketLoadProgress {
        PacketLoadProgress(phase: .completed, loadedPacketCount: packets.count, message: "Loaded test packets.")
    }
}
