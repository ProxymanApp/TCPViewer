//
//  NativeCaptureFile.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 28/5/26.
//

import Darwin
import Foundation

struct NativeCaptureFile {
    var url: URL
    var format: CaptureFileFormat
    var records: [NativePacketRecord]
    var metadata: PCPPNativeCaptureDocumentMetadataDescriptor
    var skippedPacketCount: Int = 0
    var partialLoadReason: String?

    var isPartialResult: Bool {
        skippedPacketCount > 0 || partialLoadReason != nil
    }

    func loadSummaryMessage(prefix: String) -> String {
        var message = "\(prefix) \(records.count) packets from \(url.lastPathComponent)."
        if skippedPacketCount > 0 {
            message += " Skipped \(skippedPacketCount) malformed packet record\(skippedPacketCount == 1 ? "" : "s")."
        }
        if let partialLoadReason {
            message += " \(partialLoadReason)"
        }
        return message
    }

    static func load(from url: URL) throws -> NativeCaptureFile {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw NativeNSError(.fileReadFailed, "TCP Viewer could not read \(url.lastPathComponent).")
        }

        if data.starts(with: [0x0a, 0x0d, 0x0d, 0x0a]) {
            return try PcapNGReader(url: url, data: data).read()
        }
        return try PcapReader(url: url, data: data).read()
    }

    static func write(
        records: [NativePacketRecord],
        to url: URL,
        format: CaptureFileFormat,
        textStylesByPacketID: [PacketSummary.ID: PacketTextStyle] = [:],
        commentsByPacketID: [PacketSummary.ID: String] = [:]
    ) throws {
        let outputRecords = records.map { record in
            record.withMetadata(
                textStyle: textStylesByPacketID[record.identifier] ?? record.textStyle,
                packetComment: commentsByPacketID[record.identifier] ?? record.packetComment
            )
        }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NativeNSError(.fileWriteFailed, "TCP Viewer could not create a temporary export file.")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                switch format {
                case .pcap:
                    try PcapWriter(records: outputRecords).write(to: handle)
                case .pcapng:
                    try PcapNGWriter(records: outputRecords).write(to: handle)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            if format == .pcap {
                // Classic PCAP has no metadata field, so keep its optional file metadata best-effort.
                let hasStyles = outputRecords.contains { !$0.textStyle.isPlain }
                if !hasStyles || !PcapTextStyleExtendedAttribute.write(stylesFrom: outputRecords, to: url) {
                    PcapTextStyleExtendedAttribute.remove(from: url)
                }
                let hasComments = outputRecords.contains { $0.packetComment?.isEmpty == false }
                if !hasComments || !PcapCommentExtendedAttribute.write(commentsFrom: outputRecords, to: url) {
                    PcapCommentExtendedAttribute.remove(from: url)
                }
            }
        } catch let error as NSError where error.domain == TCPViewerNativeErrorDomain {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw NativeNSError(.fileWriteFailed, "TCP Viewer could not write \(url.lastPathComponent).")
        }
    }
}

private struct PcapReader {
    let url: URL
    let data: Data

    func read() throws -> NativeCaptureFile {
        guard data.count >= 24 else {
            throw NativeNSError(.fileReadFailed, "The capture file is shorter than a PCAP header.")
        }

        let magic = Array(data.prefix(4))
        let isLittleEndian: Bool
        let timestampScale: Double
        switch magic {
        case [0xd4, 0xc3, 0xb2, 0xa1]:
            isLittleEndian = true
            timestampScale = 1_000_000
        case [0xa1, 0xb2, 0xc3, 0xd4]:
            isLittleEndian = false
            timestampScale = 1_000_000
        case [0x4d, 0x3c, 0xb2, 0xa1]:
            isLittleEndian = true
            timestampScale = 1_000_000_000
        case [0xa1, 0xb2, 0x3c, 0x4d]:
            isLittleEndian = false
            timestampScale = 1_000_000_000
        default:
            throw NativeNSError(.fileReadFailed, "The capture file is not PCAP or PCAPNG.")
        }

        let linkType = Int32(readUInt32(at: 20, littleEndian: isLittleEndian) ?? UInt32(Libpcap.dltEthernet))
        var offset = 24
        var records: [NativePacketRecord] = []
        var packetNumber: UInt64 = 1
        while offset + 16 <= data.count {
            let timestampSeconds = readUInt32(at: offset, littleEndian: isLittleEndian) ?? 0
            let timestampFraction = readUInt32(at: offset + 4, littleEndian: isLittleEndian) ?? 0
            let capturedLength = Int(readUInt32(at: offset + 8, littleEndian: isLittleEndian) ?? 0)
            let originalLength = Int(readUInt32(at: offset + 12, littleEndian: isLittleEndian) ?? UInt32(capturedLength))
            offset += 16

            guard capturedLength >= 0, offset + capturedLength <= data.count else {
                return NativeCaptureFile(
                    url: url,
                    format: .pcap,
                    records: annotatedRecords(records),
                    metadata: metadata(),
                    skippedPacketCount: 1,
                    partialLoadReason: "Stopped at a truncated packet record."
                )
            }

            let rawBytes = data.subdata(in: offset..<(offset + capturedLength))
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampSeconds) + Double(timestampFraction) / timestampScale)
            records.append(NativePacketRecord(
                identifier: packetNumber,
                packetNumber: packetNumber,
                timestamp: timestamp,
                rawBytes: rawBytes,
                originalLength: originalLength,
                linkLayerType: linkType,
                interfaceIdentifier: nil,
                interfaceName: nil,
                packetComment: nil
            ))
            packetNumber += 1
            offset += capturedLength
        }

        let trailingByteCount = data.count - offset
        return NativeCaptureFile(
            url: url,
            format: .pcap,
            records: annotatedRecords(records),
            metadata: metadata(),
            skippedPacketCount: trailingByteCount > 0 ? 1 : 0,
            partialLoadReason: trailingByteCount > 0 ? "Stopped at an incomplete packet header." : nil
        )
    }

    private func metadata() -> PCPPNativeCaptureDocumentMetadataDescriptor {
        PCPPNativeCaptureDocumentMetadataDescriptor(
            format: CaptureFileFormat.pcap.rawValue,
            operatingSystem: nil,
            hardware: nil,
            captureApplication: nil,
            fileComment: nil
        )
    }

    private func annotatedRecords(_ records: [NativePacketRecord]) -> [NativePacketRecord] {
        let styles = PcapTextStyleExtendedAttribute.read(from: url, packetCount: records.count)
        let comments = PcapCommentExtendedAttribute.read(from: url, packetCount: records.count)
        guard !styles.isEmpty || !comments.isEmpty else {
            return records
        }
        return records.enumerated().map { index, record in
            record.withMetadata(
                textStyle: styles[index] ?? .plain,
                packetComment: comments[index]
            )
        }
    }

    private func readUInt32(at offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }
        let bytes = Array(data[offset..<(offset + 4)])
        if littleEndian {
            return UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}

private struct PcapNGReader {
    private struct Interface {
        let id: UInt32
        let section: UInt32
        let linkType: Int32
        let name: String?
        let description: String?
        let timestampResolution: UInt8
        let timestampOffsetSeconds: Int64
    }

    let url: URL
    let data: Data

    func read() throws -> NativeCaptureFile {
        guard data.count >= 12 else {
            throw NativeNSError(.fileReadFailed, "The PCAPNG section header is incomplete.")
        }

        var offset = 0
        var section: UInt32 = 0
        var hasSection = false
        var littleEndian = true
        var nextInterfaceID: UInt32 = 0
        var interfaces: [UInt64: Interface] = [:]
        var records: [NativePacketRecord] = []
        var packetNumber: UInt64 = 1
        var skippedPacketCount = 0
        var partialLoadReason: String?
        var captureApplication: String?
        var sectionSupportsTextStyles = false

        while offset + 12 <= data.count {
            let blockStart = offset
            // Section headers define their own byte order, so parse them before using section endian state.
            if isSectionHeaderBlock(at: blockStart) {
                let sectionHeader: SectionHeaderBlock
                do {
                    sectionHeader = try readSectionHeaderBlock(at: blockStart)
                } catch {
                    if !hasSection {
                        throw error
                    }

                    skippedPacketCount += 1
                    partialLoadReason = "Stopped at an invalid PCAPNG section header."
                    break
                }

                littleEndian = sectionHeader.littleEndian
                if hasSection {
                    section += 1
                }
                hasSection = true
                nextInterfaceID = 0
                captureApplication = captureApplication ?? sectionHeader.userApplication
                sectionSupportsTextStyles = PcapNGTextStyleComment.supports(
                    userApplication: sectionHeader.userApplication
                )
                offset = blockStart + sectionHeader.totalLength
                continue
            }

            guard hasSection else {
                throw NativeNSError(.fileReadFailed, "The PCAPNG file is missing a section header.")
            }

            let blockType = readUInt32(at: offset, littleEndian: littleEndian) ?? 0
            let totalLength = Int(readUInt32(at: offset + 4, littleEndian: littleEndian) ?? 0)
            guard totalLength >= 12, blockStart + totalLength <= data.count else {
                skippedPacketCount += 1
                partialLoadReason = "Stopped at an invalid PCAPNG block length."
                break
            }
            let bodyStart = offset + 8
            let bodyEnd = blockStart + totalLength - 4
            let trailingLength = Int(readUInt32(at: bodyEnd, littleEndian: littleEndian) ?? 0)
            let hasValidTrailingLength = trailingLength == totalLength

            if blockType == 1 {
                guard hasValidTrailingLength, bodyStart + 8 <= bodyEnd else {
                    skippedPacketCount += 1
                    offset = blockStart + totalLength
                    continue
                }
                let linkType = Int32(readUInt16(at: bodyStart, littleEndian: littleEndian) ?? UInt16(Libpcap.dltEthernet))
                let options = readOptions(offset: bodyStart + 8, end: bodyEnd, littleEndian: littleEndian)
                let interface = Interface(
                    id: nextInterfaceID,
                    section: section,
                    linkType: linkType,
                    name: options[2].flatMap { String(data: $0, encoding: .utf8) },
                    description: options[3].flatMap { String(data: $0, encoding: .utf8) },
                    timestampResolution: options[9]?.first ?? 6,
                    timestampOffsetSeconds: options[14].flatMap { readInt64(from: $0, littleEndian: littleEndian) } ?? 0
                )
                interfaces[metadataKey(interfaceID: nextInterfaceID, section: section)] = interface
                nextInterfaceID += 1
            } else if blockType == 6 {
                guard hasValidTrailingLength, bodyStart + 20 <= bodyEnd else {
                    skippedPacketCount += 1
                    offset = blockStart + totalLength
                    continue
                }
                let interfaceID = readUInt32(at: bodyStart, littleEndian: littleEndian) ?? 0
                let timestampHigh = UInt64(readUInt32(at: bodyStart + 4, littleEndian: littleEndian) ?? 0)
                let timestampLow = UInt64(readUInt32(at: bodyStart + 8, littleEndian: littleEndian) ?? 0)
                let capturedLength = Int(readUInt32(at: bodyStart + 12, littleEndian: littleEndian) ?? 0)
                let originalLength = Int(readUInt32(at: bodyStart + 16, littleEndian: littleEndian) ?? UInt32(capturedLength))
                let packetOffset = bodyStart + 20
                guard capturedLength >= 0, packetOffset + capturedLength <= bodyEnd else {
                    skippedPacketCount += 1
                    offset = blockStart + totalLength
                    continue
                }
                let packetData = data.subdata(in: packetOffset..<(packetOffset + capturedLength))
                let optionsOffset = packetOffset + paddedLength(capturedLength)
                let packetOptions = optionsOffset <= bodyEnd
                    ? readOptions(offset: optionsOffset, end: bodyEnd, littleEndian: littleEndian)
                    : [:]
                let comment = packetOptions[1].flatMap { String(data: $0, encoding: .utf8) }
                let decodedComment = PcapNGTextStyleComment.decode(
                    comment,
                    allowsTextStyleMetadata: sectionSupportsTextStyles
                )
                let interface = interfaces[metadataKey(interfaceID: interfaceID, section: section)]
                let timestampRaw = (timestampHigh << 32) | timestampLow
                let timestampResolution = interface?.timestampResolution ?? 6
                let timestampOffset = interface?.timestampOffsetSeconds ?? 0
                let unitsPerSecond = timestampUnitsPerSecond(resolution: timestampResolution)
                records.append(NativePacketRecord(
                    identifier: packetNumber,
                    packetNumber: packetNumber,
                    timestamp: Date(timeIntervalSince1970: Double(timestampRaw) / unitsPerSecond + Double(timestampOffset)),
                    rawBytes: packetData,
                    originalLength: originalLength,
                    linkLayerType: interface?.linkType ?? Libpcap.dltEthernet,
                    interfaceIdentifier: interface?.name,
                    interfaceName: interface?.name ?? interface?.description,
                    packetComment: decodedComment.packetComment,
                    interfaceID: interfaceID,
                    sectionNumber: section,
                    pcapNGTimestampResolution: timestampResolution,
                    pcapNGTimestampOffsetSeconds: timestampOffset,
                    pcapNGTimestampRawValue: timestampRaw,
                    textStyle: decodedComment.textStyle
                ))
                packetNumber += 1
            } else if blockType == 3 {
                guard hasValidTrailingLength, bodyStart + 4 <= bodyEnd else {
                    skippedPacketCount += 1
                    offset = blockStart + totalLength
                    continue
                }
                let originalLength = Int(readUInt32(at: bodyStart, littleEndian: littleEndian) ?? 0)
                let packetOffset = bodyStart + 4
                let capturedLength = min(originalLength, bodyEnd - packetOffset)
                let packetData = data.subdata(in: packetOffset..<(packetOffset + capturedLength))
                records.append(NativePacketRecord(
                    identifier: packetNumber,
                    packetNumber: packetNumber,
                    timestamp: Date(timeIntervalSince1970: 0),
                    rawBytes: packetData,
                    originalLength: originalLength,
                    linkLayerType: Libpcap.dltEthernet,
                    interfaceIdentifier: nil,
                    interfaceName: nil,
                    packetComment: nil,
                    interfaceID: 0,
                    sectionNumber: section
                ))
                packetNumber += 1
            }

            offset = blockStart + totalLength
        }

        if offset < data.count {
            skippedPacketCount += 1
            partialLoadReason = partialLoadReason ?? "Stopped at an incomplete PCAPNG block."
        }

        return NativeCaptureFile(
            url: url,
            format: .pcapng,
            records: records,
            metadata: PCPPNativeCaptureDocumentMetadataDescriptor(
                format: CaptureFileFormat.pcapng.rawValue,
                operatingSystem: nil,
                hardware: nil,
                captureApplication: captureApplication,
                fileComment: nil
            ),
            skippedPacketCount: skippedPacketCount,
            partialLoadReason: partialLoadReason
        )
    }

    private struct SectionHeaderBlock {
        let totalLength: Int
        let littleEndian: Bool
        let userApplication: String?
    }

    private func isSectionHeaderBlock(at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= data.count else {
            return false
        }

        return data[offset..<(offset + 4)].elementsEqual([0x0a, 0x0d, 0x0d, 0x0a])
    }

    private func readSectionHeaderBlock(at offset: Int) throws -> SectionHeaderBlock {
        guard offset + 12 <= data.count else {
            throw NativeNSError(.fileReadFailed, "The PCAPNG section header is incomplete.")
        }

        let magic = Array(data[(offset + 8)..<(offset + 12)])
        let littleEndian: Bool
        switch magic {
        case [0x4d, 0x3c, 0x2b, 0x1a]:
            littleEndian = true
        case [0x1a, 0x2b, 0x3c, 0x4d]:
            littleEndian = false
        default:
            throw NativeNSError(.fileReadFailed, "The PCAPNG section has an invalid byte-order magic.")
        }

        let totalLength = Int(readUInt32(at: offset + 4, littleEndian: littleEndian) ?? 0)
        guard totalLength >= 28, totalLength <= data.count - offset else {
            throw NativeNSError(.fileReadFailed, "The PCAPNG section header has an invalid block length.")
        }

        let trailingLengthOffset = offset + totalLength - 4
        let trailingLength = Int(readUInt32(at: trailingLengthOffset, littleEndian: littleEndian) ?? 0)
        guard trailingLength == totalLength else {
            throw NativeNSError(.fileReadFailed, "The PCAPNG section header has an invalid trailing length.")
        }

        let options = readOptions(
            offset: offset + 24,
            end: trailingLengthOffset,
            littleEndian: littleEndian
        )
        return SectionHeaderBlock(
            totalLength: totalLength,
            littleEndian: littleEndian,
            userApplication: options[4].flatMap { String(data: $0, encoding: .utf8) }
        )
    }

    private func readOptions(offset: Int, end: Int, littleEndian: Bool) -> [UInt16: Data] {
        var cursor = offset
        var values: [UInt16: Data] = [:]
        while cursor + 4 <= end {
            let code = readUInt16(at: cursor, littleEndian: littleEndian) ?? 0
            let length = Int(readUInt16(at: cursor + 2, littleEndian: littleEndian) ?? 0)
            cursor += 4
            if code == 0 || cursor + length > end {
                break
            }
            values[code] = data.subdata(in: cursor..<(cursor + length))
            cursor += paddedLength(length)
        }
        return values
    }

    private func timestampUnitsPerSecond(resolution: UInt8) -> Double {
        // PCAPNG uses the high bit to distinguish decimal and binary resolution.
        if resolution & 0x80 == 0 {
            return pow(10, Double(resolution))
        }
        return pow(2, Double(resolution & 0x7f))
    }

    private func readInt64(from data: Data, littleEndian: Bool) -> Int64? {
        // Decode if_tsoffset without relying on potentially unaligned integer loads.
        guard data.count == 8 else {
            return nil
        }
        var value: UInt64 = 0
        let bytes = [UInt8](data)
        for index in 0..<8 {
            let sourceIndex = littleEndian ? 7 - index : index
            value = (value << 8) | UInt64(bytes[sourceIndex])
        }
        return Int64(bitPattern: value)
    }

    private func metadataKey(interfaceID: UInt32, section: UInt32) -> UInt64 {
        (UInt64(section) << 32) | UInt64(interfaceID)
    }

    private func paddedLength(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    private func readUInt16(at offset: Int, littleEndian: Bool) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else {
            return nil
        }
        let bytes = Array(data[offset..<(offset + 2)])
        if littleEndian {
            return UInt16(bytes[1]) << 8 | UInt16(bytes[0])
        }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readUInt32(at offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }
        let bytes = Array(data[offset..<(offset + 4)])
        if littleEndian {
            return UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}

private struct PcapWriter {
    let records: [NativePacketRecord]

    // Stream records so export memory does not scale with capture size.
    func write(to handle: FileHandle) throws {
        let linkLayerTypes = Set(records.map(\.linkLayerType))
        guard linkLayerTypes.count <= 1 else {
            throw NativeNSError(.fileWriteFailed, "PCAP export cannot represent packets from interfaces with different link-layer types. Use PCAPNG instead.")
        }

        var header = Data()
        header.appendLittleEndian(UInt32(0xa1b2c3d4))
        header.appendLittleEndian(UInt16(2))
        header.appendLittleEndian(UInt16(4))
        header.appendLittleEndian(Int32(0))
        header.appendLittleEndian(UInt32(0))
        header.appendLittleEndian(UInt32(65_535))
        header.appendLittleEndian(UInt32(records.first?.linkLayerType ?? Libpcap.dltEthernet))
        try handle.write(contentsOf: header)

        for record in records {
            guard record.rawBytes.count <= Int(UInt32.max), record.originalLength >= 0, record.originalLength <= Int(UInt32.max) else {
                throw NativeNSError(.fileWriteFailed, "Packet \(record.identifier) is too large for PCAP.")
            }
            let interval = record.timestamp.timeIntervalSince1970
            guard interval.isFinite, interval >= 0, floor(interval) <= Double(UInt32.max) else {
                throw NativeNSError(.fileWriteFailed, "Packet \(record.identifier) has a timestamp that PCAP cannot represent.")
            }
            let seconds = UInt32(floor(interval))
            let micros = UInt32((interval - floor(interval)) * 1_000_000)
            var recordHeader = Data()
            recordHeader.appendLittleEndian(seconds)
            recordHeader.appendLittleEndian(micros)
            recordHeader.appendLittleEndian(UInt32(record.rawBytes.count))
            recordHeader.appendLittleEndian(UInt32(record.originalLength))
            try handle.write(contentsOf: recordHeader)
            try handle.write(contentsOf: record.rawBytes)
        }
    }
}

private struct PcapNGWriter {
    private struct InterfaceKey: Hashable {
        let sectionNumber: UInt32
        let interfaceID: UInt32
        let linkLayerType: Int32
        let name: String?
        let timestampResolution: UInt8
        let timestampOffsetSeconds: Int64
    }

    let records: [NativePacketRecord]

    // Stream blocks so export does not duplicate all packet payloads in one Data value.
    func write(to handle: FileHandle) throws {
        var sectionBody = Data()
        sectionBody.appendLittleEndian(UInt32(0x1a2b3c4d))
        sectionBody.appendLittleEndian(UInt16(1))
        sectionBody.appendLittleEndian(UInt16(0))
        sectionBody.appendLittleEndian(UInt64.max)
        try appendOption(
            code: 4,
            value: Data(PcapNGTextStyleComment.userApplication.utf8),
            to: &sectionBody
        )
        sectionBody.appendLittleEndian(UInt16(0))
        sectionBody.appendLittleEndian(UInt16(0))
        try writeBlock(type: 0x0a0d0d0a, body: sectionBody, to: handle)

        let defaultInterface = InterfaceKey(
            sectionNumber: 0,
            interfaceID: 0,
            linkLayerType: Libpcap.dltEthernet,
            name: nil,
            timestampResolution: 6,
            timestampOffsetSeconds: 0
        )
        let interfaceKeys = orderedInterfaceKeys(defaultInterface: defaultInterface)
        let interfaceIDs = Dictionary(uniqueKeysWithValues: interfaceKeys.enumerated().map { ($0.element, UInt32($0.offset)) })

        for interface in interfaceKeys {
            guard interface.linkLayerType >= 0, interface.linkLayerType <= Int32(UInt16.max) else {
                throw NativeNSError(.fileWriteFailed, "Interface \(interface.interfaceID) has a link-layer type that PCAPNG cannot represent.")
            }
            var interfaceBody = Data()
            interfaceBody.appendLittleEndian(UInt16(interface.linkLayerType))
            interfaceBody.appendLittleEndian(UInt16(0))
            interfaceBody.appendLittleEndian(UInt32(65_535))
            if let name = interface.name, !name.isEmpty {
                try appendOption(code: 2, value: Data(name.utf8), to: &interfaceBody)
            }
            try appendOption(code: 9, value: Data([interface.timestampResolution]), to: &interfaceBody)
            if interface.timestampOffsetSeconds != 0 {
                var offset = Data()
                offset.appendLittleEndian(interface.timestampOffsetSeconds)
                try appendOption(code: 14, value: offset, to: &interfaceBody)
            }
            interfaceBody.appendLittleEndian(UInt16(0))
            interfaceBody.appendLittleEndian(UInt16(0))
            try writeBlock(type: 1, body: interfaceBody, to: handle)
        }

        for record in records {
            let interface = interfaceKey(for: record)
            guard let interfaceID = interfaceIDs[interface] else {
                throw NativeNSError(.fileWriteFailed, "Packet \(record.identifier) references an unknown interface.")
            }
            let paddingCount = (4 - (record.rawBytes.count % 4)) % 4
            guard record.rawBytes.count <= Int(UInt32.max) - 36 - paddingCount,
                  record.originalLength >= 0,
                  record.originalLength <= Int(UInt32.max) else {
                throw NativeNSError(.fileWriteFailed, "Packet \(record.identifier) is too large for PCAPNG.")
            }
            let timestamp = try timestampValue(for: record, interface: interface)
            var options = Data()
            if let comment = PcapNGTextStyleComment.encode(
                packetComment: record.packetComment,
                textStyle: record.textStyle
            ) {
                try appendOption(code: 1, value: Data(comment.utf8), to: &options)
            }
            options.appendLittleEndian(UInt16(0))
            options.appendLittleEndian(UInt16(0))
            let bodyLength = 20 + record.rawBytes.count + paddingCount + options.count
            guard bodyLength <= Int(UInt32.max) - 12 else {
                throw NativeNSError(.fileWriteFailed, "Packet \(record.identifier) metadata is too large for PCAPNG.")
            }
            let totalLength = UInt32(12 + bodyLength)
            var packetHeader = Data()
            packetHeader.appendLittleEndian(UInt32(6))
            packetHeader.appendLittleEndian(totalLength)
            packetHeader.appendLittleEndian(interfaceID)
            packetHeader.appendLittleEndian(UInt32(timestamp >> 32))
            packetHeader.appendLittleEndian(UInt32(timestamp & 0xffff_ffff))
            packetHeader.appendLittleEndian(UInt32(record.rawBytes.count))
            packetHeader.appendLittleEndian(UInt32(record.originalLength))
            try handle.write(contentsOf: packetHeader)
            try handle.write(contentsOf: record.rawBytes)
            if paddingCount > 0 {
                try handle.write(contentsOf: Data(repeating: 0, count: paddingCount))
            }
            try handle.write(contentsOf: options)
            var trailer = Data()
            trailer.appendLittleEndian(totalLength)
            try handle.write(contentsOf: trailer)
        }
    }

    private func orderedInterfaceKeys(defaultInterface: InterfaceKey) -> [InterfaceKey] {
        // Preserve first-seen interface order while remapping IDs into one output section.
        guard !records.isEmpty else {
            return [defaultInterface]
        }
        var seen: Set<InterfaceKey> = []
        return records.compactMap { record in
            let key = interfaceKey(for: record)
            return seen.insert(key).inserted ? key : nil
        }
    }

    private func interfaceKey(for record: NativePacketRecord) -> InterfaceKey {
        // Include timestamp semantics because each PCAPNG interface owns those options.
        InterfaceKey(
            sectionNumber: record.sectionNumber,
            interfaceID: record.interfaceID,
            linkLayerType: record.linkLayerType,
            name: record.interfaceName ?? record.interfaceIdentifier,
            timestampResolution: record.pcapNGTimestampResolution ?? 6,
            timestampOffsetSeconds: record.pcapNGTimestampOffsetSeconds
        )
    }

    private func timestampValue(for record: NativePacketRecord, interface: InterfaceKey) throws -> UInt64 {
        // Prefer the source integer timestamp to avoid precision loss during round trips.
        if let rawValue = record.pcapNGTimestampRawValue {
            return rawValue
        }
        let unitsPerSecond: Double
        if interface.timestampResolution & 0x80 == 0 {
            unitsPerSecond = pow(10, Double(interface.timestampResolution))
        } else {
            unitsPerSecond = pow(2, Double(interface.timestampResolution & 0x7f))
        }
        let relativeTimestamp = (record.timestamp.timeIntervalSince1970 - Double(interface.timestampOffsetSeconds)) * unitsPerSecond
        // UInt64.max rounds to 2^64 as Double, so use an exclusive upper bound before conversion.
        guard relativeTimestamp.isFinite,
              relativeTimestamp >= 0,
              relativeTimestamp < 18_446_744_073_709_551_616.0 else {
            throw NativeNSError(.fileWriteFailed, "Packet \(record.identifier) has a timestamp that PCAPNG cannot represent.")
        }
        return UInt64(relativeTimestamp.rounded())
    }

    private func appendOption(code: UInt16, value: Data, to body: inout Data) throws {
        // PCAPNG options use a 16-bit length and four-byte padding.
        guard value.count <= Int(UInt16.max) else {
            throw NativeNSError(.fileWriteFailed, "A PCAPNG interface option is too large.")
        }
        body.appendLittleEndian(code)
        body.appendLittleEndian(UInt16(value.count))
        body.append(value)
        let paddingCount = (4 - (value.count % 4)) % 4
        if paddingCount > 0 {
            body.append(Data(repeating: 0, count: paddingCount))
        }
    }

    private func writeBlock(type: UInt32, body: Data, to handle: FileHandle) throws {
        // Write the duplicated block length around the body as required by PCAPNG.
        guard body.count <= Int(UInt32.max) - 12 else {
            throw NativeNSError(.fileWriteFailed, "A PCAPNG block is too large.")
        }
        let totalLength = UInt32(12 + body.count)
        var header = Data()
        header.appendLittleEndian(type)
        header.appendLittleEndian(totalLength)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: body)
        var trailer = Data()
        trailer.appendLittleEndian(totalLength)
        try handle.write(contentsOf: trailer)
    }
}

private enum PcapNGTextStyleComment {
    static let userApplication = "TCPViewer"

    private static let markerPrefix = "[TCPViewer:text-style:v2:"
    private static let markerSuffix = "]"

    static func supports(userApplication: String?) -> Bool {
        userApplication == Self.userApplication
    }

    static func encode(packetComment: String?, textStyle: PacketTextStyle) -> String? {
        let comment = packetComment.map(escapingMarkerLines(in:))
        guard !textStyle.isPlain else {
            return comment?.isEmpty == false ? comment : nil
        }

        let color = textStyle.highlightColor?.rawValue ?? "none"
        let marker = "\(markerPrefix)\(color):\(textStyle.isStrikethrough ? 1 : 0)\(markerSuffix)"
        guard let comment, !comment.isEmpty else {
            return marker
        }
        return "\(comment)\n\(marker)"
    }

    static func decode(
        _ value: String?,
        allowsTextStyleMetadata: Bool
    ) -> (packetComment: String?, textStyle: PacketTextStyle) {
        guard let value else {
            return (nil, .plain)
        }
        guard allowsTextStyleMetadata else {
            return (value.isEmpty ? nil : value, .plain)
        }

        var style = PacketTextStyle.plain
        var retainedLines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let marker = retainedLines.last,
           let decodedStyle = textStyle(fromMarker: marker) {
            style = decodedStyle
            retainedLines.removeLast()
        }
        let packetComment = retainedLines
            .map(unescapingMarkerLine(_:))
            .joined(separator: "\n")
        return (packetComment.isEmpty ? nil : packetComment, style)
    }

    private static func escapingMarkerLines(in comment: String) -> String {
        comment
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let line = String(line)
                return hasMarkerPrefixAfterEscapes(line) ? "\\\(line)" : line
            }
            .joined(separator: "\n")
    }

    private static func unescapingMarkerLine(_ line: String) -> String {
        line.first == "\\" && hasMarkerPrefixAfterEscapes(line) ? String(line.dropFirst()) : line
    }

    private static func hasMarkerPrefixAfterEscapes(_ line: String) -> Bool {
        line.drop(while: { $0 == "\\" }).hasPrefix(markerPrefix)
    }

    private static func textStyle(fromMarker line: String) -> PacketTextStyle? {
        guard line.hasPrefix(markerPrefix), line.hasSuffix(markerSuffix) else {
            return nil
        }
        let payload = line.dropFirst(markerPrefix.count).dropLast(markerSuffix.count)
        let components = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[1] == "0" || components[1] == "1" else {
            return nil
        }
        let color = components[0] == "none" ? nil : PacketHighlightColor(rawValue: String(components[0]))
        guard components[0] == "none" || color != nil else {
            return nil
        }
        return PacketTextStyle(highlightColor: color, isStrikethrough: components[1] == "1")
    }
}

private enum PcapTextStyleExtendedAttribute {
    private static let name = "com.proxyman.TCPViewer.packet-text-styles"
    private static let magic = Data("TCPVSTY1".utf8)
    private static let headerLength = magic.count + 8
    private static let entryLength = 9

    static func write(stylesFrom records: [NativePacketRecord], to url: URL) -> Bool {
        var data = magic
        data.appendLittleEndian(UInt64(records.count))
        for (index, record) in records.enumerated() where !record.textStyle.isPlain {
            data.appendLittleEndian(UInt64(index))
            data.append(PacketTextStyleBinaryCodec.encode(record.textStyle))
        }

        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        return result == 0
    }

    static func read(from url: URL, packetCount: Int) -> [Int: PacketTextStyle] {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length >= headerLength else {
            return [:]
        }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == length, data.starts(with: magic),
              data.readLittleEndianUInt64(at: magic.count) == UInt64(packetCount),
              (data.count - headerLength).isMultiple(of: entryLength) else {
            return [:]
        }

        var styles: [Int: PacketTextStyle] = [:]
        var offset = headerLength
        while offset + entryLength <= data.count {
            guard let ordinal = data.readLittleEndianUInt64(at: offset),
                  ordinal < UInt64(packetCount),
                  let style = PacketTextStyleBinaryCodec.decode(data[offset + 8]) else {
                return [:]
            }
            styles[Int(ordinal)] = style
            offset += entryLength
        }
        return styles
    }

    static func remove(from url: URL) {
        _ = removexattr(url.path, name, 0)
    }

}

private enum PcapCommentExtendedAttribute {
    private static let name = "com.proxyman.TCPViewer.packet-comments"
    private static let magic = Data("TCPVCMT1".utf8)
    private static let headerLength = magic.count + 8

    static func write(commentsFrom records: [NativePacketRecord], to url: URL) -> Bool {
        var data = magic
        data.appendLittleEndian(UInt64(records.count))
        for (index, record) in records.enumerated() {
            guard let comment = record.packetComment, !comment.isEmpty else {
                continue
            }
            let commentData = Data(comment.utf8)
            guard commentData.count <= Int(UInt32.max) else {
                return false
            }
            data.appendLittleEndian(UInt64(index))
            data.appendLittleEndian(UInt32(commentData.count))
            data.append(commentData)
        }

        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        return result == 0
    }

    static func read(from url: URL, packetCount: Int) -> [Int: String] {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length >= headerLength else {
            return [:]
        }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == length, data.starts(with: magic),
              data.readLittleEndianUInt64(at: magic.count) == UInt64(packetCount) else {
            return [:]
        }

        var comments: [Int: String] = [:]
        var offset = headerLength
        while offset < data.count {
            guard let ordinal = data.readLittleEndianUInt64(at: offset),
                  let commentLength = data.readLittleEndianUInt32(at: offset + 8),
                  ordinal < UInt64(packetCount) else {
                return [:]
            }
            let commentStart = offset + 12
            let commentEnd = commentStart + Int(commentLength)
            guard commentEnd <= data.count,
                  let comment = String(data: data[commentStart..<commentEnd], encoding: .utf8) else {
                return [:]
            }
            comments[Int(ordinal)] = comment
            offset = commentEnd
        }
        return comments
    }

    static func remove(from url: URL) {
        _ = removexattr(url.path, name, 0)
    }
}

enum PacketTextStyleBinaryCodec {
    static func encode(_ style: PacketTextStyle) -> UInt8 {
        colorCode(style.highlightColor) | (style.isStrikethrough ? 0x80 : 0)
    }

    static func decode(_ byte: UInt8) -> PacketTextStyle? {
        let colorValue = Int(byte & 0x7f)
        let decodedColor = color(from: UInt8(colorValue))
        guard decodedColor.isValid else {
            return nil
        }
        let style = PacketTextStyle(
            highlightColor: decodedColor.color,
            isStrikethrough: byte & 0x80 != 0
        )
        return style.isPlain ? nil : style
    }

    private static func colorCode(_ color: PacketHighlightColor?) -> UInt8 {
        switch color {
        case nil: 0
        case .red: 1
        case .orange: 2
        case .yellow: 3
        case .green: 4
        case .teal: 5
        case .blue: 6
        case .indigo: 7
        case .purple: 8
        case .pink: 9
        case .brown: 10
        case .gray: 11
        }
    }

    private static func color(from code: UInt8) -> (isValid: Bool, color: PacketHighlightColor?) {
        switch code {
        case 0: (true, nil)
        case 1: (true, .red)
        case 2: (true, .orange)
        case 3: (true, .yellow)
        case 4: (true, .green)
        case 5: (true, .teal)
        case 6: (true, .blue)
        case 7: (true, .indigo)
        case 8: (true, .purple)
        case 9: (true, .pink)
        case 10: (true, .brown)
        case 11: (true, .gray)
        default: (false, nil)
        }
    }
}

private extension NativePacketRecord {
    func withMetadata(textStyle: PacketTextStyle, packetComment: String?) -> NativePacketRecord {
        NativePacketRecord(
            identifier: identifier,
            packetNumber: packetNumber,
            timestamp: timestamp,
            rawBytes: rawBytes,
            originalLength: originalLength,
            linkLayerType: linkLayerType,
            interfaceIdentifier: interfaceIdentifier,
            interfaceName: interfaceName,
            packetComment: packetComment,
            interfaceID: interfaceID,
            sectionNumber: sectionNumber,
            pcapNGTimestampResolution: pcapNGTimestampResolution,
            pcapNGTimestampOffsetSeconds: pcapNGTimestampOffsetSeconds,
            pcapNGTimestampRawValue: pcapNGTimestampRawValue,
            textStyle: textStyle
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }

    func readLittleEndianUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else {
            return nil
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[offset + index]) << UInt32(index * 8)
        }
        return value
    }

}
