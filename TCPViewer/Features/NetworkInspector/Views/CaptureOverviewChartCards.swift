//
//  CaptureOverviewChartCards.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/10/26.
//

import Charts
import SwiftUI

// MARK: - Hover

enum CaptureOverviewChartHoverSelection {
    // The slots fill the plot exactly, so a pointer fraction maps straight to one slot.
    static func slotIndex(fraction: CGFloat?, slotCount: Int) -> Int? {
        guard let fraction, slotCount > 0, fraction.isFinite else {
            return nil
        }
        return min(max(Int(fraction * CGFloat(slotCount)), 0), slotCount - 1)
    }

    // Show the tooltip beside the slot, flipped to the left near the trailing edge.
    static func tooltipX(slot: Int, slotCount: Int, width: CGFloat, tooltipWidth: CGFloat) -> CGFloat {
        let slotWidth = width / CGFloat(max(slotCount, 1))
        let trailing = slotWidth * CGFloat(slot + 1) + 8
        if trailing + tooltipWidth <= width {
            return trailing
        }
        return max(slotWidth * CGFloat(slot) - 8 - tooltipWidth, 0)
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

// Sits on the plot area only, so x = 0 is the start of the first slot.
private struct CaptureOverviewSlotHoverLayer<Tooltip: View>: View {
    let slotCount: Int
    let hoverFraction: CGFloat?
    let onHoverChange: (CGFloat?) -> Void
    @ViewBuilder let tooltip: (Int) -> Tooltip

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            onHoverChange(geometry.size.width > 0 ? location.x / geometry.size.width : nil)
                        case .ended:
                            onHoverChange(nil)
                        }
                    }

                if let slot = CaptureOverviewChartHoverSelection.slotIndex(fraction: hoverFraction, slotCount: slotCount) {
                    tooltip(slot)
                        .offset(
                            x: CaptureOverviewChartHoverSelection.tooltipX(
                                slot: slot,
                                slotCount: slotCount,
                                width: geometry.size.width,
                                tooltipWidth: CaptureOverviewChartTooltip.width
                            ),
                            y: 4
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

struct CaptureOverviewTooltipRow: Identifiable {
    let id: String
    let color: Color
    let title: String
    let value: String
}

private struct CaptureOverviewChartTooltip: View {
    static let width: CGFloat = 176

    let title: String
    let headline: String
    let rows: [CaptureOverviewTooltipRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 7, height: 7)
                    Text(row.title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CaptureOverviewStyle.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 3)
        .accessibilityHidden(true)
    }
}

// MARK: - Timeline Helpers

private extension CaptureOverviewTimelinePresentation {
    var xDomain: ClosedRange<Date> {
        let start = points.first?.date ?? Date(timeIntervalSince1970: 0)
        return start...start.addingTimeInterval(interval * Double(max(points.count, 1)))
    }

    func slotStart(_ index: Int) -> Date {
        points[index].date
    }

    func slotCenter(_ index: Int) -> Date {
        points[index].date.addingTimeInterval(interval / 2)
    }

    func slotEnd(_ index: Int) -> Date {
        points[index].date.addingTimeInterval(interval)
    }

    func slotTitle(_ index: Int) -> String {
        "\(CaptureOverviewFormat.time(slotStart(index), slotInterval: interval)) – " +
            CaptureOverviewFormat.time(slotEnd(index), slotInterval: interval)
    }

    var axisFormat: Date.FormatStyle {
        if interval < 60 {
            return .dateTime.hour().minute().second()
        }
        if interval < 86_400 {
            return .dateTime.hour().minute()
        }
        // Captures merged from different years need the year to tell the labels apart.
        if interval * Double(points.count) < 300 * 86_400 {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.year().month(.abbreviated)
    }
}

// MARK: - Packets

// Packets per time slot with TCP problems stacked in red, like Wireshark's default I/O Graph.
struct CaptureOverviewPacketsCard: View {
    let timeline: CaptureOverviewTimelinePresentation

    @State private var hoverFraction: CGFloat?

    private var points: [CaptureOverviewTimelinePoint] { timeline.points }

    private var hoveredIndex: Int? {
        CaptureOverviewChartHoverSelection.slotIndex(fraction: hoverFraction, slotCount: points.count)
    }

    private var subtitle: String {
        let peak = points.map(\.totals.packets).max() ?? 0
        return "Packets every \(CaptureOverviewFormat.span(timeline.interval)) · Peak \(CaptureOverviewFormat.count(peak))"
    }

    var body: some View {
        CaptureOverviewCardView(card: .packets, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    CaptureOverviewLegendItem(
                        color: .blue,
                        title: "Packets",
                        value: CaptureOverviewFormat.count(timeline.totals.packets)
                    )
                    if timeline.totals.issuePackets > 0 {
                        CaptureOverviewLegendItem(
                            color: CaptureOverviewStyle.issue,
                            title: "TCP Issues",
                            value: CaptureOverviewFormat.count(timeline.totals.issuePackets)
                        )
                    }
                }
                .lineLimit(1)
                if points.isEmpty {
                    CaptureOverviewPlaceholder(text: "No packets yet")
                } else {
                    chart
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            // Behind the bars, so the hovered slot reads like a selected column.
            if let index = hoveredIndex {
                RectangleMark(xStart: .value("Start", timeline.slotStart(index)), xEnd: .value("End", timeline.slotEnd(index)))
                    .foregroundStyle(CaptureOverviewStyle.hover)
            }
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                // Stack by hand: the issue bar starts where the normal packets end.
                let issues = Int(clamping: point.totals.issuePackets)
                let normal = Int(clamping: point.totals.packets) - issues
                if normal > 0 {
                    bar(index, from: 0, to: normal, color: .blue)
                }
                if issues > 0 {
                    bar(index, from: normal, to: normal + issues, color: CaptureOverviewStyle.issue)
                }
            }
        }
        .chartXScale(domain: timeline.xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: timeline.axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    Text(CaptureOverviewFormat.count(UInt64(max(0, value.as(Double.self) ?? 0))))
                }
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { plotArea in
            plotArea.overlay {
                CaptureOverviewSlotHoverLayer(
                    slotCount: points.count,
                    hoverFraction: hoverFraction,
                    onHoverChange: { hoverFraction = $0 },
                    tooltip: tooltip
                )
            }
        }
        .accessibilityLabel("Packets over time")
    }

    private func bar(_ index: Int, from start: Int, to end: Int, color: Color) -> some ChartContent {
        // Leave a small gap between slots.
        let inset = timeline.interval * 0.1
        return RectangleMark(
            xStart: .value("Start", timeline.slotStart(index).addingTimeInterval(inset)),
            xEnd: .value("End", timeline.slotEnd(index).addingTimeInterval(-inset)),
            yStart: .value("Packets", start),
            yEnd: .value("Packets", end)
        )
        .foregroundStyle(color.gradient)
        .cornerRadius(2)
    }

    private func tooltip(_ index: Int) -> CaptureOverviewChartTooltip {
        let totals = points[index].totals
        var rows: [CaptureOverviewTooltipRow] = []
        if totals.issuePackets > 0 {
            rows.append(CaptureOverviewTooltipRow(
                id: "issues",
                color: CaptureOverviewStyle.issue,
                title: "TCP Issues",
                value: CaptureOverviewFormat.count(totals.issuePackets)
            ))
        }
        rows += CaptureOverviewThroughputSeries.series(for: timeline.totals).map { series in
            CaptureOverviewTooltipRow(
                id: series.id,
                color: series.color,
                title: series.id,
                value: CaptureOverviewFormat.bytes(totals[keyPath: series.bytes])
            )
        }
        return CaptureOverviewChartTooltip(
            title: timeline.slotTitle(index),
            headline: "\(CaptureOverviewFormat.count(totals.packets)) packets",
            rows: rows
        )
    }
}

// MARK: - Throughput

// One line per direction; captures without a local address only have a total.
private struct CaptureOverviewThroughputSeries: Identifiable {
    let id: String
    let color: Color
    let bytes: KeyPath<CaptureOverviewTrafficTotals, UInt64>

    static func series(for totals: CaptureOverviewTrafficTotals) -> [CaptureOverviewThroughputSeries] {
        guard totals.sentBytes > 0 || totals.receivedBytes > 0 else {
            return [CaptureOverviewThroughputSeries(id: "Total", color: .orange, bytes: \.bytes)]
        }
        var series = [
            CaptureOverviewThroughputSeries(id: "Received", color: CaptureOverviewStyle.received, bytes: \.receivedBytes),
            CaptureOverviewThroughputSeries(id: "Sent", color: CaptureOverviewStyle.sent, bytes: \.sentBytes),
        ]
        if totals.unclassifiedBytes > 0 {
            series.append(CaptureOverviewThroughputSeries(
                id: "Other",
                color: CaptureOverviewStyle.unknownDirection,
                bytes: \.unclassifiedBytes
            ))
        }
        return series
    }
}

// Bytes per second per direction; hovering a slot shows each rate.
struct CaptureOverviewThroughputCard: View {
    let timeline: CaptureOverviewTimelinePresentation

    @State private var hoverFraction: CGFloat?

    private var points: [CaptureOverviewTimelinePoint] { timeline.points }
    private var series: [CaptureOverviewThroughputSeries] { CaptureOverviewThroughputSeries.series(for: timeline.totals) }

    private var hoveredIndex: Int? {
        CaptureOverviewChartHoverSelection.slotIndex(fraction: hoverFraction, slotCount: points.count)
    }

    private var subtitle: String {
        guard let peak = points.map(\.totals.bytes).max(), peak > 0 else {
            return "Bytes per second"
        }
        return "Peak \(CaptureOverviewFormat.rate(rate(peak))) · per \(CaptureOverviewFormat.span(timeline.interval))"
    }

    var body: some View {
        CaptureOverviewCardView(card: .throughput, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    ForEach(series) { series in
                        CaptureOverviewLegendItem(
                            color: series.color,
                            title: series.id,
                            value: CaptureOverviewFormat.bytes(timeline.totals[keyPath: series.bytes])
                        )
                    }
                }
                .lineLimit(1)
                if points.isEmpty {
                    CaptureOverviewPlaceholder(text: "No packets yet")
                } else {
                    chart
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            if let index = hoveredIndex {
                RectangleMark(xStart: .value("Start", timeline.slotStart(index)), xEnd: .value("End", timeline.slotEnd(index)))
                    .foregroundStyle(CaptureOverviewStyle.hover)
            }
            // Every direction starts at zero, so a small series is never hidden under a large one.
            ForEach(series) { series in
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    let value = rate(point.totals[keyPath: series.bytes])
                    AreaMark(
                        x: .value("Time", timeline.slotCenter(index)),
                        yStart: .value("Rate", 0),
                        yEnd: .value("Rate", value),
                        series: .value("Area", series.id)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [series.color.opacity(0.35), series.color.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", timeline.slotCenter(index)),
                        y: .value("Rate", value),
                        series: .value("Line", series.id)
                    )
                    .foregroundStyle(series.color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
            }
            if let index = hoveredIndex {
                ForEach(series) { series in
                    PointMark(
                        x: .value("Time", timeline.slotCenter(index)),
                        y: .value("Rate", rate(points[index].totals[keyPath: series.bytes]))
                    )
                    .foregroundStyle(series.color)
                }
            }
        }
        .chartXScale(domain: timeline.xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: timeline.axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    Text(CaptureOverviewFormat.rate(value.as(Double.self) ?? 0))
                }
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { plotArea in
            plotArea.overlay {
                CaptureOverviewSlotHoverLayer(
                    slotCount: points.count,
                    hoverFraction: hoverFraction,
                    onHoverChange: { hoverFraction = $0 },
                    tooltip: tooltip
                )
            }
        }
        .accessibilityLabel("Throughput over time")
    }

    private func rate(_ bytes: UInt64) -> Double {
        Double(bytes) / max(timeline.interval, 1)
    }

    private func tooltip(_ index: Int) -> CaptureOverviewChartTooltip {
        let totals = points[index].totals
        var rows = series.map { series in
            CaptureOverviewTooltipRow(
                id: series.id,
                color: series.color,
                title: series.id,
                value: CaptureOverviewFormat.rate(rate(totals[keyPath: series.bytes]))
            )
        }
        rows.append(CaptureOverviewTooltipRow(
            id: "packets",
            color: .blue,
            title: "Packets",
            value: CaptureOverviewFormat.count(totals.packets)
        ))
        return CaptureOverviewChartTooltip(
            title: timeline.slotTitle(index),
            headline: CaptureOverviewFormat.rate(rate(totals.bytes)),
            rows: rows
        )
    }
}

// MARK: - Protocols

private enum CaptureOverviewProtocolPalette {
    static let colors: [Color] = [.blue, .cyan, .purple, .orange, .green, .pink]

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

// The protocol column's share of captured bytes, as a donut and a legend beside it.
struct CaptureOverviewProtocolsCard: View {
    private static let innerRadiusRatio: CGFloat = 0.62

    let rows: [CaptureOverviewProtocolPresentation]

    @State private var hoveredRowID: String?
    @State private var hoverLocation: CGPoint = .zero

    private var hoveredRow: CaptureOverviewProtocolPresentation? {
        rows.first { $0.id == hoveredRowID }
    }

    var body: some View {
        CaptureOverviewCardView(card: .protocols, subtitle: "Share of captured bytes") {
            if rows.isEmpty {
                CaptureOverviewPlaceholder(text: "No packets yet")
            } else {
                HStack(alignment: .center, spacing: 14) {
                    donut
                        .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            legendRow(row)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var donut: some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value("Bytes", row.fraction),
                innerRadius: .ratio(Self.innerRadiusRatio),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(CaptureOverviewProtocolPalette.color(at: row.colorIndex))
            .opacity(hoveredRowID == nil || hoveredRowID == row.id ? 1 : 0.4)
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredRowID = row(at: location, proxy: proxy, geometry: geometry)?.id
                                hoverLocation = location
                            case .ended:
                                hoveredRowID = nil
                            }
                        }

                    if let hoveredRow {
                        CaptureOverviewChartTooltip(
                            title: hoveredRow.title,
                            headline: hoveredRow.percentageText,
                            rows: [
                                CaptureOverviewTooltipRow(
                                    id: hoveredRow.id,
                                    color: CaptureOverviewProtocolPalette.color(at: hoveredRow.colorIndex),
                                    title: "Bytes",
                                    value: hoveredRow.totalText
                                ),
                            ]
                        )
                        // The donut is small, so the tooltip floats beside the pointer, outside the ring.
                        .offset(x: hoverLocation.x + 12, y: hoverLocation.y - 30)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .overlay {
            VStack(spacing: 1) {
                Text("\(rows.count)")
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                Text(rows.count == 1 ? "protocol" : "protocols")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        }
        .zIndex(1)
        .accessibilityLabel("Protocol traffic breakdown")
    }

    private func row(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CaptureOverviewProtocolPresentation? {
        guard let plotFrame = proxy.plotFrame else {
            return nil
        }
        let plotRect = geometry[plotFrame]
        guard plotRect.contains(location) else {
            return nil
        }
        return CaptureOverviewChartHoverSelection.protocolRow(
            at: CGPoint(x: location.x - plotRect.minX, y: location.y - plotRect.minY),
            in: plotRect.size,
            innerRadiusRatio: Self.innerRadiusRatio,
            rows: rows
        )
    }

    private func legendRow(_ row: CaptureOverviewProtocolPresentation) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(CaptureOverviewProtocolPalette.color(at: row.colorIndex))
                .frame(width: 7, height: 7)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(row.totalText)
                .fontWeight(.medium)
                .monospacedDigit()
            Text(row.percentageText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 11))
        .opacity(hoveredRowID == nil || hoveredRowID == row.id ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Packet Lengths

// Wireshark's Packet Lengths statistics as a histogram; hovering a bar shows its share.
struct CaptureOverviewPacketLengthsCard: View {
    let rows: [CaptureOverviewPacketLengthPresentation]
    let subtitle: String

    @State private var hoverFraction: CGFloat?

    private var hoveredIndex: Int? {
        CaptureOverviewChartHoverSelection.slotIndex(fraction: hoverFraction, slotCount: rows.count)
    }

    var body: some View {
        CaptureOverviewCardView(card: .packetLengths, subtitle: subtitle) {
            if rows.allSatisfy({ $0.count == 0 }) {
                CaptureOverviewPlaceholder(text: "No packets yet")
            } else {
                chart
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var chart: some View {
        Chart(rows) { row in
            BarMark(
                x: .value("Length", row.axisTitle),
                y: .value("Packets", Int(clamping: row.count)),
                width: .ratio(0.62)
            )
            .foregroundStyle(Color.pink.gradient)
            .cornerRadius(4)
            .opacity(hoveredIndex == nil || hoveredIndex == row.id ? 1 : 0.45)
            .annotation(position: .top, spacing: 3) {
                Text(Int(clamping: row.count).formatted(.number.notation(.compactName)))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.system(size: 9))
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.overlay {
                CaptureOverviewSlotHoverLayer(
                    slotCount: rows.count,
                    hoverFraction: hoverFraction,
                    onHoverChange: { hoverFraction = $0 },
                    tooltip: tooltip
                )
            }
        }
        .accessibilityLabel("Packet lengths histogram")
    }

    private func tooltip(_ index: Int) -> CaptureOverviewChartTooltip {
        let row = rows[index]
        return CaptureOverviewChartTooltip(
            title: row.title,
            headline: "\(CaptureOverviewFormat.count(row.count)) packets",
            rows: [
                CaptureOverviewTooltipRow(id: "share", color: .pink, title: "Of all packets", value: row.percentageText),
            ]
        )
    }
}
