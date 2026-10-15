//
//  CaptureOverviewViewController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 2/9/26.
//

import AppKit
import PcapPlusPlusCore
import SwiftUI
import UniformTypeIdentifiers

protocol CaptureOverviewViewControllerDelegate: AnyObject {
    func captureOverviewViewControllerDidRequestPackets(_ controller: CaptureOverviewViewController)
    func captureOverviewViewControllerDidRequestEndpoints(_ controller: CaptureOverviewViewController)
    func captureOverviewViewController(
        _ controller: CaptureOverviewViewController,
        didSelect selection: PacketSourceListSelection
    )
    func captureOverviewViewController(
        _ controller: CaptureOverviewViewController,
        didRequestDisplayFilter expression: String
    )
}

private struct CaptureOverviewNetworkFingerprint: Equatable {
    let workspaceMode: NetworkInspectorWorkspaceMode
    let backingIdentity: String?
    let packetLineageRevision: UInt64
    let source: CaptureSource?
    let sessionPhase: CaptureSessionState.Phase
    let interfaceName: String?
    let interfaceTechnicalName: String?
    let documentPhase: CaptureDocumentState.Phase
    let documentFileName: String?
    let importedFileCount: Int
    let firstImportedFileName: String?

    init(snapshot: NetworkInspectorSnapshot) {
        let ingest = snapshot.base.packetIngestState
        let interface = snapshot.base.sessionState.selectedInterface
        workspaceMode = snapshot.workspaceMode
        backingIdentity = ingest.backingIdentity
        packetLineageRevision = ingest.packetLineageRevision
        source = ingest.source
        sessionPhase = snapshot.base.sessionState.phase
        interfaceName = interface?.displayName
        interfaceTechnicalName = interface?.technicalName
        documentPhase = snapshot.base.documentState.phase
        documentFileName = snapshot.base.documentState.fileURL?.lastPathComponent
        importedFileCount = ingest.importedFiles.count
        firstImportedFileName = ingest.importedFiles.first?.displayName
    }
}

final class CaptureOverviewViewController: NSViewController {
    weak var delegate: CaptureOverviewViewControllerDelegate?

    private let latestIngestStateProvider: () -> PacketIngestState
    private let cardLayoutStore: CaptureOverviewCardLayoutStore
    private var service: CaptureOverviewService?
    private var hostingController: NSHostingController<CaptureOverviewDashboardView>?
    private var latestNetworkSnapshot: NetworkInspectorSnapshot?
    private var overviewSnapshot = CaptureOverviewSnapshot.empty
    private var renderedBackingIdentity: String?
    private var renderedPacketLineageRevision: UInt64?
    private var renderedNetworkFingerprint: CaptureOverviewNetworkFingerprint?
    private var renderedDashboardModel: CaptureOverviewDashboardModel?
    private var iconCache: [String: NSImage] = [:]

    init(
        latestIngestStateProvider: @escaping () -> PacketIngestState,
        cardLayoutStore: CaptureOverviewCardLayoutStore = CaptureOverviewCardLayoutStore()
    ) {
        self.latestIngestStateProvider = latestIngestStateProvider
        self.cardLayoutStore = cardLayoutStore
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

    // Hidden panes keep no packet snapshot or aggregation pipeline alive.
    func suspend() {
        service?.snapshotHandler = nil
        service?.cancel()
        service = nil
        latestNetworkSnapshot = nil
        renderedNetworkFingerprint = nil
        overviewSnapshot = .empty
        renderedDashboardModel = nil
        iconCache.removeAll()
    }

    private func makeDashboardView(model: CaptureOverviewDashboardModel) -> CaptureOverviewDashboardView {
        CaptureOverviewDashboardView(
            model: model,
            actions: CaptureOverviewDashboardActions(
                viewPackets: { [weak self] in
                    guard let self else { return }
                    delegate?.captureOverviewViewControllerDidRequestPackets(self)
                },
                showEndpoints: { [weak self] in
                    guard let self else { return }
                    delegate?.captureOverviewViewControllerDidRequestEndpoints(self)
                },
                performRowAction: { [weak self] action in
                    self?.perform(action)
                },
                setCardVisible: { [weak self] card, isVisible in
                    self?.cardLayoutStore.setVisible(card, isVisible)
                    self?.renderDashboard()
                },
                restoreDefaultCards: { [weak self] in
                    self?.cardLayoutStore.restoreDefaults()
                    self?.renderDashboard()
                },
                copyMarkdown: { [weak self] in
                    self?.copyMarkdown()
                },
                saveMarkdown: { [weak self] in
                    self?.saveMarkdown()
                },
                shareMarkdown: { [weak self] in
                    self?.shareMarkdown()
                }
            )
        )
    }

    private func perform(_ action: CaptureOverviewRowAction) {
        switch action {
        case .selection(let selection):
            delegate?.captureOverviewViewController(self, didSelect: selection)
        case .displayFilter(let expression):
            delegate?.captureOverviewViewController(self, didRequestDisplayFilter: expression)
        }
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
        let snapshot = overviewSnapshot
        let totals = snapshot.totals
        return CaptureOverviewDashboardModel(
            title: "Overview",
            subtitle: headerSubtitle(network),
            status: statusPresentation(network),
            hasTraffic: totals.packets > 0,
            metrics: metricPresentations(),
            cards: cardLayoutStore.cards,
            timeline: CaptureOverviewTimelinePresentation(
                points: CaptureOverviewTimelinePresentation.padded(snapshot.timeline, interval: snapshot.timelineInterval),
                interval: snapshot.timelineInterval,
                totals: totals
            ),
            protocolRows: snapshot.protocols.enumerated().map { index, row in
                CaptureOverviewProtocolPresentation(
                    id: row.id,
                    title: row.title,
                    totalText: CaptureOverviewFormat.bytes(row.totals.bytes),
                    percentageText: CaptureOverviewFormat.percent(row.totals.bytes, of: totals.bytes),
                    fraction: CaptureOverviewFormat.fraction(row.totals.bytes, of: totals.bytes),
                    colorIndex: index
                )
            },
            topApps: sourceRows(snapshot.topApps),
            topDestinations: sourceRows(snapshot.topDestinations),
            conversations: conversationRows(),
            services: serviceRows(),
            tcpAnalysis: tcpAnalysisPresentation(),
            packetLengths: snapshot.packetLengthCounts.enumerated().map { index, count in
                CaptureOverviewPacketLengthPresentation(
                    id: index,
                    title: CaptureOverviewClassifier.packetLengthTitle(forBucket: index),
                    axisTitle: CaptureOverviewClassifier.packetLengthAxisTitle(forBucket: index),
                    count: count,
                    percentageText: CaptureOverviewFormat.percent(count, of: totals.packets)
                )
            },
            packetLengthSubtitle: totals.packets > 0
                ? "Average \(CaptureOverviewFormat.bytes(totals.bytes / totals.packets)) per packet"
                : "Wireshark size ranges"
        )
    }

    // MARK: - Metrics

    private func metricPresentations() -> [CaptureOverviewMetricPresentation] {
        let totals = overviewSnapshot.totals
        let duration = captureDuration
        let hasDirectionalTraffic = totals.sentBytes > 0 || totals.receivedBytes > 0
        let packetsPerSecond = duration >= 1 ? Double(totals.packets) / duration : 0
        let packetsDetail: String
        if duration < 1 {
            packetsDetail = "In \(CaptureOverviewFormat.span(duration))"
        } else if packetsPerSecond < 1 {
            packetsDetail = "Avg <1 packet/s"
        } else {
            packetsDetail = "Avg \(CaptureOverviewFormat.count(UInt64(packetsPerSecond))) packets/s"
        }
        let trafficDetail = hasDirectionalTraffic
            ? "↑ \(CaptureOverviewFormat.bytes(totals.sentBytes))   ↓ \(CaptureOverviewFormat.bytes(totals.receivedBytes))"
            : "Original packet bytes"
        let tcpPackets = overviewSnapshot.tcpPacketCount
        let issuesDetail: String
        // Issue packets are always TCP packets, so the share stays within the TCP traffic.
        if totals.issuePackets > 0 {
            issuesDetail = "\(CaptureOverviewFormat.percent(totals.issuePackets, of: tcpPackets)) of TCP packets"
        } else {
            issuesDetail = tcpPackets > 0 ? "No TCP problems detected" : "No TCP traffic"
        }
        let domainCount = overviewSnapshot.domainCount

        return [
            CaptureOverviewMetricPresentation(
                id: "packets",
                title: "Packets",
                value: CaptureOverviewFormat.count(totals.packets),
                detail: packetsDetail,
                symbol: "shippingbox.fill",
                tone: .blue
            ),
            CaptureOverviewMetricPresentation(
                id: "traffic",
                title: "Data Transferred",
                value: CaptureOverviewFormat.bytes(totals.bytes),
                detail: trafficDetail,
                symbol: "arrow.up.arrow.down",
                tone: .indigo
            ),
            CaptureOverviewMetricPresentation(
                id: "throughput",
                title: "Average Throughput",
                value: duration >= 1 ? CaptureOverviewFormat.rate(Double(totals.bytes) / duration) : "–",
                detail: "Peak \(CaptureOverviewFormat.rate(peakBytesPerSecond))",
                symbol: "speedometer",
                tone: .orange
            ),
            CaptureOverviewMetricPresentation(
                id: "issues",
                title: "TCP Issues",
                value: CaptureOverviewFormat.count(totals.issuePackets),
                detail: issuesDetail,
                symbol: "exclamationmark.triangle.fill",
                tone: totals.issuePackets > 0 ? .red : .gray
            ),
            CaptureOverviewMetricPresentation(
                id: "apps",
                title: "Apps",
                value: CaptureOverviewFormat.count(UInt64(overviewSnapshot.appCount)),
                detail: domainCount == 1 ? "1 domain" : "\(CaptureOverviewFormat.count(UInt64(domainCount))) domains",
                symbol: "square.grid.2x2.fill",
                tone: .green
            ),
        ]
    }

    private var captureDuration: TimeInterval {
        guard let first = overviewSnapshot.firstPacketDate, let last = overviewSnapshot.lastPacketDate else {
            return 0
        }
        return max(0, last.timeIntervalSince(first))
    }

    private var peakBytesPerSecond: Double {
        let peak = overviewSnapshot.timeline.map(\.totals.bytes).max() ?? 0
        return Double(peak) / max(overviewSnapshot.timelineInterval, 1)
    }

    // MARK: - Rows

    private func sourceRows(_ rows: [CaptureOverviewTopRow]) -> [CaptureOverviewTrafficRowPresentation] {
        let totalBytes = overviewSnapshot.totals.bytes
        let maximumBytes = rows.map(\.totals.bytes).max() ?? 0
        return rows.prefix(CaptureOverviewStyle.rowLimit).map { row in
            let iconPath = PacketClientIconCache.normalizedIconPath(row.iconFilePath)
            return CaptureOverviewTrafficRowPresentation(
                id: row.id,
                title: row.title,
                icon: iconPath.map(icon(forNormalizedPath:)),
                iconIdentity: iconPath,
                badgeText: nil,
                symbolName: symbolName(for: row.selection),
                valueText: CaptureOverviewFormat.bytes(row.totals.bytes),
                detailText: "\(packetCountText(row.totals.packets)) · " +
                    CaptureOverviewFormat.percent(row.totals.bytes, of: totalBytes),
                issueCount: row.totals.issuePackets,
                sentFraction: CaptureOverviewFormat.fraction(row.totals.sentBytes, of: maximumBytes),
                receivedFraction: CaptureOverviewFormat.fraction(row.totals.receivedBytes, of: maximumBytes),
                unknownFraction: CaptureOverviewFormat.fraction(row.totals.unclassifiedBytes, of: maximumBytes),
                help: "Show packets of \(row.title)\n\(directionText(row.totals))",
                action: .selection(row.selection)
            )
        }
    }

    private func conversationRows() -> [CaptureOverviewTrafficRowPresentation] {
        let rows = overviewSnapshot.topConversations
        let totalBytes = overviewSnapshot.totals.bytes
        let maximumBytes = rows.map(\.totals.bytes).max() ?? 0
        return rows.prefix(CaptureOverviewStyle.rowLimit).map { row in
            let key = row.key
            let server = CaptureOverviewClassifier.endpointText(address: row.domainName ?? key.serverAddress, port: key.serverPort)
            let endpoints = "\(CaptureOverviewClassifier.endpointText(address: key.clientAddress, port: key.clientPort)) ⇄ " +
                CaptureOverviewClassifier.endpointText(address: key.serverAddress, port: key.serverPort)
            let filter = CaptureOverviewClassifier.displayFilter(for: key)
            let iconPath = PacketClientIconCache.normalizedIconPath(row.appIconFilePath)
            let helpLines = [endpoints, row.appName, directionText(row.totals), filter.map { "Filter: \($0)" }]
            return CaptureOverviewTrafficRowPresentation(
                id: "\(key.transport.rawValue)|\(key.clientAddress)|\(key.clientPort)|\(key.serverAddress)|\(key.serverPort)",
                title: server,
                icon: iconPath.map(icon(forNormalizedPath:)),
                iconIdentity: iconPath,
                badgeText: nil,
                symbolName: "arrow.left.arrow.right",
                valueText: CaptureOverviewFormat.bytes(row.totals.bytes),
                detailText: "\(key.transport.rawValue) · " + CaptureOverviewFormat.percent(row.totals.bytes, of: totalBytes),
                issueCount: row.totals.issuePackets,
                sentFraction: CaptureOverviewFormat.fraction(row.totals.sentBytes, of: maximumBytes),
                receivedFraction: CaptureOverviewFormat.fraction(row.totals.receivedBytes, of: maximumBytes),
                unknownFraction: CaptureOverviewFormat.fraction(row.totals.unclassifiedBytes, of: maximumBytes),
                help: helpLines.compactMap { $0 }.joined(separator: "\n"),
                action: filter.map { .displayFilter($0) }
            )
        }
    }

    private func serviceRows() -> [CaptureOverviewTrafficRowPresentation] {
        let rows = overviewSnapshot.topServices
        let totalBytes = overviewSnapshot.totals.bytes
        let maximumBytes = rows.map(\.totals.bytes).max() ?? 0
        return rows.prefix(CaptureOverviewStyle.rowLimit).map { row in
            let key = row.key
            let name = CaptureOverviewClassifier.serviceName(for: key)
            let filter = CaptureOverviewClassifier.displayFilter(for: key)
            return CaptureOverviewTrafficRowPresentation(
                id: "\(key.transport.rawValue)|\(key.port)",
                title: name ?? "\(key.transport.rawValue) \(key.port)",
                icon: nil,
                iconIdentity: nil,
                badgeText: "\(key.port)",
                symbolName: "number",
                valueText: CaptureOverviewFormat.bytes(row.totals.bytes),
                detailText: "\(key.transport.rawValue) · " + CaptureOverviewFormat.percent(row.totals.bytes, of: totalBytes),
                issueCount: row.totals.issuePackets,
                sentFraction: CaptureOverviewFormat.fraction(row.totals.sentBytes, of: maximumBytes),
                receivedFraction: CaptureOverviewFormat.fraction(row.totals.receivedBytes, of: maximumBytes),
                unknownFraction: CaptureOverviewFormat.fraction(row.totals.unclassifiedBytes, of: maximumBytes),
                help: "\(key.transport.rawValue) port \(key.port)\(name.map { " (\($0))" } ?? "")\n" +
                    "\(directionText(row.totals))\nFilter: \(filter)",
                action: .displayFilter(filter)
            )
        }
    }

    private func tcpAnalysisPresentation() -> CaptureOverviewTCPAnalysisPresentation {
        let totals = overviewSnapshot.totals
        let tcpPackets = overviewSnapshot.tcpPacketCount
        let rows = overviewSnapshot.tcpIssues.map { row in
            // Malformed packets can be any protocol; every other flag is a share of TCP packets.
            let base = row.kind == .malformed ? totals.packets : tcpPackets
            let filter = CaptureOverviewClassifier.displayFilter(for: row.kind)
            return CaptureOverviewTCPIssuePresentation(
                id: row.kind.rawValue,
                title: row.kind.title,
                count: row.packets,
                countText: CaptureOverviewFormat.count(row.packets),
                percentageText: CaptureOverviewFormat.percent(row.packets, of: base),
                tone: row.kind.tone,
                help: "\(row.kind.explanation)\nFilter: \(filter)",
                displayFilter: filter
            )
        }
        let subtitle = totals.issuePackets > 0
            ? "\(CaptureOverviewFormat.count(totals.issuePackets)) of \(CaptureOverviewFormat.count(tcpPackets)) TCP packets flagged"
            : "\(CaptureOverviewFormat.count(tcpPackets)) TCP packets analyzed"
        return CaptureOverviewTCPAnalysisPresentation(
            subtitle: subtitle,
            rows: rows,
            emptyTitle: tcpPackets > 0 ? "No TCP problems detected" : "No TCP traffic",
            emptyDetail: tcpPackets > 0
                ? "No retransmissions, lost segments, zero windows or resets."
                : "TCP problems appear here as packets are analyzed."
        )
    }

    private func packetCountText(_ packets: UInt64) -> String {
        packets == 1 ? "1 packet" : "\(CaptureOverviewFormat.count(packets)) packets"
    }

    private func directionText(_ totals: CaptureOverviewTrafficTotals) -> String {
        "\(packetCountText(totals.packets)) · ↑ \(CaptureOverviewFormat.bytes(totals.sentBytes))  " +
            "↓ \(CaptureOverviewFormat.bytes(totals.receivedBytes))"
    }

    private func symbolName(for selection: PacketSourceListSelection) -> String {
        switch selection {
        case .app:
            return "app.dashed"
        case .domain:
            return "globe"
        default:
            return "network"
        }
    }

    private func icon(forNormalizedPath path: String) -> NSImage {
        if let cached = iconCache[path] {
            return cached
        }
        let image = PacketClientIconImageLoader.image(forNormalizedPath: path)
        iconCache[path] = image
        return image
    }

    // MARK: - Share

    // Rendered on demand, so live updates never pay for a report nobody asked for.
    private func markdownReport(generatedAt: Date) -> String {
        CaptureOverviewMarkdown.render(
            overviewSnapshot,
            source: latestNetworkSnapshot.map(sourceDescription) ?? "Capture",
            cards: cardLayoutStore.cards,
            generatedAt: generatedAt
        )
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdownReport(generatedAt: Date()), forType: .string)
    }

    private func saveMarkdown() {
        let generatedAt = Date()
        let markdown = markdownReport(generatedAt: generatedAt)
        let panel = NSSavePanel()
        panel.title = "Save Overview as Markdown"
        panel.nameFieldStringValue = CaptureOverviewMarkdown.fileName(generatedAt: generatedAt)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.presentError(error)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    // The menu has closed by now, so the share picker opens where the pointer chose "Share…".
    private func shareMarkdown() {
        guard let anchorView = hostingController?.view, let window = anchorView.window else {
            return
        }
        let location = anchorView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: [markdownReport(generatedAt: Date())])
        picker.show(relativeTo: NSRect(x: location.x, y: location.y, width: 1, height: 1), of: anchorView, preferredEdge: .minY)
    }

    // MARK: - Header

    private func headerSubtitle(_ network: NetworkInspectorSnapshot) -> String {
        var parts = [sourceDescription(network)]
        if let firstPacketDate = overviewSnapshot.firstPacketDate {
            // A live capture usually started today, so the time is enough.
            let start = Calendar.current.isDateInToday(firstPacketDate)
                ? firstPacketDate.formatted(date: .omitted, time: .standard)
                : firstPacketDate.formatted(date: .abbreviated, time: .standard)
            parts.append("Started \(start)")
            parts.append(CaptureOverviewFormat.span(captureDuration))
        } else if network.base.packetIngestState.source != .offline {
            parts.append("Waiting for packets")
        }
        return parts.joined(separator: " · ")
    }

    private func sourceDescription(_ network: NetworkInspectorSnapshot) -> String {
        if let fileName = network.base.documentState.fileURL?.lastPathComponent {
            return fileName
        }
        let ingest = network.base.packetIngestState
        if ingest.source == .offline {
            if ingest.importedFiles.count == 1, let importedFile = ingest.importedFiles.first {
                return importedFile.displayName
            }
            return ingest.importedFiles.isEmpty ? "Imported capture" : "\(ingest.importedFiles.count) imported captures"
        }
        guard let interface = network.base.sessionState.selectedInterface else {
            return "No capture source selected"
        }
        let name = interface.displayName == interface.technicalName
            ? interface.displayName
            : "\(interface.displayName) (\(interface.technicalName))"
        return "Live capture on \(name)"
    }

    private func statusPresentation(_ snapshot: NetworkInspectorSnapshot) -> CaptureOverviewStatusPresentation {
        if snapshot.base.packetIngestState.source == .offline {
            let phase = snapshot.base.documentState.phase
            let title = phase == .idle ? "Loaded" : phase.rawValue.capitalized
            let tone: CaptureOverviewStatusTone = phase == .failed ? .error : .active
            return CaptureOverviewStatusPresentation(title: title, tone: tone)
        }
        let phase = snapshot.base.sessionState.phase
        switch phase {
        case .running:
            return CaptureOverviewStatusPresentation(title: "Live", tone: .positive)
        case .starting, .stopping:
            return CaptureOverviewStatusPresentation(title: phase.rawValue.capitalized, tone: .active)
        case .paused:
            return CaptureOverviewStatusPresentation(title: "Paused", tone: .attention)
        case .failed:
            return CaptureOverviewStatusPresentation(title: "Failed", tone: .error)
        case .idle, .ready, .stopped:
            return CaptureOverviewStatusPresentation(title: phase.rawValue.capitalized, tone: .neutral)
        }
    }
}

private extension CaptureOverviewTCPIssueKind {
    var tone: CaptureOverviewVisualTone {
        switch self {
        case .malformed: .brown
        case .lostSegment: .red
        case .retransmission: .orange
        case .outOfOrder: .purple
        case .zeroWindow: .pink
        case .duplicateAck: .yellow
        case .reset: .indigo
        }
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
