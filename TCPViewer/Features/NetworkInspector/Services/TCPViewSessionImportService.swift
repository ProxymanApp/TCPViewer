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
}

final class TCPViewSessionImportService {
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

            let packetRecords = try decodePacketRecords(
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
            guard packetRecords.count == manifest.packetCount else {
                throw invalidPackage("The session packet count does not match the manifest.")
            }

            let packets = TCPViewSessionClientStoreBuilder.rehydratePackets(records: packetRecords, clients: clients)
            return TCPViewSessionPackageContents(
                sourceURL: url,
                extractionDirectoryURL: extractionRoot,
                packageDirectoryURL: packageDirectoryURL,
                captureFileURL: captureFileURL,
                manifest: manifest,
                packetRecords: packetRecords,
                clientStore: clients,
                annotations: annotations,
                state: state,
                packets: packets
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
    }

    private func decodePacketRecords(from url: URL) throws -> [TCPViewSessionPacketRecord] {
        let data = try Data(contentsOf: url)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw invalidPackage("The packet sidecar is not valid UTF-8.")
        }

        let decoder = jsonDecoder()
        var records: [TCPViewSessionPacketRecord] = []
        for line in payload.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8) else {
                throw invalidPackage("The packet sidecar contains an invalid line.")
            }
            records.append(try decoder.decode(TCPViewSessionPacketRecord.self, from: lineData))
        }
        return records
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

    let state: TCPViewSessionState
    let importedFiles: [ImportedCaptureFile]
    let importedPacketReferenceByID: [PacketSummary.ID: ImportedPacketReference]

    private let contents: TCPViewSessionPackageContents
    private let core: any TCPViewerCoreProviding
    private let fileManager: FileManager
    private var innerDocument: (any OfflineCaptureDocumentProviding)?
    private var innerPacketIDBySessionID: [PacketSummary.ID: PacketSummary.ID] = [:]
    private var sessionPacketByID: [PacketSummary.ID: PacketSummary] = [:]
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

    func currentURL() -> URL {
        contents.sourceURL
    }

    func currentMetadata() -> CaptureDocumentMetadata {
        metadata
    }

    func packetSummaries() -> [PacketSummary] {
        contents.packets
    }

    func loadProgress() -> PacketLoadProgress {
        progress
    }

    private func finishInnerOpen(_ result: Result<[PacketSummary], Error>, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        switch result {
        case .success(let innerPackets):
            do {
                try rebuildPacketMapping(innerPackets: innerPackets)
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
                    loadedPacketCount: contents.packets.count,
                    message: "Loaded \(contents.packets.count) packets from \(contents.sourceURL.lastPathComponent)."
                )
                eventHandler?(.success(.documentMetadataChanged(metadata)))
                eventHandler?(.success(.packetBatch(contents.packets, disposition: .replace)))
                eventHandler?(.success(.loadProgressChanged(progress)))
                eventHandler?(.success(.documentStateChanged(phase: .loaded, message: progress.message)))
                completion(.success(contents.packets))
            } catch {
                progress = PacketLoadProgress(
                    phase: .failed,
                    loadedPacketCount: 0,
                    message: Self.errorMessage(error)
                )
                completion(.failure(error))
            }
        case .failure(let error):
            progress = PacketLoadProgress(
                phase: .failed,
                loadedPacketCount: 0,
                message: Self.errorMessage(error)
            )
            completion(.failure(error))
        }
    }

    private func rebuildPacketMapping(innerPackets: [PacketSummary]) throws {
        guard innerPackets.count == contents.packets.count else {
            throw TCPViewerCoreError(
                code: .offlineFileOpenFailed,
                message: "The session pcapng packet count does not match packets.jsonl."
            )
        }

        innerPacketIDBySessionID.removeAll(keepingCapacity: true)
        sessionPacketByID.removeAll(keepingCapacity: true)
        for (sessionPacket, innerPacket) in zip(contents.packets, innerPackets) {
            innerPacketIDBySessionID[sessionPacket.id] = innerPacket.id
            sessionPacketByID[sessionPacket.id] = sessionPacket
        }
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
