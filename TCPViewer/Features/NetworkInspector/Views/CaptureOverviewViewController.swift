//
//  CaptureOverviewViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import AppKit
import PcapPlusPlusCore

protocol CaptureOverviewViewControllerDelegate: AnyObject {
    func captureOverviewViewControllerDidRequestPackets(_ controller: CaptureOverviewViewController)
    func captureOverviewViewControllerDidRequestEndpoints(_ controller: CaptureOverviewViewController)
    func captureOverviewViewController(
        _ controller: CaptureOverviewViewController,
        didSelect selection: PacketSourceListSelection
    )
}

private class CaptureOverviewCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }
}

private final class CaptureOverviewMetricView: CaptureOverviewCardView {
    private let titleLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
        color: .secondaryLabelColor
    )
    private let valueLabel = TCPViewerUI.label(
        "",
        font: .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
    )
    private let detailLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
        color: .tertiaryLabelColor
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [titleLabel, valueLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        valueLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(title: String, value: String, detail: String = "") {
        titleLabel.stringValue = title
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
    }
}

private final class CaptureOverviewTrafficBarView: NSView {
    private var totals = CaptureOverviewTrafficTotals()
    private var maximumBytes: UInt64 = 0

    override var isFlipped: Bool { true }

    func render(totals: CaptureOverviewTrafficTotals, maximumBytes: UInt64) {
        self.totals = totals
        self.maximumBytes = maximumBytes
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        backgroundPath.fill()
        guard maximumBytes > 0, totals.bytes > 0, bounds.width > 0 else {
            return
        }

        let usedWidth = bounds.width * CGFloat(Double(totals.bytes) / Double(maximumBytes))
        let parts = [
            (totals.sentBytes, NSColor.systemBlue),
            (totals.receivedBytes, NSColor.systemTeal),
            (totals.unclassifiedBytes, NSColor.systemGray),
        ]
        var currentX: CGFloat = 0
        for (bytes, color) in parts where bytes > 0 {
            let width = usedWidth * CGFloat(Double(bytes) / Double(totals.bytes))
            color.setFill()
            NSBezierPath(rect: NSRect(x: currentX, y: 0, width: width, height: bounds.height)).fill()
            currentX += width
        }
    }
}

private final class CaptureOverviewTopCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureOverviewTopCell")

    private let iconView = NSImageView()
    private let titleLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    )
    private let trafficLabel = TCPViewerUI.label(
        "",
        font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .secondaryLabelColor
    )
    private let barView = CaptureOverviewTrafficBarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingMiddle
        trafficLabel.alignment = .right
        trafficLabel.lineBreakMode = .byTruncatingTail
        barView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(trafficLabel)
        addSubview(barView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trafficLabel.leadingAnchor, constant: -8),

            trafficLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            trafficLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            trafficLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),

            barView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            barView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            barView.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        row: CaptureOverviewTopRow,
        icon: NSImage?,
        maximumBytes: UInt64,
        captureBytes: UInt64,
        byteFormatter: ByteCountFormatter
    ) {
        titleLabel.stringValue = row.title
        iconView.image = icon
        iconView.contentTintColor = icon?.isTemplate == true ? .secondaryLabelColor : nil
        let percentage = captureBytes > 0 ? Int((Double(row.totals.bytes) / Double(captureBytes) * 100).rounded()) : 0
        let total = byteFormatter.string(fromByteCount: Int64(clamping: row.totals.bytes))
        let sent = byteFormatter.string(fromByteCount: Int64(clamping: row.totals.sentBytes))
        let received = byteFormatter.string(fromByteCount: Int64(clamping: row.totals.receivedBytes))
        trafficLabel.stringValue = "\(total) · ↑\(sent) ↓\(received) · \(percentage)%"
        barView.render(totals: row.totals, maximumBytes: maximumBytes)
        toolTip = "\(row.title)\n\(trafficLabel.stringValue)"
    }
}

private final class CaptureOverviewProtocolRowView: NSView {
    private let titleLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    )
    private let valueLabel = TCPViewerUI.label(
        "",
        font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .secondaryLabelColor
    )
    private let barView = CaptureOverviewTrafficBarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.alignment = .right
        barView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(barView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),
            barView.leadingAnchor.constraint(equalTo: leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: trailingAnchor),
            barView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            barView.heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        row: CaptureOverviewProtocolRow,
        totalBytes: UInt64,
        byteFormatter: ByteCountFormatter
    ) {
        titleLabel.stringValue = row.title
        let percentage = totalBytes > 0 ? Int((Double(row.totals.bytes) / Double(totalBytes) * 100).rounded()) : 0
        valueLabel.stringValue = "\(percentage)% · \(byteFormatter.string(fromByteCount: Int64(clamping: row.totals.bytes)))"
        barView.render(totals: row.totals, maximumBytes: totalBytes)
    }
}

private final class CaptureOverviewTrafficChartView: NSView, NSViewToolTipOwner {
    private var points: [CaptureOverviewTimelinePoint] = []
    private let byteFormatter: ByteCountFormatter
    private let timeFormatter: DateFormatter
    private var toolTipTag: NSView.ToolTipTag = 0

    init(byteFormatter: ByteCountFormatter) {
        self.byteFormatter = byteFormatter
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        timeFormatter = formatter
        super.init(frame: .zero)
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func render(points: [CaptureOverviewTimelinePoint]) {
        self.points = points
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if toolTipTag != 0 {
            removeToolTip(toolTipTag)
        }
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = plotRect
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        for index in 0...3 {
            let y = plot.minY + plot.height * CGFloat(index) / 3
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = 0.5
            path.stroke()
        }
        guard !points.isEmpty else {
            return
        }
        let maximum = points.reduce(UInt64(0)) { currentMaximum, point in
            max(currentMaximum, point.totals.sentBytes, point.totals.receivedBytes)
        }
        drawPath(for: \CaptureOverviewTrafficTotals.sentBytes, maximum: maximum, color: .systemBlue, in: plot)
        drawPath(for: \CaptureOverviewTrafficTotals.receivedBytes, maximum: maximum, color: .systemTeal, in: plot)
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let item = nearestPoint(to: point) else {
            return "No traffic"
        }
        return [
            timeFormatter.string(from: item.date),
            "Sent \(byteFormatter.string(fromByteCount: Int64(clamping: item.totals.sentBytes)))",
            "Received \(byteFormatter.string(fromByteCount: Int64(clamping: item.totals.receivedBytes)))",
            "\(item.totals.packets) packets",
        ].joined(separator: "\n")
    }

    private var plotRect: NSRect {
        bounds.insetBy(dx: 8, dy: 8)
    }

    private func drawPath(
        for keyPath: KeyPath<CaptureOverviewTrafficTotals, UInt64>,
        maximum: UInt64,
        color: NSColor,
        in plot: NSRect
    ) {
        guard maximum > 0 else {
            return
        }
        let firstDate = points.first?.date.timeIntervalSince1970 ?? 0
        let lastDate = points.last?.date.timeIntervalSince1970 ?? firstDate
        let span = max(1, lastDate - firstDate)
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let x = plot.minX + plot.width * CGFloat((point.date.timeIntervalSince1970 - firstDate) / span)
            let ratio = CGFloat(Double(point.totals[keyPath: keyPath]) / Double(maximum))
            let y = plot.maxY - plot.height * ratio
            if index == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        color.setStroke()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
        if points.count == 1, let point = points.first {
            let ratio = CGFloat(Double(point.totals[keyPath: keyPath]) / Double(maximum))
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: plot.minX - 2, y: plot.maxY - plot.height * ratio - 2, width: 4, height: 4)).fill()
        }
    }

    private func nearestPoint(to point: NSPoint) -> CaptureOverviewTimelinePoint? {
        guard !points.isEmpty else {
            return nil
        }
        guard let firstDate = points.first?.date.timeIntervalSince1970,
              let lastDate = points.last?.date.timeIntervalSince1970 else {
            return nil
        }
        let fraction = min(1, max(0, (point.x - plotRect.minX) / max(1, plotRect.width)))
        let targetDate = firstDate + (lastDate - firstDate) * Double(fraction)
        return points.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince1970 - targetDate) < abs(rhs.date.timeIntervalSince1970 - targetDate)
        }
    }
}

final class CaptureOverviewViewController: NSViewController {
    weak var delegate: CaptureOverviewViewControllerDelegate?

    private let latestIngestStateProvider: () -> PacketIngestState
    private var service: CaptureOverviewService?
    private var latestNetworkSnapshot: NetworkInspectorSnapshot?
    private var overviewSnapshot = CaptureOverviewSnapshot.empty
    private var selectedTopGroup = CaptureOverviewTopGroup.apps
    private var renderedBackingIdentity: String?
    private var renderedPacketLineageRevision: UInt64?

    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let sourceLabel = TCPViewerUI.label("Overview", font: .systemFont(ofSize: 24, weight: .semibold))
    private let sourceDetailLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .secondaryLabelColor
    )
    private let viewPacketsButton = NSButton(title: "View Packets", target: nil, action: nil)
    private let endpointsButton = NSButton(title: "Endpoints…", target: nil, action: nil)
    private let durationMetric = CaptureOverviewMetricView()
    private let packetMetric = CaptureOverviewMetricView()
    private let trafficMetric = CaptureOverviewMetricView()
    private let directionMetric = CaptureOverviewMetricView()
    private let chartView: CaptureOverviewTrafficChartView
    private let topSegment = NSSegmentedControl(
        labels: CaptureOverviewTopGroup.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let topTableView = NSTableView()
    private let topScrollView = NSScrollView()
    private let topEmptyLabel = TCPViewerUI.label(
        "No app traffic yet.",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .secondaryLabelColor
    )
    private let protocolStack = NSStackView()
    private let protocolEmptyLabel = TCPViewerUI.label(
        "No protocol traffic yet.",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .secondaryLabelColor
    )
    private let noTrafficCard = CaptureOverviewCardView()
    private let noTrafficLabel = TCPViewerUI.label(
        "No traffic captured yet.",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .secondaryLabelColor
    )
    private let warningCard = CaptureOverviewCardView()
    private let warningLabel = TCPViewerUI.label(
        "",
        font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        color: .systemOrange
    )
    private let detailsButton = NSButton(title: "Capture details", target: nil, action: nil)
    private let detailsLabel = TCPViewerUI.label(
        "",
        font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        color: .secondaryLabelColor
    )
    private let byteFormatter: ByteCountFormatter
    private let numberFormatter: NumberFormatter
    private let dateFormatter: DateFormatter
    private let durationFormatter = DateComponentsFormatter()
    private var iconCache: [String: NSImage] = [:]
    private weak var chartCard: NSView?
    private weak var trafficDetailsView: NSView?

    init(latestIngestStateProvider: @escaping () -> PacketIngestState) {
        self.latestIngestStateProvider = latestIngestStateProvider

        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        byteFormatter.allowedUnits = .useAll
        byteFormatter.includesUnit = true
        self.byteFormatter = byteFormatter
        chartView = CaptureOverviewTrafficChartView(byteFormatter: byteFormatter)

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.maximumFractionDigits = 0
        self.numberFormatter = numberFormatter

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        self.dateFormatter = dateFormatter

        durationFormatter.allowedUnits = [.day, .hour, .minute, .second]
        durationFormatter.unitsStyle = .abbreviated
        durationFormatter.maximumUnitCount = 2
        durationFormatter.zeroFormattingBehavior = .pad
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        service?.cancel()
    }

    override func loadView() {
        view = TCPViewerDynamicBackgroundView(backgroundColor: .windowBackgroundColor)
        setupLayout()
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        let ingestState = snapshot.base.packetIngestState
        if renderedBackingIdentity != ingestState.backingIdentity ||
            renderedPacketLineageRevision != ingestState.packetLineageRevision {
            overviewSnapshot = .empty
            renderedBackingIdentity = ingestState.backingIdentity
            renderedPacketLineageRevision = ingestState.packetLineageRevision
        }
        latestNetworkSnapshot = snapshot
        if snapshot.workspaceMode == .overview, service == nil {
            let service = CaptureOverviewService(latestIngestStateProvider: latestIngestStateProvider)
            service.snapshotHandler = { [weak self] overviewSnapshot in
                guard let self else {
                    return
                }
                self.overviewSnapshot = overviewSnapshot
                self.renderContent()
            }
            self.service = service
        }
        service?.consume(ingestState)
        renderContent()
    }

    // Build a scrollable dashboard that keeps the most useful capture metrics visible first.
    private func setupLayout() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceDetailLabel.lineBreakMode = .byTruncatingMiddle
        viewPacketsButton.target = self
        viewPacketsButton.action = #selector(showPackets(_:))
        viewPacketsButton.bezelStyle = .rounded
        endpointsButton.target = self
        endpointsButton.action = #selector(showEndpoints(_:))
        endpointsButton.bezelStyle = .rounded

        let headerText = NSStackView(views: [sourceLabel, sourceDetailLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        let headerButtons = NSStackView(views: [viewPacketsButton, endpointsButton])
        headerButtons.orientation = .horizontal
        headerButtons.alignment = .centerY
        headerButtons.spacing = 8
        let header = NSStackView(views: [headerText, headerButtons])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .gravityAreas

        let metrics = NSStackView(views: [durationMetric, packetMetric, trafficMetric, directionMetric])
        metrics.orientation = .horizontal
        metrics.alignment = .top
        metrics.distribution = .fillEqually
        metrics.spacing = 12
        for metric in [durationMetric, packetMetric, trafficMetric, directionMetric] {
            metric.heightAnchor.constraint(equalToConstant: 92).isActive = true
        }

        let chartCard = sectionCard(title: "Traffic over time", accessory: trafficLegend(), content: chartView)
        self.chartCard = chartCard
        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartView.heightAnchor.constraint(equalToConstant: 210).isActive = true

        setupTopTable()
        topSegment.selectedSegment = selectedTopGroup.rawValue
        topSegment.target = self
        topSegment.action = #selector(changeTopGroup(_:))
        topSegment.controlSize = .small
        let topContainer = NSView()
        topContainer.translatesAutoresizingMaskIntoConstraints = false
        topScrollView.translatesAutoresizingMaskIntoConstraints = false
        topEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        topEmptyLabel.alignment = .center
        topContainer.addSubview(topScrollView)
        topContainer.addSubview(topEmptyLabel)
        NSLayoutConstraint.activate([
            topContainer.heightAnchor.constraint(equalToConstant: 330),
            topScrollView.leadingAnchor.constraint(equalTo: topContainer.leadingAnchor),
            topScrollView.trailingAnchor.constraint(equalTo: topContainer.trailingAnchor),
            topScrollView.topAnchor.constraint(equalTo: topContainer.topAnchor),
            topScrollView.bottomAnchor.constraint(equalTo: topContainer.bottomAnchor),
            topEmptyLabel.centerXAnchor.constraint(equalTo: topContainer.centerXAnchor),
            topEmptyLabel.centerYAnchor.constraint(equalTo: topContainer.centerYAnchor),
        ])
        let topCard = sectionCard(title: "Top traffic", accessory: topSegment, content: topContainer)

        protocolStack.orientation = .vertical
        protocolStack.alignment = .width
        protocolStack.spacing = 8
        protocolStack.translatesAutoresizingMaskIntoConstraints = false
        protocolEmptyLabel.alignment = .center
        protocolEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let protocolContainer = NSView()
        protocolContainer.translatesAutoresizingMaskIntoConstraints = false
        protocolContainer.addSubview(protocolStack)
        protocolContainer.addSubview(protocolEmptyLabel)
        NSLayoutConstraint.activate([
            protocolContainer.heightAnchor.constraint(equalToConstant: 330),
            protocolStack.leadingAnchor.constraint(equalTo: protocolContainer.leadingAnchor),
            protocolStack.trailingAnchor.constraint(equalTo: protocolContainer.trailingAnchor),
            protocolStack.topAnchor.constraint(equalTo: protocolContainer.topAnchor),
            protocolEmptyLabel.centerXAnchor.constraint(equalTo: protocolContainer.centerXAnchor),
            protocolEmptyLabel.centerYAnchor.constraint(equalTo: protocolContainer.centerYAnchor),
        ])
        let protocolCard = sectionCard(title: "Traffic by protocol", content: protocolContainer)

        let trafficDetails = NSStackView(views: [topCard, protocolCard])
        trafficDetailsView = trafficDetails
        trafficDetails.orientation = .horizontal
        trafficDetails.alignment = .top
        trafficDetails.distribution = .fillEqually
        trafficDetails.spacing = 12

        noTrafficLabel.alignment = .center
        noTrafficLabel.translatesAutoresizingMaskIntoConstraints = false
        noTrafficCard.addSubview(noTrafficLabel)
        NSLayoutConstraint.activate([
            noTrafficLabel.leadingAnchor.constraint(equalTo: noTrafficCard.leadingAnchor, constant: 14),
            noTrafficLabel.trailingAnchor.constraint(equalTo: noTrafficCard.trailingAnchor, constant: -14),
            noTrafficLabel.topAnchor.constraint(equalTo: noTrafficCard.topAnchor, constant: 28),
            noTrafficLabel.bottomAnchor.constraint(equalTo: noTrafficCard.bottomAnchor, constant: -28),
        ])

        warningLabel.maximumNumberOfLines = 3
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningCard.addSubview(warningLabel)
        NSLayoutConstraint.activate([
            warningLabel.leadingAnchor.constraint(equalTo: warningCard.leadingAnchor, constant: 14),
            warningLabel.trailingAnchor.constraint(equalTo: warningCard.trailingAnchor, constant: -14),
            warningLabel.topAnchor.constraint(equalTo: warningCard.topAnchor, constant: 12),
            warningLabel.bottomAnchor.constraint(equalTo: warningCard.bottomAnchor, constant: -12),
        ])

        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails(_:))
        detailsButton.setButtonType(.onOff)
        detailsButton.bezelStyle = .disclosure
        detailsButton.state = .off
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.isHidden = true
        let detailsStack = NSStackView(views: [detailsButton, detailsLabel])
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 8

        let rootStack = NSStackView(views: [
            header,
            metrics,
            noTrafficCard,
            chartCard,
            trafficDetails,
            warningCard,
            detailsStack,
        ])
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 16
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rootStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -22),
            rootStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -22),
        ])
    }

    private func setupTopTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topTraffic"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        topTableView.addTableColumn(column)
        topTableView.headerView = nil
        topTableView.rowHeight = 42
        topTableView.backgroundColor = .clear
        topTableView.selectionHighlightStyle = .regular
        topTableView.intercellSpacing = NSSize(width: 0, height: 2)
        topTableView.delegate = self
        topTableView.dataSource = self
        topTableView.target = self
        topTableView.action = #selector(openSelectedTopRow(_:))
        topScrollView.documentView = topTableView
        topScrollView.hasVerticalScroller = true
        topScrollView.drawsBackground = false
    }

    private func sectionCard(title: String, accessory: NSView? = nil, content: NSView) -> CaptureOverviewCardView {
        let card = CaptureOverviewCardView()
        let titleLabel = TCPViewerUI.label(
            title,
            font: .systemFont(ofSize: 15, weight: .semibold)
        )
        let headerViews = [titleLabel, accessory].compactMap { $0 }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .gravityAreas
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    private func trafficLegend() -> NSView {
        let sent = legendLabel(title: "Sent", color: .systemBlue)
        let received = legendLabel(title: "Received", color: .systemTeal)
        let stack = NSStackView(views: [sent, received])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func legendLabel(title: String, color: NSColor) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        let label = TCPViewerUI.label(
            title,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .secondaryLabelColor
        )
        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    // Render the latest immutable aggregate together with current capture health and source state.
    private func renderContent() {
        guard isViewLoaded, let network = latestNetworkSnapshot else {
            return
        }
        sourceLabel.stringValue = sourceTitle(network)
        sourceDetailLabel.stringValue = sourceDetails(network)
        endpointsButton.isEnabled = overviewSnapshot.totals.packets > 0
        noTrafficCard.isHidden = overviewSnapshot.totals.packets > 0
        chartCard?.isHidden = overviewSnapshot.totals.packets == 0
        trafficDetailsView?.isHidden = overviewSnapshot.totals.packets == 0

        durationMetric.render(
            title: "Duration",
            value: durationText,
            detail: overviewSnapshot.firstPacketDate.map { "Started \(dateFormatter.string(from: $0))" } ?? "No packets yet"
        )
        packetMetric.render(
            title: "Packets",
            value: formattedNumber(overviewSnapshot.totals.packets),
            detail: "\(overviewSnapshot.appCount) apps · \(overviewSnapshot.domainCount) domains"
        )
        trafficMetric.render(
            title: "Total traffic",
            value: formattedBytes(overviewSnapshot.totals.bytes),
            detail: overviewSnapshot.totals.unclassifiedBytes > 0
                ? "\(formattedBytes(overviewSnapshot.totals.unclassifiedBytes)) unclassified"
                : "Original packet size"
        )
        directionMetric.render(
            title: "Sent / Received",
            value: "↑ \(formattedBytes(overviewSnapshot.totals.sentBytes))",
            detail: "↓ \(formattedBytes(overviewSnapshot.totals.receivedBytes))"
        )
        chartView.render(points: overviewSnapshot.timeline)
        renderTopRows()
        renderProtocols()
        renderWarnings(network)
        renderCaptureDetails(network)
    }

    private func renderTopRows() {
        let rows = overviewSnapshot.topRows(for: selectedTopGroup)
        topEmptyLabel.stringValue = selectedTopGroup == .apps ? "No app traffic yet." : "No resolved domains yet."
        topEmptyLabel.isHidden = !rows.isEmpty
        topScrollView.isHidden = rows.isEmpty
        topTableView.reloadData()
    }

    private func renderProtocols() {
        protocolStack.arrangedSubviews.forEach { item in
            protocolStack.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        protocolEmptyLabel.isHidden = !overviewSnapshot.protocols.isEmpty
        for row in overviewSnapshot.protocols {
            let rowView = CaptureOverviewProtocolRowView()
            rowView.render(row: row, totalBytes: overviewSnapshot.totals.bytes, byteFormatter: byteFormatter)
            protocolStack.addArrangedSubview(rowView)
        }
    }

    private func renderWarnings(_ snapshot: NetworkInspectorSnapshot) {
        var warnings: [String] = []
        if snapshot.droppedPacketCount > 0 {
            warnings.append("\(formattedNumber(snapshot.droppedPacketCount)) packets dropped")
        }
        if overviewSnapshot.malformedPacketCount > 0 {
            warnings.append("\(formattedNumber(overviewSnapshot.malformedPacketCount)) malformed packets")
        }
        if snapshot.base.packetIngestState.truncatedPacketCount > 0 {
            warnings.append("\(formattedNumber(UInt64(snapshot.base.packetIngestState.truncatedPacketCount))) truncated packets")
        }
        if snapshot.base.packetIngestState.decodeIssueCount > 0 {
            warnings.append("\(formattedNumber(UInt64(snapshot.base.packetIngestState.decodeIssueCount))) decode issues")
        }
        warningLabel.stringValue = warnings.joined(separator: " · ")
        warningCard.isHidden = warnings.isEmpty
    }

    private func renderCaptureDetails(_ snapshot: NetworkInspectorSnapshot) {
        let session = snapshot.base.sessionState
        let ingest = snapshot.base.packetIngestState
        var details: [String] = []
        if ingest.source != .offline, let interface = session.selectedInterface {
            details.append("Interface: \(interface.displayName) (\(interface.technicalName))")
            details.append("Link type: \(interface.linkType.rawValue)")
        }
        if let fileName = snapshot.base.documentState.fileURL?.lastPathComponent {
            details.append("File: \(fileName)")
        }
        if !ingest.importedFiles.isEmpty {
            details.append("Imported files: \(ingest.importedFiles.count)")
        }
        if let captureFilter = snapshot.base.filterState.normalizedCaptureFilter, !captureFilter.isEmpty {
            details.append("Capture filter: \(captureFilter)")
        }
        details.append("Source: \(ingest.source?.rawValue ?? "none")")
        detailsLabel.stringValue = details.joined(separator: "\n")
    }

    private func sourceTitle(_ snapshot: NetworkInspectorSnapshot) -> String {
        if let fileName = snapshot.base.documentState.fileURL?.lastPathComponent {
            return fileName
        }
        if snapshot.base.packetIngestState.source == .offline {
            let importedFiles = snapshot.base.packetIngestState.importedFiles
            if importedFiles.count == 1, let importedFile = importedFiles.first {
                return importedFile.displayName
            }
            return importedFiles.isEmpty ? "Imported capture" : "\(importedFiles.count) imported captures"
        }
        if let interface = snapshot.base.sessionState.selectedInterface {
            return interface.displayName
        }
        return "Capture overview"
    }

    private func sourceDetails(_ snapshot: NetworkInspectorSnapshot) -> String {
        if snapshot.base.packetIngestState.source == .offline {
            let phase = snapshot.base.documentState.phase
            return phase == .idle ? "Imported capture" : "Imported capture · \(phase.rawValue.capitalized)"
        }
        let status = snapshot.base.sessionState.phase.rawValue.capitalized
        if let interface = snapshot.base.sessionState.selectedInterface {
            return "\(interface.technicalName) · \(status)"
        }
        return status
    }

    private var durationText: String {
        guard let first = overviewSnapshot.firstPacketDate,
              let last = overviewSnapshot.lastPacketDate else {
            return "0s"
        }
        return durationFormatter.string(from: max(0, last.timeIntervalSince(first))) ?? "0s"
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private func formattedNumber(_ value: UInt64) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func icon(for row: CaptureOverviewTopRow) -> NSImage? {
        if let iconFilePath = row.iconFilePath {
            if let cached = iconCache[iconFilePath] {
                return cached
            }
            if let image = NSImage(contentsOfFile: iconFilePath) {
                iconCache[iconFilePath] = image
                return image
            }
        }
        switch row.selection {
        case .app:
            return TCPViewerUI.image("app")
        case .domain:
            return TCPViewerUI.image("globe")
        default:
            return TCPViewerUI.image("network")
        }
    }

    @objc private func showPackets(_ sender: Any?) {
        delegate?.captureOverviewViewControllerDidRequestPackets(self)
    }

    @objc private func showEndpoints(_ sender: Any?) {
        delegate?.captureOverviewViewControllerDidRequestEndpoints(self)
    }

    @objc private func changeTopGroup(_ sender: NSSegmentedControl) {
        guard let group = CaptureOverviewTopGroup(rawValue: sender.selectedSegment) else {
            return
        }
        selectedTopGroup = group
        renderTopRows()
    }

    @objc private func toggleDetails(_ sender: NSButton) {
        detailsLabel.isHidden = sender.state != .on
    }

    @objc private func openSelectedTopRow(_ sender: Any?) {
        let selectedRow = topTableView.clickedRow >= 0 ? topTableView.clickedRow : topTableView.selectedRow
        let rows = overviewSnapshot.topRows(for: selectedTopGroup)
        guard rows.indices.contains(selectedRow) else {
            return
        }
        delegate?.captureOverviewViewController(self, didSelect: rows[selectedRow].selection)
    }
}

extension CaptureOverviewViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        overviewSnapshot.topRows(for: selectedTopGroup).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = overviewSnapshot.topRows(for: selectedTopGroup)
        guard rows.indices.contains(row) else {
            return nil
        }
        let cell = tableView.makeView(
            withIdentifier: CaptureOverviewTopCellView.identifier,
            owner: self
        ) as? CaptureOverviewTopCellView ?? CaptureOverviewTopCellView(frame: .zero)
        cell.identifier = CaptureOverviewTopCellView.identifier
        let maximumBytes = rows.map(\.totals.bytes).max() ?? 0
        cell.render(
            row: rows[row],
            icon: icon(for: rows[row]),
            maximumBytes: maximumBytes,
            captureBytes: overviewSnapshot.totals.bytes,
            byteFormatter: byteFormatter
        )
        return cell
    }

}
