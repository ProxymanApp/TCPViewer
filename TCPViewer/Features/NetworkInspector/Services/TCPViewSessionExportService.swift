//
//  TCPViewSessionExportService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/6/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore
import ZIPFoundation

protocol TCPViewSessionExportWriting: AnyObject {
    func writePackage(
        snapshot: TCPViewSessionExportSnapshot,
        captureFileURL: URL,
        to destinationURL: URL,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?
    ) throws
}

final class TCPViewSessionExportService: TCPViewSessionExportWriting {
    private let fileManager: FileManager
    private let bundle: Bundle
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.now = now
    }

    // Build the inspectable ZIP package in a staging directory before touching the destination file.
    func writePackage(
        snapshot: TCPViewSessionExportSnapshot,
        captureFileURL: URL,
        to destinationURL: URL,
        progress: PacketExportProgressHandler? = nil,
        shouldCancel: PacketExportCancellationCheck? = nil
    ) throws {
        let cancellationCheck = shouldCancel ?? { false }
        try throwIfCancelled(cancellationCheck)

        guard fileManager.fileExists(atPath: captureFileURL.path) else {
            throw TCPViewerCoreError(
                code: .offlineFileSaveFailed,
                message: "The temporary pcapng file could not be found."
            )
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("TCPViewSessionExport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: stagingRoot)
        }

        let packageURL = stagingRoot.appendingPathComponent(TCPViewSessionFormat.packageDirectoryName, isDirectory: true)
        let iconsDirectoryURL = packageURL.appendingPathComponent(TCPViewSessionFormat.iconsDirectoryPath, isDirectory: true)
        let zipURL = stagingRoot.appendingPathComponent("\(destinationURL.deletingPathExtension().lastPathComponent).zip")
        try fileManager.createDirectory(at: iconsDirectoryURL, withIntermediateDirectories: true)

        let totalUnits = max(snapshot.packets.count + 6, 1)
        var completedUnits = 0
        func report(_ units: Int = 0) {
            completedUnits = min(totalUnits, completedUnits + units)
            progress?(PacketExportProgress(exportedPacketCount: completedUnits, totalPacketCount: totalUnits))
        }

        try fileManager.copyItem(
            at: captureFileURL,
            to: packageURL.appendingPathComponent(TCPViewSessionFormat.capturePath)
        )
        report(1)

        let iconIDByClientID = writeIcons(for: snapshot.packets, to: iconsDirectoryURL)
        let storeResult = TCPViewSessionClientStoreBuilder.buildClientStore(
            packets: snapshot.packets,
            iconIDForClient: { client in
                iconIDByClientID[TCPViewSessionClientStoreBuilder.stableClientID(for: client)]
            }
        )

        try writePacketRecords(
            storeResult.records,
            to: packageURL.appendingPathComponent(TCPViewSessionFormat.packetsPath),
            completedUnits: &completedUnits,
            totalUnits: totalUnits,
            progress: progress,
            shouldCancel: cancellationCheck
        )
        try throwIfCancelled(cancellationCheck)

        try writeJSON(
            storeResult.clients,
            to: packageURL.appendingPathComponent(TCPViewSessionFormat.clientsPath)
        )
        report(1)

        try writeJSON(
            annotations(for: snapshot.packets),
            to: packageURL.appendingPathComponent(TCPViewSessionFormat.annotationsPath)
        )
        report(1)

        try writeJSON(
            snapshot.state,
            to: packageURL.appendingPathComponent(TCPViewSessionFormat.statePath)
        )
        report(1)

        let manifest = manifest(packetCount: snapshot.packets.count)
        try writeJSON(
            manifest,
            to: packageURL.appendingPathComponent(TCPViewSessionFormat.manifestPath)
        )
        report(1)

        try throwIfCancelled(cancellationCheck)
        let zipProgress = Progress(totalUnitCount: 100)
        try fileManager.zipItem(
            at: packageURL,
            to: zipURL,
            shouldKeepParent: true,
            compressionMethod: .deflate,
            progress: zipProgress
        )
        report(1)
        try throwIfCancelled(cancellationCheck)

        try atomicallyReplaceItem(at: destinationURL, with: zipURL)
    }

    private func manifest(packetCount: Int) -> TCPViewSessionManifest {
        TCPViewSessionManifest(
            createdAt: now(),
            applicationName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TCPViewer",
            applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            applicationBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            packetCount: packetCount
        )
    }

    private func annotations(for packets: [PacketSummary]) -> TCPViewSessionAnnotations {
        TCPViewSessionAnnotations(
            annotations: packets.compactMap { packet in
                guard packet.captureMetadata.packetComment != nil else {
                    return nil
                }
                return TCPViewSessionPacketAnnotation(
                    packetID: packet.id,
                    packetComment: packet.captureMetadata.packetComment,
                    customComment: nil,
                    colorHex: nil
                )
            }
        )
    }

    private func writePacketRecords(
        _ records: [TCPViewSessionPacketRecord],
        to url: URL,
        completedUnits: inout Int,
        totalUnits: Int,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck
    ) throws {
        let encoder = compactJSONEncoder()
        var data = Data()
        data.reserveCapacity(records.count * 512)

        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 512) {
                try throwIfCancelled(shouldCancel)
                progress?(PacketExportProgress(
                    exportedPacketCount: min(totalUnits, completedUnits + index),
                    totalPacketCount: totalUnits
                ))
            }
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }

        try data.write(to: url, options: .atomic)
        completedUnits = min(totalUnits, completedUnits + records.count)
        progress?(PacketExportProgress(exportedPacketCount: completedUnits, totalPacketCount: totalUnits))
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        try compactJSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func compactJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func writeIcons(for packets: [PacketSummary], to iconsDirectoryURL: URL) -> [String: String] {
        var iconIDByClientID: [String: String] = [:]
        var writtenIconIDs = Set<String>()

        for packet in packets {
            guard let client = packet.client,
                  let iconPath = PacketClientIconPathResolver.iconFilePath(for: client),
                  fileManager.fileExists(atPath: iconPath) else {
                continue
            }

            let clientID = TCPViewSessionClientStoreBuilder.stableClientID(for: client)
            let iconID = TCPViewSessionClientStoreBuilder.stableIconID(for: iconPath)
            iconIDByClientID[clientID] = iconID

            guard writtenIconIDs.insert(iconID).inserted else {
                continue
            }

            let iconURL = iconsDirectoryURL.appendingPathComponent("\(iconID).png")
            try? writePNGIcon(forFile: iconPath, to: iconURL)
        }

        return iconIDByClientID
    }

    private func writePNGIcon(forFile path: String, to url: URL) throws {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        guard let tiffData = icon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        try pngData.write(to: url, options: .atomic)
    }

    private func atomicallyReplaceItem(at destinationURL: URL, with stagedURL: URL) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let replacementURL = parentURL.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.moveItem(at: stagedURL, to: replacementURL)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: replacementURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: replacementURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: replacementURL)
            throw error
        }
    }

    private func throwIfCancelled(_ shouldCancel: PacketExportCancellationCheck) throws {
        guard shouldCancel() else {
            return
        }

        throw TCPViewerCoreError(code: .operationCancelled, message: "TCPViewer session export was cancelled.")
    }
}
