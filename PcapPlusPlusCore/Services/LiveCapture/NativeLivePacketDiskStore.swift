//
//  NativeLivePacketDiskStore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Foundation

private struct NativeLivePacketDiskEntry {
    let identifier: UInt64
    let packetNumber: UInt64
    let timestamp: Date
    let offset: UInt64
    let capturedLength: Int
    let originalLength: Int
    let linkLayerType: Int32
    let interfaceIdentifier: String?
    let interfaceName: String?
    let packetComment: String?
    let interfaceID: UInt32
    let sectionNumber: UInt32
    let pcapNGTimestampResolution: UInt8?
    let pcapNGTimestampOffsetSeconds: Int64
    let pcapNGTimestampRawValue: UInt64?
}

final class NativeLivePacketDiskStore {
    private let fileManager: FileManager
    private let backingFileURL: URL
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var entries: [NativeLivePacketDiskEntry] = []
    private var entryIndexByID: [UInt64: Int] = [:]
    private(set) var backingFileSize: UInt64 = 0

    init(fileManager: FileManager = .default, temporaryDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.backingFileURL = (temporaryDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("TCPViewerLivePacketStore-\(UUID().uuidString).bin")
    }

    deinit {
        reset()
    }

    var count: Int {
        entries.count
    }

    var fileExists: Bool {
        fileManager.fileExists(atPath: backingFileURL.path)
    }

    var filePath: String {
        backingFileURL.path
    }

    // Append packet bytes at EOF while retaining only compact metadata in memory.
    func append(_ record: NativePacketRecord) throws {
        try openHandlesIfNeeded()
        guard let writer else {
            throw NativeNSError(.fileWriteFailed, "The live packet backing store could not be opened for writing.")
        }

        do {
            try writer.write(contentsOf: record.rawBytes)
        } catch {
            throw NativeNSError(.fileWriteFailed, "The live packet backing store could not write packet \(record.identifier): \(error.localizedDescription)")
        }

        let entry = NativeLivePacketDiskEntry(
            identifier: record.identifier,
            packetNumber: record.packetNumber,
            timestamp: record.timestamp,
            offset: backingFileSize,
            capturedLength: record.rawBytes.count,
            originalLength: record.originalLength,
            linkLayerType: record.linkLayerType,
            interfaceIdentifier: record.interfaceIdentifier,
            interfaceName: record.interfaceName,
            packetComment: record.packetComment,
            interfaceID: record.interfaceID,
            sectionNumber: record.sectionNumber,
            pcapNGTimestampResolution: record.pcapNGTimestampResolution,
            pcapNGTimestampOffsetSeconds: record.pcapNGTimestampOffsetSeconds,
            pcapNGTimestampRawValue: record.pcapNGTimestampRawValue
        )
        entryIndexByID[record.identifier] = entries.count
        entries.append(entry)
        backingFileSize += UInt64(record.rawBytes.count)
    }

    // Rehydrate only the requested packet bytes from disk.
    func record(withIdentifier identifier: UInt64) throws -> NativePacketRecord {
        guard let index = entryIndexByID[identifier] else {
            throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the live backing store.")
        }
        return try record(for: entries[index])
    }

    func records(withIdentifiers identifiers: [UInt64]?) throws -> [NativePacketRecord] {
        guard let identifiers else {
            return try entries.map(record)
        }
        return try identifiers.compactMap { identifier in
            guard let index = entryIndexByID[identifier] else {
                return nil
            }
            return try record(for: entries[index])
        }
    }

    func records(matching identifiers: Set<UInt64>) throws -> [NativePacketRecord] {
        try entries.compactMap { entry in
            guard identifiers.contains(entry.identifier) else {
                return nil
            }
            return try record(for: entry)
        }
    }

    func records(upTo identifier: UInt64) throws -> [NativePacketRecord] {
        let limit = identifier == 0 ? UInt64.max : identifier
        return try entries.lazy.filter { $0.identifier <= limit }.map(record)
    }

    func offset(for identifier: UInt64) throws -> UInt64 {
        guard let index = entryIndexByID[identifier] else {
            throw NativeNSError(.fileReadFailed, "Packet \(identifier) is not available in the live backing store.")
        }
        return entries[index].offset
    }

    // Close and delete the temporary backing file so captured payloads do not outlive the session.
    func reset() {
        try? writer?.close()
        try? reader?.close()
        writer = nil
        reader = nil
        entries.removeAll(keepingCapacity: false)
        entryIndexByID.removeAll(keepingCapacity: false)
        backingFileSize = 0
        try? fileManager.removeItem(at: backingFileURL)
    }

    private func openHandlesIfNeeded() throws {
        guard writer == nil || reader == nil else {
            return
        }
        if !fileExists {
            guard fileManager.createFile(
                atPath: backingFileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw NativeNSError(.fileWriteFailed, "The live packet backing store could not be created.")
            }
        }
        do {
            writer = try FileHandle(forWritingTo: backingFileURL)
            reader = try FileHandle(forReadingFrom: backingFileURL)
            try writer?.seekToEnd()
        } catch {
            try? writer?.close()
            writer = nil
            reader = nil
            throw NativeNSError(.fileWriteFailed, "The live packet backing store could not be opened: \(error.localizedDescription)")
        }
    }

    private func record(for entry: NativeLivePacketDiskEntry) throws -> NativePacketRecord {
        guard entry.capturedLength >= 0 else {
            throw NativeNSError(.fileReadFailed, "Packet \(entry.identifier) has an invalid captured length.")
        }
        do {
            try openHandlesIfNeeded()
            guard let reader else {
                throw NativeNSError(.fileReadFailed, "The live packet backing store could not be opened for reading.")
            }
            try reader.seek(toOffset: entry.offset)
            let bytes = try reader.read(upToCount: entry.capturedLength) ?? Data()
            guard bytes.count == entry.capturedLength else {
                throw NativeNSError(.fileReadFailed, "Packet \(entry.identifier) is truncated in the live backing store.")
            }
            return NativePacketRecord(
                identifier: entry.identifier,
                packetNumber: entry.packetNumber,
                timestamp: entry.timestamp,
                rawBytes: bytes,
                originalLength: entry.originalLength,
                linkLayerType: entry.linkLayerType,
                interfaceIdentifier: entry.interfaceIdentifier,
                interfaceName: entry.interfaceName,
                packetComment: entry.packetComment,
                interfaceID: entry.interfaceID,
                sectionNumber: entry.sectionNumber,
                pcapNGTimestampResolution: entry.pcapNGTimestampResolution,
                pcapNGTimestampOffsetSeconds: entry.pcapNGTimestampOffsetSeconds,
                pcapNGTimestampRawValue: entry.pcapNGTimestampRawValue
            )
        } catch let error as NSError where error.domain == TCPViewerNativeErrorDomain {
            throw error
        } catch {
            throw NativeNSError(.fileReadFailed, "The live packet backing store could not read packet \(entry.identifier): \(error.localizedDescription)")
        }
    }
}
