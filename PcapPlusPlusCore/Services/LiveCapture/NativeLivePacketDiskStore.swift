//
//  NativeLivePacketDiskStore.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Darwin
import Foundation

fileprivate struct NativeLivePacketDiskEntry {
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
    var tcpStreamIdentifier: UInt32?
    var previousSameTCPStreamEntryIndex: Int?
}

final class NativeLivePacketDiskSnapshot: @unchecked Sendable {
    let capturedThroughPacketID: UInt64
    private let fileDescriptor: Int32
    private let entries: [NativeLivePacketDiskEntry]

    fileprivate init(fileDescriptor: Int32, entries: [NativeLivePacketDiskEntry], capturedThroughPacketID: UInt64) {
        self.fileDescriptor = fileDescriptor
        self.entries = entries
        self.capturedThroughPacketID = capturedThroughPacketID
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    // Rehydrate a bounded immutable snapshot without holding the live capture lock.
    func records(
        maximumBytes: Int,
        shouldCancel: TCPFollowCancellationCheck? = nil
    ) throws -> [NativePacketRecord] {
        var remainingBytes = max(maximumBytes, 1)
        var records: [NativePacketRecord] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            if shouldCancel?() == true {
                throw NativeNSError(.operationCancelled, "TCP stream reassembly was cancelled.")
            }
            guard entry.capturedLength <= remainingBytes else {
                throw NativeNSError(.unavailableFeature, "The TCP stream snapshot exceeds the \(maximumBytes)-byte input limit.")
            }
            remainingBytes -= entry.capturedLength
            let bytes = try readBytes(for: entry)
            records.append(NativePacketRecord(
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
            ))
        }
        return records
    }

    private func readBytes(for entry: NativeLivePacketDiskEntry) throws -> Data {
        var bytes = Data(count: entry.capturedLength)
        let bytesRead = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            var totalRead = 0
            while totalRead < entry.capturedLength {
                let count = Darwin.pread(
                    fileDescriptor,
                    baseAddress.advanced(by: totalRead),
                    entry.capturedLength - totalRead,
                    off_t(entry.offset) + off_t(totalRead)
                )
                guard count > 0 else {
                    return totalRead
                }
                totalRead += count
            }
            return totalRead
        }
        guard bytesRead == entry.capturedLength else {
            throw NativeNSError(.fileReadFailed, "Packet \(entry.identifier) is truncated in the live backing store.")
        }
        return bytes
    }
}

final class NativeLivePacketDiskStore {
    private let fileManager: FileManager
    private let backingFileURL: URL
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var entries: [NativeLivePacketDiskEntry] = []
    private var entryIndexByID: [UInt64: Int] = [:]
    private var latestEntryIndexByTCPStreamID: [UInt32: Int] = [:]
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
    func append(_ record: NativePacketRecord, tcpStreamIdentifier: UInt32? = nil) throws {
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
            pcapNGTimestampRawValue: record.pcapNGTimestampRawValue,
            tcpStreamIdentifier: nil,
            previousSameTCPStreamEntryIndex: nil
        )
        entryIndexByID[record.identifier] = entries.count
        entries.append(entry)
        if let tcpStreamIdentifier {
            markTCPStreamReady(identifier: record.identifier, streamIdentifier: tcpStreamIdentifier)
        }
        backingFileSize += UInt64(record.rawBytes.count)
    }

    // Publish the stream link only after Wireshark has accepted this packet into its first pass.
    func markTCPStreamReady(identifier: UInt64, streamIdentifier: UInt32) {
        guard let index = entryIndexByID[identifier], entries[index].tcpStreamIdentifier == nil else {
            return
        }
        entries[index].tcpStreamIdentifier = streamIdentifier
        entries[index].previousSameTCPStreamEntryIndex = latestEntryIndexByTCPStreamID[streamIdentifier]
        latestEntryIndexByTCPStreamID[streamIdentifier] = index
    }

    // Apply Wireshark's per-packet stream delta in capture order so dependency frames keep a valid chain.
    func markTCPStreamsReady(_ updates: [WiresharkTCPStreamIndexEntry]) {
        let orderedUpdates = updates.compactMap { update -> (index: Int, update: WiresharkTCPStreamIndexEntry)? in
            guard let index = entryIndexByID[update.packetIdentifier] else {
                return nil
            }
            return (index, update)
        }.sorted { $0.index < $1.index }

        for item in orderedUpdates {
            markTCPStreamReady(
                identifier: item.update.packetIdentifier,
                streamIdentifier: item.update.streamIdentifier
            )
        }
    }

    // Duplicate the anonymous backing file and copy only this stream's compact index chain.
    func snapshotForTCPStream(
        containing identifier: UInt64,
        maximumPacketCount: Int,
        shouldCancel: TCPFollowCancellationCheck? = nil
    ) throws -> NativeLivePacketDiskSnapshot {
        guard let selectedIndex = entryIndexByID[identifier],
              let streamIdentifier = entries[selectedIndex].tcpStreamIdentifier,
              var index = latestEntryIndexByTCPStreamID[streamIdentifier] else {
            throw NativeNSError(.unavailableFeature, "Select a TCP packet to follow its stream.")
        }

        var selectedEntries: [NativeLivePacketDiskEntry] = []
        while true {
            if shouldCancel?() == true {
                throw NativeNSError(.operationCancelled, "TCP stream reassembly was cancelled.")
            }
            selectedEntries.append(entries[index])
            if selectedEntries.count > maximumPacketCount {
                throw NativeNSError(
                    .unavailableFeature,
                    "This TCP stream has more than \(maximumPacketCount) packets."
                )
            }
            guard let previousIndex = entries[index].previousSameTCPStreamEntryIndex else {
                break
            }
            index = previousIndex
        }
        selectedEntries.reverse()

        try openHandlesIfNeeded()
        guard let reader else {
            throw NativeNSError(.fileReadFailed, "The live packet backing store could not be opened for reading.")
        }
        let descriptor = Darwin.dup(reader.fileDescriptor)
        guard descriptor >= 0 else {
            throw NativeNSError(.fileReadFailed, "The live packet backing store could not create a stable snapshot.")
        }
        return NativeLivePacketDiskSnapshot(
            fileDescriptor: descriptor,
            entries: selectedEntries,
            capturedThroughPacketID: entries.last?.identifier ?? identifier
        )
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

    // Read and release one packet payload at a time while rebuilding stateful dissector sessions.
    func forEachRecord(_ body: (NativePacketRecord) throws -> Void) throws {
        for entry in entries {
            try autoreleasepool {
                try body(record(for: entry))
            }
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
        latestEntryIndexByTCPStreamID.removeAll(keepingCapacity: false)
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
            // Keep packet payloads accessible only through open descriptors so crashes leave no named file behind.
            try fileManager.removeItem(at: backingFileURL)
        } catch {
            try? writer?.close()
            try? reader?.close()
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
