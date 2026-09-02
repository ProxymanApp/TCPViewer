//
//  CaptureOverviewViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import AppKit
import PcapPlusPlusCore
import SwiftUI

protocol CaptureOverviewViewControllerDelegate: AnyObject {
    func captureOverviewViewControllerDidRequestPackets(_ controller: CaptureOverviewViewController)
    func captureOverviewViewControllerDidRequestEndpoints(_ controller: CaptureOverviewViewController)
    func captureOverviewViewController(
        _ controller: CaptureOverviewViewController,
        didSelect selection: PacketSourceListSelection
    )
}

private struct CaptureOverviewNetworkFingerprint: Equatable {
    let workspaceMode: NetworkInspectorWorkspaceMode
    let backingIdentity: String?
    let packetLineageRevision: UInt64
    let source: CaptureSource?
    let sessionPhase: CaptureSessionState.Phase
    let interfaceID: String?
    let interfaceName: String?
    let interfaceTechnicalName: String?
    let interfaceLinkType: CaptureLinkType?
    let documentPhase: CaptureDocumentState.Phase
    let documentFileName: String?
    let importedFileCount: Int
    let firstImportedFileName: String?
    let captureFilter: String?
    let droppedPacketCount: UInt64
    let truncatedPacketCount: Int
    let decodeIssueCount: Int

    init(snapshot: NetworkInspectorSnapshot) {
        let ingest = snapshot.base.packetIngestState
        let interface = snapshot.base.sessionState.selectedInterface
        workspaceMode = snapshot.workspaceMode
        backingIdentity = ingest.backingIdentity
        packetLineageRevision = ingest.packetLineageRevision
        source = ingest.source
        sessionPhase = snapshot.base.sessionState.phase
        interfaceID = interface?.id
        interfaceName = interface?.displayName
        interfaceTechnicalName = interface?.technicalName
        interfaceLinkType = interface?.linkType
        documentPhase = snapshot.base.documentState.phase
        documentFileName = snapshot.base.documentState.fileURL?.lastPathComponent
        importedFileCount = ingest.importedFiles.count
        firstImportedFileName = ingest.importedFiles.first?.displayName
        captureFilter = snapshot.base.filterState.normalizedCaptureFilter
        droppedPacketCount = snapshot.droppedPacketCount
        truncatedPacketCount = ingest.truncatedPacketCount
        decodeIssueCount = ingest.decodeIssueCount
    }
}

final class CaptureOverviewViewController: NSViewController {
    weak var delegate: CaptureOverviewViewControllerDelegate?

    private let latestIngestStateProvider: () -> PacketIngestState
    private var service: CaptureOverviewService?
    private var hostingController: NSHostingController<CaptureOverviewDashboardView>?
    private var latestNetworkSnapshot: NetworkInspectorSnapshot?
    private var overviewSnapshot = CaptureOverviewSnapshot.empty
    private var selectedTopGroup = CaptureOverviewTopGroup.apps
    private var isCaptureDetailsExpanded = false
    private var renderedBackingIdentity: String?
    private var renderedPacketLineageRevision: UInt64?
    private var renderedNetworkFingerprint: CaptureOverviewNetworkFingerprint?
    private var renderedDashboardModel: CaptureOverviewDashboardModel?
    private var iconCache: [String: NSImage] = [:]

    private let byteFormatter: ByteCountFormatter
    private let numberFormatter: NumberFormatter
    private let dateFormatter: DateFormatter
    private let durationFormatter = DateComponentsFormatter()

    init(latestIngestStateProvider: @escaping () -> PacketIngestState) {
        self.latestIngestStateProvider = latestIngestStateProvider

        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        byteFormatter.allowedUnits = .useAll
        byteFormatter.includesUnit = true
        self.byteFormatter = byteFormatter

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
        durationFormatter.zeroFormattingBehavior = .dropLeading
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
        view = NSView()
        let controller = NSHostingController(rootView: makeDashboardView(model: .empty))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController = controller
    }

    // Keep raw capture updates in the existing service and replace the immutable SwiftUI root at most every 500 ms.
    func render(snapshot: NetworkInspectorSnapshot) {
        let ingestState = snapshot.base.packetIngestState
        if renderedBackingIdentity != ingestState.backingIdentity ||
            renderedPacketLineageRevision != ingestState.packetLineageRevision {
            overviewSnapshot = .empty
            renderedBackingIdentity = ingestState.backingIdentity
            renderedPacketLineageRevision = ingestState.packetLineageRevision
            renderedDashboardModel = nil
        }
        latestNetworkSnapshot = snapshot

        guard snapshot.workspaceMode == .overview || service != nil else {
            return
        }

        var didCreateService = false
        if snapshot.workspaceMode == .overview, service == nil {
            let service = CaptureOverviewService(latestIngestStateProvider: latestIngestStateProvider)
            service.snapshotHandler = { [weak self] overviewSnapshot in
                guard let self, self.overviewSnapshot != overviewSnapshot else {
                    return
                }
                self.overviewSnapshot = overviewSnapshot
                self.renderDashboard()
            }
            self.service = service
            didCreateService = true
        }
        service?.consume(ingestState)

        let networkFingerprint = CaptureOverviewNetworkFingerprint(snapshot: snapshot)
        guard didCreateService || renderedNetworkFingerprint != networkFingerprint else {
            return
        }
        renderedNetworkFingerprint = networkFingerprint
        renderDashboard()
    }

    private func makeDashboardView(model: CaptureOverviewDashboardModel) -> CaptureOverviewDashboardView {
        CaptureOverviewDashboardView(
            model: model,
            onViewPackets: { [weak self] in
                guard let self else { return }
                delegate?.captureOverviewViewControllerDidRequestPackets(self)
            },
            onShowEndpoints: { [weak self] in
                guard let self else { return }
                delegate?.captureOverviewViewControllerDidRequestEndpoints(self)
            },
            onSelectTopGroup: { [weak self] group in
                guard let self, selectedTopGroup != group else { return }
                selectedTopGroup = group
                renderDashboard()
            },
            onSelectTrafficRow: { [weak self] selection in
                guard let self else { return }
                delegate?.captureOverviewViewController(self, didSelect: selection)
            },
            onToggleDetails: { [weak self] in
                guard let self else { return }
                isCaptureDetailsExpanded.toggle()
                renderDashboard()
            }
        )
    }

    // Format the bounded aggregate once before handing it to small SwiftUI value views.
    private func renderDashboard() {
        guard isViewLoaded, let network = latestNetworkSnapshot else {
            return
        }
        let model = makeDashboardModel(network: network)
        guard renderedDashboardModel != model else {
            return
        }
        renderedDashboardModel = model
        hostingController?.rootView = makeDashboardView(model: model)
    }

    private func makeDashboardModel(network: NetworkInspectorSnapshot) -> CaptureOverviewDashboardModel {
        let totals = overviewSnapshot.totals
        let topRows = overviewSnapshot.topRows(for: selectedTopGroup)
        let maximumTopBytes = topRows.map(\.totals.bytes).max() ?? 0
        let hasDirectionalTraffic = totals.sentBytes > 0 || totals.receivedBytes > 0
        let chartPoints = overviewSnapshot.timeline.flatMap { point -> [CaptureOverviewChartPoint] in
            let directions: [(CaptureOverviewChartPoint.Direction, UInt64)] = hasDirectionalTraffic
                ? [(.sent, point.totals.sentBytes), (.received, point.totals.receivedBytes)]
                : [(.total, point.totals.bytes)]
            return directions.map { direction, bytes in
                CaptureOverviewChartPoint(
                    id: .init(date: point.date, direction: direction),
                    date: point.date,
                    direction: direction,
                    bytes: Double(bytes)
                )
            }
        }

        return CaptureOverviewDashboardModel(
            title: sourceTitle(network),
            subtitle: sourceSubtitle(network),
            status: statusPresentation(network),
            metrics: metricPresentations(),
            hasTraffic: totals.packets > 0,
            hasDirectionalTraffic: hasDirectionalTraffic,
            trafficPoints: chartPoints,
            totalText: formattedBytes(totals.bytes),
            sentText: formattedBytes(totals.sentBytes),
            receivedText: formattedBytes(totals.receivedBytes),
            selectedTopGroup: selectedTopGroup,
            topRows: topRows.map { rowPresentation($0, maximumBytes: maximumTopBytes) },
            protocolRows: overviewSnapshot.protocols.enumerated().map { index, row in
                CaptureOverviewProtocolPresentation(
                    id: row.id,
                    title: row.title,
                    totalText: formattedBytes(row.totals.bytes),
                    percentageText: percentageText(row.totals.bytes, of: totals.bytes),
                    fraction: fraction(row.totals.bytes, of: totals.bytes),
                    colorIndex: index
                )
            },
            warningText: warningText(network),
            details: captureDetails(network),
            isDetailsExpanded: isCaptureDetailsExpanded
        )
    }

    private func metricPresentations() -> [CaptureOverviewMetricPresentation] {
        let totals = overviewSnapshot.totals
        let startedText = overviewSnapshot.firstPacketDate.map {
            "Started \(dateFormatter.string(from: $0))"
        } ?? "No packets yet"
        let totalDetail = totals.unclassifiedBytes > 0
            ? "\(formattedBytes(totals.unclassifiedBytes)) direction unknown"
            : "Original packet bytes"

        return [
            CaptureOverviewMetricPresentation(
                id: "duration",
                title: "Duration",
                value: durationText,
                detail: startedText,
                symbol: "timer",
                tone: .indigo
            ),
            CaptureOverviewMetricPresentation(
                id: "packets",
                title: "Packets",
                value: formattedNumber(totals.packets),
                detail: "Across the full capture",
                symbol: "shippingbox.fill",
                tone: .orange
            ),
            CaptureOverviewMetricPresentation(
                id: "traffic",
                title: "Total traffic",
                value: formattedBytes(totals.bytes),
                detail: totalDetail,
                symbol: "arrow.up.arrow.down",
                tone: .blue
            ),
            CaptureOverviewMetricPresentation(
                id: "sent",
                title: "Sent",
                value: formattedBytes(totals.sentBytes),
                detail: "\(percentageText(totals.sentBytes, of: totals.bytes)) of capture",
                symbol: "arrow.up.right",
                tone: .cyan
            ),
            CaptureOverviewMetricPresentation(
                id: "received",
                title: "Received",
                value: formattedBytes(totals.receivedBytes),
                detail: "\(percentageText(totals.receivedBytes, of: totals.bytes)) of capture",
                symbol: "arrow.down.left",
                tone: .green
            ),
            CaptureOverviewMetricPresentation(
                id: "identities",
                title: "Discovered",
                value: "\(overviewSnapshot.appCount) apps",
                detail: "\(overviewSnapshot.domainCount) resolved domains",
                symbol: "point.3.connected.trianglepath.dotted",
                tone: .purple
            ),
        ]
    }

    private func rowPresentation(
        _ row: CaptureOverviewTopRow,
        maximumBytes: UInt64
    ) -> CaptureOverviewTopTrafficPresentation {
        CaptureOverviewTopTrafficPresentation(
            id: row.id,
            title: row.title,
            icon: icon(for: row),
            iconFilePath: row.iconFilePath,
            selection: row.selection,
            totalText: formattedBytes(row.totals.bytes),
            sentText: formattedBytes(row.totals.sentBytes),
            receivedText: formattedBytes(row.totals.receivedBytes),
            percentageText: percentageText(row.totals.bytes, of: overviewSnapshot.totals.bytes),
            sentFraction: fraction(row.totals.sentBytes, of: maximumBytes),
            receivedFraction: fraction(row.totals.receivedBytes, of: maximumBytes),
            unknownFraction: fraction(row.totals.unclassifiedBytes, of: maximumBytes)
        )
    }

    private func icon(for row: CaptureOverviewTopRow) -> NSImage {
        if let path = row.iconFilePath {
            if let cached = iconCache[path] {
                return cached
            }
            if let image = NSImage(contentsOfFile: path) {
                iconCache[path] = image
                return image
            }
        }
        let symbol: String
        switch row.selection {
        case .app:
            symbol = "app.fill"
        case .domain:
            symbol = "globe"
        default:
            symbol = "network"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
    }

    private func sourceTitle(_ snapshot: NetworkInspectorSnapshot) -> String {
        if let fileName = snapshot.base.documentState.fileURL?.lastPathComponent {
            return fileName
        }
        let ingest = snapshot.base.packetIngestState
        if ingest.source == .offline {
            if ingest.importedFiles.count == 1, let importedFile = ingest.importedFiles.first {
                return importedFile.displayName
            }
            return ingest.importedFiles.isEmpty ? "Imported capture" : "\(ingest.importedFiles.count) imported captures"
        }
        return snapshot.base.sessionState.selectedInterface?.displayName ?? "Capture overview"
    }

    private func sourceSubtitle(_ snapshot: NetworkInspectorSnapshot) -> String {
        let ingest = snapshot.base.packetIngestState
        if ingest.source == .offline {
            let count = ingest.importedFiles.count
            return count > 1 ? "Imported capture · \(count) source files" : "Imported capture"
        }
        if let interface = snapshot.base.sessionState.selectedInterface {
            return "Live capture · \(interface.technicalName)"
        }
        return "No capture source selected"
    }

    private func statusPresentation(_ snapshot: NetworkInspectorSnapshot) -> CaptureOverviewStatusPresentation {
        if snapshot.base.packetIngestState.source == .offline {
            let phase = snapshot.base.documentState.phase
            let title = phase == .idle ? "Loaded" : phase.rawValue.capitalized
            let tone: CaptureOverviewStatusTone = phase == .failed ? .error : .active
            return CaptureOverviewStatusPresentation(title: title, tone: tone)
        }
        let phase = snapshot.base.sessionState.phase
        let tone: CaptureOverviewStatusTone
        switch phase {
        case .running:
            tone = .positive
        case .starting, .stopping:
            tone = .active
        case .paused:
            tone = .attention
        case .failed:
            tone = .error
        case .idle, .ready, .stopped:
            tone = .neutral
        }
        return CaptureOverviewStatusPresentation(title: phase.rawValue.capitalized, tone: tone)
    }

    private func warningText(_ snapshot: NetworkInspectorSnapshot) -> String? {
        var warnings: [String] = []
        if snapshot.droppedPacketCount > 0 {
            warnings.append("\(formattedNumber(snapshot.droppedPacketCount)) packets dropped")
        }
        if overviewSnapshot.malformedPacketCount > 0 {
            warnings.append("\(formattedNumber(overviewSnapshot.malformedPacketCount)) malformed packets")
        }
        let ingest = snapshot.base.packetIngestState
        if ingest.truncatedPacketCount > 0 {
            warnings.append("\(formattedNumber(UInt64(ingest.truncatedPacketCount))) truncated packets")
        }
        if ingest.decodeIssueCount > 0 {
            warnings.append("\(formattedNumber(UInt64(ingest.decodeIssueCount))) decode issues")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    private func captureDetails(_ snapshot: NetworkInspectorSnapshot) -> [CaptureOverviewDetailPresentation] {
        let session = snapshot.base.sessionState
        let ingest = snapshot.base.packetIngestState
        var details: [CaptureOverviewDetailPresentation] = []
        if ingest.source != .offline, let interface = session.selectedInterface {
            details.append(.init(id: "interface", label: "Interface", value: "\(interface.displayName) (\(interface.technicalName))"))
            details.append(.init(id: "link", label: "Link type", value: interface.linkType.rawValue.capitalized))
        }
        if let fileName = snapshot.base.documentState.fileURL?.lastPathComponent {
            details.append(.init(id: "file", label: "File", value: fileName))
        }
        if !ingest.importedFiles.isEmpty {
            details.append(.init(id: "imports", label: "Imported files", value: formattedNumber(UInt64(ingest.importedFiles.count))))
        }
        if let captureFilter = snapshot.base.filterState.normalizedCaptureFilter, !captureFilter.isEmpty {
            details.append(.init(id: "filter", label: "Capture filter", value: captureFilter))
        }
        details.append(.init(id: "source", label: "Source", value: ingest.source?.rawValue.capitalized ?? "None"))
        return details
    }

    private var durationText: String {
        guard let first = overviewSnapshot.firstPacketDate,
              let last = overviewSnapshot.lastPacketDate else {
            return "0s"
        }
        return durationFormatter.string(from: max(0, last.timeIntervalSince(first))) ?? "0s"
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else {
            return "0 bytes"
        }
        return byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private func formattedNumber(_ value: UInt64) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func fraction(_ value: UInt64, of total: UInt64) -> Double {
        guard total > 0 else {
            return 0
        }
        return min(1, Double(value) / Double(total))
    }

    private func percentageText(_ value: UInt64, of total: UInt64) -> String {
        let percentage = fraction(value, of: total) * 100
        if value > 0, percentage < 1 {
            return "<1%"
        }
        return "\(Int(percentage.rounded()))%"
    }
}

#if DEBUG
extension CaptureOverviewViewController {
    var isSwiftUIHostedForTesting: Bool {
        hostingController != nil
    }

    var showsNoTrafficStateForTesting: Bool {
        renderedDashboardModel?.hasTraffic == false
    }
}
#endif
