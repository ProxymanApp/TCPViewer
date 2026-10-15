//
//  CaptureOverviewMarkdown.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Foundation

// Renders the Overview as GitHub-flavored Markdown, to paste into an issue, a chat or a doc.
enum CaptureOverviewMarkdown {
    static let busiestSlotCount = 5

    // Sections follow the visible cards, so the report matches what the user sees.
    static func render(
        _ snapshot: CaptureOverviewSnapshot,
        source: String,
        cards: [CaptureOverviewCard],
        generatedAt: Date
    ) -> String {
        var lines = [
            "# TCP Viewer Overview",
            "",
            "_\(escape(source)) · Generated on \(generatedAt.formatted(date: .abbreviated, time: .standard))_",
            "",
        ]
        guard snapshot.totals.packets > 0 else {
            lines.append("No packets were captured.")
            return lines.joined(separator: "\n") + "\n"
        }

        lines += summarySection(snapshot)
        var didRenderActivity = false
        for card in cards {
            switch card {
            case .packets, .throughput:
                // Both time charts share one table of the busiest slots.
                guard !didRenderActivity else {
                    continue
                }
                didRenderActivity = true
                lines += activitySection(snapshot)
            case .protocols:
                lines += protocolSection(snapshot)
            case .topApps:
                lines += sourceSection(card.title, nameTitle: "App", rows: snapshot.topApps, snapshot: snapshot)
            case .topDestinations:
                lines += sourceSection(card.title, nameTitle: "Destination", rows: snapshot.topDestinations, snapshot: snapshot)
            case .tcpAnalysis:
                lines += tcpAnalysisSection(snapshot)
            case .conversations:
                lines += conversationSection(snapshot)
            case .services:
                lines += serviceSection(snapshot)
            case .packetLengths:
                lines += packetLengthSection(snapshot)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // A fixed English date pattern, so file names sort the same whatever the user's calendar and digits.
    static func fileName(generatedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "TCP Viewer Overview \(formatter.string(from: generatedAt)).md"
    }

    // MARK: - Sections

    private static func summarySection(_ snapshot: CaptureOverviewSnapshot) -> [String] {
        let totals = snapshot.totals
        var rows: [[String]] = []
        if let first = snapshot.firstPacketDate, let last = snapshot.lastPacketDate {
            let span = max(0, last.timeIntervalSince(first))
            rows.append([
                "Captured",
                "\(dateTime(first)) – \(dateTime(last)) (\(CaptureOverviewFormat.span(span)))",
            ])
            if span >= 1 {
                rows.append(["Average throughput", CaptureOverviewFormat.rate(Double(totals.bytes) / span)])
            }
        }
        if let peak = snapshot.timeline.map(\.totals.bytes).max(), peak > 0 {
            rows.append(["Peak throughput", CaptureOverviewFormat.rate(Double(peak) / max(snapshot.timelineInterval, 1))])
        }
        rows.append(["Packets", CaptureOverviewFormat.count(totals.packets)])
        let data = totals.sentBytes > 0 || totals.receivedBytes > 0
            ? "\(bytes(totals.bytes)) (↑ \(bytes(totals.sentBytes)) · ↓ \(bytes(totals.receivedBytes)))"
            : bytes(totals.bytes)
        rows.append(["Data transferred", data])
        rows.append(["TCP packets", CaptureOverviewFormat.count(snapshot.tcpPacketCount)])
        // Same share as the Overview tile: issue packets out of TCP packets.
        rows.append([
            "TCP issues",
            "\(CaptureOverviewFormat.count(totals.issuePackets)) " +
                "(\(CaptureOverviewFormat.percent(totals.issuePackets, of: snapshot.tcpPacketCount)) of TCP packets)",
        ])
        rows.append(["Apps", CaptureOverviewFormat.count(UInt64(snapshot.appCount))])
        rows.append(["Domains", CaptureOverviewFormat.count(UInt64(snapshot.domainCount))])
        return table("Summary", columns: [("Metric", false), ("Value", false)], rows: rows)
    }

    // The busiest time slots, standing in for the two time charts.
    private static func activitySection(_ snapshot: CaptureOverviewSnapshot) -> [String] {
        let interval = max(snapshot.timelineInterval, 1)
        let busiest = snapshot.timeline
            .filter { $0.totals.packets > 0 }
            .sorted { lhs, rhs in
                lhs.totals.packets != rhs.totals.packets ? lhs.totals.packets > rhs.totals.packets : lhs.date < rhs.date
            }
            .prefix(busiestSlotCount)
        let rows = busiest.map { point in
            [
                "\(dateTime(point.date)) (+\(CaptureOverviewFormat.span(interval)))",
                CaptureOverviewFormat.count(point.totals.packets),
                CaptureOverviewFormat.count(point.totals.issuePackets),
                bytes(point.totals.bytes),
                CaptureOverviewFormat.rate(Double(point.totals.bytes) / interval),
            ]
        }
        return table(
            "Busiest Moments",
            columns: [("Time slot", false), ("Packets", true), ("TCP Issues", true), ("Data", true), ("Rate", true)],
            rows: rows
        )
    }

    // Bytes and packets per Protocol column value.
    private static func protocolSection(_ snapshot: CaptureOverviewSnapshot) -> [String] {
        let rows = snapshot.protocols.map { row in
            [
                row.title,
                CaptureOverviewFormat.count(row.totals.packets),
                bytes(row.totals.bytes),
                CaptureOverviewFormat.percent(row.totals.bytes, of: snapshot.totals.bytes),
            ]
        }
        return table(
            "Protocols",
            columns: [("Protocol", false), ("Packets", true), ("Data", true), ("Share", true)],
            rows: rows
        )
    }

    // A ranked table of apps or destinations.
    private static func sourceSection(
        _ title: String,
        nameTitle: String,
        rows: [CaptureOverviewTopRow],
        snapshot: CaptureOverviewSnapshot
    ) -> [String] {
        let tableRows = rows.enumerated().map { index, row in
            ["\(index + 1)", row.title] + trafficCells(row.totals, of: snapshot.totals)
        }
        return table(title, columns: [("#", true), (nameTitle, false)] + trafficColumns, rows: tableRows)
    }

    // Each Wireshark flag with its share and the filter that shows it.
    private static func tcpAnalysisSection(_ snapshot: CaptureOverviewSnapshot) -> [String] {
        guard !snapshot.tcpIssues.isEmpty else {
            let text = snapshot.tcpPacketCount > 0
                ? "No TCP problems detected in \(CaptureOverviewFormat.count(snapshot.tcpPacketCount)) TCP packets."
                : "No TCP traffic."
            return ["## \(CaptureOverviewCard.tcpAnalysis.title)", "", text, ""]
        }
        let rows = snapshot.tcpIssues.map { row in
            // Malformed packets can be any protocol; every other flag is a share of TCP packets.
            let base = row.kind == .malformed ? snapshot.totals.packets : snapshot.tcpPacketCount
            return [
                row.kind.title,
                CaptureOverviewFormat.count(row.packets),
                CaptureOverviewFormat.percent(row.packets, of: base),
                "`\(CaptureOverviewClassifier.displayFilter(for: row.kind))`",
            ]
        }
        return table(
            CaptureOverviewCard.tcpAnalysis.title,
            columns: [("Problem", false), ("Packets", true), ("Share", true), ("Wireshark filter", false)],
            rows: rows
        )
    }

    // The busiest conversations with both endpoints.
    private static func conversationSection(_ snapshot: CaptureOverviewSnapshot) -> [String] {
        let rows = snapshot.topConversations.enumerated().map { index, row in
            let endpoints = row.endpoints
            return [
                "\(index + 1)",
                EndpointStatisticsClassifier.transportKey(address: endpoints.clientAddress, port: endpoints.clientPort),
                EndpointStatisticsClassifier.transportKey(address: endpoints.serverAddress, port: endpoints.serverPort),
                endpoints.transport.rawValue,
                row.domainName ?? "–",
                row.appName ?? "–",
            ] + trafficCells(row.totals, of: snapshot.totals)
        }
        return table(
            CaptureOverviewCard.conversations.title,
            columns: [("#", true), ("Client", false), ("Server", false), ("Transport", false), ("Domain", false), ("App", false)]
                + trafficColumns,
            rows: rows
        )
    }

    // The busiest server ports with their service names.
    private static func serviceSection(_ snapshot: CaptureOverviewSnapshot) -> [String] {
        let rows = snapshot.topServices.enumerated().map { index, row in
            [
                "\(index + 1)",
                "\(row.key.port)/\(row.key.transport.rawValue)",
                CaptureOverviewClassifier.serviceName(for: row.key) ?? "–",
            ] + trafficCells(row.totals, of: snapshot.totals)
        }
        return table(
            CaptureOverviewCard.services.title,
            columns: [("#", true), ("Port", false), ("Service", false)] + trafficColumns,
            rows: rows
        )
    }

    // Non-empty Packet Lengths ranges.
    private static func packetLengthSection(_ snapshot: CaptureOverviewSnapshot) -> [String] {
        let rows = snapshot.packetLengthCounts.enumerated().compactMap { index, count -> [String]? in
            guard count > 0 else {
                return nil
            }
            return [
                CaptureOverviewClassifier.packetLengthTitle(forBucket: index),
                CaptureOverviewFormat.count(count),
                CaptureOverviewFormat.percent(count, of: snapshot.totals.packets),
            ]
        }
        return table(
            CaptureOverviewCard.packetLengths.title,
            columns: [("Length", false), ("Packets", true), ("Share", true)],
            rows: rows
        )
    }

    // MARK: - Helpers

    private static let trafficColumns: [(title: String, isNumeric: Bool)] = [
        ("Packets", true), ("Sent", true), ("Received", true), ("Total", true), ("Share", true), ("TCP Issues", true),
    ]

    // Packets, bytes per direction, share and issues for one ranked row.
    private static func trafficCells(_ totals: CaptureOverviewTrafficTotals, of all: CaptureOverviewTrafficTotals) -> [String] {
        [
            CaptureOverviewFormat.count(totals.packets),
            bytes(totals.sentBytes),
            bytes(totals.receivedBytes),
            bytes(totals.bytes),
            CaptureOverviewFormat.percent(totals.bytes, of: all.bytes),
            CaptureOverviewFormat.count(totals.issuePackets),
        ]
    }

    // Every cell is escaped here, because names and addresses come from capture data.
    private static func table(_ title: String, columns: [(title: String, isNumeric: Bool)], rows: [[String]]) -> [String] {
        guard !rows.isEmpty else {
            return []
        }
        var lines = [
            "## \(title)",
            "",
            "| " + columns.map { escape($0.title) }.joined(separator: " | ") + " |",
            "| " + columns.map { $0.isNumeric ? "---:" : "---" }.joined(separator: " | ") + " |",
        ]
        lines += rows.map { "| " + $0.map(escape).joined(separator: " | ") + " |" }
        lines.append("")
        return lines
    }

    // Keep untrusted text inside its table cell as plain text: no HTML, and no Markdown links or images
    // that could load a remote URL when the report is pasted into an issue or chat.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // Byte counts formatted like the Overview cards.
    private static func bytes(_ value: UInt64) -> String {
        CaptureOverviewFormat.bytes(value)
    }

    // Locale date and time for the report text.
    private static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
