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

actor NativeLiveCaptureSessionState {
    private let nativeSession: PCPPNativeLiveSession
    private let streamBox: EventStreamBox<PacketIngestEvent>
    private let stopCondition: CaptureStopCondition

    private var phase: LiveCaptureSessionPhase = .ready
    private var health: CaptureHealthSnapshot = .empty
    private var startedAt: Date?
    private var activeRunPacketCount: UInt64 = 0
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

        do {
            try nativeSession.pause()
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

        do {
            try nativeSession.stop()
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
        streamBox.yield(.packetBatch(batch, disposition: .append))

        if case .packetCount(let limit) = stopCondition, activeRunPacketCount >= limit {
            do {
                try stop(reason: "Capture stopped after reaching \(limit) packets.")
            } catch {
                streamBox.finish(throwing: NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed))
            }
        }
    }

    private func handlePhaseChange(_ phase: PCPPNativeLiveSessionPhase, message: String) {
        let mappedPhase = NativeBridgeMapper.livePhase(phase)
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
        streamBox.yield(.liveStateChanged(phase: .failed, message: packetryError.message))
        streamBox.finish(throwing: packetryError)
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
