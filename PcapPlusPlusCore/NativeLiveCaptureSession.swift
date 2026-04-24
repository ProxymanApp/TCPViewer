import Foundation
@_implementationOnly import PacketryNativeBridge

public final class NativeLiveCaptureSession: LiveCaptureSessionProviding, @unchecked Sendable {
    private let streamBox = EventStreamBox<PacketIngestEvent>()
    private let state: NativeLiveCaptureSessionState

    init(interfaceID: String, options: CaptureOptions) throws {
        self.state = try NativeLiveCaptureSessionState(
            interfaceID: interfaceID,
            options: options,
            streamBox: streamBox
        )
    }

    public func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        streamBox.stream
    }

    public func start() async throws {
        try await state.start()
    }

    public func pause() async throws {
        try await state.pause()
    }

    public func resume() async throws {
        try await state.resume()
    }

    public func stop() async throws {
        try await state.stop(reason: nil)
    }

    public func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        try await state.inspectPacket(id: id)
    }

    public func healthSnapshot() async -> CaptureHealthSnapshot {
        await state.healthSnapshot()
    }
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
}

actor NativeLiveCaptureSessionState {
    private static let maxLivePacketBatchSize = 256
    private static let livePacketBatchInterval: Duration = .milliseconds(100)

    private let nativeSession: PCPPNativeLiveSession
    private let streamBox: EventStreamBox<PacketIngestEvent>
    private let stopCondition: CaptureStopCondition

    private var phase: LiveCaptureSessionPhase = .ready
    private var health: CaptureHealthSnapshot = .empty
    private var startedAt: Date?
    private var activeRunPacketCount: UInt64 = 0
    private var packetBatchBuffer = LivePacketBatchBuffer<PacketSummary>(maxBatchSize: maxLivePacketBatchSize)
    private var packetBatchFlushTask: Task<Void, Never>?
    private var durationStopTask: Task<Void, Never>?

    init(interfaceID: String, options: CaptureOptions, streamBox: EventStreamBox<PacketIngestEvent>) throws {
        self.streamBox = streamBox
        self.stopCondition = options.stopCondition
        var nativeError: NSError?
        self.nativeSession = PCPPNativeLiveSession(
            interfaceIdentifier: interfaceID,
            options: NativeBridgeMapper.nativeCaptureOptions(options),
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

            Task {
                await self.handlePacketBatch(packets)
            }
        }

        nativeSession.phaseHandler = { [weak self] phase, message in
            guard let self else {
                return
            }

            Task {
                await self.handlePhaseChange(phase, message: message)
            }
        }

        nativeSession.healthHandler = { [weak self] health in
            guard let self else {
                return
            }

            Task {
                await self.handleHealthChange(health)
            }
        }

        nativeSession.errorHandler = { [weak self] error in
            guard let self else {
                return
            }

            Task {
                await self.handleError(error)
            }
        }
    }

    func start() throws {
        cancelDurationStopTask()
        if phase == .stopped || phase == .failed || phase == .ready {
            activeRunPacketCount = 0
            startedAt = Date()
            cancelPacketBatchFlushTask()
            _ = packetBatchBuffer.flush()
        }

        do {
            try nativeSession.start()
            if startedAt == nil {
                startedAt = Date()
            }
            scheduleDurationStopIfNeeded()
        } catch {
            let packetryError = NativeBridgeMapper.coreError(error, defaultCode: .liveSessionStartFailed)
            phase = .failed
            streamBox.yield(.liveStateChanged(phase: .failed, message: packetryError.message))
            throw packetryError
        }
    }

    func pause() throws {
        cancelDurationStopTask()
        flushPendingPacketBatch()

        do {
            try nativeSession.pause()
            flushPendingPacketBatch()
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    func resume() throws {
        do {
            try nativeSession.resume()
            scheduleDurationStopIfNeeded()
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    func stop(reason: String?) throws {
        cancelDurationStopTask()
        flushPendingPacketBatch()

        do {
            try nativeSession.stop()
            flushPendingPacketBatch()
            if let reason {
                streamBox.yield(.liveStateChanged(phase: .stopped, message: reason))
            }
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    func healthSnapshot() -> CaptureHealthSnapshot {
        health
    }

    func inspectPacket(id: PacketSummary.ID) throws -> PacketInspection {
        do {
            let descriptor = try nativeSession.inspectPacket(withIdentifier: id)
            return NativeBridgeMapper.packetInspection(descriptor)
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        }
    }

    private func handlePacketBatch(_ packets: [PCPPNativePacketSummaryDescriptor]) {
        let batch = NativeBridgeMapper.packetBatch(packets, source: .live)
        activeRunPacketCount += UInt64(batch.count)
        if let readyBatch = packetBatchBuffer.append(batch) {
            cancelPacketBatchFlushTask()
            yieldPacketBatch(readyBatch)
        } else if phase == .running || phase == .starting {
            schedulePacketBatchFlushIfNeeded()
        } else {
            flushPendingPacketBatch()
        }

        if case .packetCount(let limit) = stopCondition, activeRunPacketCount >= limit {
            do {
                flushPendingPacketBatch()
                try stop(reason: "Capture stopped after reaching \(limit) packets.")
            } catch {
                streamBox.finish(throwing: NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed))
            }
        }
    }

    private func handlePhaseChange(_ phase: PCPPNativeLiveSessionPhase, message: String) {
        let mappedPhase = NativeBridgeMapper.livePhase(phase)
        if mappedPhase == .paused || mappedPhase == .stopped || mappedPhase == .failed {
            flushPendingPacketBatch()
        }
        self.phase = mappedPhase
        streamBox.yield(.liveStateChanged(phase: mappedPhase, message: message))

        if mappedPhase == .stopped {
            cancelDurationStopTask()
        }
    }

    private func handleHealthChange(_ descriptor: PCPPNativeCaptureHealthDescriptor) {
        let snapshot = NativeBridgeMapper.healthSnapshot(descriptor)
        health = snapshot
        streamBox.yield(.healthChanged(snapshot))
    }

    private func handleError(_ error: Error) {
        let packetryError = NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        phase = .failed
        cancelDurationStopTask()
        flushPendingPacketBatch()
        streamBox.yield(.liveStateChanged(phase: .failed, message: packetryError.message))
        streamBox.finish(throwing: packetryError)
    }

    private func yieldPacketBatch(_ batch: [PacketSummary]) {
        guard !batch.isEmpty else {
            return
        }

        streamBox.yield(.packetBatch(batch, disposition: .append))
    }

    private func schedulePacketBatchFlushIfNeeded() {
        guard packetBatchFlushTask == nil, !packetBatchBuffer.isEmpty else {
            return
        }

        packetBatchFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.livePacketBatchInterval)
                guard !Task.isCancelled, let self else {
                    return
                }

                await self.flushPendingPacketBatchFromTimer()
            } catch {
            }
        }
    }

    private func flushPendingPacketBatchFromTimer() {
        packetBatchFlushTask = nil
        flushPendingPacketBatch()
    }

    private func flushPendingPacketBatch() {
        cancelPacketBatchFlushTask()
        if let batch = packetBatchBuffer.flush() {
            yieldPacketBatch(batch)
        }
    }

    private func cancelPacketBatchFlushTask() {
        packetBatchFlushTask?.cancel()
        packetBatchFlushTask = nil
    }

    private func scheduleDurationStopIfNeeded() {
        guard case .durationMilliseconds(let duration) = stopCondition else {
            return
        }

        cancelDurationStopTask()
        durationStopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(duration))
                guard !Task.isCancelled, let self else {
                    return
                }

                await self.stopAfterDuration(duration)
            } catch {
            }
        }
    }

    private func stopAfterDuration(_ duration: UInt64) {
        guard phase == .running || phase == .starting || phase == .paused else {
            return
        }

        do {
            try stop(reason: "Capture stopped after \(duration) ms.")
        } catch {
            streamBox.finish(throwing: NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed))
        }
    }

    private func cancelDurationStopTask() {
        durationStopTask?.cancel()
        durationStopTask = nil
    }
}
