//
//  CaptureOverviewMarkdownTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Foundation
import PcapPlusPlusCore
import Testing
@testable import TCPViewer

struct CaptureOverviewMarkdownTests {
    private let generatedAt = Date(timeIntervalSince1970: 2_000)

    @Test func emptyCaptureSaysSoWithoutTables() {
        let markdown = CaptureOverviewMarkdown.render(
            .empty,
            source: "Live capture on Wi-Fi (en0)",
            cards: CaptureOverviewCard.defaults,
            generatedAt: generatedAt
        )

        #expect(markdown.hasPrefix("# TCP Viewer Overview\n"))
        #expect(markdown.contains("No packets were captured."))
        #expect(!markdown.contains("| "))
    }

    @Test func sectionsFollowTheVisibleCardsInOrder() {
        let markdown = CaptureOverviewMarkdown.render(
            makeSnapshot(),
            source: "capture.pcapng",
            cards: [.services, .topApps, .packets, .throughput],
            generatedAt: generatedAt
        )
        let headings = markdown.split(separator: "\n").filter { $0.hasPrefix("## ") }

        // Both time charts share one "Busiest Moments" table; hidden cards add nothing.
        #expect(headings == ["## Summary", "## Services & Ports", "## Top Apps", "## Busiest Moments"])
        #expect(markdown.contains("| 1 | 443/TCP | HTTPS | 10 |"))
    }

    @Test func capturedNamesStayInsideTheirCellsAndNeverBecomeHTML() {
        let markdown = CaptureOverviewMarkdown.render(
            makeSnapshot(appTitle: "Evil | <script>\nApp"),
            source: "a|b.pcap",
            cards: [.topApps],
            generatedAt: generatedAt
        )

        #expect(markdown.contains("| 1 | Evil \\| &lt;script&gt; App | 10 |"))
        #expect(markdown.contains("_a\\|b.pcap · Generated on"))
        #expect(!markdown.contains("<script>"))
    }

    @Test func capturedNamesCannotBecomeLinksOrImages() {
        let markdown = CaptureOverviewMarkdown.render(
            makeSnapshot(appTitle: "![x](https://attacker.example/pixel) [click](https://attacker.example)"),
            source: "capture.pcapng",
            cards: [.topApps],
            generatedAt: generatedAt
        )

        #expect(markdown.contains("!\\[x\\](https://attacker.example/pixel) \\[click\\](https://attacker.example)"))
        #expect(!markdown.contains("![x]("))
        #expect(!markdown.contains("[click]("))
    }

    @Test func summaryReportsTCPIssuesAsAShareOfTCPPackets() {
        let markdown = CaptureOverviewMarkdown.render(
            makeSnapshot(tcpIssues: [CaptureOverviewTCPIssueRow(kind: .retransmission, packets: 2)]),
            source: "capture.pcapng",
            cards: [],
            generatedAt: generatedAt
        )

        #expect(markdown.contains("| TCP issues | 2 (25% of TCP packets) |"))
    }

    @Test func tcpAnalysisRowsCarryTheirWiresharkFilter() {
        let flagged = CaptureOverviewMarkdown.render(
            makeSnapshot(tcpIssues: [CaptureOverviewTCPIssueRow(kind: .retransmission, packets: 2)]),
            source: "capture.pcapng",
            cards: [.tcpAnalysis],
            generatedAt: generatedAt
        )
        #expect(flagged.contains(
            "| Retransmissions | 2 | 25% | `tcp.analysis.retransmission \\|\\| tcp.analysis.fast_retransmission " +
                "\\|\\| tcp.analysis.spurious_retransmission` |"
        ))

        let clean = CaptureOverviewMarkdown.render(
            makeSnapshot(),
            source: "capture.pcapng",
            cards: [.tcpAnalysis],
            generatedAt: generatedAt
        )
        #expect(clean.contains("No TCP problems detected in 8 TCP packets."))
    }

    @Test func conversationsListBothEndpointsWithIPv6Brackets() {
        let markdown = CaptureOverviewMarkdown.render(
            makeSnapshot(),
            source: "capture.pcapng",
            cards: [.conversations],
            generatedAt: generatedAt
        )

        // Escaped brackets still render as "[fe80::1]:51000".
        #expect(markdown.contains("| 1 | \\[fe80::1\\]:51000 | \\[2001:db8::1\\]:443 | TCP | api.example | Browser | 10 |"))
    }

    @Test func fileNameUsesAFixedDatePattern() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 18, minute: 5, second: 8)))

        #expect(CaptureOverviewMarkdown.fileName(generatedAt: date) == "TCP Viewer Overview 2026-10-15 at 18.05.08.md")
    }

    private func makeSnapshot(
        appTitle: String = "Browser",
        tcpIssues: [CaptureOverviewTCPIssueRow] = []
    ) -> CaptureOverviewSnapshot {
        let totals = CaptureOverviewTrafficTotals(
            packets: 10,
            bytes: 1_000,
            sentPackets: 4,
            sentBytes: 400,
            receivedPackets: 6,
            receivedBytes: 600,
            issuePackets: tcpIssues.reduce(0) { $0 + $1.packets }
        )
        let domain = PacketSourceDomainKey(rawValue: "api.example", isMissingDomain: false)
        return CaptureOverviewSnapshot(
            totals: totals,
            firstPacketDate: Date(timeIntervalSince1970: 1_000),
            lastPacketDate: Date(timeIntervalSince1970: 1_010),
            appCount: 1,
            domainCount: 1,
            malformedPacketCount: 0,
            tcpPacketCount: 8,
            topApps: [
                CaptureOverviewTopRow(
                    id: "bundleIdentifier:com.example.browser",
                    title: appTitle,
                    iconFilePath: nil,
                    selection: .app(PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.browser")),
                    totals: totals
                ),
            ],
            topDestinations: [
                CaptureOverviewTopRow(id: "domain:api.example", title: "api.example", iconFilePath: nil, selection: .domain(domain), totals: totals),
            ],
            protocols: [CaptureOverviewProtocolRow(id: "TLSv1.3", title: "TLSv1.3", totals: totals)],
            tcpIssues: tcpIssues,
            topServices: [CaptureOverviewServiceRow(key: CaptureOverviewServiceKey(transport: .tcp, port: 443), totals: totals)],
            topConversations: [
                CaptureOverviewConversationRow(
                    key: .stream(FollowStreamID(streamProtocol: .tcp, streamID: 1)),
                    endpoints: CaptureOverviewConversationEndpoints(
                        transport: .tcp,
                        clientAddress: "fe80::1",
                        clientPort: 51_000,
                        serverAddress: "2001:db8::1",
                        serverPort: 443
                    ),
                    domainName: "api.example",
                    appName: appTitle,
                    appIconFilePath: nil,
                    totals: totals
                ),
            ],
            packetLengthCounts: [2, 0, 0, 0, 0, 8, 0],
            timeline: [CaptureOverviewTimelinePoint(date: Date(timeIntervalSince1970: 1_000), totals: totals)],
            timelineInterval: 1
        )
    }
}
