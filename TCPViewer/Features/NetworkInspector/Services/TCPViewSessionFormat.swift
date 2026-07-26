//
//  TCPViewSessionFormat.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/6/26.
//

import Foundation
import PcapPlusPlusCore

enum TCPViewSessionFormat {
    static let fileExtension = "tcpviewsession"
    static let importedTypeIdentifier = "com.proxyman.tcpviewer.session"
    static let packageDirectoryName = "TCPViewerSession"
    static let magic = "TCPViewerSession"
    static let schemaVersion = 1
    static let minimumCompatibleSchemaVersion = 1

    static let manifestPath = "manifest.json"
    static let capturePath = "capture.pcapng"
    static let packetsPath = "packets.jsonl"
    static let clientsPath = "clients.json"
    static let annotationsPath = "annotations.json"
    static let statePath = "state.json"
    static let iconsDirectoryPath = "icons"
}

struct TCPViewSessionManifest: Codable, Equatable {
    var magic: String
    var schemaVersion: Int
    var minimumCompatibleSchemaVersion: Int
    var createdAt: Date
    var applicationName: String
    var applicationVersion: String
    var applicationBuild: String
    var packetCount: Int
    var files: [String]
    var captureFile: String
    var packetsFile: String
    var clientsFile: String
    var annotationsFile: String
    var stateFile: String
    var iconsDirectory: String

    init(
        createdAt: Date,
        applicationName: String,
        applicationVersion: String,
        applicationBuild: String,
        packetCount: Int,
        files: [String] = [
            TCPViewSessionFormat.manifestPath,
            TCPViewSessionFormat.capturePath,
            TCPViewSessionFormat.packetsPath,
            TCPViewSessionFormat.clientsPath,
            TCPViewSessionFormat.annotationsPath,
            TCPViewSessionFormat.statePath,
            TCPViewSessionFormat.iconsDirectoryPath,
        ]
    ) {
        self.magic = TCPViewSessionFormat.magic
        self.schemaVersion = TCPViewSessionFormat.schemaVersion
        self.minimumCompatibleSchemaVersion = TCPViewSessionFormat.minimumCompatibleSchemaVersion
        self.createdAt = createdAt
        self.applicationName = applicationName
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
        self.packetCount = packetCount
        self.files = files
        self.captureFile = TCPViewSessionFormat.capturePath
        self.packetsFile = TCPViewSessionFormat.packetsPath
        self.clientsFile = TCPViewSessionFormat.clientsPath
        self.annotationsFile = TCPViewSessionFormat.annotationsPath
        self.stateFile = TCPViewSessionFormat.statePath
        self.iconsDirectory = TCPViewSessionFormat.iconsDirectoryPath
    }
}

struct TCPViewSessionPacketRecord: Codable, Equatable {
    let packetID: PacketSummary.ID
    let captureOrdinal: Int
    let clientID: String?
    let packet: PacketSummary
}

struct TCPViewSessionClientRecord: Codable, Equatable {
    let id: String
    let client: PacketClient
    let iconID: String?
}

struct TCPViewSessionClientStore: Codable, Equatable {
    let clients: [TCPViewSessionClientRecord]
}

struct TCPViewSessionPacketAnnotation: Codable, Equatable {
    let packetID: PacketSummary.ID
    let packetComment: String?
    let customComment: String?
    let colorHex: String?
    let textStyle: PacketTextStyle?

    init(
        packetID: PacketSummary.ID,
        packetComment: String?,
        customComment: String?,
        colorHex: String?,
        textStyle: PacketTextStyle? = nil
    ) {
        self.packetID = packetID
        self.packetComment = packetComment
        self.customComment = customComment
        self.colorHex = colorHex
        self.textStyle = textStyle
    }
}

struct TCPViewSessionAnnotations: Codable, Equatable {
    let annotations: [TCPViewSessionPacketAnnotation]
}

struct TCPViewSessionImportReport: Sendable, Equatable {
    let importedFlowCount: Int
    let failedFlowCount: Int

    var hasFailedFlows: Bool {
        failedFlowCount > 0
    }

    func addingFailedFlows(_ count: Int) -> TCPViewSessionImportReport {
        guard count > 0 else {
            return self
        }

        return TCPViewSessionImportReport(
            importedFlowCount: max(0, importedFlowCount - count),
            failedFlowCount: failedFlowCount + count
        )
    }
}

struct TCPViewSessionImportedFileRecord: Codable, Equatable {
    let fileID: String
    let urlPath: String
    let displayName: String
    let packetIDs: [PacketSummary.ID]

    init(file: ImportedCaptureFile) {
        self.fileID = file.id.rawValue
        self.urlPath = file.url.path
        self.displayName = file.displayName
        self.packetIDs = file.packetIDs
    }

    func importedFile() -> ImportedCaptureFile {
        ImportedCaptureFile(
            id: ImportedCaptureFileID(rawValue: fileID),
            url: URL(fileURLWithPath: urlPath),
            displayName: displayName,
            packetIDs: packetIDs
        )
    }
}

struct TCPViewSessionImportedPacketReferenceRecord: Codable, Equatable {
    let packetID: PacketSummary.ID
    let fileID: String
    let originalPacketID: PacketSummary.ID

    init(packetID: PacketSummary.ID, reference: ImportedPacketReference) {
        self.packetID = packetID
        self.fileID = reference.fileID.rawValue
        self.originalPacketID = reference.originalPacketID
    }

    func importedPacketReference() -> (PacketSummary.ID, ImportedPacketReference) {
        (
            packetID,
            ImportedPacketReference(
                fileID: ImportedCaptureFileID(rawValue: fileID),
                originalPacketID: originalPacketID
            )
        )
    }
}

struct TCPViewSessionSourceListSelectionRecord: Codable, Equatable {
    let kind: String
    let values: [String]

    init(selection: PacketSourceListSelection) {
        switch selection {
        case .allPackets:
            kind = "allPackets"; values = []
        case .pinned:
            kind = "pinned"; values = []
        case .pinnedItem(let pinID):
            kind = "pinnedItem"; values = [pinID.rawValue]
        case .pinnedItemDomain(let pinID, let domain):
            kind = "pinnedItemDomain"; values = [pinID.rawValue, domain.rawValue, String(domain.isMissingDomain)]
        case .pinnedItemIPAddress(let pinID, let ipAddress):
            kind = "pinnedItemIPAddress"; values = [pinID.rawValue, ipAddress.rawValue]
        case .saved:
            kind = "saved"; values = []
        case .files:
            kind = "files"; values = []
        case .file(let fileID):
            kind = "file"; values = [fileID.rawValue]
        case .fileApps(let fileID):
            kind = "fileApps"; values = [fileID.rawValue]
        case .fileApp(let fileID, let client):
            kind = "fileApp"; values = [fileID.rawValue, client.rawValue]
        case .fileAppDomain(let fileID, let client, let domain):
            kind = "fileAppDomain"; values = [fileID.rawValue, client.rawValue, domain.rawValue, String(domain.isMissingDomain)]
        case .fileAppIPAddress(let fileID, let client, let ipAddress):
            kind = "fileAppIPAddress"; values = [fileID.rawValue, client.rawValue, ipAddress.rawValue]
        case .fileDomains(let fileID):
            kind = "fileDomains"; values = [fileID.rawValue]
        case .fileDomain(let fileID, let domain):
            kind = "fileDomain"; values = [fileID.rawValue, domain.rawValue, String(domain.isMissingDomain)]
        case .fileIPAddress(let fileID, let ipAddress):
            kind = "fileIPAddress"; values = [fileID.rawValue, ipAddress.rawValue]
        case .apps:
            kind = "apps"; values = []
        case .app(let client):
            kind = "app"; values = [client.rawValue]
        case .appDomain(let client, let domain):
            kind = "appDomain"; values = [client.rawValue, domain.rawValue, String(domain.isMissingDomain)]
        case .appIPAddress(let client, let ipAddress):
            kind = "appIPAddress"; values = [client.rawValue, ipAddress.rawValue]
        case .domains:
            kind = "domains"; values = []
        case .domain(let domain):
            kind = "domain"; values = [domain.rawValue, String(domain.isMissingDomain)]
        case .ipAddress(let ipAddress):
            kind = "ipAddress"; values = [ipAddress.rawValue]
        }
    }

    func selection() -> PacketSourceListSelection? {
        switch kind {
        case "allPackets":
            return .allPackets
        case "pinned":
            return .pinned
        case "pinnedItem":
            guard let pinID = value(0) else { return nil }
            return .pinnedItem(PacketPinID(rawValue: pinID))
        case "pinnedItemDomain":
            guard let pinID = value(0), let domain = domainKey(startingAt: 1) else { return nil }
            return .pinnedItemDomain(PacketPinID(rawValue: pinID), domain)
        case "pinnedItemIPAddress":
            guard let pinID = value(0), let ipAddress = ipAddressKey(1) else { return nil }
            return .pinnedItemIPAddress(PacketPinID(rawValue: pinID), ipAddress)
        case "saved":
            return .saved
        case "files":
            return .files
        case "file":
            guard let fileID = fileID(0) else { return nil }
            return .file(fileID)
        case "fileApps":
            guard let fileID = fileID(0) else { return nil }
            return .fileApps(fileID)
        case "fileApp":
            guard let fileID = fileID(0), let client = clientKey(1) else { return nil }
            return .fileApp(fileID, client)
        case "fileAppDomain":
            guard let fileID = fileID(0), let client = clientKey(1), let domain = domainKey(startingAt: 2) else { return nil }
            return .fileAppDomain(fileID, client, domain)
        case "fileAppIPAddress":
            guard let fileID = fileID(0), let client = clientKey(1), let ipAddress = ipAddressKey(2) else { return nil }
            return .fileAppIPAddress(fileID, client, ipAddress)
        case "fileDomains":
            guard let fileID = fileID(0) else { return nil }
            return .fileDomains(fileID)
        case "fileDomain":
            guard let fileID = fileID(0), let domain = domainKey(startingAt: 1) else { return nil }
            return .fileDomain(fileID, domain)
        case "fileIPAddress":
            guard let fileID = fileID(0), let ipAddress = ipAddressKey(1) else { return nil }
            return .fileIPAddress(fileID, ipAddress)
        case "apps":
            return .apps
        case "app":
            guard let client = clientKey(0) else { return nil }
            return .app(client)
        case "appDomain":
            guard let client = clientKey(0), let domain = domainKey(startingAt: 1) else { return nil }
            return .appDomain(client, domain)
        case "appIPAddress":
            guard let client = clientKey(0), let ipAddress = ipAddressKey(1) else { return nil }
            return .appIPAddress(client, ipAddress)
        case "domains":
            return .domains
        case "domain":
            guard let domain = domainKey(startingAt: 0) else { return nil }
            return .domain(domain)
        case "ipAddress":
            guard let ipAddress = ipAddressKey(0) else { return nil }
            return .ipAddress(ipAddress)
        default:
            return nil
        }
    }

    private func value(_ index: Int) -> String? {
        values.indices.contains(index) ? values[index] : nil
    }

    private func fileID(_ index: Int) -> ImportedCaptureFileID? {
        value(index).map { ImportedCaptureFileID(rawValue: $0) }
    }

    private func clientKey(_ index: Int) -> PacketSourceClientKey? {
        value(index).map { PacketSourceClientKey(rawValue: $0) }
    }

    private func ipAddressKey(_ index: Int) -> PacketSourceIPAddressKey? {
        value(index).map { PacketSourceIPAddressKey(rawValue: $0) }
    }

    private func domainKey(startingAt index: Int) -> PacketSourceDomainKey? {
        guard let rawValue = value(index) else {
            return nil
        }
        let isMissingDomain = value(index + 1).flatMap(Bool.init) ?? false
        return PacketSourceDomainKey(rawValue: rawValue, isMissingDomain: isMissingDomain)
    }
}

struct TCPViewSessionState: Codable, Equatable {
    let source: String?
    let backingIdentity: String?
    let importedFiles: [TCPViewSessionImportedFileRecord]
    let importedPacketReferences: [TCPViewSessionImportedPacketReferenceRecord]
    let pins: [PacketPin]
    let savedPackets: [SavedPacketRecord]
    let customFilters: [PacketCustomFilter]
    let quickFilterSelection: PacketQuickFilterSelection
    let structuredFilterGroup: PacketStructuredFilterGroup
    let displayFilterText: String
    let sourceListFilterText: String
    let selectedPacketID: PacketSummary.ID?
    let selectedSourceListSelection: TCPViewSessionSourceListSelectionRecord?
    let workspaceMode: String
    let inspectorTab: String
    let inspectorPlacement: String
    let isInspectorVisible: Bool
    let isStructuredFilterVisible: Bool
    let tableColumnLayout: PacketTableColumnLayout?
    let importedFileProvenance: String?
    let sourceMetadata: TCPViewSessionSourceMetadata?

    var importedCaptureFiles: [ImportedCaptureFile] {
        importedFiles.map { $0.importedFile() }
    }

    var importedPacketReferenceByID: [PacketSummary.ID: ImportedPacketReference] {
        var references: [PacketSummary.ID: ImportedPacketReference] = [:]
        for record in importedPacketReferences where references[record.packetID] == nil {
            let reference = record.importedPacketReference()
            references[reference.0] = reference.1
        }
        return references
    }
}

struct TCPViewSessionSourceMetadata: Codable, Equatable {
    let fileName: String?
    let filePath: String?
    let format: String?
    let packetCount: Int
}

struct TCPViewSessionExportSnapshot {
    let packets: [PacketSummary]
    let source: CaptureSource?
    let backingIdentity: String?
    let importedFiles: [ImportedCaptureFile]
    let importedPacketReferenceByID: [PacketSummary.ID: ImportedPacketReference]
    let pins: [PacketPin]
    let savedPackets: [SavedPacketRecord]
    let customFilters: [PacketCustomFilter]
    let quickFilterSelection: PacketQuickFilterSelection
    let structuredFilterGroup: PacketStructuredFilterGroup
    let displayFilterText: String
    let sourceListFilterText: String
    let selectedPacketID: PacketSummary.ID?
    let selectedSourceListSelection: PacketSourceListSelection
    let workspaceMode: NetworkInspectorWorkspaceMode
    let inspectorTab: PacketInspectorTab
    let inspectorPlacement: NetworkInspectorPlacement
    let isInspectorVisible: Bool
    let isStructuredFilterVisible: Bool
    let tableColumnLayout: PacketTableColumnLayout?
    let sourceMetadata: TCPViewSessionSourceMetadata?

    var state: TCPViewSessionState {
        TCPViewSessionState(
            source: source?.rawValue,
            backingIdentity: backingIdentity,
            importedFiles: importedFiles.map(TCPViewSessionImportedFileRecord.init),
            importedPacketReferences: importedPacketReferenceByID
                .map { TCPViewSessionImportedPacketReferenceRecord(packetID: $0.key, reference: $0.value) }
                .sorted { $0.packetID < $1.packetID },
            pins: pins,
            savedPackets: savedPackets,
            customFilters: customFilters,
            quickFilterSelection: quickFilterSelection,
            structuredFilterGroup: structuredFilterGroup,
            displayFilterText: displayFilterText,
            sourceListFilterText: sourceListFilterText,
            selectedPacketID: selectedPacketID,
            selectedSourceListSelection: TCPViewSessionSourceListSelectionRecord(selection: selectedSourceListSelection),
            workspaceMode: workspaceMode.rawValue,
            inspectorTab: inspectorTab.rawValue,
            inspectorPlacement: inspectorPlacement.rawValue,
            isInspectorVisible: isInspectorVisible,
            isStructuredFilterVisible: isStructuredFilterVisible,
            tableColumnLayout: tableColumnLayout,
            importedFileProvenance: importedFiles.isEmpty ? nil : "Imported capture grouping is preserved for TCPViewer source-list reconstruction.",
            sourceMetadata: sourceMetadata
        )
    }
}

enum TCPViewSessionClientStoreBuilder {
    static func buildClientStore(
        packets: [PacketSummary],
        iconIDForClient: ((PacketClient) -> String?)? = nil
    ) -> (records: [TCPViewSessionPacketRecord], clients: TCPViewSessionClientStore) {
        var clientRecordByID: [String: TCPViewSessionClientRecord] = [:]
        var clientOrder: [String] = []
        var packetRecords: [TCPViewSessionPacketRecord] = []
        packetRecords.reserveCapacity(packets.count)

        for (ordinal, packet) in packets.enumerated() {
            let clientID = packet.client.map(stableClientID)
            if let client = packet.client, let clientID, clientRecordByID[clientID] == nil {
                clientRecordByID[clientID] = TCPViewSessionClientRecord(
                    id: clientID,
                    client: client,
                    iconID: iconIDForClient?(client)
                )
                clientOrder.append(clientID)
            }

            packetRecords.append(TCPViewSessionPacketRecord(
                packetID: packet.id,
                captureOrdinal: ordinal,
                clientID: clientID,
                packet: packet.tcpviewSessionPacketWithoutClient()
            ))
        }

        let clients = TCPViewSessionClientStore(
            clients: clientOrder.compactMap { clientRecordByID[$0] }
        )
        return (packetRecords, clients)
    }

    static func rehydratePackets(records: [TCPViewSessionPacketRecord], clients: TCPViewSessionClientStore) -> [PacketSummary] {
        var clientsByID: [String: PacketClient] = [:]
        for record in clients.clients where clientsByID[record.id] == nil {
            clientsByID[record.id] = record.client
        }
        return records
            .sorted { $0.captureOrdinal < $1.captureOrdinal }
            .map { record in
                record.packet.tcpviewSessionPacketWithClient(record.clientID.flatMap { clientsByID[$0] })
            }
    }

    static func stableClientID(for client: PacketClient) -> String {
        let fingerprint = [
            "\(client.pid)",
            client.name,
            client.displayName,
            client.executablePath ?? "",
            client.bundleIdentifier ?? "",
            client.bundlePath ?? "",
        ].joined(separator: "\u{1f}")
        return "client-\(fnv1a64Hex(fingerprint))"
    }

    static func stableIconID(for iconPath: String) -> String {
        "icon-\(fnv1a64Hex(iconPath))"
    }

    private static func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

extension PacketIngestState {
    func tcpviewSessionClientIconFilePath(for client: PacketClient?) -> String? {
        guard let client else {
            return nil
        }

        let clientID = TCPViewSessionClientStoreBuilder.stableClientID(for: client)
        return sessionClientIconFilePathByClientID[clientID]
    }
}

extension PacketSummary {
    func tcpviewSessionPacketWithoutClient() -> PacketSummary {
        tcpviewSessionPacketWithClient(nil)
    }

    func tcpviewSessionPacketWithClient(_ client: PacketClient?) -> PacketSummary {
        PacketSummary(
            id: id,
            packetNumber: packetNumber,
            timestamp: timestamp,
            source: source,
            interfaceID: interfaceID,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: endpoints,
            originalLength: originalLength,
            capturedLength: capturedLength,
            streamID: streamID,
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary,
            layers: layers,
            decodeStatus: decodeStatus,
            captureMetadata: captureMetadata,
            sniDomainName: sniDomainName,
            client: client,
            textStyle: textStyle,
            customComment: customComment
        )
    }
}
