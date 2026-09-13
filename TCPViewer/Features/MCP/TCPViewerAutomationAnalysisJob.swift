//
//  TCPViewerAutomationAnalysisJob.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 13/9/26.
//

import Foundation
import PcapPlusPlusCore

// An explicit analysis request owns one bounded drain, never a live presentation timer.
final class TCPViewerAutomationAnalysisJob: TCPViewerWorkspaceControllerDelegate {
    private let request: TCPViewerMCPRequest
    private let model: NetworkInspectorViewModel
    private let isValid: () -> Bool
    private let completion: (TCPViewerMCPResponse) -> Void
    private let queue: DispatchQueue
    private let cancellation = EndpointStatisticsCancellationToken()
    private let backingIdentity: String?
    private let lineage: UInt64
    private let sourcePacketCount: Int
    private let packetWatermark: PacketSummary.ID?
    private let displayedIDs: [PacketSummary.ID]?
    private let displayedMembership: Set<PacketSummary.ID>?
    private let sourceIDs: [PacketSourceListSelection: String]
    private let group: EndpointStatisticsGroup
    private let sort: EndpointStatisticsTableSort
    private let search: String
    private let offset: Int
    private let limit: Int
    private let deadline = DispatchTime.now() + 100
    private var overview = CaptureOverviewAccumulator()
    private let statistics = EndpointStatisticsService()
    private var nextIndex = 0
    private var processedCount = 0
    private var revision: UInt64 = 0
    private var observedRevision: UInt64
    private var metadata: [PacketSummary.ID: PacketSummary] = [:]
    private var finished = false

    static func start(_ request: TCPViewerMCPRequest, model: NetworkInspectorViewModel,
                      isValid: @escaping () -> Bool,
                      queue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.automation.analysis", qos: .userInitiated),
                      completion: @escaping (TCPViewerMCPResponse) -> Void) throws {
        guard !model.captureWorkspace.automationAnalysisIsRunning else {
            throw TCPViewerAutomationCommandRouter.invalid("An analysis is already running for this capture. Retry when it finishes.")
        }
        let job = try TCPViewerAutomationAnalysisJob(request, model: model, isValid: isValid, queue: queue, completion: completion)
        model.captureWorkspace.automationAnalysisIsRunning = true
        model.captureWorkspace.subscribe(job)
        job.queue.async {
            _ = job.statistics.consume(EndpointStatisticsIngestUpdate(packetRevision: 0, packetLineageRevision: 0,
                                                                     totalPacketCount: 0, kind: .replace([])))
            DispatchQueue.main.async { job.nextChunk() }
        }
    }

    private init(_ request: TCPViewerMCPRequest, model: NetworkInspectorViewModel,
                 isValid: @escaping () -> Bool, queue: DispatchQueue, completion: @escaping (TCPViewerMCPResponse) -> Void) throws {
        self.request = request
        self.model = model
        self.isValid = isValid
        self.completion = completion
        self.queue = queue
        let state = model.captureSnapshotForCommands.packetIngestState
        backingIdentity = state.backingIdentity
        lineage = state.packetLineageRevision
        sourcePacketCount = state.totalPacketCount
        packetWatermark = state.packets.last?.id
        observedRevision = state.packetRevision
        displayedIDs = request.string("scope") == "displayed" ? model.snapshot.base.navigationState.visiblePacketIDs : nil
        displayedMembership = displayedIDs.map(Set.init)
        sourceIDs = Dictionary(TCPViewerAutomationCommandRouter.sourceItems(model.snapshot.sourceListSnapshot).compactMap { item in
            item.selection.map { ($0, item.id) }
        }, uniquingKeysWith: { first, _ in first })
        group = EndpointStatisticsGroup(rawValue: try request.automationEnum("group", values: EndpointStatisticsGroup.allCases.map(\.rawValue), default: "apps"))!
        let sortName = try request.automationEnum("sort", values: EndpointStatisticsTableColumn.allCases.map(\.jsonKey), default: "bytes")
        sort = EndpointStatisticsTableSort(column: EndpointStatisticsTableColumn.allCases.first { $0.jsonKey == sortName }!,
                                           isAscending: try request.automationEnum("order", values: ["asc", "desc"], default: "desc") == "asc")
        search = try request.automationString("search") ?? ""
        offset = try request.automationInt("offset", default: 0, range: 0...Int.max)
        limit = try request.automationInt("limit", default: 50, range: 1...500)
    }

    // Each main-thread visit copies at most 2048 summaries and releases the capture array before dispatch.
    private func nextChunk() {
        guard !finished else { return }
        guard validate() else { finish(.failure("The analysis target changed or the request timed out.")); return }
        let count = displayedIDs?.count ?? sourcePacketCount
        guard nextIndex < count else { finishAnalysis(); return }
        let end = min(count, nextIndex + 2048)
        let packets: [PacketSummary]
        if let displayedIDs {
            packets = model.packetSummariesForEndpointStatistics(Array(displayedIDs[nextIndex..<end]))
        } else {
            packets = Array(model.captureSnapshotForCommands.packetIngestState.packets[nextIndex..<end])
        }
        nextIndex = end
        queue.async {
            self.overview.appendReplacementChunk(packets)
            self.processedCount += packets.count
            self.revision &+= 1
            _ = self.statistics.consume(EndpointStatisticsIngestUpdate(packetRevision: self.revision, packetLineageRevision: 0,
                                                                       totalPacketCount: self.processedCount, kind: .append(packets)))
            DispatchQueue.main.async { self.nextChunk() }
        }
    }

    // Exact metadata deltas repair already-processed chunks without rescanning the capture.
    func tcpViewerWorkspaceControllerDidChange(_ controller: TCPViewerWorkspaceController) {
        guard !finished else { return }
        let state = controller.snapshot.packetIngestState
        guard state.packetRevision != observedRevision else { return }
        guard validate(), state.packetRevision == observedRevision &+ 1 else {
            finish(.failure("The capture changed too quickly to produce a consistent analysis. Retry the request.")); return
        }
        observedRevision = state.packetRevision
        let ids: [PacketSummary.ID]
        switch state.lastMutation {
        case .metadataUpdate(let changed): ids = changed
        case .appendWithMetadataUpdates(_, let changed): ids = changed
        case .append: ids = []
        default: finish(.failure("The capture was replaced during analysis.")); return
        }
        for id in ids {
            guard let index = state.packetIndexByID[id], index < sourcePacketCount,
                  displayedMembership?.contains(id) != false, let packet = state.packet(withID: id) else { continue }
            guard metadata.count < 10_000 || metadata[id] != nil else {
                finish(.failure("Too many metadata changes occurred during analysis. Retry the request.")); return
            }
            metadata[id] = packet
        }
    }

    private func validate() -> Bool {
        let state = model.captureSnapshotForCommands.packetIngestState
        return isValid() && !model.isClosed && state.backingIdentity == backingIdentity && state.packetLineageRevision == lineage &&
            state.totalPacketCount >= sourcePacketCount && DispatchTime.now() < deadline
    }

    // Stop observing at a defined watermark before sorting and serializing on the worker queue.
    private func finishAnalysis() {
        model.captureWorkspace.unsubscribe(self)
        let updates = Array(metadata.values)
        metadata.removeAll()
        queue.async {
            self.overview.appendReplacementChunk(updates)
            self.revision &+= 1
            _ = self.statistics.consume(EndpointStatisticsIngestUpdate(packetRevision: self.revision, packetLineageRevision: 0,
                                                                       totalPacketCount: self.processedCount, kind: .metadata(updates)))
            var data: [String: TCPViewerMCPValue]
            if self.request.command == TCPViewerMCPCommand.getOverviewStatistics.rawValue {
                data = self.overviewData(self.overview.snapshot())
            } else {
                let snapshot = self.statistics.currentSnapshot(for: self.group)
                guard let table = EndpointStatisticsTablePresenter.presentation(rows: snapshot.rows, searchText: self.search,
                                                                                sort: self.sort, cancellationToken: self.cancellation) else { return }
                let rows = Array(table.rows.dropFirst(self.offset).prefix(self.limit))
                data = ["group": .string(self.group.rawValue), "scope": .string(self.displayedIDs == nil ? "all" : "displayed"),
                        "rows": .array(rows.map { .object(Self.endpointData($0)) }),
                        "endpoint_counts": .object(Dictionary(uniqueKeysWithValues: snapshot.endpointCounts.map { ($0.key.rawValue, .int($0.value)) })),
                        "total_count": .int(table.rows.count), "returned_count": .int(rows.count),
                        "next_offset": self.offset + rows.count < table.rows.count ? .int(self.offset + rows.count) : .null,
                        "totals": .object(Self.endpointTotals(snapshot.footerTotals))]
            }
            data["packet_count"] = .int(self.processedCount)
            data["captured_through_packet_id"] = self.packetWatermark.map { .string(String($0)) } ?? .null
            data["source_packet_count"] = .int(self.sourcePacketCount)
            let result = data
            DispatchQueue.main.async {
                self.finish(self.validate() ? .success(result) : .failure("The analysis target changed."))
            }
        }
    }

    private func finish(_ response: TCPViewerMCPResponse) {
        guard !finished else { return }
        finished = true
        cancellation.cancel()
        model.captureWorkspace.unsubscribe(self)
        model.captureWorkspace.automationAnalysisIsRunning = false
        completion(response)
    }

    private func overviewData(_ snapshot: CaptureOverviewSnapshot) -> [String: TCPViewerMCPValue] {
        func top(_ row: CaptureOverviewTopRow) -> TCPViewerMCPValue {
            .object(["title": .string(row.title), "source_id": sourceIDs[row.selection].map(TCPViewerMCPValue.string) ?? .null,
                     "totals": .object(Self.trafficTotals(row.totals))])
        }
        return ["totals": .object(Self.trafficTotals(snapshot.totals)),
                "first_packet_at": snapshot.firstPacketDate.map(Self.dateValue) ?? .null,
                "last_packet_at": snapshot.lastPacketDate.map(Self.dateValue) ?? .null,
                "app_count": .int(snapshot.appCount), "domain_count": .int(snapshot.domainCount),
                "malformed_packet_count": .string(String(snapshot.malformedPacketCount)),
                "top_apps": .array(snapshot.topApps.map(top)), "top_destinations": .array(snapshot.topDestinations.map(top)),
                "protocols": .array(snapshot.protocols.map { .object(["protocol": .string($0.title), "totals": .object(Self.trafficTotals($0.totals))]) }),
                "timeline": .array(snapshot.timeline.map { .object(["timestamp": Self.dateValue($0.date), "totals": .object(Self.trafficTotals($0.totals))]) })]
    }

    static func dateValue(_ date: Date) -> TCPViewerMCPValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }

    static func trafficTotals(_ value: CaptureOverviewTrafficTotals) -> [String: TCPViewerMCPValue] {
        ["packets": .string(String(value.packets)), "bytes": .string(String(value.bytes)),
         "sent_packets": .string(String(value.sentPackets)), "sent_bytes": .string(String(value.sentBytes)),
         "received_packets": .string(String(value.receivedPackets)), "received_bytes": .string(String(value.receivedBytes)),
         "unclassified_packets": .string(String(value.unclassifiedPackets)), "unclassified_bytes": .string(String(value.unclassifiedBytes))]
    }

    static func endpointTotals(_ value: EndpointStatisticsTotals) -> [String: TCPViewerMCPValue] {
        ["packets": .string(String(value.packets)), "bytes": .string(String(value.bytes)),
         "tx_packets": .string(String(value.txPackets)), "tx_bytes": .string(String(value.txBytes)),
         "rx_packets": .string(String(value.rxPackets)), "rx_bytes": .string(String(value.rxBytes)),
         "unclassified_packets": .string(String(value.unclassifiedPackets)), "unclassified_bytes": .string(String(value.unclassifiedBytes))]
    }

    static func endpointData(_ row: EndpointStatisticsRow) -> [String: TCPViewerMCPValue] {
        var data = endpointTotals(row.totals)
        data["endpoint"] = .object(["group": .string(row.group.rawValue), "key": .string(row.id.key)])
        for (key, value) in [("address", row.address), ("port", row.port), ("protocol", row.protocolName), ("client", row.client), ("domain", row.domain)] {
            data[key] = value.map(TCPViewerMCPValue.string) ?? .null
        }
        return data
    }
}
