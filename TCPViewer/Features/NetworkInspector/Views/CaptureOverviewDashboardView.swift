//
//  CaptureOverviewDashboardView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import AppKit
import SwiftUI

// MARK: - Presentation

enum CaptureOverviewVisualTone: Equatable {
    case orange
    case blue
    case cyan
    case green
    case indigo
    case purple
    case red
    case pink
    case teal
    case mint
    case yellow
    case brown
    case gray

    var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .cyan: .cyan
        case .green: .green
        case .indigo: .indigo
        case .purple: .purple
        case .red: .red
        case .pink: .pink
        case .teal: .teal
        case .mint: .mint
        case .yellow: .yellow
        case .brown: .brown
        case .gray: .gray
        }
    }
}

enum CaptureOverviewStatusTone: Equatable {
    case active
    case positive
    case attention
    case error
    case neutral

    var color: Color {
        switch self {
        case .active: .blue
        case .positive: .green
        case .attention: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}

struct CaptureOverviewStatusPresentation: Equatable {
    let title: String
    let tone: CaptureOverviewStatusTone
}

struct CaptureOverviewMetricPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tone: CaptureOverviewVisualTone
}

// What a clickable row opens: the sidebar scope, or a Wireshark display filter on all packets.
enum CaptureOverviewRowAction: Equatable {
    case selection(PacketSourceListSelection)
    case displayFilter(String)
}

// An app, destination, conversation or service: a name and value, then a bar and a note.
struct CaptureOverviewTrafficRowPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: NSImage?
    let iconIdentity: String?
    let badgeText: String?
    let symbolName: String
    let valueText: String
    let detailText: String
    let issueCount: UInt64
    let sentFraction: Double
    let receivedFraction: Double
    let unknownFraction: Double
    let help: String
    let action: CaptureOverviewRowAction?

    // NSImage has reference identity, so rows compare by the icon path that produced it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.iconIdentity == rhs.iconIdentity &&
            lhs.badgeText == rhs.badgeText &&
            lhs.symbolName == rhs.symbolName &&
            lhs.valueText == rhs.valueText &&
            lhs.detailText == rhs.detailText &&
            lhs.issueCount == rhs.issueCount &&
            lhs.sentFraction == rhs.sentFraction &&
            lhs.receivedFraction == rhs.receivedFraction &&
            lhs.unknownFraction == rhs.unknownFraction &&
            lhs.help == rhs.help &&
            lhs.action == rhs.action
    }
}

struct CaptureOverviewProtocolPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let totalText: String
    let percentageText: String
    let fraction: Double
    let colorIndex: Int
}

struct CaptureOverviewTCPIssuePresentation: Identifiable, Equatable {
    let id: Int
    let title: String
    let count: UInt64
    let countText: String
    let percentageText: String
    let tone: CaptureOverviewVisualTone
    let help: String
    let displayFilter: String
}

struct CaptureOverviewTCPAnalysisPresentation: Equatable {
    let subtitle: String
    let rows: [CaptureOverviewTCPIssuePresentation]
    let emptyTitle: String
    let emptyDetail: String

    static let empty = CaptureOverviewTCPAnalysisPresentation(
        subtitle: "Wireshark TCP expert flags",
        rows: [],
        emptyTitle: "No TCP traffic",
        emptyDetail: "TCP problems appear here as packets are analyzed."
    )
}

struct CaptureOverviewPacketLengthPresentation: Identifiable, Equatable {
    let id: Int
    let title: String
    let axisTitle: String
    let count: UInt64
    let percentageText: String
}

struct CaptureOverviewTimelinePresentation: Equatable {
    static let minimumSlotCount = 12

    let points: [CaptureOverviewTimelinePoint]
    let interval: TimeInterval
    let totals: CaptureOverviewTrafficTotals

    static let empty = CaptureOverviewTimelinePresentation(points: [], interval: 1, totals: CaptureOverviewTrafficTotals())

    // A short capture still gets a few empty slots, instead of one bar filling the whole chart.
    static func padded(_ points: [CaptureOverviewTimelinePoint], interval: TimeInterval) -> [CaptureOverviewTimelinePoint] {
        guard let last = points.last, points.count < minimumSlotCount else {
            return points
        }
        return points + (1...(minimumSlotCount - points.count)).map { offset in
            CaptureOverviewTimelinePoint(
                date: last.date.addingTimeInterval(interval * Double(offset)),
                totals: CaptureOverviewTrafficTotals()
            )
        }
    }
}

struct CaptureOverviewDashboardModel: Equatable {
    let title: String
    let subtitle: String
    let status: CaptureOverviewStatusPresentation
    let hasTraffic: Bool
    let metrics: [CaptureOverviewMetricPresentation]
    let cards: [CaptureOverviewCard]
    let timeline: CaptureOverviewTimelinePresentation
    let protocolRows: [CaptureOverviewProtocolPresentation]
    let topApps: [CaptureOverviewTrafficRowPresentation]
    let topDestinations: [CaptureOverviewTrafficRowPresentation]
    let conversations: [CaptureOverviewTrafficRowPresentation]
    let services: [CaptureOverviewTrafficRowPresentation]
    let tcpAnalysis: CaptureOverviewTCPAnalysisPresentation
    let packetLengths: [CaptureOverviewPacketLengthPresentation]
    let packetLengthSubtitle: String

    static let empty = CaptureOverviewDashboardModel(
        title: "Overview",
        subtitle: "No capture source selected",
        status: CaptureOverviewStatusPresentation(title: "Ready", tone: .neutral),
        hasTraffic: false,
        metrics: [],
        cards: CaptureOverviewCard.defaults,
        timeline: .empty,
        protocolRows: [],
        topApps: [],
        topDestinations: [],
        conversations: [],
        services: [],
        tcpAnalysis: .empty,
        packetLengths: [],
        packetLengthSubtitle: ""
    )
}

// User actions the AppKit controller turns into delegate calls or layout changes.
struct CaptureOverviewDashboardActions {
    let viewPackets: () -> Void
    let showEndpoints: () -> Void
    let performRowAction: (CaptureOverviewRowAction) -> Void
    let setCardVisible: (CaptureOverviewCard, Bool) -> Void
    let restoreDefaultCards: () -> Void
    let copyMarkdown: () -> Void
    let saveMarkdown: () -> Void
    let shareMarkdown: () -> Void
}

// MARK: - Formatting

// Shared by the controller and the chart tooltips so numbers read the same everywhere.
enum CaptureOverviewFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useAll
        formatter.includesUnit = true
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let spanFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    static func bytes(_ value: UInt64) -> String {
        guard value > 0 else {
            return "0 bytes"
        }
        return byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else {
            return "0 bytes"
        }
        // Rates over very long captures can fall below one byte per second.
        guard value >= 1 else {
            return "<1 byte"
        }
        return bytes(UInt64(min(value, Double(Int64.max))))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(bytesPerSecond))/s"
    }

    static func count(_ value: UInt64) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func fraction(_ value: UInt64, of total: UInt64) -> Double {
        guard total > 0 else {
            return 0
        }
        return min(1, Double(value) / Double(total))
    }

    static func percent(_ value: UInt64, of total: UInt64) -> String {
        let percentage = fraction(value, of: total) * 100
        if value > 0, percentage < 1 {
            return "<1%"
        }
        return "\(Int(percentage.rounded()))%"
    }

    static func span(_ interval: TimeInterval) -> String {
        guard interval >= 1 else {
            return interval > 0 ? "\(Int((interval * 1_000).rounded())) ms" : "0s"
        }
        return spanFormatter.string(from: interval) ?? "0s"
    }

    // Seconds matter for short slots; longer slots only need hours and minutes.
    static func time(_ date: Date, slotInterval: TimeInterval) -> String {
        if slotInterval < 60 {
            return date.formatted(.dateTime.hour().minute().second())
        }
        if slotInterval < 86_400 {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

// MARK: - Style

// Grouped cards on a soft background, matching Proxyman's Overview.
enum CaptureOverviewStyle {
    static let cornerRadius: CGFloat = 18
    // Same-size cards, like collection view cells; narrow enough that a name and its value stay close.
    static let cardHeight: CGFloat = 340
    static let cardMinimumWidth: CGFloat = 330
    static let cardMaximumWidth: CGFloat = 460
    static let rowLimit = 6

    static let background = dynamicColor(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1),
        dark: NSColor(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1)
    )
    static let card = dynamicColor(light: .white, dark: NSColor(srgbRed: 0.137, green: 0.137, blue: 0.149, alpha: 1))
    static let cardBorder = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.08)
    )
    static let shadow = dynamicColor(light: NSColor.black.withAlphaComponent(0.05), dark: .clear)
    static let track = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.06)

    static let received = Color.blue
    static let sent = Color.purple
    static let unknownDirection = Color.gray
    static let issue = Color.red

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension CaptureOverviewCard {
    var tint: Color {
        switch self {
        case .packets: .blue
        case .throughput: .indigo
        case .protocols: .purple
        case .topApps: .orange
        case .topDestinations: .cyan
        case .tcpAnalysis: .red
        case .conversations: .teal
        case .services: .mint
        case .packetLengths: .pink
        }
    }
}

// MARK: - Root

struct CaptureOverviewDashboardView: View {
    let model: CaptureOverviewDashboardModel
    let actions: CaptureOverviewDashboardActions

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                CaptureOverviewHeaderView(model: model, actions: actions)
                if model.hasTraffic {
                    CaptureOverviewMetricsView(metrics: model.metrics)
                    CaptureOverviewCardGrid(model: model, actions: actions)
                } else {
                    CaptureOverviewEmptyStateView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CaptureOverviewStyle.background.ignoresSafeArea())
    }
}

// MARK: - Header

private struct CaptureOverviewHeaderView: View {
    let model: CaptureOverviewDashboardModel
    let actions: CaptureOverviewDashboardActions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CaptureOverviewIconTile(symbolName: "chart.bar.xaxis", tint: .orange, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 20, weight: .bold))
                    CaptureOverviewStatusPill(status: model.status)
                }
                Text(model.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button(action: actions.viewPackets) {
                Label("View Packets", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)
            Button(action: actions.showEndpoints) {
                Label("Endpoints…", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasTraffic)
            CaptureOverviewShareMenu(actions: actions)
                .disabled(!model.hasTraffic)
        }
    }
}

// Exports the Overview as a Markdown report; the controller renders it only when an item is chosen.
private struct CaptureOverviewShareMenu: View {
    let actions: CaptureOverviewDashboardActions

    @State private var didCopy = false

    var body: some View {
        Menu {
            Button("Copy as Markdown", systemImage: "doc.on.doc") {
                actions.copyMarkdown()
                // Confirm on the button for a moment, like Proxyman's Overview.
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    didCopy = false
                }
            }
            Button("Save as Markdown…", systemImage: "square.and.arrow.down", action: actions.saveMarkdown)
            Divider()
            Button("Share…", systemImage: "square.and.arrow.up", action: actions.shareMarkdown)
        } label: {
            if didCopy {
                Label("Copied", systemImage: "checkmark")
            } else {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Share this Overview as a Markdown report")
    }
}

private struct CaptureOverviewStatusPill: View {
    let status: CaptureOverviewStatusPresentation

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.tone.color)
                .frame(width: 6, height: 6)
            Text(status.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(status.tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(status.tone.color.opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture status, \(status.title)")
    }
}

// MARK: - Metrics

private struct CaptureOverviewMetricsView: View {
    let metrics: [CaptureOverviewMetricPresentation]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(metrics) { metric in
                CaptureOverviewMetricTile(metric: metric)
            }
        }
    }
}

private struct CaptureOverviewMetricTile: View {
    let metric: CaptureOverviewMetricPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CaptureOverviewIconTile(symbolName: metric.symbol, tint: metric.tone.color)
                Text(metric.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(metric.value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(metric.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .captureOverviewCardBackground(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card Grid

// Same-size cards, as many per row as fit, then the "+" cell that shows or hides cards.
private struct CaptureOverviewCardGrid: View {
    let model: CaptureOverviewDashboardModel
    let actions: CaptureOverviewDashboardActions

    var body: some View {
        let columns = [
            GridItem(
                .adaptive(minimum: CaptureOverviewStyle.cardMinimumWidth, maximum: CaptureOverviewStyle.cardMaximumWidth),
                spacing: 16,
                alignment: .top
            ),
        ]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(model.cards) { card in
                cardView(for: card)
                    .frame(height: CaptureOverviewStyle.cardHeight)
                    .contextMenu {
                        Button("Remove from Overview", systemImage: "minus.circle") {
                            actions.setCardVisible(card, false)
                        }
                    }
            }
            CaptureOverviewAddCardCell(
                visibleCards: model.cards,
                onSetVisible: actions.setCardVisible,
                onRestoreDefaults: actions.restoreDefaultCards
            )
            .frame(height: CaptureOverviewStyle.cardHeight)
        }
    }

    @ViewBuilder
    private func cardView(for card: CaptureOverviewCard) -> some View {
        switch card {
        case .packets:
            CaptureOverviewPacketsCard(timeline: model.timeline)
        case .throughput:
            CaptureOverviewThroughputCard(timeline: model.timeline)
        case .protocols:
            CaptureOverviewProtocolsCard(rows: model.protocolRows)
        case .topApps:
            CaptureOverviewRowsCard(
                card: card,
                subtitle: "By data transferred",
                placeholder: "Apps appear when TCP Viewer identifies the local process.",
                rows: model.topApps,
                onAction: actions.performRowAction
            )
        case .topDestinations:
            CaptureOverviewRowsCard(
                card: card,
                subtitle: "By data transferred",
                placeholder: "No domains or IP addresses yet",
                rows: model.topDestinations,
                onAction: actions.performRowAction
            )
        case .tcpAnalysis:
            CaptureOverviewTCPAnalysisCard(analysis: model.tcpAnalysis, onAction: actions.performRowAction)
        case .conversations:
            CaptureOverviewRowsCard(
                card: card,
                subtitle: "TCP and UDP, by data transferred",
                placeholder: "No TCP or UDP conversations yet",
                rows: model.conversations,
                onAction: actions.performRowAction
            )
        case .services:
            CaptureOverviewRowsCard(
                card: card,
                subtitle: "By server port and data transferred",
                placeholder: "No TCP or UDP ports yet",
                rows: model.services,
                onAction: actions.performRowAction
            )
        case .packetLengths:
            CaptureOverviewPacketLengthsCard(rows: model.packetLengths, subtitle: model.packetLengthSubtitle)
        }
    }
}

// A rounded card with an icon, a title, a one-line subtitle and its content.
struct CaptureOverviewCardView<Content: View>: View {
    let card: CaptureOverviewCard
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                CaptureOverviewIconTile(symbolName: card.symbolName, tint: card.tint, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    // One line, so every card keeps the same room for its content.
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .captureOverviewCardBackground()
    }
}

// MARK: - Add Card

// The last cell of the grid. Its popover lists every card with a checkmark to show or hide it.
private struct CaptureOverviewAddCardCell: View {
    let visibleCards: [CaptureOverviewCard]
    let onSetVisible: (CaptureOverviewCard, Bool) -> Void
    let onRestoreDefaults: () -> Void

    @State private var isPickerShown = false
    @State private var isHovered = false

    private var hiddenCards: [CaptureOverviewCard] {
        CaptureOverviewCard.allCases.filter { !visibleCards.contains($0) }
    }

    // A few hidden card names, so it's clear what the cell offers.
    private var hint: String {
        guard !hiddenCards.isEmpty else {
            return "Every chart is on the Overview"
        }
        let names = hiddenCards.prefix(3).map(\.title).joined(separator: ", ")
        return hiddenCards.count > 3 ? names + "…" : names
    }

    var body: some View {
        Button {
            isPickerShown = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.orange.opacity(isHovered ? 0.2 : 0.12)))
                Text("Add Chart")
                    .font(.system(size: 13, weight: .semibold))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: CaptureOverviewStyle.cornerRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(isHovered ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.35))
            )
            .contentShape(RoundedRectangle(cornerRadius: CaptureOverviewStyle.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPickerShown, attachmentAnchor: .point(.center)) {
            CaptureOverviewCardPicker(
                visibleCards: visibleCards,
                onSetVisible: onSetVisible,
                onRestoreDefaults: onRestoreDefaults
            )
        }
        .help("Show or hide Overview charts")
        .accessibilityLabel("Add Chart")
    }
}

// Every card with a checkmark; clicking a row shows or hides that card without closing the popover.
private struct CaptureOverviewCardPicker: View {
    let visibleCards: [CaptureOverviewCard]
    let onSetVisible: (CaptureOverviewCard, Bool) -> Void
    let onRestoreDefaults: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Overview Charts")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(CaptureOverviewCard.allCases) { card in
                    let isVisible = visibleCards.contains(card)
                    // Send the state the row asks for, not a flip, in case another window changed the layout.
                    CaptureOverviewCardPickerRow(card: card, isVisible: isVisible) {
                        onSetVisible(card, !isVisible)
                    }
                }
            }
            .padding(.horizontal, 6)

            Divider()
                .padding(.top, 6)
            HStack(spacing: 8) {
                Text("Right-click a chart to remove it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if visibleCards != CaptureOverviewCard.defaults {
                    Button("Restore Defaults", action: onRestoreDefaults)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
    }
}

private struct CaptureOverviewCardPickerRow: View {
    let card: CaptureOverviewCard
    let isVisible: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                CaptureOverviewIconTile(symbolName: card.symbolName, tint: card.tint, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(card.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: isVisible ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isVisible ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.9 : 0.5))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? CaptureOverviewStyle.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(card.title)
        .accessibilityValue(isVisible ? "Shown" : "Hidden")
        .accessibilityHint(isVisible ? "Removes this chart from the Overview" : "Adds this chart to the Overview")
    }
}

// MARK: - Row Cards

// Apps, destinations, conversations or services ranked by data, each row opening matching packets.
private struct CaptureOverviewRowsCard: View {
    let card: CaptureOverviewCard
    let subtitle: String
    let placeholder: String
    let rows: [CaptureOverviewTrafficRowPresentation]
    let onAction: (CaptureOverviewRowAction) -> Void

    var body: some View {
        CaptureOverviewCardView(card: card, subtitle: subtitle) {
            if rows.isEmpty {
                CaptureOverviewPlaceholder(text: placeholder)
            } else {
                VStack(spacing: 2) {
                    // Keyed by rank, so a re-ranked live list keeps the hover on the row under the pointer.
                    ForEach(Array(rows.prefix(CaptureOverviewStyle.rowLimit).enumerated()), id: \.offset) { _, row in
                        CaptureOverviewTrafficRow(row: row, onAction: onAction)
                    }
                }
            }
        }
    }
}

private struct CaptureOverviewTrafficRow: View {
    let row: CaptureOverviewTrafficRowPresentation
    let onAction: (CaptureOverviewRowAction) -> Void

    private var rowAction: (() -> Void)? {
        guard let action = row.action else {
            return nil
        }
        return { onAction(action) }
    }

    var body: some View {
        CaptureOverviewRowButton(action: rowAction) {
            leading
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.issueCount > 0 {
                        Label(CaptureOverviewFormat.count(row.issueCount), systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(CaptureOverviewStyle.issue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(CaptureOverviewStyle.issue.opacity(0.12)))
                            .fixedSize()
                            .help("Packets flagged by TCP analysis")
                    }
                    Spacer(minLength: 6)
                    Text(row.valueText)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    CaptureOverviewTrafficBar(
                        sentFraction: row.sentFraction,
                        receivedFraction: row.receivedFraction,
                        unknownFraction: row.unknownFraction
                    )
                    Text(row.detailText)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .help(row.help)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        if let badgeText = row.badgeText {
            Text(badgeText)
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.mint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 40, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.mint.opacity(0.14)))
        } else if let icon = row.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            CaptureOverviewIconTile(symbolName: row.symbolName, tint: .blue)
        }
    }
}

// MARK: - TCP Analysis

// One segmented capsule for every flagged packet, then a row per Wireshark expert flag group.
private struct CaptureOverviewTCPAnalysisCard: View {
    let analysis: CaptureOverviewTCPAnalysisPresentation
    let onAction: (CaptureOverviewRowAction) -> Void

    var body: some View {
        CaptureOverviewCardView(card: .tcpAnalysis, subtitle: analysis.subtitle) {
            if analysis.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text(analysis.emptyTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(analysis.emptyDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    CaptureOverviewSegmentedBar(segments: analysis.rows.map { ($0.count, $0.tone.color) })
                        .padding(.horizontal, 6)
                    VStack(spacing: 2) {
                        ForEach(analysis.rows) { row in
                            CaptureOverviewRowButton(action: { onAction(.displayFilter(row.displayFilter)) }) {
                                Circle()
                                    .fill(row.tone.color)
                                    .frame(width: 8, height: 8)
                                Text(row.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(row.countText)
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                Text(row.percentageText)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .help(row.help)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared Views

// A white SF Symbol on a tinted rounded square, like a macOS Settings icon.
struct CaptureOverviewIconTile: View {
    let symbolName: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

// Shown in a card that has nothing to list yet.
struct CaptureOverviewPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// A colored dot, a name and a value, used by chart legends.
struct CaptureOverviewLegendItem: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}

// A clickable row: highlighted on hover, with a chevron that says it opens packets. No action, no button.
private struct CaptureOverviewRowButton<Content: View>: View {
    let action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) {
                label
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            content()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovered ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? CaptureOverviewStyle.hover : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// Received, sent and unknown-direction bytes, relative to the biggest row.
private struct CaptureOverviewTrafficBar: View {
    let sentFraction: Double
    let receivedFraction: Double
    let unknownFraction: Double

    var body: some View {
        GeometryReader { geometry in
            let total = receivedFraction + sentFraction + unknownFraction
            // Keep a tiny row visible instead of an empty track.
            let width = total > 0 ? max(geometry.size.width * min(total, 1), 4) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(CaptureOverviewStyle.track)
                HStack(spacing: 0) {
                    Rectangle().fill(CaptureOverviewStyle.received).frame(width: width * share(receivedFraction, of: total))
                    Rectangle().fill(CaptureOverviewStyle.sent).frame(width: width * share(sentFraction, of: total))
                    Rectangle().fill(CaptureOverviewStyle.unknownDirection).frame(width: width * share(unknownFraction, of: total))
                }
                .frame(width: width, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func share(_ value: Double, of total: Double) -> CGFloat {
        total > 0 ? CGFloat(value / total) : 0
    }
}

// A capsule split into colored parts by count.
private struct CaptureOverviewSegmentedBar: View {
    let segments: [(count: UInt64, color: Color)]

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let total = max(segments.reduce(0) { $0 + Double($1.count) }, 1)
            let available = max(geometry.size.width - spacing * CGFloat(max(segments.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(available * CGFloat(Double(segment.count) / total), 3))
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

private struct CaptureOverviewEmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No traffic captured yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Start a capture or open a capture file. The Overview fills in as packets arrive.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .captureOverviewCardBackground()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func captureOverviewCardBackground(cornerRadius: CGFloat = CaptureOverviewStyle.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(CaptureOverviewStyle.card))
            .overlay(shape.strokeBorder(CaptureOverviewStyle.cardBorder, lineWidth: 1))
            .shadow(color: CaptureOverviewStyle.shadow, radius: 8, x: 0, y: 2)
    }
}
