//
//  NativeLiveCaptureSession.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import Foundation

public final class NativeLiveCaptureSession: LiveCaptureSessionProviding, @unchecked Sendable {
    private let eventBox = EventCallbackBox<PacketIngestEvent>()
    private let state: NativeLiveCaptureSessionState

    public var eventHandler: PacketIngestEventHandler? {
        get { eventBox.handler }
        set { eventBox.handler = newValue }
    }

    init(interfaceID: String, options: CaptureOptions, disablesWireshark: Bool = false) throws {
        self.state = try NativeLiveCaptureSessionState(
            interfaceID: interfaceID,
            options: options,
            disablesWireshark: disablesWireshark,
            eventBox: eventBox
        )
    }

    public func start(completion: @escaping TCPViewerVoidCompletion) {
        state.start(completion: completion)
    }

    public func pause(completion: @escaping TCPViewerVoidCompletion) {
        state.pause(completion: completion)
    }

    public func resume(completion: @escaping TCPViewerVoidCompletion) {
        state.resume(completion: completion)
    }

    public func stop(completion: @escaping TCPViewerVoidCompletion) {
        state.stop(completion: completion)
    }

    public func clearCapturedPackets(completion: @escaping TCPViewerVoidCompletion) {
        state.clearCapturedPackets(completion: completion)
    }

    public func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        state.inspectPacket(id: id, completion: completion)
    }

    public func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        state.exportPackets(withIDs: identifiers, to: url, format: format, progress: progress, shouldCancel: shouldCancel, completion: completion)
    }

    public func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        state.healthSnapshot(completion: completion)
    }

    #if DEBUG
    public func debugMemorySnapshot() -> LiveCaptureSessionDebugSnapshot {
        state.debugMemorySnapshot()
    }
    #endif
}

struct LivePacketBatchBuffer<Element: Sendable>: Sendable {
    let maxBatchSize: Int
    private(set) var pendingElements: [Element] = []

    init(maxBatchSize: Int) {
        self.maxBatchSize = max(maxBatchSize, 1)
    }

    var isEmpty: Bool {
        pendingElements.isEmpty
    }

    var pendingCount: Int {
        pendingElements.count
    }

    mutating func append(_ elements: [Element]) -> [Element]? {
        guard !elements.isEmpty else {
            return nil
        }

        pendingElements.append(contentsOf: elements)
        guard pendingElements.count >= maxBatchSize else {
            return nil
        }

        return flush()
    }

    mutating func flush() -> [Element]? {
        guard !pendingElements.isEmpty else {
            return nil
        }

        let elements = pendingElements
        pendingElements.removeAll(keepingCapacity: true)
        return elements
    }

    mutating func discardPending(releasingCapacity: Bool) {
        pendingElements.removeAll(keepingCapacity: !releasingCapacity)
    }
}

struct LivePacketReanalysisQueue<ID: Hashable & Sendable>: Sendable {
    private var queuedIDs: [ID] = []
    private var queuedIDSet: Set<ID> = []
    private var readIndex = 0

    var isEmpty: Bool {
        pendingCount == 0
    }

    var pendingCount: Int {
        queuedIDs.count - readIndex
    }

    mutating func enqueue(_ ids: [ID]) {
        for id in ids where queuedIDSet.insert(id).inserted {
            queuedIDs.append(id)
        }
    }

    mutating func dequeue(maxCount: Int) -> [ID] {
        guard !isEmpty else {
            return []
        }

        let upperBound = min(readIndex + max(maxCount, 1), queuedIDs.count)
        let ids = Array(queuedIDs[readIndex..<upperBound])
        for id in ids {
            queuedIDSet.remove(id)
        }
        readIndex = upperBound
        compactIfNeeded()
        return ids
    }

    mutating func discardPending(releasingCapacity: Bool) {
        queuedIDs.removeAll(keepingCapacity: !releasingCapacity)
        queuedIDSet.removeAll(keepingCapacity: !releasingCapacity)
        readIndex = 0
    }

    private mutating func compactIfNeeded() {
        guard readIndex > 0 else {
            return
        }

        if readIndex == queuedIDs.count {
            queuedIDs.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 1_024 && readIndex > queuedIDs.count / 2 {
            queuedIDs.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

struct LiveCaptureDurationStopTimer: Sendable {
    let durationMilliseconds: UInt64
    private var deadline: Date?
    private var pausedRemainingMilliseconds: UInt64?

    init(durationMilliseconds: UInt64) {
        self.durationMilliseconds = durationMilliseconds
    }

    mutating func scheduleDelay(now: Date = Date()) -> UInt64 {
        let delay = max(pausedRemainingMilliseconds ?? durationMilliseconds, 1)
        pausedRemainingMilliseconds = nil
        deadline = now.addingTimeInterval(Double(delay) / 1000)
        return delay
    }

    @discardableResult
    mutating func pause(now: Date = Date()) -> UInt64? {
        guard let deadline else {
            return nil
        }

        let milliseconds = ceil(deadline.timeIntervalSince(now) * 1000)
        let remaining = UInt64(max(milliseconds, 1))
        self.deadline = nil
        pausedRemainingMilliseconds = remaining
        return remaining
    }

    mutating func reset() {
        deadline = nil
        pausedRemainingMilliseconds = nil
    }
}

private struct LivePacketSummaryText: Equatable {
    let protocolSummary: String?
    let infoSummary: String

    init(packet: PacketSummary) {
        self.protocolSummary = packet.protocolSummary
        self.infoSummary = packet.infoSummary
    }

    init(update: PCPPNativePacketSummaryUpdateDescriptor) {
        self.protocolSummary = update.protocolSummary
        self.infoSummary = update.infoSummary
    }
}

private final class NativeLiveCaptureSessionState: @unchecked Sendable {
    private static let maxLivePacketBatchSize = 256
    private static let maxLiveReanalysisBatchSize = 128
    private static let livePacketBatchInterval: DispatchTimeInterval = .milliseconds(100)
    private static let liveReanalysisInterval: DispatchTimeInterval = .milliseconds(250)

    private let queue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.NativeLiveCaptureSession", qos: .userInitiated)
    private let nativeSession: PCPPNativeLiveSession
    private let eventBox: EventCallbackBox<PacketIngestEvent>
    private let stopCondition: CaptureStopCondition

    private var phase: LiveCaptureSessionPhase = .ready
    private var health: CaptureHealthSnapshot = .empty
    private var startedAt: Date?
    private var activeRunPacketCount: UInt64 = 0
    private var packetBatchBuffer = LivePacketBatchBuffer<PacketSummary>(maxBatchSize: maxLivePacketBatchSize)
    private var packetBatchFlushWorkItem: DispatchWorkItem?
    private var packetReanalysisWorkItem: DispatchWorkItem?
    private var packetReanalysisQueue = LivePacketReanalysisQueue<PacketSummary.ID>()
    private var packetSummaryTextByID: [PacketSummary.ID: LivePacketSummaryText] = [:]
    private var durationStopWorkItem: DispatchWorkItem?
    private var durationStopTimer: LiveCaptureDurationStopTimer?

    init(interfaceID: String, options: CaptureOptions, disablesWireshark: Bool, eventBox: EventCallbackBox<PacketIngestEvent>) throws {
        self.eventBox = eventBox
        self.stopCondition = options.stopCondition
        if case .durationMilliseconds(let duration) = options.stopCondition {
            self.durationStopTimer = LiveCaptureDurationStopTimer(durationMilliseconds: duration)
        }
        var nativeError: NSError?
        self.nativeSession = PCPPNativeLiveSession(
            interfaceIdentifier: interfaceID,
            options: NativeBridgeMapper.nativeCaptureOptions(options),
            disablesWireshark: disablesWireshark,
            error: &nativeError
        )

        if let nativeError {
            throw NativeBridgeMapper.coreError(
                nativeError,
                defaultCode: .liveSessionStartFailed
            )
        }

        self.health = NativeBridgeMapper.healthSnapshot(nativeSession.healthSnapshot)
        nativeSession.packetHandler = { [weak self] packets in
            guard let self else {
                return
            }

            // Bridge native packet descriptors into Swift values before the async queue hop.
            let batch = NativeBridgeMapper.packetBatch(packets, source: .live)
            self.queue.async { [weak self] in
                self?.handlePacketBatch(batch)
            }
        }

        nativeSession.phaseHandler = { [weak self] phase, message in
            self?.queue.async {
                self?.handlePhaseChange(phase, message: message)
            }
        }

        nativeSession.healthHandler = { [weak self] health in
            guard let self else {
                return
            }

            // Keep Objective-C health descriptors out of queued Swift state.
            let snapshot = NativeBridgeMapper.healthSnapshot(health)
            self.queue.async { [weak self] in
                self?.handleHealthChange(snapshot)
            }
        }

        nativeSession.errorHandler = { [weak self] error in
            self?.queue.async {
                self?.handleError(error)
            }
        }
    }

    func start(completion: @escaping TCPViewerVoidCompletion) {
        queue.async {
            completion(Result {
                try self.startOnQueue()
            })
        }
    }

    func pause(completion: @escaping TCPViewerVoidCompletion) {
        queue.async {
            completion(Result {
                try self.pauseOnQueue()
            })
        }
    }

    func resume(completion: @escaping TCPViewerVoidCompletion) {
        queue.async {
            completion(Result {
                try self.resumeOnQueue()
            })
        }
    }

    func stop(completion: @escaping TCPViewerVoidCompletion) {
        queue.async {
            completion(Result {
                try self.stopOnQueue(reason: nil)
            })
        }
    }

    func clearCapturedPackets(completion: @escaping TCPViewerVoidCompletion) {
        queue.async {
            completion(Result {
                self.clearCapturedPacketsOnQueue()
            })
        }
    }

    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        queue.async {
            completion(self.health)
        }
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        queue.async {
            completion(Result {
                try self.inspectPacketOnQueue(id: id)
            })
        }
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        queue.async {
            completion(Result {
                guard !identifiers.isEmpty else {
                    throw TCPViewerCoreError(code: .offlineFileSaveFailed, message: "There are no packets to export.")
                }

                do {
                    try self.nativeSession.exportPackets(
                        withIdentifiers: identifiers.map { NSNumber(value: $0) },
                        to: url,
                        format: format.rawValue,
                        progressHandler: { exportedPacketCount, totalPacketCount in
                            progress?(PacketExportProgress(
                                exportedPacketCount: Int(exportedPacketCount),
                                totalPacketCount: Int(totalPacketCount)
                            ))
                        },
                        cancellationCheck: shouldCancel.map { check in
                            { check() }
                        }
                    )
                } catch {
                    throw NativeBridgeMapper.coreError(error, defaultCode: .offlineFileSaveFailed)
                }
            })
        }
    }

    #if DEBUG
    func debugMemorySnapshot() -> LiveCaptureSessionDebugSnapshot {
        queue.sync {
            LiveCaptureSessionDebugSnapshot(
                pendingBatchCount: packetBatchBuffer.pendingCount,
                activeRunPacketCount: activeRunPacketCount
            )
        }
    }
    #endif

    private func startOnQueue() throws {
        cancelDurationStopWorkItem()
        if phase == .stopped || phase == .failed || phase == .ready {
            activeRunPacketCount = 0
            startedAt = Date()
            cancelPacketBatchFlushWorkItem()
            cancelPacketReanalysisWorkItem()
            packetReanalysisQueue.discardPending(releasingCapacity: true)
            packetSummaryTextByID.removeAll(keepingCapacity: false)
            packetBatchBuffer.discardPending(releasingCapacity: true)
        }

        do {
            try nativeSession.start()
            if startedAt == nil {
                startedAt = Date()
            }
            scheduleDurationStopIfNeeded()
        } catch {
            let tcpviewerError = NativeBridgeMapper.coreError(error, defaultCode: .liveSessionStartFailed)
            phase = .failed
            eventBox.yield(.liveStateChanged(phase: .failed, message: tcpviewerError.message))
            throw tcpviewerError
        }
    }

    private func pauseOnQueue() throws {
        let didPauseTimer = pauseDurationStopTimerIfNeeded()
        flushPendingPacketBatch()

        do {
            try nativeSession.pause()
            flushPendingPacketBatch()
        } catch {
            if didPauseTimer {
                scheduleDurationStopIfNeeded()
            }
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    private func resumeOnQueue() throws {
        do {
            try nativeSession.resume()
            scheduleDurationStopIfNeeded()
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    private func clearCapturedPacketsOnQueue() {
        cancelPacketBatchFlushWorkItem()
        cancelPacketReanalysisWorkItem()
        packetBatchBuffer.discardPending(releasingCapacity: true)
        packetReanalysisQueue.discardPending(releasingCapacity: true)
        packetSummaryTextByID.removeAll(keepingCapacity: false)
        activeRunPacketCount = 0
        nativeSession.clearCapturedPackets()
        health = NativeBridgeMapper.healthSnapshot(nativeSession.healthSnapshot)
        eventBox.yield(.healthChanged(health))
    }

    private func stopOnQueue(reason: String?) throws {
        cancelDurationStopWorkItem()
        flushPendingPacketBatch()

        do {
            try nativeSession.stop()
            flushPendingPacketBatch()
            if let reason {
                eventBox.yield(.liveStateChanged(phase: .stopped, message: reason))
            }
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    private func inspectPacketOnQueue(id: PacketSummary.ID) throws -> PacketInspection {
        do {
            let descriptor = try nativeSession.inspectPacket(withIdentifier: id)
            return NativeBridgeMapper.packetInspection(descriptor)
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    private func handlePacketBatch(_ batch: [PacketSummary]) {
        activeRunPacketCount += UInt64(batch.count)
        if let readyBatch = packetBatchBuffer.append(batch) {
            cancelPacketBatchFlushWorkItem()
            yieldPacketBatch(readyBatch)
        } else if phase == .running || phase == .starting {
            schedulePacketBatchFlushIfNeeded()
        } else {
            flushPendingPacketBatch()
        }

        if case .packetCount(let limit) = stopCondition, activeRunPacketCount >= limit {
            do {
                flushPendingPacketBatch()
                try stopOnQueue(reason: "Capture stopped after reaching \(limit) packets.")
            } catch {
                eventBox.finish(throwing: NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed))
            }
        }
    }

    private func handlePhaseChange(_ phase: PCPPNativeLiveSessionPhase, message: String) {
        let mappedPhase = NativeBridgeMapper.livePhase(phase)
        if mappedPhase == .paused || mappedPhase == .stopped || mappedPhase == .failed {
            flushPendingPacketBatch()
        }
        self.phase = mappedPhase
        eventBox.yield(.liveStateChanged(phase: mappedPhase, message: message))

        if mappedPhase == .stopped {
            cancelDurationStopWorkItem()
        }
    }

    private func handleHealthChange(_ snapshot: CaptureHealthSnapshot) {
        health = snapshot
        eventBox.yield(.healthChanged(snapshot))
    }

    private func handleError(_ error: Error) {
        let tcpviewerError = NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        phase = .failed
        cancelDurationStopWorkItem()
        flushPendingPacketBatch()
        eventBox.yield(.liveStateChanged(phase: .failed, message: tcpviewerError.message))
        eventBox.finish(throwing: tcpviewerError)
    }

    private func yieldPacketBatch(_ batch: [PacketSummary]) {
        guard !batch.isEmpty else {
            return
        }

        for packet in batch {
            packetSummaryTextByID[packet.id] = LivePacketSummaryText(packet: packet)
        }
        eventBox.yield(.packetBatch(batch, disposition: .append))
        packetReanalysisQueue.enqueue(batch.map(\.id))
        schedulePacketReanalysisIfNeeded()
    }

    private func schedulePacketBatchFlushIfNeeded() {
        guard packetBatchFlushWorkItem == nil, !packetBatchBuffer.isEmpty else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingPacketBatchFromTimer()
        }
        packetBatchFlushWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.livePacketBatchInterval, execute: workItem)
    }

    private func flushPendingPacketBatchFromTimer() {
        packetBatchFlushWorkItem = nil
        flushPendingPacketBatch()
    }

    private func flushPendingPacketBatch() {
        cancelPacketBatchFlushWorkItem()
        if let batch = packetBatchBuffer.flush() {
            yieldPacketBatch(batch)
        }
    }

    private func cancelPacketBatchFlushWorkItem() {
        packetBatchFlushWorkItem?.cancel()
        packetBatchFlushWorkItem = nil
    }

    private func schedulePacketReanalysisIfNeeded() {
        guard packetReanalysisWorkItem == nil, !packetReanalysisQueue.isEmpty else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.reanalyzePacketSummariesFromTimer()
        }
        packetReanalysisWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.liveReanalysisInterval, execute: workItem)
    }

    private func reanalyzePacketSummariesFromTimer() {
        packetReanalysisWorkItem = nil
        let packetIDs = packetReanalysisQueue.dequeue(maxCount: Self.maxLiveReanalysisBatchSize)
        guard !packetIDs.isEmpty else {
            return
        }

        do {
            // Reanalyze only queued rows so live capture cost does not grow with the full capture.
            let descriptors = try autoreleasepool {
                try nativeSession.reanalyzePacketSummaryUpdates(withIdentifiers: packetIDs)
            }
            let updates = descriptors.compactMap { descriptor -> PacketSummaryUpdate? in
                let packetID = descriptor.packetIdentifier
                let summaryText = LivePacketSummaryText(update: descriptor)
                guard let current = packetSummaryTextByID[packetID] else {
                    packetSummaryTextByID[packetID] = summaryText
                    return nil
                }

                guard current != summaryText else {
                    return nil
                }
                packetSummaryTextByID[packetID] = summaryText
                return PacketSummaryUpdate(
                    packetID: packetID,
                    protocolSummary: summaryText.protocolSummary,
                    infoSummary: summaryText.infoSummary
                )
            }

            if !updates.isEmpty {
                eventBox.yield(.packetSummaryUpdates(updates))
            }
            schedulePacketReanalysisIfNeeded()
        } catch {
            // Reanalysis only refines table text; capture delivery should continue if it fails.
        }
    }

    private func cancelPacketReanalysisWorkItem() {
        packetReanalysisWorkItem?.cancel()
        packetReanalysisWorkItem = nil
    }

    private func scheduleDurationStopIfNeeded() {
        guard var timer = durationStopTimer else {
            return
        }

        cancelDurationStopWorkItem(resetTimer: false)
        let delay = timer.scheduleDelay()
        durationStopTimer = timer
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopAfterDuration(timer.durationMilliseconds)
        }
        durationStopWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(min(delay, UInt64(Int.max)))), execute: workItem)
    }

    private func pauseDurationStopTimerIfNeeded() -> Bool {
        guard var timer = durationStopTimer,
              timer.pause() != nil else {
            return false
        }

        durationStopTimer = timer
        cancelDurationStopWorkItem(resetTimer: false)
        return true
    }

    private func stopAfterDuration(_ duration: UInt64) {
        guard phase == .running || phase == .starting || phase == .paused else {
            return
        }

        do {
            try stopOnQueue(reason: "Capture stopped after \(duration) ms.")
        } catch {
            eventBox.finish(throwing: NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed))
        }
    }

    private func cancelDurationStopWorkItem(resetTimer: Bool = true) {
        durationStopWorkItem?.cancel()
        durationStopWorkItem = nil
        if resetTimer {
            durationStopTimer?.reset()
        }
    }
}
