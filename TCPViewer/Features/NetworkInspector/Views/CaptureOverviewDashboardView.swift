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

        var color: Color {
            switch self {
            case .sent: .blue
            case .received: .cyan
            case .total: .orange
            }
        }

        var sortOrder: Int {
            switch self {
            case .sent: 0
            case .received: 1
            case .total: 2
            }
        }
    }

    let id: ID
    let date: Date
    let direction: Direction
    let bytes: Double
}

struct CaptureOverviewTopTrafficPresentation: Identifiable, Equatable {
    let id: String
    let rank: Int
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
            lhs.rank == rhs.rank &&
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

enum CaptureOverviewChartHoverSelection {
    static func nearestDate(to date: Date, in points: [CaptureOverviewChartPoint]) -> Date? {
        points.reduce(nil) { nearestDate, point in
            guard let nearestDate else {
                return point.date
            }
            let nearestDistance = abs(nearestDate.timeIntervalSince(date))
            let pointDistance = abs(point.date.timeIntervalSince(date))
            if pointDistance == nearestDistance {
                return min(nearestDate, point.date)
            }
            return pointDistance < nearestDistance ? point.date : nearestDate
        }
    }

    static func protocolRow(
        at location: CGPoint,
        in size: CGSize,
        innerRadiusRatio: CGFloat,
        rows: [CaptureOverviewProtocolPresentation]
    ) -> CaptureOverviewProtocolPresentation? {
        let radius = min(size.width, size.height) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let offsetX = location.x - center.x
        let offsetY = location.y - center.y
        let distance = hypot(offsetX, offsetY)
        guard radius > 0,
              distance >= radius * innerRadiusRatio,
              distance <= radius else {
            return nil
        }

        var clockwiseAngle = atan2(offsetX, -offsetY)
        if clockwiseAngle < 0 {
            clockwiseAngle += 2 * .pi
        }
        let totalFraction = rows.reduce(0) { $0 + max(0, $1.fraction) }
        guard totalFraction > 0 else {
            return nil
        }

        let targetFraction = clockwiseAngle / (2 * .pi) * totalFraction
        var accumulatedFraction = 0.0
        for row in rows {
            accumulatedFraction += max(0, row.fraction)
            if targetFraction <= accumulatedFraction {
                return row
            }
        }
        return rows.last
    }
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
    let topApps: [CaptureOverviewTopTrafficPresentation]
    let topDestinations: [CaptureOverviewTopTrafficPresentation]
    let protocolRows: [CaptureOverviewProtocolPresentation]

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
        topApps: [],
        topDestinations: [],
        protocolRows: []
    )
}

struct CaptureOverviewDashboardView: View {
    let model: CaptureOverviewDashboardModel
    let onViewPackets: () -> Void
    let onShowEndpoints: () -> Void
    let onSelectTrafficRow: (PacketSourceListSelection) -> Void

    var body: some View {
        ZStack {
            CaptureOverviewBackgroundView()
            ScrollView {
                CaptureOverviewDashboardContent(
                    model: model,
                    onViewPackets: onViewPackets,
                    onShowEndpoints: onShowEndpoints,
                    onSelectTrafficRow: onSelectTrafficRow
                )
                    .frame(maxWidth: 1_900)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
        }
    }
}

private struct CaptureOverviewDashboardContent: View {
    let model: CaptureOverviewDashboardModel
    let onViewPackets: () -> Void
    let onShowEndpoints: () -> Void
    let onSelectTrafficRow: (PacketSourceListSelection) -> Void

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                CaptureOverviewSections(
                    model: model,
                    onViewPackets: onViewPackets,
                    onShowEndpoints: onShowEndpoints,
                    onSelectTrafficRow: onSelectTrafficRow
                )
            }
        } else {
            CaptureOverviewSections(
                model: model,
                onViewPackets: onViewPackets,
                onShowEndpoints: onShowEndpoints,
                onSelectTrafficRow: onSelectTrafficRow
            )
        }
    }
}

private struct CaptureOverviewSections: View {
    let model: CaptureOverviewDashboardModel
    let onViewPackets: () -> Void
    let onShowEndpoints: () -> Void
    let onSelectTrafficRow: (PacketSourceListSelection) -> Void

    var body: some View {
        VStack(spacing: 12) {
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
                    apps: model.topApps,
                    destinations: model.topDestinations,
                    onSelectRow: onSelectTrafficRow
                )
            } else {
                CaptureOverviewEmptyStateView()
            }
        }
    }
}

private struct CaptureOverviewBackgroundView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(colorScheme == .dark ? 0.035 : 0.02),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
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
            HStack(spacing: 14) {
                CaptureOverviewHeaderIdentity(title: title, subtitle: subtitle, status: status)
                Spacer(minLength: 20)
                CaptureOverviewHeaderActions(
                    hasTraffic: hasTraffic,
                    onViewPackets: onViewPackets,
                    onShowEndpoints: onShowEndpoints
                )
            }
            .frame(minWidth: 640)

            VStack(alignment: .leading, spacing: 12) {
                CaptureOverviewHeaderIdentity(title: title, subtitle: subtitle, status: status)
                CaptureOverviewHeaderActions(
                    hasTraffic: hasTraffic,
                    onViewPackets: onViewPackets,
                    onShowEndpoints: onShowEndpoints
                )
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

private struct CaptureOverviewHeaderIdentity: View {
    let title: String
    let subtitle: String
    let status: CaptureOverviewStatusPresentation

    var body: some View {
        HStack(spacing: 12) {
            CaptureOverviewHeaderIcon()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    CaptureOverviewStatusPill(status: status)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureOverviewHeaderIcon: View {
    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            icon
                .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 10))
        } else {
            icon
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var icon: some View {
        Image(systemName: "chart.xyaxis.line")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
    }
}

private struct CaptureOverviewStatusPill: View {
    let status: CaptureOverviewStatusPresentation

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.tone.color)
                .frame(width: 6, height: 6)
            Text(status.title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(status.tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.tone.color.opacity(0.12), in: Capsule())
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
            HStack(spacing: 8) {
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
            .controlSize(.regular)
        } else {
            HStack(spacing: 8) {
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
            .controlSize(.regular)
        }
    }
}

private struct CaptureOverviewMetricsView: View {
    let metrics: [CaptureOverviewMetricPresentation]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            CaptureOverviewMetricStrip(metrics: metrics)
                .frame(minWidth: 1_020)
            CaptureOverviewMetricGrid(metrics: metrics, columnCount: 3)
            CaptureOverviewMetricGrid(metrics: metrics, columnCount: 2)
        }
        .padding(.vertical, 4)
        .captureOverviewPanel()
    }
}

private struct CaptureOverviewMetricStrip: View {
    let metrics: [CaptureOverviewMetricPresentation]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(metrics) { metric in
                CaptureOverviewMetricCell(metric: metric)
                    .overlay(alignment: .trailing) {
                        if metric.id != metrics.last?.id {
                            Divider()
                                .padding(.vertical, 10)
                        }
                    }
            }
        }
    }
}

private struct CaptureOverviewMetricGrid: View {
    let metrics: [CaptureOverviewMetricPresentation]
    let columnCount: Int

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 0), count: columnCount),
            spacing: 0
        ) {
            ForEach(metrics) { metric in
                CaptureOverviewMetricCell(metric: metric)
            }
        }
    }
}

private struct CaptureOverviewMetricCell: View {
    let metric: CaptureOverviewMetricPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: metric.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(metric.tone.color)
                    .accessibilityHidden(true)
                Text(metric.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(metric.value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(metric.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
            HStack(alignment: .top, spacing: 0) {
                CaptureOverviewTrafficChartView(
                    points: trafficPoints,
                    hasDirectionalTraffic: hasDirectionalTraffic,
                    totalText: totalText,
                    sentText: sentText,
                    receivedText: receivedText
                )
                .frame(maxWidth: .infinity)
                Divider()
                    .padding(.vertical, 16)
                CaptureOverviewProtocolView(rows: protocols)
                    .frame(width: 370)
            }
            .frame(minWidth: 980)

            VStack(spacing: 0) {
                CaptureOverviewTrafficChartView(
                    points: trafficPoints,
                    hasDirectionalTraffic: hasDirectionalTraffic,
                    totalText: totalText,
                    sentText: sentText,
                    receivedText: receivedText
                )
                Divider()
                    .padding(.horizontal, 16)
                CaptureOverviewProtocolView(rows: protocols)
            }
        }
        .captureOverviewPanel()
    }
}

private struct CaptureOverviewTrafficChartView: View {
    let points: [CaptureOverviewChartPoint]
    let hasDirectionalTraffic: Bool
    let totalText: String
    let sentText: String
    let receivedText: String

    @State private var hoveredDate: Date?

    private var hoveredPoints: [CaptureOverviewChartPoint] {
        guard let hoveredDate else {
            return []
        }
        return points
            .filter { $0.date == hoveredDate }
            .sorted { $0.direction.sortOrder < $1.direction.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Chart {
                ForEach(points) { point in
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

                if let hoveredDate, !hoveredPoints.isEmpty {
                    RuleMark(x: .value("Hovered time", hoveredDate))
                        .foregroundStyle(Color.primary.opacity(0.24))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            CaptureOverviewChartTooltip(
                                title: hoveredDate.formatted(.dateTime.hour().minute().second()),
                                rows: hoveredPoints.map {
                                    CaptureOverviewChartTooltipRow(
                                        id: $0.direction.rawValue,
                                        title: $0.direction.rawValue,
                                        value: CaptureOverviewByteFormatting.string($0.bytes),
                                        color: $0.direction.color
                                    )
                                }
                            )
                        }

                    ForEach(hoveredPoints) { point in
                        PointMark(
                            x: .value("Hovered time", point.date),
                            y: .value("Hovered bytes", point.bytes)
                        )
                        .foregroundStyle(point.direction.color)
                        .symbolSize(50)
                    }
                }
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
                plotArea.background(Color.primary.opacity(0.018))
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                guard let plotFrame = proxy.plotFrame else {
                                    hoveredDate = nil
                                    return
                                }
                                let plotRect = geometry[plotFrame]
                                guard plotRect.contains(location),
                                      let date = proxy.value(
                                          atX: location.x - plotRect.minX,
                                          as: Date.self
                                      ) else {
                                    hoveredDate = nil
                                    return
                                }
                                hoveredDate = CaptureOverviewChartHoverSelection.nearestDate(
                                    to: date,
                                    in: points
                                )
                            case .ended:
                                hoveredDate = nil
                            }
                        }
                }
            }
            .accessibilityLabel(
                hasDirectionalTraffic ? "Sent and received traffic over time" : "Total traffic over time"
            )
        }
        .frame(maxWidth: .infinity, minHeight: 258, maxHeight: 258, alignment: .topLeading)
        .padding(16)
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

    @State private var hoverState: CaptureOverviewProtocolHoverState?

    private var protocolNames: [String] {
        rows.map(\.title)
    }

    private var protocolColors: [Color] {
        rows.map { CaptureOverviewPalette.protocolColor(at: $0.colorIndex) }
    }

    private var hoveredRow: CaptureOverviewProtocolPresentation? {
        guard let hoverState else {
            return nil
        }
        return rows.first { $0.id == hoverState.rowID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Protocols")
                    .font(.headline)
                Text("Share of captured bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Chart(rows) { row in
                    SectorMark(
                        angle: .value("Bytes", row.fraction),
                        innerRadius: .ratio(0.67),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Protocol", row.title))
                    .opacity(hoverState == nil || hoverState?.rowID == row.id ? 1 : 0.42)
                }
                .chartForegroundStyleScale(domain: protocolNames, range: protocolColors)
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(location):
                                        guard let plotFrame = proxy.plotFrame else {
                                            hoverState = nil
                                            return
                                        }
                                        let plotRect = geometry[plotFrame]
                                        let plotLocation = CGPoint(
                                            x: location.x - plotRect.minX,
                                            y: location.y - plotRect.minY
                                        )
                                        guard plotRect.contains(location),
                                              let row = CaptureOverviewChartHoverSelection.protocolRow(
                                                  at: plotLocation,
                                                  in: plotRect.size,
                                                  innerRadiusRatio: 0.67,
                                                  rows: rows
                                              ) else {
                                            hoverState = nil
                                            return
                                        }
                                        hoverState = CaptureOverviewProtocolHoverState(
                                            rowID: row.id,
                                            location: location
                                        )
                                    case .ended:
                                        hoverState = nil
                                    }
                                }

                            if let hoverState, let hoveredRow {
                                CaptureOverviewChartTooltip(
                                    title: hoveredRow.title,
                                    rows: [
                                        CaptureOverviewChartTooltipRow(
                                            id: hoveredRow.id,
                                            title: hoveredRow.percentageText,
                                            value: hoveredRow.totalText,
                                            color: CaptureOverviewPalette.protocolColor(
                                                at: hoveredRow.colorIndex
                                            )
                                        ),
                                    ]
                                )
                                .position(
                                    x: min(max(hoverState.location.x, 48), geometry.size.width - 48),
                                    y: hoverState.location.y < geometry.size.height / 2
                                        ? min(geometry.size.height - 24, hoverState.location.y + 34)
                                        : max(24, hoverState.location.y - 34)
                                )
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .overlay {
                    VStack(spacing: 2) {
                        Text("\(rows.count)")
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text(rows.count == 1 ? "protocol" : "protocols")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: 122, height: 122)
                .accessibilityLabel("Protocol traffic breakdown")

                VStack(spacing: 9) {
                    ForEach(rows) { row in
                        CaptureOverviewProtocolLegendRow(row: row)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 258, maxHeight: 258, alignment: .topLeading)
        .padding(16)
    }
}

private struct CaptureOverviewProtocolHoverState {
    let rowID: String
    let location: CGPoint
}

private struct CaptureOverviewChartTooltipRow: Identifiable {
    let id: String
    let title: String
    let value: String
    let color: Color
}

private struct CaptureOverviewChartTooltip: View {
    let title: String
    let rows: [CaptureOverviewChartTooltipRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 6, height: 6)
                    Text(row.title)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
        .fixedSize()
        .accessibilityHidden(true)
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
    let apps: [CaptureOverviewTopTrafficPresentation]
    let destinations: [CaptureOverviewTopTrafficPresentation]
    let onSelectRow: (PacketSourceListSelection) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                appRanking
                Divider()
                    .padding(.horizontal, 16)
                destinationRanking
            }
            .frame(minWidth: 900)

            VStack(spacing: 16) {
                appRanking
                Divider()
                destinationRanking
            }
        }
        .padding(16)
        .captureOverviewPanel()
    }

    private var appRanking: some View {
        CaptureOverviewTrafficRankingView(
            title: "Top apps",
            subtitle: "Top 10 by total traffic",
            emptyTitle: "No app traffic",
            emptyDescription: "Apps appear when TCP Viewer identifies the local process.",
            emptySymbol: "app.dashed",
            rows: apps,
            onSelect: onSelectRow
        )
    }

    private var destinationRanking: some View {
        CaptureOverviewTrafficRankingView(
            title: "Top domains & IPs",
            subtitle: "Top 10 by total traffic",
            emptyTitle: "No domains or IP addresses",
            emptyDescription: "Destinations appear as traffic is captured.",
            emptySymbol: "globe.desk",
            rows: destinations,
            onSelect: onSelectRow
        )
    }
}

private struct CaptureOverviewTrafficRankingView: View {
    let title: String
    let subtitle: String
    let emptyTitle: String
    let emptyDescription: String
    let emptySymbol: String
    let rows: [CaptureOverviewTopTrafficPresentation]
    let onSelect: (PacketSourceListSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: emptySymbol)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(emptyTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(emptyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button {
                            onSelect(row.selection)
                        } label: {
                            CaptureOverviewCompactTrafficRow(row: row)
                        }
                        .buttonStyle(CaptureOverviewTrafficRowButtonStyle())
                        .accessibilityLabel(
                            "Number \(row.rank), \(row.title), \(row.totalText), \(row.percentageText) of capture"
                        )
                        .accessibilityHint("Shows matching packets in the main table")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CaptureOverviewCompactTrafficRow: View {
    let row: CaptureOverviewTopTrafficPresentation

    var body: some View {
        HStack(spacing: 10) {
            Text("\(row.rank)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 18, alignment: .trailing)

            Image(nsImage: row.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.totalText)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    Text(row.percentageText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                }

                CaptureOverviewStackedTrafficBar(
                    sentFraction: row.sentFraction,
                    receivedFraction: row.receivedFraction,
                    unknownFraction: row.unknownFraction
                )
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
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
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct CaptureOverviewTrafficRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

private struct CaptureOverviewEmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "No traffic captured yet",
            systemImage: "waveform.path.ecg",
            description: Text("Start a capture or open a capture file. This overview will fill in as packets arrive.")
        )
        .frame(maxWidth: .infinity, minHeight: 280)
        .captureOverviewPanel()
    }
}

private struct CaptureOverviewPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(
                    Color(nsColor: .controlBackgroundColor)
                        .opacity(colorScheme == .dark ? 0.24 : 0.42),
                    in: shape
                )
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.05), radius: 8, y: 2)
        }
    }
}

private extension View {
    func captureOverviewPanel() -> some View {
        modifier(CaptureOverviewPanelModifier())
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
