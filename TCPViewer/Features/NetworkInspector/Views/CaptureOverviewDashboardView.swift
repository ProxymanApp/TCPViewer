//
//  CaptureOverviewDashboardView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import AppKit
import Charts
import SwiftUI

enum CaptureOverviewVisualTone: Equatable {
    case orange
    case blue
    case cyan
    case green
    case indigo
    case purple

    var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .cyan: .cyan
        case .green: .green
        case .indigo: .indigo
        case .purple: .purple
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

struct CaptureOverviewChartPoint: Identifiable, Equatable {
    struct ID: Hashable {
        let date: Date
        let direction: Direction
    }

    enum Direction: String, Hashable {
        case sent = "Sent"
        case received = "Received"
        case total = "Total"
    }

    let id: ID
    let date: Date
    let direction: Direction
    let bytes: Double
}

struct CaptureOverviewTopTrafficPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: NSImage
    let iconFilePath: String?
    let selection: PacketSourceListSelection
    let totalText: String
    let sentText: String
    let receivedText: String
    let percentageText: String
    let sentFraction: Double
    let receivedFraction: Double
    let unknownFraction: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.iconFilePath == rhs.iconFilePath &&
            lhs.selection == rhs.selection &&
            lhs.totalText == rhs.totalText &&
            lhs.sentText == rhs.sentText &&
            lhs.receivedText == rhs.receivedText &&
            lhs.percentageText == rhs.percentageText &&
            lhs.sentFraction == rhs.sentFraction &&
            lhs.receivedFraction == rhs.receivedFraction &&
            lhs.unknownFraction == rhs.unknownFraction
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

struct CaptureOverviewDetailPresentation: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

struct CaptureOverviewDashboardModel: Equatable {
    let title: String
    let subtitle: String
    let status: CaptureOverviewStatusPresentation
    let metrics: [CaptureOverviewMetricPresentation]
    let hasTraffic: Bool
    let hasDirectionalTraffic: Bool
    let trafficPoints: [CaptureOverviewChartPoint]
    let totalText: String
    let sentText: String
    let receivedText: String
    let selectedTopGroup: CaptureOverviewTopGroup
    let topRows: [CaptureOverviewTopTrafficPresentation]
    let protocolRows: [CaptureOverviewProtocolPresentation]
    let warningText: String?
    let details: [CaptureOverviewDetailPresentation]
    let isDetailsExpanded: Bool

    static let empty = CaptureOverviewDashboardModel(
        title: "Capture overview",
        subtitle: "No capture source selected",
        status: CaptureOverviewStatusPresentation(title: "Ready", tone: .neutral),
        metrics: [],
        hasTraffic: false,
        hasDirectionalTraffic: false,
        trafficPoints: [],
        totalText: "0 bytes",
        sentText: "0 bytes",
        receivedText: "0 bytes",
        selectedTopGroup: .apps,
        topRows: [],
        protocolRows: [],
        warningText: nil,
        details: [],
        isDetailsExpanded: false
    )
}

struct CaptureOverviewDashboardView: View {
    let model: CaptureOverviewDashboardModel
    let onViewPackets: () -> Void
    let onShowEndpoints: () -> Void
    let onSelectTopGroup: (CaptureOverviewTopGroup) -> Void
    let onSelectTrafficRow: (PacketSourceListSelection) -> Void
    let onToggleDetails: () -> Void

    var body: some View {
        ZStack {
            CaptureOverviewBackgroundView()
            ScrollView {
                dashboard
                    .frame(maxWidth: 1_720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 36)
            }
        }
    }

    @ViewBuilder
    private var dashboard: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 18) {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            CaptureOverviewHeaderView(
                title: model.title,
                subtitle: model.subtitle,
                status: model.status,
                hasTraffic: model.hasTraffic,
                onViewPackets: onViewPackets,
                onShowEndpoints: onShowEndpoints
            )

            if model.hasTraffic {
                CaptureOverviewMetricsView(metrics: model.metrics)
                CaptureOverviewPrimaryDataView(
                    trafficPoints: model.trafficPoints,
                    hasDirectionalTraffic: model.hasDirectionalTraffic,
                    totalText: model.totalText,
                    sentText: model.sentText,
                    receivedText: model.receivedText,
                    protocols: model.protocolRows
                )
                CaptureOverviewTopTrafficView(
                    selectedGroup: model.selectedTopGroup,
                    rows: model.topRows,
                    onSelectGroup: onSelectTopGroup,
                    onSelectRow: onSelectTrafficRow
                )
            } else {
                CaptureOverviewEmptyStateView()
            }

            if let warningText = model.warningText {
                CaptureOverviewWarningView(text: warningText)
            }

            CaptureOverviewDetailsView(
                details: model.details,
                isExpanded: model.isDetailsExpanded,
                onToggle: onToggleDetails
            )
        }
    }
}

private struct CaptureOverviewBackgroundView: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.orange.opacity(0.11))
                    .frame(width: 620, height: 620)
                    .blur(radius: 150)
                    .offset(x: -220, y: -300)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.cyan.opacity(0.08))
                    .frame(width: 720, height: 720)
                    .blur(radius: 170)
                    .offset(x: 260, y: 320)
            }
            .ignoresSafeArea()
    }
}

private struct CaptureOverviewHeaderView: View {
    let title: String
    let subtitle: String
    let status: CaptureOverviewStatusPresentation
    let hasTraffic: Bool
    let onViewPackets: () -> Void
    let onShowEndpoints: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                identity
                Spacer(minLength: 24)
                CaptureOverviewHeaderActions(
                    hasTraffic: hasTraffic,
                    onViewPackets: onViewPackets,
                    onShowEndpoints: onShowEndpoints
                )
            }
            .frame(minWidth: 700)

            VStack(alignment: .leading, spacing: 18) {
                identity
                CaptureOverviewHeaderActions(
                    hasTraffic: hasTraffic,
                    onViewPackets: onViewPackets,
                    onShowEndpoints: onShowEndpoints
                )
            }
        }
        .padding(22)
        .captureOverviewSurface(tint: .orange)
    }

    private var identity: some View {
        HStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 54, height: 54)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.24), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    CaptureOverviewStatusPill(status: status)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureOverviewStatusPill: View {
    let status: CaptureOverviewStatusPresentation

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.tone.color)
                .frame(width: 7, height: 7)
            Text(status.title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(status.tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(status.tone.color.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(status.tone.color.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture status, \(status.title)")
    }
}

private struct CaptureOverviewHeaderActions: View {
    let hasTraffic: Bool
    let onViewPackets: () -> Void
    let onShowEndpoints: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: 10) {
                Button(action: onViewPackets) {
                    Label("View Packets", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.glassProminent)
                Button(action: onShowEndpoints) {
                    Label("Endpoints…", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.glass)
                .disabled(!hasTraffic)
            }
            .controlSize(.large)
        } else {
            HStack(spacing: 10) {
                Button(action: onViewPackets) {
                    Label("View Packets", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.borderedProminent)
                Button(action: onShowEndpoints) {
                    Label("Endpoints…", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.bordered)
                .disabled(!hasTraffic)
            }
            .controlSize(.large)
        }
    }
}

private struct CaptureOverviewMetricsView: View {
    let metrics: [CaptureOverviewMetricPresentation]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                cards
            }
            .frame(minWidth: 1_080)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 160), spacing: 14), count: 3),
                spacing: 14
            ) {
                cards
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 14), count: 2),
                spacing: 14
            ) {
                cards
            }
        }
    }

    private var cards: some View {
        ForEach(metrics) { metric in
            CaptureOverviewMetricCard(metric: metric)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct CaptureOverviewMetricCard: View {
    let metric: CaptureOverviewMetricPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: metric.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(metric.tone.color)
                    .frame(width: 30, height: 30)
                    .background(metric.tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                Text(metric.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(metric.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(metric.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(16)
        .captureOverviewSurface(tint: metric.tone.color)
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureOverviewPrimaryDataView: View {
    let trafficPoints: [CaptureOverviewChartPoint]
    let hasDirectionalTraffic: Bool
    let totalText: String
    let sentText: String
    let receivedText: String
    let protocols: [CaptureOverviewProtocolPresentation]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                CaptureOverviewTrafficChartView(
                    points: trafficPoints,
                    hasDirectionalTraffic: hasDirectionalTraffic,
                    totalText: totalText,
                    sentText: sentText,
                    receivedText: receivedText
                )
                .frame(maxWidth: .infinity)
                CaptureOverviewProtocolView(rows: protocols)
                    .frame(width: 410)
            }
            .frame(minWidth: 1_040)

            VStack(spacing: 18) {
                CaptureOverviewTrafficChartView(
                    points: trafficPoints,
                    hasDirectionalTraffic: hasDirectionalTraffic,
                    totalText: totalText,
                    sentText: sentText,
                    receivedText: receivedText
                )
                CaptureOverviewProtocolView(rows: protocols)
            }
        }
    }
}

private struct CaptureOverviewTrafficChartView: View {
    let points: [CaptureOverviewChartPoint]
    let hasDirectionalTraffic: Bool
    let totalText: String
    let sentText: String
    let receivedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Traffic over time")
                        .font(.headline)
                    Text(hasDirectionalTraffic ? "Packet bytes by local direction" : "Total packet bytes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hasDirectionalTraffic {
                    CaptureOverviewChartLegend(title: "Sent", value: sentText, color: .blue)
                    CaptureOverviewChartLegend(title: "Received", value: receivedText, color: .cyan)
                } else {
                    CaptureOverviewChartLegend(title: "Total", value: totalText, color: .orange)
                }
            }

            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Bytes", point.bytes),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value("Direction", point.direction.rawValue))
                .interpolationMethod(.catmullRom)
                .opacity(0.1)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Bytes", point.bytes)
                )
                .foregroundStyle(by: .value("Direction", point.direction.rawValue))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Bytes", point.bytes)
                )
                .foregroundStyle(by: .value("Direction", point.direction.rawValue))
                .symbolSize(16)
            }
            .chartForegroundStyleScale([
                CaptureOverviewChartPoint.Direction.sent.rawValue: Color.blue,
                CaptureOverviewChartPoint.Direction.received.rawValue: Color.cyan,
                CaptureOverviewChartPoint.Direction.total.rawValue: Color.orange,
            ])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(CaptureOverviewByteFormatting.string(bytes))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .chartPlotStyle { plotArea in
                plotArea.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityLabel(
                hasDirectionalTraffic ? "Sent and received traffic over time" : "Total traffic over time"
            )
        }
        .frame(maxWidth: .infinity, minHeight: 292, maxHeight: 292, alignment: .topLeading)
        .padding(20)
        .captureOverviewSurface(tint: .blue)
    }
}

private struct CaptureOverviewChartLegend: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureOverviewProtocolView: View {
    let rows: [CaptureOverviewProtocolPresentation]

    private var protocolNames: [String] {
        rows.map(\.title)
    }

    private var protocolColors: [Color] {
        rows.map { CaptureOverviewPalette.protocolColor(at: $0.colorIndex) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Protocols")
                    .font(.headline)
                Text("Share of captured bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                Chart(rows) { row in
                    SectorMark(
                        angle: .value("Bytes", row.fraction),
                        innerRadius: .ratio(0.67),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Protocol", row.title))
                }
                .chartForegroundStyleScale(domain: protocolNames, range: protocolColors)
                .chartLegend(.hidden)
                .overlay {
                    VStack(spacing: 2) {
                        Text("\(rows.count)")
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text(rows.count == 1 ? "protocol" : "protocols")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 142, height: 142)
                .accessibilityLabel("Protocol traffic breakdown")

                VStack(spacing: 11) {
                    ForEach(rows) { row in
                        CaptureOverviewProtocolLegendRow(row: row)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 292, maxHeight: 292, alignment: .topLeading)
        .padding(20)
        .captureOverviewSurface(tint: .purple)
    }
}

private struct CaptureOverviewProtocolLegendRow: View {
    let row: CaptureOverviewProtocolPresentation

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(CaptureOverviewPalette.protocolColor(at: row.colorIndex))
                    .frame(width: 7, height: 7)
                Text(row.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(row.percentageText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text(row.totalText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(CaptureOverviewPalette.protocolColor(at: row.colorIndex))
                            .frame(width: geometry.size.width * row.fraction)
                    }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureOverviewTopTrafficView: View {
    let selectedGroup: CaptureOverviewTopGroup
    let rows: [CaptureOverviewTopTrafficPresentation]
    let onSelectGroup: (CaptureOverviewTopGroup) -> Void
    let onSelectRow: (PacketSourceListSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Top traffic")
                        .font(.headline)
                    Text("Ranked by total bytes across the capture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CaptureOverviewSegmentedControl(selection: selectedGroup, onSelect: onSelectGroup)
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    selectedGroup == .apps ? "No app traffic" : "No resolved domains",
                    systemImage: selectedGroup == .apps ? "app.dashed" : "globe.desk",
                    description: Text(
                        selectedGroup == .apps
                            ? "App attribution will appear when TCP Viewer can identify the local process."
                            : "Resolved domains will appear as packet metadata becomes available."
                    )
                )
                .frame(minHeight: 210)
            } else {
                ViewThatFits(in: .horizontal) {
                    CaptureOverviewTopTrafficGrid(rows: rows, columnCount: 2, onSelect: onSelectRow)
                        .frame(minWidth: 880)
                    CaptureOverviewTopTrafficGrid(rows: rows, columnCount: 1, onSelect: onSelectRow)
                }
            }
        }
        .padding(20)
        .captureOverviewSurface(tint: .orange)
    }
}

private struct CaptureOverviewSegmentedControl: View {
    let selection: CaptureOverviewTopGroup
    let onSelect: (CaptureOverviewTopGroup) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CaptureOverviewTopGroup.allCases, id: \.rawValue) { group in
                Button(group.title) {
                    onSelect(group)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(selection == group ? Color.white : Color.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(selection == group ? Color.orange : Color.clear, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == group ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top traffic category")
    }
}

private struct CaptureOverviewTopTrafficGrid: View {
    let rows: [CaptureOverviewTopTrafficPresentation]
    let columnCount: Int
    let onSelect: (PacketSourceListSelection) -> Void

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 360), spacing: 12), count: columnCount),
            spacing: 12
        ) {
            ForEach(rows) { row in
                Button {
                    onSelect(row.selection)
                } label: {
                    CaptureOverviewTopTrafficRow(row: row)
                }
                .buttonStyle(CaptureOverviewTrafficRowButtonStyle())
                .accessibilityLabel("\(row.title), \(row.totalText), \(row.percentageText) of capture")
                .accessibilityHint("Shows matching packets in the main table")
            }
        }
    }
}

private struct CaptureOverviewTopTrafficRow: View {
    let row: CaptureOverviewTopTrafficPresentation

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: row.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(row.percentageText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    Spacer(minLength: 8)
                    Text(row.totalText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }

                CaptureOverviewStackedTrafficBar(
                    sentFraction: row.sentFraction,
                    receivedFraction: row.receivedFraction,
                    unknownFraction: row.unknownFraction
                )

                HStack(spacing: 14) {
                    Label(row.sentText, systemImage: "arrow.up.right")
                        .foregroundStyle(.blue)
                    Label(row.receivedText, systemImage: "arrow.down.left")
                        .foregroundStyle(.cyan)
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct CaptureOverviewStackedTrafficBar: View {
    let sentFraction: Double
    let receivedFraction: Double
    let unknownFraction: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * sentFraction)
                        Rectangle()
                            .fill(Color.cyan)
                            .frame(width: geometry.size.width * receivedFraction)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: geometry.size.width * unknownFraction)
                    }
                }
                .compositingGroup()
                .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct CaptureOverviewTrafficRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CaptureOverviewEmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "No traffic captured yet",
            systemImage: "waveform.path.ecg",
            description: Text("Start a capture or open a capture file. This overview will fill in as packets arrive.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
        .captureOverviewSurface(tint: .orange)
    }
}

private struct CaptureOverviewWarningView: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(16)
        .captureOverviewSurface(tint: .orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture warning, \(text)")
    }
}

private struct CaptureOverviewDetailsView: View {
    let details: [CaptureOverviewDetailPresentation]
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onToggle) {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Capture details")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(details.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(details) { detail in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(detail.value)
                                .font(.callout.weight(.medium))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .captureOverviewSurface(tint: .secondary)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }
}

private struct CaptureOverviewSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(tint.opacity(colorScheme == .dark ? 0.055 : 0.035), in: shape)
                .overlay {
                    shape.strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09),
                        lineWidth: 1
                    )
                }
                .glassEffect(.regular.tint(tint.opacity(0.045)), in: .rect(cornerRadius: 22))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09),
                        lineWidth: 1
                    )
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.07), radius: 16, y: 6)
        }
    }
}

private extension View {
    func captureOverviewSurface(tint: Color) -> some View {
        modifier(CaptureOverviewSurfaceModifier(tint: tint))
    }
}

private enum CaptureOverviewPalette {
    static let protocolColors: [Color] = [
        .blue,
        .cyan,
        .purple,
        .orange,
        .green,
        .pink,
    ]

    static func protocolColor(at index: Int) -> Color {
        protocolColors[index % protocolColors.count]
    }
}

private enum CaptureOverviewByteFormatting {
    static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useAll
        formatter.includesUnit = true
        return formatter
    }()

    static func string(_ bytes: Double) -> String {
        let byteCount = UInt64(max(0, bytes))
        guard byteCount > 0 else {
            return "0 bytes"
        }
        return formatter.string(fromByteCount: Int64(clamping: byteCount))
    }
}
