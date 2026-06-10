//
//  NativeCaptureFile.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 28/5/26.
//

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

    static func write(records: [NativePacketRecord], to url: URL, format: CaptureFileFormat) throws {
        let data: Data
        switch format {
        case .pcap:
            data = PcapWriter(records: records).data()
        case .pcapng:
            data = PcapNGWriter(records: records).data()
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
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
                    records: records,
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
            records: records,
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
                    name: options[2],
                    description: options[3]
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
                let interface = interfaces[metadataKey(interfaceID: interfaceID, section: section)]
                let timestampMicros = (timestampHigh << 32) | timestampLow
                records.append(NativePacketRecord(
                    identifier: packetNumber,
                    packetNumber: packetNumber,
                    timestamp: Date(timeIntervalSince1970: Double(timestampMicros) / 1_000_000.0),
                    rawBytes: packetData,
                    originalLength: originalLength,
                    linkLayerType: interface?.linkType ?? Libpcap.dltEthernet,
                    interfaceIdentifier: interface?.name,
                    interfaceName: interface?.name ?? interface?.description,
                    packetComment: nil
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
                    packetComment: nil
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
                captureApplication: nil,
                fileComment: nil
            ),
            skippedPacketCount: skippedPacketCount,
            partialLoadReason: partialLoadReason
        )
    }

    private struct SectionHeaderBlock {
        let totalLength: Int
        let littleEndian: Bool
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

        return SectionHeaderBlock(totalLength: totalLength, littleEndian: littleEndian)
    }

    private func readOptions(offset: Int, end: Int, littleEndian: Bool) -> [UInt16: String] {
        var cursor = offset
        var values: [UInt16: String] = [:]
        while cursor + 4 <= end {
            let code = readUInt16(at: cursor, littleEndian: littleEndian) ?? 0
            let length = Int(readUInt16(at: cursor + 2, littleEndian: littleEndian) ?? 0)
            cursor += 4
            if code == 0 || cursor + length > end {
                break
            }
            if let value = String(data: data.subdata(in: cursor..<(cursor + length)), encoding: .utf8) {
                values[code] = value
            }
            cursor += paddedLength(length)
        }
        return values
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

    func data() -> Data {
        var output = Data()
        output.appendLittleEndian(UInt32(0xa1b2c3d4))
        output.appendLittleEndian(UInt16(2))
        output.appendLittleEndian(UInt16(4))
        output.appendLittleEndian(Int32(0))
        output.appendLittleEndian(UInt32(0))
        output.appendLittleEndian(UInt32(65_535))
        output.appendLittleEndian(UInt32(records.first?.linkLayerType ?? Libpcap.dltEthernet))

        for record in records {
            let interval = record.timestamp.timeIntervalSince1970
            let seconds = UInt32(max(interval, 0))
            let micros = UInt32(max((interval - floor(interval)) * 1_000_000, 0))
            output.appendLittleEndian(seconds)
            output.appendLittleEndian(micros)
            output.appendLittleEndian(UInt32(record.rawBytes.count))
            output.appendLittleEndian(UInt32(record.originalLength))
            output.append(record.rawBytes)
        }
        return output
    }
}

private struct PcapNGWriter {
    let records: [NativePacketRecord]

    func data() -> Data {
        var output = Data()
        var sectionBody = Data()
        sectionBody.appendLittleEndian(UInt32(0x1a2b3c4d))
        sectionBody.appendLittleEndian(UInt16(1))
        sectionBody.appendLittleEndian(UInt16(0))
        sectionBody.appendLittleEndian(UInt64.max)
        appendBlock(type: 0x0a0d0d0a, body: sectionBody, to: &output)

        var interfaceBody = Data()
        interfaceBody.appendLittleEndian(UInt16(records.first?.linkLayerType ?? Libpcap.dltEthernet))
        interfaceBody.appendLittleEndian(UInt16(0))
        interfaceBody.appendLittleEndian(UInt32(65_535))
        interfaceBody.appendLittleEndian(UInt16(0))
        interfaceBody.appendLittleEndian(UInt16(0))
        appendBlock(type: 1, body: interfaceBody, to: &output)

        for record in records {
            var packetBody = Data()
            let timestamp = UInt64(max(record.timestamp.timeIntervalSince1970, 0) * 1_000_000)
            packetBody.appendLittleEndian(UInt32(0))
            packetBody.appendLittleEndian(UInt32(timestamp >> 32))
            packetBody.appendLittleEndian(UInt32(timestamp & 0xffff_ffff))
            packetBody.appendLittleEndian(UInt32(record.rawBytes.count))
            packetBody.appendLittleEndian(UInt32(record.originalLength))
            packetBody.append(record.rawBytes)
            packetBody.appendPcapNGPadding(for: record.rawBytes.count)
            packetBody.appendLittleEndian(UInt16(0))
            packetBody.appendLittleEndian(UInt16(0))
            appendBlock(type: 6, body: packetBody, to: &output)
        }
        return output
    }

    private func appendBlock(type: UInt32, body: Data, to output: inout Data) {
        let totalLength = UInt32(12 + body.count)
        output.appendLittleEndian(type)
        output.appendLittleEndian(totalLength)
        output.append(body)
        output.appendLittleEndian(totalLength)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendPcapNGPadding(for byteCount: Int) {
        let padding = (4 - (byteCount % 4)) % 4
        if padding > 0 {
            append(Data(repeating: 0, count: padding))
        }
    }
}
