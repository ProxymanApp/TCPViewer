//
//  TCPViewSessionImportService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/6/26.
//

import Foundation
import PcapPlusPlusCore
import ZIPFoundation

struct TCPViewSessionPackageContents {
    let sourceURL: URL
    let extractionDirectoryURL: URL
    let packageDirectoryURL: URL
    let captureFileURL: URL
    let manifest: TCPViewSessionManifest
    let packetRecords: [TCPViewSessionPacketRecord]
    let clientStore: TCPViewSessionClientStore
    let annotations: TCPViewSessionAnnotations
    let state: TCPViewSessionState
    let packets: [PacketSummary]
    let clientIconFilePathByClientID: [String: String]
    let importReport: TCPViewSessionImportReport
}

final class TCPViewSessionImportService {
    private struct PacketRecordDecodeResult {
        let records: [TCPViewSessionPacketRecord]
        let failedLineCount: Int
    }

    private struct SanitizedSidecars {
        let packetRecords: [TCPViewSessionPacketRecord]
        let clientStore: TCPViewSessionClientStore
        let annotations: TCPViewSessionAnnotations
        let state: TCPViewSessionState
        let importReport: TCPViewSessionImportReport
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // Validate ZIP entries before extraction so a malformed package never writes outside temp.
    func loadPackage(at url: URL) throws -> TCPViewSessionPackageContents {
        try validateArchive(at: url)

        let extractionRoot = fileManager.temporaryDirectory
            .appendingPathComponent("TCPViewSessionImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: url, to: extractionRoot)

            let packageDirectoryURL = extractionRoot.appendingPathComponent(TCPViewSessionFormat.packageDirectoryName, isDirectory: true)
            let manifest: TCPViewSessionManifest = try decodeJSON(
                TCPViewSessionManifest.self,
                from: packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.manifestPath)
            )
            try validateManifest(manifest)

            let decodedPacketRecords = try decodePacketRecords(
                from: packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.packetsPath)
            )
            let clients: TCPViewSessionClientStore = try decodeJSON(
                TCPViewSessionClientStore.self,
                from: packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.clientsPath)
            )
            let annotations: TCPViewSessionAnnotations = try decodeJSON(
                TCPViewSessionAnnotations.self,
                from: packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.annotationsPath)
            )
            let state: TCPViewSessionState = try decodeJSON(
                TCPViewSessionState.self,
                from: packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.statePath)
            )
            let captureFileURL = packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.capturePath)
            guard fileManager.fileExists(atPath: captureFileURL.path) else {
                throw invalidPackage("The session package is missing capture.pcapng.")
            }
            let sidecars = try sanitizeSidecars(
                decodedPacketRecords: decodedPacketRecords,
                clients: clients,
                annotations: annotations,
                state: state,
                packetCount: manifest.packetCount
            )

            let clientIconFilePathByClientID = resolveClientIconFilePaths(
                clients: sidecars.clientStore,
                packageDirectoryURL: packageDirectoryURL
            )
            let annotationsByPacketID = Dictionary(
                uniqueKeysWithValues: sidecars.annotations.annotations.map { ($0.packetID, $0) }
            )
            let packets = TCPViewSessionClientStoreBuilder
                .rehydratePackets(records: sidecars.packetRecords, clients: sidecars.clientStore)
                .map { packet in
                    guard let annotation = annotationsByPacketID[packet.id] else {
                        return packet
                    }
                    let styledPacket = annotation.textStyle.map(packet.applying(textStyle:)) ?? packet
                    return annotation.customComment.map(styledPacket.applying(customComment:)) ?? styledPacket
                }
            return TCPViewSessionPackageContents(
                sourceURL: url,
                extractionDirectoryURL: extractionRoot,
                packageDirectoryURL: packageDirectoryURL,
                captureFileURL: captureFileURL,
                manifest: manifest,
                packetRecords: sidecars.packetRecords,
                clientStore: sidecars.clientStore,
                annotations: sidecars.annotations,
                state: sidecars.state,
                packets: packets,
                clientIconFilePathByClientID: clientIconFilePathByClientID,
                importReport: sidecars.importReport
            )
        } catch {
            try? fileManager.removeItem(at: extractionRoot)
            throw error
        }
    }

    private func validateArchive(at url: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw invalidPackage("The TCPViewer session file is not a readable ZIP archive.")
        }

        var files = Set<String>()
        let rootPrefix = "\(TCPViewSessionFormat.packageDirectoryName)/"
        for entry in archive {
            guard entry.type != .symlink else {
                throw invalidPackage("The TCPViewer session file contains an unsupported symbolic link.")
            }

            let path = entry.path
            guard !path.hasPrefix("/"),
                  path == TCPViewSessionFormat.packageDirectoryName || path.hasPrefix(rootPrefix),
                  !path.split(separator: "/").contains("..") else {
                throw invalidPackage("The TCPViewer session file contains an unsafe path.")
            }

            guard entry.type == .file else {
                continue
            }

            let relativePath = String(path.dropFirst(rootPrefix.count))
            files.insert(relativePath)
        }

        for requiredFile in requiredFiles {
            guard files.contains(requiredFile) else {
                throw invalidPackage("The TCPViewer session file is missing \(requiredFile).")
            }
        }
    }

    private var requiredFiles: [String] {
        [
            TCPViewSessionFormat.manifestPath,
            TCPViewSessionFormat.capturePath,
            TCPViewSessionFormat.packetsPath,
            TCPViewSessionFormat.clientsPath,
            TCPViewSessionFormat.annotationsPath,
            TCPViewSessionFormat.statePath,
        ]
    }

    private func validateManifest(_ manifest: TCPViewSessionManifest) throws {
        guard manifest.magic == TCPViewSessionFormat.magic else {
            throw invalidPackage("The selected file is not a TCPViewer session.")
        }
        guard manifest.schemaVersion <= TCPViewSessionFormat.schemaVersion,
              manifest.minimumCompatibleSchemaVersion <= TCPViewSessionFormat.schemaVersion else {
            throw invalidPackage("This TCPViewer session uses an unsupported schema version.")
        }
        guard manifest.packetCount >= 0 else {
            throw invalidPackage("The session manifest contains an invalid packet count.")
        }
    }

    private func sanitizeSidecars(
        decodedPacketRecords: PacketRecordDecodeResult,
        clients: TCPViewSessionClientStore,
        annotations: TCPViewSessionAnnotations,
        state: TCPViewSessionState,
        packetCount: Int
    ) throws -> SanitizedSidecars {
        let clientStore = sanitizedClientStore(clients)
        let clientIDs = Set(clientStore.clients.map(\.id))
        var packetIDs = Set<PacketSummary.ID>()
        var ordinals = Set<Int>()
        var validRecords: [TCPViewSessionPacketRecord] = []
        validRecords.reserveCapacity(decodedPacketRecords.records.count)
        var skippedDecodedRecordCount = 0

        for record in decodedPacketRecords.records {
            guard isValidPacketRecord(
                record,
                packetCount: packetCount,
                clientIDs: clientIDs,
                packetIDs: &packetIDs,
                ordinals: &ordinals
            ) else {
                skippedDecodedRecordCount += 1
                continue
            }

            validRecords.append(record)
        }

        let validPacketIDs = Set(validRecords.map(\.packetID))
        let failedFlowCount = max(
            decodedPacketRecords.failedLineCount + skippedDecodedRecordCount,
            max(0, packetCount - validRecords.count)
        )
        let sanitizedState = sanitizeState(state, validPacketIDs: validPacketIDs)
        let sanitizedAnnotations = sanitizeAnnotations(annotations, validPacketIDs: validPacketIDs)
        return SanitizedSidecars(
            packetRecords: validRecords,
            clientStore: clientStore,
            annotations: sanitizedAnnotations,
            state: sanitizedState,
            importReport: TCPViewSessionImportReport(
                importedFlowCount: validRecords.count,
                failedFlowCount: failedFlowCount
            )
        )
    }

    private func sanitizedClientStore(_ clients: TCPViewSessionClientStore) -> TCPViewSessionClientStore {
        var seenClientIDs = Set<String>()
        var sanitizedClients: [TCPViewSessionClientRecord] = []
        sanitizedClients.reserveCapacity(clients.clients.count)
        for client in clients.clients {
            guard !client.id.isEmpty,
                  seenClientIDs.insert(client.id).inserted else {
                continue
            }

            sanitizedClients.append(TCPViewSessionClientRecord(
                id: client.id,
                client: client.client,
                iconID: client.iconID.flatMap { isValidIconID($0) ? $0 : nil }
            ))
        }
        return TCPViewSessionClientStore(clients: sanitizedClients)
    }

    private func isValidPacketRecord(
        _ record: TCPViewSessionPacketRecord,
        packetCount: Int,
        clientIDs: Set<String>,
        packetIDs: inout Set<PacketSummary.ID>,
        ordinals: inout Set<Int>
    ) -> Bool {
        guard record.packetID == record.packet.id else {
            return false
        }
        guard record.captureOrdinal >= 0,
              record.captureOrdinal < packetCount else {
            return false
        }
        guard !packetIDs.contains(record.packetID) else {
            return false
        }
        guard !ordinals.contains(record.captureOrdinal) else {
            return false
        }
        if let clientID = record.clientID, !clientIDs.contains(clientID) {
            return false
        }
        packetIDs.insert(record.packetID)
        ordinals.insert(record.captureOrdinal)
        return true
    }

    private func sanitizeAnnotations(
        _ annotations: TCPViewSessionAnnotations,
        validPacketIDs: Set<PacketSummary.ID>
    ) -> TCPViewSessionAnnotations {
        var seenPacketIDs = Set<PacketSummary.ID>()
        let sanitized = annotations.annotations.compactMap { annotation -> TCPViewSessionPacketAnnotation? in
            guard validPacketIDs.contains(annotation.packetID),
                  seenPacketIDs.insert(annotation.packetID).inserted else {
                return nil
            }
            let customComment = annotation.customComment
                .map(PacketComment.sanitized)
                .flatMap { $0.isEmpty ? nil : $0 }
            return TCPViewSessionPacketAnnotation(
                packetID: annotation.packetID,
                packetComment: annotation.packetComment,
                customComment: customComment,
                colorHex: annotation.colorHex,
                textStyle: annotation.textStyle
            )
        }
        return TCPViewSessionAnnotations(annotations: sanitized)
    }

    private func sanitizeState(
        _ state: TCPViewSessionState,
        validPacketIDs: Set<PacketSummary.ID>
    ) -> TCPViewSessionState {
        var importedFileIDs = Set<String>()
        var importedFiles: [TCPViewSessionImportedFileRecord] = []
        for file in state.importedFiles {
            guard importedFileIDs.insert(file.fileID).inserted else {
                continue
            }

            let packetIDs = file.packetIDs.filter { validPacketIDs.contains($0) }
            guard !packetIDs.isEmpty else {
                continue
            }

            importedFiles.append(TCPViewSessionImportedFileRecord(file: ImportedCaptureFile(
                id: ImportedCaptureFileID(rawValue: file.fileID),
                url: URL(fileURLWithPath: file.urlPath),
                displayName: file.displayName,
                packetIDs: packetIDs
            )))
        }

        let validImportedFileIDs = Set(importedFiles.map(\.fileID))
        let selectedSourceListSelection = sanitizeSourceListSelection(
            state.selectedSourceListSelection,
            validImportedFileIDs: validImportedFileIDs
        )
        return TCPViewSessionState(
            source: state.source,
            backingIdentity: state.backingIdentity,
            importedFiles: importedFiles,
            importedPacketReferences: sanitizedImportedPacketReferences(
                state.importedPacketReferences,
                validPacketIDs: validPacketIDs,
                validImportedFileIDs: validImportedFileIDs
            ),
            pins: uniquePins(state.pins),
            savedPackets: sanitizedSavedPackets(state.savedPackets, validPacketIDs: validPacketIDs),
            customFilters: uniqueCustomFilters(state.customFilters),
            quickFilterSelection: state.quickFilterSelection,
            structuredFilterGroup: state.structuredFilterGroup,
            displayFilterText: state.displayFilterText,
            sourceListFilterText: state.sourceListFilterText,
            selectedPacketID: state.selectedPacketID.flatMap { validPacketIDs.contains($0) ? $0 : nil },
            selectedSourceListSelection: selectedSourceListSelection,
            workspaceMode: state.workspaceMode,
            inspectorTab: state.inspectorTab,
            inspectorPlacement: state.inspectorPlacement,
            isInspectorVisible: state.isInspectorVisible,
            isStructuredFilterVisible: state.isStructuredFilterVisible,
            filterMode: state.filterMode,
            wiresharkExpression: state.wiresharkExpression,
            tableColumnLayout: state.tableColumnLayout,
            importedFileProvenance: importedFiles.isEmpty ? nil : state.importedFileProvenance,
            sourceMetadata: state.sourceMetadata.map { metadata in
                TCPViewSessionSourceMetadata(
                    fileName: metadata.fileName,
                    filePath: metadata.filePath,
                    format: metadata.format,
                    packetCount: validPacketIDs.count
                )
            }
        )
    }

    private func sanitizedImportedPacketReferences(
        _ references: [TCPViewSessionImportedPacketReferenceRecord],
        validPacketIDs: Set<PacketSummary.ID>,
        validImportedFileIDs: Set<String>
    ) -> [TCPViewSessionImportedPacketReferenceRecord] {
        var seenPacketIDs = Set<PacketSummary.ID>()
        return references.filter { reference in
            validPacketIDs.contains(reference.packetID) &&
                validImportedFileIDs.contains(reference.fileID) &&
                seenPacketIDs.insert(reference.packetID).inserted
        }
    }

    private func sanitizedSavedPackets(
        _ records: [SavedPacketRecord],
        validPacketIDs: Set<PacketSummary.ID>
    ) -> [SavedPacketRecord] {
        var seenPacketIDs = Set<PacketSummary.ID>()
        return records.filter { record in
            validPacketIDs.contains(record.packet.id) &&
                seenPacketIDs.insert(record.packet.id).inserted
        }
    }

    private func uniquePins(_ pins: [PacketPin]) -> [PacketPin] {
        var seenPinIDs = Set<PacketPinID>()
        return pins.filter { seenPinIDs.insert($0.id).inserted }
    }

    private func uniqueCustomFilters(_ filters: [PacketCustomFilter]) -> [PacketCustomFilter] {
        var seenFilterIDs = Set<PacketCustomFilter.ID>()
        return filters.filter { seenFilterIDs.insert($0.id).inserted }
    }

    private func sanitizeSourceListSelection(
        _ selection: TCPViewSessionSourceListSelectionRecord?,
        validImportedFileIDs: Set<String>
    ) -> TCPViewSessionSourceListSelectionRecord? {
        guard let selection,
              selection.kind.hasPrefix("file"),
              let fileID = selection.values.first else {
            return selection
        }
        return validImportedFileIDs.contains(fileID)
            ? selection
            : TCPViewSessionSourceListSelectionRecord(selection: .allPackets)
    }

    private func resolveClientIconFilePaths(
        clients: TCPViewSessionClientStore,
        packageDirectoryURL: URL
    ) -> [String: String] {
        let iconsDirectoryURL = packageDirectoryURL.appendingPathComponent(TCPViewSessionFormat.iconsDirectoryPath, isDirectory: true)
        var iconPathByClientID: [String: String] = [:]
        for client in clients.clients {
            guard let iconID = client.iconID,
                  isValidIconID(iconID) else {
                continue
            }

            let iconURL = iconsDirectoryURL.appendingPathComponent("\(iconID).png")
            if fileManager.fileExists(atPath: iconURL.path) {
                iconPathByClientID[client.id] = iconURL.path
            }
        }
        return iconPathByClientID
    }

    private func isValidIconID(_ iconID: String) -> Bool {
        !iconID.isEmpty &&
            iconID.utf8.allSatisfy { byte in
                (48...57).contains(Int(byte)) ||
                    (65...90).contains(Int(byte)) ||
                    (97...122).contains(Int(byte)) ||
                    byte == 45 ||
                    byte == 95
            }
    }

    private func decodePacketRecords(from url: URL) throws -> PacketRecordDecodeResult {
        let data = try Data(contentsOf: url)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw invalidPackage("The packet sidecar is not valid UTF-8.")
        }

        let decoder = jsonDecoder()
        var records: [TCPViewSessionPacketRecord] = []
        var failedLineCount = 0
        for line in payload.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8) else {
                failedLineCount += 1
                continue
            }
            do {
                records.append(try decoder.decode(TCPViewSessionPacketRecord.self, from: lineData))
            } catch {
                failedLineCount += 1
            }
        }
        return PacketRecordDecodeResult(records: records, failedLineCount: failedLineCount)
    }

    private func decodeJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try jsonDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func invalidPackage(_ message: String) -> TCPViewerCoreError {
        TCPViewerCoreError(code: .offlineFileOpenFailed, message: message)
    }
}

final class TCPViewSessionOfflineDocument: OfflineCaptureDocumentProviding {
    var eventHandler: PacketIngestEventHandler?

    private(set) var state: TCPViewSessionState
    private(set) var importedFiles: [ImportedCaptureFile]
    private(set) var importedPacketReferenceByID: [PacketSummary.ID: ImportedPacketReference]
    let clientIconFilePathByClientID: [String: String]
    private(set) var importReport: TCPViewSessionImportReport

    private let contents: TCPViewSessionPackageContents
    private let core: any TCPViewerCoreProviding
    private let fileManager: FileManager
    private var innerDocument: (any OfflineCaptureDocumentProviding)?
    private var innerPacketIDBySessionID: [PacketSummary.ID: PacketSummary.ID] = [:]
    private var sessionPacketByID: [PacketSummary.ID: PacketSummary] = [:]
    private var openedPackets: [PacketSummary]
    private var progress: PacketLoadProgress
    private var metadata: CaptureDocumentMetadata

    init(
        contents: TCPViewSessionPackageContents,
        core: any TCPViewerCoreProviding,
        fileManager: FileManager = .default
    ) {
        self.contents = contents
        self.core = core
        self.fileManager = fileManager
        self.state = contents.state
        self.importedFiles = contents.state.importedCaptureFiles
        self.importedPacketReferenceByID = contents.state.importedPacketReferenceByID
        self.clientIconFilePathByClientID = contents.clientIconFilePathByClientID
        self.importReport = contents.importReport
        self.openedPackets = contents.packets
        self.progress = PacketLoadProgress(
            phase: .idle,
            loadedPacketCount: 0,
            message: "TCPViewer session is ready to open."
        )
        self.metadata = CaptureDocumentMetadata(
            format: .pcapng,
            captureApplication: contents.manifest.applicationName,
            fileComment: "TCPViewer Session"
        )
    }

    deinit {
        try? fileManager.removeItem(at: contents.extractionDirectoryURL)
    }

    func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        progress = PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "Opening \(contents.sourceURL.lastPathComponent)..."
        )
        eventHandler?(.success(.loadProgressChanged(progress)))

        core.openOfflineCaptureDocument(at: contents.captureFileURL) { [weak self] result in
            guard let self else {
                completion(.failure(Self.cancelledError()))
                return
            }

            switch result {
            case .success(let document):
                self.innerDocument = document
                document.open { [weak self] result in
                    guard let self else {
                        completion(.failure(Self.cancelledError()))
                        return
                    }
                    self.finishInnerOpen(result, completion: completion)
                }
            case .failure(let error):
                self.progress = PacketLoadProgress(
                    phase: .failed,
                    loadedPacketCount: 0,
                    message: Self.errorMessage(error)
                )
                completion(.failure(error))
            }
        }
    }

    func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        guard let innerDocument else {
            open(completion: completion)
            return
        }

        progress = PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "Reopening \(contents.sourceURL.lastPathComponent)..."
        )
        innerDocument.reopen { [weak self] result in
            self?.finishInnerOpen(result, completion: completion)
        }
    }

    func cancelLoading(completion: (() -> Void)?) {
        guard let innerDocument else {
            completion?()
            return
        }

        innerDocument.cancelLoading(completion: completion)
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        guard let innerDocument,
              let innerID = innerPacketIDBySessionID[id] else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }

        innerDocument.inspectPacket(id: innerID) { [weak self] result in
            guard let self else {
                completion(.failure(Self.cancelledError()))
                return
            }

            completion(result.map { inspection in
                let sessionPacket = self.sessionPacketByID[id]
                return PacketInspection(
                    packetID: id,
                    packetNumber: sessionPacket?.packetNumber ?? inspection.packetNumber,
                    rawBytes: inspection.rawBytes,
                    byteViews: inspection.byteViews,
                    detailNodes: inspection.detailNodes,
                    decodeStatus: inspection.decodeStatus
                )
            })
        }
    }

    // Translate inner capture packet IDs back to their stable session IDs.
    func followTCPStream(
        containing packetID: PacketSummary.ID,
        limits: TCPFollowLimits,
        progress: TCPFollowProgressHandler?,
        shouldCancel: TCPFollowCancellationCheck?,
        completion: @escaping TCPViewerCompletion<TCPFollowStream>
    ) {
        guard let innerDocument,
              let innerID = innerPacketIDBySessionID[packetID] else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }
        let packetIDMapping = innerPacketIDBySessionID
        innerDocument.followTCPStream(
            containing: innerID,
            limits: limits,
            progress: progress,
            shouldCancel: shouldCancel
        ) { result in
            completion(result.map { stream in
                let relevantInnerIDs = Set(stream.records.map(\.packetID) + [stream.capturedThroughPacketID])
                let sessionIDByInnerID = Dictionary(
                    uniqueKeysWithValues: packetIDMapping.compactMap { sessionID, innerID in
                        relevantInnerIDs.contains(innerID) ? (innerID, sessionID) : nil
                    }
                )
                return stream.tcpviewerRemapping(
                    packetIDByOriginalID: sessionIDByInnerID,
                    fallbackPacketID: packetID
                )
            })
        }
    }

    func save(completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(Self.readOnlyError()))
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        completion(.failure(Self.readOnlyError()))
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        guard let innerDocument else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }

        let innerIDs = identifiers.compactMap { innerPacketIDBySessionID[$0] }
        guard innerIDs.count == identifiers.count else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }

        innerDocument.exportPackets(
            withIDs: innerIDs,
            to: url,
            format: format,
            progress: progress,
            shouldCancel: shouldCancel,
            completion: completion
        )
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        metadata: PacketExportMetadata,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        guard let innerDocument else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }

        let innerIDs = identifiers.compactMap { innerPacketIDBySessionID[$0] }
        guard innerIDs.count == identifiers.count else {
            completion(.failure(Self.unavailableBackingError()))
            return
        }

        var remappedStyles: [PacketSummary.ID: PacketTextStyle] = [:]
        var remappedComments: [PacketSummary.ID: String] = [:]
        for (sessionID, innerID) in zip(identifiers, innerIDs) {
            if let style = metadata.textStylesByPacketID[sessionID] {
                remappedStyles[innerID] = style
            }
            if let comment = metadata.commentsByPacketID[sessionID] {
                remappedComments[innerID] = comment
            }
        }
        innerDocument.exportPackets(
            withIDs: innerIDs,
            to: url,
            format: format,
            metadata: PacketExportMetadata(
                textStylesByPacketID: remappedStyles,
                commentsByPacketID: remappedComments
            ),
            progress: progress,
            shouldCancel: shouldCancel,
            completion: completion
        )
    }

    func currentURL() -> URL {
        contents.sourceURL
    }

    func currentMetadata() -> CaptureDocumentMetadata {
        metadata
    }

    func packetSummaries() -> [PacketSummary] {
        openedPackets
    }

    func loadProgress() -> PacketLoadProgress {
        progress
    }

    private func finishInnerOpen(_ result: Result<[PacketSummary], Error>, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        switch result {
        case .success(let innerPackets):
            let mapping = rebuildPacketMapping(innerPackets: innerPackets)
            openedPackets = mapping.packets
            importReport = importReport.addingFailedFlows(mapping.failedFlowCount)
            if let innerDocument {
                let innerMetadata = innerDocument.currentMetadata()
                metadata = CaptureDocumentMetadata(
                    format: .pcapng,
                    operatingSystem: innerMetadata.operatingSystem,
                    hardware: innerMetadata.hardware,
                    captureApplication: contents.manifest.applicationName,
                    fileComment: innerMetadata.fileComment ?? "TCPViewer Session"
                )
            }
            progress = PacketLoadProgress(
                phase: .completed,
                loadedPacketCount: openedPackets.count,
                message: progressMessage(loadedPacketCount: openedPackets.count)
            )
            eventHandler?(.success(.documentMetadataChanged(metadata)))
            eventHandler?(.success(.packetBatch(openedPackets, disposition: .replace)))
            eventHandler?(.success(.loadProgressChanged(progress)))
            eventHandler?(.success(.documentStateChanged(phase: .loaded, message: progress.message)))
            completion(.success(openedPackets))
        case .failure(let error):
            progress = PacketLoadProgress(
                phase: .failed,
                loadedPacketCount: 0,
                message: Self.errorMessage(error)
            )
            completion(.failure(error))
        }
    }

    private func rebuildPacketMapping(innerPackets: [PacketSummary]) -> (packets: [PacketSummary], failedFlowCount: Int) {
        innerPacketIDBySessionID.removeAll(keepingCapacity: true)
        sessionPacketByID.removeAll(keepingCapacity: true)
        var sessionPacketByRecordID: [PacketSummary.ID: PacketSummary] = [:]
        for packet in contents.packets where sessionPacketByRecordID[packet.id] == nil {
            sessionPacketByRecordID[packet.id] = packet
        }

        var mappedPackets: [PacketSummary] = []
        mappedPackets.reserveCapacity(contents.packets.count)
        var failedFlowCount = 0
        for record in contents.packetRecords.sorted(by: { $0.captureOrdinal < $1.captureOrdinal }) {
            guard innerPackets.indices.contains(record.captureOrdinal),
                  let sessionPacket = sessionPacketByRecordID[record.packetID] else {
                failedFlowCount += 1
                continue
            }

            let innerPacket = innerPackets[record.captureOrdinal]
            innerPacketIDBySessionID[sessionPacket.id] = innerPacket.id
            let mappedPacket = sessionPacket.tcpviewerApplying(
                tcpFollowStreamID: innerPacket.tcpFollowStreamID
            )
            sessionPacketByID[sessionPacket.id] = mappedPacket
            mappedPackets.append(mappedPacket)
        }

        trimDocumentState(to: Set(mappedPackets.map(\.id)))
        return (mappedPackets, failedFlowCount)
    }

    private func trimDocumentState(to packetIDs: Set<PacketSummary.ID>) {
        importedFiles = contents.state.importedCaptureFiles.compactMap { file in
            let remainingPacketIDs = file.packetIDs.filter { packetIDs.contains($0) }
            guard !remainingPacketIDs.isEmpty else {
                return nil
            }
            return ImportedCaptureFile(
                id: file.id,
                url: file.url,
                displayName: file.displayName,
                packetIDs: remainingPacketIDs
            )
        }
        importedPacketReferenceByID = contents.state.importedPacketReferenceByID.filter { packetIDs.contains($0.key) }
        let importedFileRecords = importedFiles.map(TCPViewSessionImportedFileRecord.init)
        let validImportedFileIDs = Set(importedFileRecords.map(\.fileID))
        state = TCPViewSessionState(
            source: state.source,
            backingIdentity: state.backingIdentity,
            importedFiles: importedFileRecords,
            importedPacketReferences: importedPacketReferenceByID
                .map { TCPViewSessionImportedPacketReferenceRecord(packetID: $0.key, reference: $0.value) }
                .sorted { $0.packetID < $1.packetID },
            pins: state.pins,
            savedPackets: state.savedPackets.filter { packetIDs.contains($0.packet.id) },
            customFilters: state.customFilters,
            quickFilterSelection: state.quickFilterSelection,
            structuredFilterGroup: state.structuredFilterGroup,
            displayFilterText: state.displayFilterText,
            sourceListFilterText: state.sourceListFilterText,
            selectedPacketID: state.selectedPacketID.flatMap { packetIDs.contains($0) ? $0 : nil },
            selectedSourceListSelection: sessionSelection(
                state.selectedSourceListSelection,
                validImportedFileIDs: validImportedFileIDs
            ),
            workspaceMode: state.workspaceMode,
            inspectorTab: state.inspectorTab,
            inspectorPlacement: state.inspectorPlacement,
            isInspectorVisible: state.isInspectorVisible,
            isStructuredFilterVisible: state.isStructuredFilterVisible,
            filterMode: state.filterMode,
            wiresharkExpression: state.wiresharkExpression,
            tableColumnLayout: state.tableColumnLayout,
            importedFileProvenance: importedFileRecords.isEmpty ? nil : state.importedFileProvenance,
            sourceMetadata: state.sourceMetadata.map { metadata in
                TCPViewSessionSourceMetadata(
                    fileName: metadata.fileName,
                    filePath: metadata.filePath,
                    format: metadata.format,
                    packetCount: packetIDs.count
                )
            }
        )
    }

    private func sessionSelection(
        _ selection: TCPViewSessionSourceListSelectionRecord?,
        validImportedFileIDs: Set<String>
    ) -> TCPViewSessionSourceListSelectionRecord? {
        guard let selection,
              selection.kind.hasPrefix("file"),
              let fileID = selection.values.first else {
            return selection
        }
        return validImportedFileIDs.contains(fileID)
            ? selection
            : TCPViewSessionSourceListSelectionRecord(selection: .allPackets)
    }

    private func progressMessage(loadedPacketCount: Int) -> String {
        let baseMessage = "Loaded \(loadedPacketCount) packets from \(contents.sourceURL.lastPathComponent)."
        guard importReport.hasFailedFlows else {
            return baseMessage
        }

        let reason = importReport.failedFlowCount == 1 ? "it was malformed" : "they were malformed"
        return "\(baseMessage) Skipped \(flowCountText(importReport.failedFlowCount)) because \(reason)."
    }

    private func flowCountText(_ count: Int) -> String {
        "\(count) malformed flow\(count == 1 ? "" : "s")"
    }

    private static func readOnlyError() -> TCPViewerCoreError {
        TCPViewerCoreError(
            code: .offlineFileSaveFailed,
            message: "TCPViewer sessions are read-only. Export the packets or create a new session file instead."
        )
    }

    private static func unavailableBackingError() -> TCPViewerCoreError {
        TCPViewerCoreError(
            code: .offlineFileOpenFailed,
            message: "The TCPViewer session backing pcapng is not available."
        )
    }

    private static func cancelledError() -> TCPViewerCoreError {
        TCPViewerCoreError(code: .operationCancelled, message: "The TCPViewer session operation was cancelled.")
    }

    private static func errorMessage(_ error: Error) -> String {
        if let tcpviewerError = error as? TCPViewerCoreError {
            return tcpviewerError.message
        }
        return error.localizedDescription
    }
}
