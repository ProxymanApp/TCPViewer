//
//  TCPFollowStreamViewModel.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/8/26.
//

import AppKit
import PcapPlusPlusCore

enum TCPFollowDirectionFilter: Int, CaseIterable {
    case both
    case clientToServer
    case serverToClient
}

enum TCPFollowRepresentation: Int, CaseIterable {
    case text
    case hex
}

struct TCPFollowPacketRange {
    let range: NSRange
    let revealTarget: TCPFollowRevealTarget
}

struct TCPFollowRevealTarget: Equatable {
    let packetID: PacketSummary.ID
    let payload: Data
}

struct TCPFollowRenderedContent {
    let attributedText: NSAttributedString
    let plainText: String
    let packetRanges: [TCPFollowPacketRange]
    let displayedByteCount: Int
    let statusText: String
}

final class TCPFollowStreamViewModel {
    private static let defaultMaximumDisplayedPayloadBytes = 4 * 1_024 * 1_024
    private static let defaultMaximumDisplayedRecordCount = 10_000
    private static let minimumHexBytesPerLine = 16
    private static let maximumHexBytesPerLine = 64
    static let payloadFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let transcriptParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .leftToRight
        style.lineBreakMode = .byCharWrapping
        return style
    }()

    private(set) var stream: TCPFollowStream?
    private(set) var directionFilter: TCPFollowDirectionFilter = .both
    private(set) var representation: TCPFollowRepresentation = .text
    private(set) var hexBytesPerLine = TCPFollowStreamViewModel.minimumHexBytesPerLine
    private let maximumDisplayedPayloadBytes: Int
    private let maximumDisplayedRecordCount: Int

    init(
        maximumDisplayedPayloadBytes: Int = TCPFollowStreamViewModel.defaultMaximumDisplayedPayloadBytes,
        maximumDisplayedRecordCount: Int = TCPFollowStreamViewModel.defaultMaximumDisplayedRecordCount
    ) {
        self.maximumDisplayedPayloadBytes = max(maximumDisplayedPayloadBytes, 1)
        self.maximumDisplayedRecordCount = max(maximumDisplayedRecordCount, 1)
    }

    // Replace the current immutable stream snapshot.
    func setStream(_ stream: TCPFollowStream) {
        self.stream = stream
    }

    // Change which side of the conversation is displayed.
    func setDirectionFilter(_ filter: TCPFollowDirectionFilter) {
        directionFilter = filter
    }

    // Change payload rendering without repeating reassembly.
    func setRepresentation(_ representation: TCPFollowRepresentation) {
        self.representation = representation
    }

    // Keep hex rows aligned while using the available transcript width.
    func setHexBytesPerLine(_ byteCount: Int) {
        hexBytesPerLine = min(
            max(byteCount, Self.minimumHexBytesPerLine),
            Self.maximumHexBytesPerLine
        )
    }

    // Fit complete offset, hex, and ASCII columns, rounded to readable eight-byte groups.
    static func preferredHexBytesPerLine(for availableWidth: CGFloat) -> Int {
        let characterWidth = ("0" as NSString).size(withAttributes: [.font: payloadFont]).width
        guard availableWidth > 0, characterWidth > 0 else {
            return minimumHexBytesPerLine
        }
        let availableCharacters = max(Int(floor(availableWidth / characterWidth)) - 1, 0)
        let fittedByteCount = max((availableCharacters - 11) / 4, minimumHexBytesPerLine)
        let groupedByteCount = fittedByteCount - fittedByteCount % 8
        return min(max(groupedByteCount, minimumHexBytesPerLine), maximumHexBytesPerLine)
    }

    // Build one attributed transcript and packet-character index for the text view.
    func renderedContent() -> TCPFollowRenderedContent {
        guard let stream else {
            return TCPFollowRenderedContent(
                attributedText: NSAttributedString(string: ""),
                plainText: "",
                packetRanges: [],
                displayedByteCount: 0,
                statusText: "No stream loaded"
            )
        }

        let output = NSMutableAttributedString()
        var ranges: [TCPFollowPacketRange] = []
        var displayedByteCount = 0
        var displayIsLimited = false
        for record in stream.records where includes(record.direction) {
            guard ranges.count < maximumDisplayedRecordCount,
                  displayedByteCount < maximumDisplayedPayloadBytes else {
                displayIsLimited = true
                break
            }
            let remainingByteCount = maximumDisplayedPayloadBytes - displayedByteCount
            let displayedData = Data(record.data.prefix(remainingByteCount))
            let start = output.length
            append(record: record, data: displayedData, to: output)
            ranges.append(TCPFollowPacketRange(
                range: NSRange(location: start, length: output.length - start),
                revealTarget: TCPFollowRevealTarget(packetID: record.packetID, payload: record.data)
            ))
            displayedByteCount += displayedData.count
            if displayedData.count < record.data.count {
                displayIsLimited = true
                break
            }
        }

        let selectedByteCount = max(selectedByteCount(in: stream), displayedByteCount)
        let byteStatus = displayIsLimited
            ? "\(displayedByteCount.formatted()) of \(selectedByteCount.formatted()) bytes shown · display limited for responsiveness"
            : "\(displayedByteCount.formatted()) bytes"
        let truncation = stream.isTruncated ? " · truncated at safety limit" : ""
        let status = "\(byteStatus) · snapshot through packet \(stream.capturedThroughPacketID)\(truncation)"
        return TCPFollowRenderedContent(
            attributedText: output,
            plainText: output.string,
            packetRanges: ranges,
            displayedByteCount: displayedByteCount,
            statusText: status
        )
    }

    // Concatenate reassembled bytes for raw export in the selected direction.
    func rawData(for direction: TCPFollowDirection) -> Data {
        guard let stream else {
            return Data()
        }
        return Self.rawData(in: stream, for: direction)
    }

    // Keep raw export independent from the bounded on-screen representation.
    static func rawData(in stream: TCPFollowStream, for direction: TCPFollowDirection) -> Data {
        stream.records
            .filter { $0.direction == direction }
            .reduce(into: Data()) { $0.append($1.data) }
    }

    private func includes(_ direction: TCPFollowDirection) -> Bool {
        switch directionFilter {
        case .both:
            true
        case .clientToServer:
            direction == .clientToServer
        case .serverToClient:
            direction == .serverToClient
        }
    }

    // Format each reassembled record as an easily scannable conversation turn.
    private func append(record: TCPFollowRecord, data: Data, to output: NSMutableAttributedString) {
        let isClient = record.direction == .clientToServer
        let title = isClient ? "→ Client to Server" : "← Server to Client"
        let color: NSColor = isClient ? .systemBlue : .systemOrange
        let header = "\(title) · Packet \(record.packetID) · \(data.count.formatted()) B\n"
        output.append(NSAttributedString(
            string: header,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: Self.transcriptParagraphStyle,
            ]
        ))

        let payload = representation == .text ? text(data) : hex(data)
        output.append(NSAttributedString(
            string: payload,
            attributes: [
                .font: Self.payloadFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: Self.transcriptParagraphStyle,
            ]
        ))
        if !payload.hasSuffix("\n") {
            output.append(NSAttributedString(string: "\n"))
        }
        output.append(NSAttributedString(string: "\n"))
    }

    // Resolve the selected side's full reassembled count without overflowing Int.
    private func selectedByteCount(in stream: TCPFollowStream) -> Int {
        switch directionFilter {
        case .both:
            let (total, overflow) = stream.clientByteCount.addingReportingOverflow(stream.serverByteCount)
            return overflow ? Int.max : total
        case .clientToServer:
            return stream.clientByteCount
        case .serverToClient:
            return stream.serverByteCount
        }
    }

    // Preserve readable whitespace while replacing unsafe control scalars.
    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).unicodeScalars.reduce(into: "") { result, scalar in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("·")
            }
        }
    }

    // Render width-aware rows with offsets and an aligned ASCII gutter.
    private func hex(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }
        let bytes = [UInt8](data)
        let paddedHexLength = hexBytesPerLine * 3 - 1
        return stride(from: 0, to: bytes.count, by: hexBytesPerLine).map { offset in
            let line = Array(bytes[offset..<min(offset + hexBytesPerLine, bytes.count)])
            let hexBytes = line.map { String(format: "%02x", $0) }.joined(separator: " ")
            let paddedHex = hexBytes.padding(toLength: paddedHexLength, withPad: " ", startingAt: 0)
            let ascii = String(line.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08x  %@  %@", offset, paddedHex, ascii)
        }.joined(separator: "\n")
    }
}
