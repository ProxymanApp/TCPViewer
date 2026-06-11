//
//  TCPViewerStatusMetricsService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 11/6/26.
//

import Darwin.Mach
import Foundation
import PcapPlusPlusCore

struct TCPViewerStatusMetricsSnapshot: Equatable, Sendable {
    let memoryBytes: UInt64
    let uploadBytesPerSecond: UInt64
    let downloadBytesPerSecond: UInt64

    static let empty = TCPViewerStatusMetricsSnapshot(
        memoryBytes: 0,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0
    )
}

struct TCPViewerCapturedTrafficSample: Equatable, Sendable {
    let uploadBytes: UInt64
    let downloadBytes: UInt64

    static let zero = TCPViewerCapturedTrafficSample(uploadBytes: 0, downloadBytes: 0)

    var isEmpty: Bool {
        uploadBytes == 0 && downloadBytes == 0
    }

    func adding(_ sample: TCPViewerCapturedTrafficSample) -> TCPViewerCapturedTrafficSample {
        TCPViewerCapturedTrafficSample(
            uploadBytes: uploadBytes &+ sample.uploadBytes,
            downloadBytes: downloadBytes &+ sample.downloadBytes
        )
    }
}

enum TCPViewerStatusMetricsFormatter {
    static func displayText(for snapshot: TCPViewerStatusMetricsSnapshot) -> String {
        "• \(memoryText(bytes: snapshot.memoryBytes)) ↑ \(speedText(bytesPerSecond: snapshot.uploadBytesPerSecond)) ↓ \(speedText(bytesPerSecond: snapshot.downloadBytesPerSecond))"
    }

    static func memoryText(bytes: UInt64) -> String {
        let gigabyte: UInt64 = 1_024 * 1_024 * 1_024
        let megabyte: UInt64 = 1_024 * 1_024
        if bytes >= gigabyte {
            return "\(ceilDivide(bytes, by: gigabyte)) GB"
        }

        return "\(ceilDivide(bytes, by: megabyte)) MB"
    }

    static func speedText(bytesPerSecond: UInt64) -> String {
        guard bytesPerSecond > 0 else {
            return "0 KB/s"
        }

        let megabyte: UInt64 = 1_024 * 1_024
        let kilobyte: UInt64 = 1_024
        if bytesPerSecond >= megabyte {
            return "\(ceilDivide(bytesPerSecond, by: megabyte)) MB/s"
        }

        return "\(ceilDivide(bytesPerSecond, by: kilobyte)) KB/s"
    }

    private static func ceilDivide(_ value: UInt64, by unit: UInt64) -> UInt64 {
        guard value > 0 else {
            return 0
        }

        return (value / unit) + (value.isMultiple(of: unit) ? 0 : 1)
    }
}

final class TCPViewerStatusMetricsService {
    typealias SnapshotHandler = (TCPViewerStatusMetricsSnapshot) -> Void
    typealias MemorySampler = () -> UInt64?
    typealias DateProvider = () -> Date

    private struct State {
        var pendingTraffic = TCPViewerCapturedTrafficSample.zero
        var pendingDirectionalPacketIDs: Set<PacketSummary.ID> = []
        var pendingDirectionalPacketIDsByStreamID: [UInt32: [PacketSummary.ID]] = [:]
        var latestSnapshot = TCPViewerStatusMetricsSnapshot.empty
        var lastSampleDate: Date?
        var observedPacketRevision: UInt64 = 0
        var observedPacketLineageRevision: UInt64 = 0
    }

    var snapshotHandler: SnapshotHandler?

    private let timerInterval: TimeInterval
    private let memorySampler: MemorySampler
    private let dateProvider: DateProvider
    private let timerQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let state = Protected(State())
    private var timer: DispatchSourceTimer?

    // Mirror the metadata backfill cap so delayed direction bookkeeping stays bounded per flow.
    private static let maxPendingDirectionalPacketIDsPerStream = 128

    init(
        timerInterval: TimeInterval = 2,
        memorySampler: @escaping MemorySampler = TCPViewerStatusMetricsService.currentMemoryFootprintBytes,
        dateProvider: @escaping DateProvider = Date.init,
        timerQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.StatusMetrics", qos: .utility),
        callbackQueue: DispatchQueue = .main
    ) {
        self.timerInterval = max(timerInterval, 0.1)
        self.memorySampler = memorySampler
        self.dateProvider = dateProvider
        self.timerQueue = timerQueue
        self.callbackQueue = callbackQueue
    }

    deinit {
        stop()
    }

    var snapshot: TCPViewerStatusMetricsSnapshot {
        state.read(\.latestSnapshot)
    }

    // Start the lightweight timer and publish an immediate baseline sample.
    func start() {
        guard timer == nil else {
            return
        }

        sampleNow()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + timerInterval,
            repeating: timerInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.sampleNow()
        }
        self.timer = timer
        timer.resume()
    }

    // Stop sampling when the owning view model goes away.
    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    // Accumulate only new live append ranges from the ingest state.
    func recordPacketIngestState(_ ingestState: PacketIngestState) {
        state.write { state in
            if ingestState.packetLineageRevision != state.observedPacketLineageRevision {
                resetTraffic(in: &state)
            }

            defer {
                state.observedPacketRevision = ingestState.packetRevision
                state.observedPacketLineageRevision = ingestState.packetLineageRevision
            }

            guard ingestState.source == .live,
                  ingestState.packetRevision != state.observedPacketRevision else {
                return
            }

            switch ingestState.lastMutation {
            case .append(let range):
                guard range.lowerBound >= 0,
                      range.upperBound <= ingestState.packets.count else {
                    return
                }

                let sample = Self.trafficSample(for: ingestState.packets[range], state: &state)
                state.pendingTraffic = state.pendingTraffic.adding(sample)
            case .appendWithMetadataUpdates(let range, let updatedPacketIDs):
                guard range.lowerBound >= 0,
                      range.upperBound <= ingestState.packets.count else {
                    return
                }

                let appendedSample = Self.trafficSample(for: ingestState.packets[range], state: &state)
                let updatedSample = Self.trafficSample(
                    forUpdatedPacketIDs: updatedPacketIDs,
                    ingestState: ingestState,
                    state: &state
                )
                let sample = appendedSample.adding(updatedSample)
                state.pendingTraffic = state.pendingTraffic.adding(sample)
            case .reset, .replace:
                resetTraffic(in: &state)
            case .metadataUpdate(let packetIDs):
                let sample = Self.trafficSample(
                    forUpdatedPacketIDs: packetIDs,
                    ingestState: ingestState,
                    state: &state
                )
                state.pendingTraffic = state.pendingTraffic.adding(sample)
            case .none:
                break
            }
        }
    }

    // Reset pending traffic while preserving the current memory reading.
    func resetTraffic() {
        state.write { state in
            resetTraffic(in: &state)
        }
    }

    // Produce a new snapshot from pending bytes and the current memory footprint.
    @discardableResult
    func sampleNow(notifiesHandler: Bool = true) -> TCPViewerStatusMetricsSnapshot {
        let now = dateProvider()
        let memoryBytes = memorySampler()
        let nextSnapshot = state.write { state -> TCPViewerStatusMetricsSnapshot in
            let previousDate = state.lastSampleDate
            let elapsed = previousDate.map { now.timeIntervalSince($0) } ?? 0
            let uploadBytesPerSecond = Self.bytesPerSecond(state.pendingTraffic.uploadBytes, elapsed: elapsed)
            let downloadBytesPerSecond = Self.bytesPerSecond(state.pendingTraffic.downloadBytes, elapsed: elapsed)
            let snapshot = TCPViewerStatusMetricsSnapshot(
                memoryBytes: memoryBytes ?? state.latestSnapshot.memoryBytes,
                uploadBytesPerSecond: uploadBytesPerSecond,
                downloadBytesPerSecond: downloadBytesPerSecond
            )
            state.pendingTraffic = .zero
            state.latestSnapshot = snapshot
            state.lastSampleDate = now
            return snapshot
        }

        if notifiesHandler {
            deliver(nextSnapshot)
        }
        return nextSnapshot
    }

    // Read the current process footprint so the value stays close to Activity Monitor's Memory column.
    private static func currentMemoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return UInt64(info.phys_footprint)
    }

    // Convert an appended packet slice into directional byte counts.
    private static func trafficSample(for packets: ArraySlice<PacketSummary>, state: inout State) -> TCPViewerCapturedTrafficSample {
        packets.reduce(into: TCPViewerCapturedTrafficSample.zero) { sample, packet in
            let byteCount = UInt64(max(packet.originalLength, 0))
            switch packet.direction {
            case .outbound:
                removePendingDirectionalPacket(packet, state: &state)
                sample = sample.adding(TCPViewerCapturedTrafficSample(uploadBytes: byteCount, downloadBytes: 0))
            case .inbound:
                removePendingDirectionalPacket(packet, state: &state)
                sample = sample.adding(TCPViewerCapturedTrafficSample(uploadBytes: 0, downloadBytes: byteCount))
            case .local:
                removePendingDirectionalPacket(packet, state: &state)
            case .unknown, nil:
                appendPendingDirectionalPacketIfNeeded(packet, state: &state)
                break
            @unknown default:
                break
            }
        }
    }

    // Count packets whose direction arrived after append, without recounting already handled packets.
    private static func trafficSample(
        forUpdatedPacketIDs packetIDs: [PacketSummary.ID],
        ingestState: PacketIngestState,
        state: inout State
    ) -> TCPViewerCapturedTrafficSample {
        packetIDs.reduce(into: TCPViewerCapturedTrafficSample.zero) { sample, packetID in
            guard state.pendingDirectionalPacketIDs.contains(packetID),
                  let packet = ingestState.packet(withID: packetID) else {
                return
            }

            let byteCount = UInt64(max(packet.originalLength, 0))
            switch packet.direction {
            case .outbound:
                removePendingDirectionalPacket(packet, state: &state)
                sample = sample.adding(TCPViewerCapturedTrafficSample(uploadBytes: byteCount, downloadBytes: 0))
            case .inbound:
                removePendingDirectionalPacket(packet, state: &state)
                sample = sample.adding(TCPViewerCapturedTrafficSample(uploadBytes: 0, downloadBytes: byteCount))
            case .local:
                removePendingDirectionalPacket(packet, state: &state)
            case .unknown, nil:
                break
            @unknown default:
                break
            }
        }
    }

    private static func bytesPerSecond(_ bytes: UInt64, elapsed: TimeInterval) -> UInt64 {
        guard bytes > 0, elapsed > 0 else {
            return 0
        }

        return UInt64(ceil(Double(bytes) / elapsed))
    }

    private static func appendPendingDirectionalPacketIfNeeded(_ packet: PacketSummary, state: inout State) {
        guard packet.originalLength > 0,
              let streamID = packet.streamID,
              state.pendingDirectionalPacketIDs.insert(packet.id).inserted else {
            return
        }

        var streamPacketIDs = state.pendingDirectionalPacketIDsByStreamID[streamID] ?? []
        streamPacketIDs.append(packet.id)
        if streamPacketIDs.count > maxPendingDirectionalPacketIDsPerStream {
            let removedCount = streamPacketIDs.count - maxPendingDirectionalPacketIDsPerStream
            for packetID in streamPacketIDs.prefix(removedCount) {
                state.pendingDirectionalPacketIDs.remove(packetID)
            }
            streamPacketIDs.removeFirst(removedCount)
        }
        state.pendingDirectionalPacketIDsByStreamID[streamID] = streamPacketIDs
    }

    private static func removePendingDirectionalPacket(_ packet: PacketSummary, state: inout State) {
        guard state.pendingDirectionalPacketIDs.remove(packet.id) != nil,
              let streamID = packet.streamID,
              var streamPacketIDs = state.pendingDirectionalPacketIDsByStreamID[streamID] else {
            return
        }

        streamPacketIDs.removeAll { $0 == packet.id }
        if streamPacketIDs.isEmpty {
            state.pendingDirectionalPacketIDsByStreamID.removeValue(forKey: streamID)
        } else {
            state.pendingDirectionalPacketIDsByStreamID[streamID] = streamPacketIDs
        }
    }

    private func resetTraffic(in state: inout State) {
        state.pendingTraffic = .zero
        state.pendingDirectionalPacketIDs.removeAll(keepingCapacity: false)
        state.pendingDirectionalPacketIDsByStreamID.removeAll(keepingCapacity: false)
        state.latestSnapshot = TCPViewerStatusMetricsSnapshot(
            memoryBytes: state.latestSnapshot.memoryBytes,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0
        )
        state.lastSampleDate = dateProvider()
    }

    private func deliver(_ snapshot: TCPViewerStatusMetricsSnapshot) {
        callbackQueue.async { [weak self] in
            self?.snapshotHandler?(snapshot)
        }
    }
}
