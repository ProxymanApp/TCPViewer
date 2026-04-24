import Foundation
@_implementationOnly import PacketryNativeBridge

public final class NativeLiveCaptureSession: LiveCaptureSessionProviding, @unchecked Sendable {
    private let eventBox = EventCallbackBox<PacketIngestEvent>()
    private let state: NativeLiveCaptureSessionState

    public var eventHandler: PacketIngestEventHandler? {
        get { eventBox.handler }
        set { eventBox.handler = newValue }
    }

    init(interfaceID: String, options: CaptureOptions) throws {
        self.state = try NativeLiveCaptureSessionState(
            interfaceID: interfaceID,
            options: options,
            eventBox: eventBox
        )
    }

    public func start(completion: @escaping PacketryVoidCompletion) {
        state.start(completion: completion)
    }

    public func pause(completion: @escaping PacketryVoidCompletion) {
        state.pause(completion: completion)
    }

    public func resume(completion: @escaping PacketryVoidCompletion) {
        state.resume(completion: completion)
    }

    public func stop(completion: @escaping PacketryVoidCompletion) {
        state.stop(completion: completion)
    }

    public func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>) {
        state.inspectPacket(id: id, completion: completion)
    }

    public func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        state.healthSnapshot(completion: completion)
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

private final class NativeLiveCaptureSessionState: @unchecked Sendable {
    private static let maxLivePacketBatchSize = 256
    private static let livePacketBatchInterval: DispatchTimeInterval = .milliseconds(100)

    private let queue = DispatchQueue(label: "com.proxyman.Packetry.PcapPlusPlusCore.NativeLiveCaptureSession", qos: .userInitiated)
    private let nativeSession: PCPPNativeLiveSession
    private let eventBox: EventCallbackBox<PacketIngestEvent>
    private let stopCondition: CaptureStopCondition

    private var phase: LiveCaptureSessionPhase = .ready
    private var health: CaptureHealthSnapshot = .empty
    private var startedAt: Date?
    private var activeRunPacketCount: UInt64 = 0
    private var packetBatchBuffer = LivePacketBatchBuffer<PacketSummary>(maxBatchSize: maxLivePacketBatchSize)
    private var packetBatchFlushWorkItem: DispatchWorkItem?
    private var durationStopWorkItem: DispatchWorkItem?

    init(interfaceID: String, options: CaptureOptions, eventBox: EventCallbackBox<PacketIngestEvent>) throws {
        self.eventBox = eventBox
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
            self?.queue.async {
                self?.handlePacketBatch(packets)
            }
        }

        nativeSession.phaseHandler = { [weak self] phase, message in
            self?.queue.async {
                self?.handlePhaseChange(phase, message: message)
            }
        }

        nativeSession.healthHandler = { [weak self] health in
            self?.queue.async {
                self?.handleHealthChange(health)
            }
        }

        nativeSession.errorHandler = { [weak self] error in
            self?.queue.async {
                self?.handleError(error)
            }
        }
    }

    func start(completion: @escaping PacketryVoidCompletion) {
        queue.async {
            completion(Result {
                try self.startOnQueue()
            })
        }
    }

    func pause(completion: @escaping PacketryVoidCompletion) {
        queue.async {
            completion(Result {
                try self.pauseOnQueue()
            })
        }
    }

    func resume(completion: @escaping PacketryVoidCompletion) {
        queue.async {
            completion(Result {
                try self.resumeOnQueue()
            })
        }
    }

    func stop(completion: @escaping PacketryVoidCompletion) {
        queue.async {
            completion(Result {
                try self.stopOnQueue(reason: nil)
            })
        }
    }

    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        queue.async {
            completion(self.health)
        }
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>) {
        queue.async {
            completion(Result {
                try self.inspectPacketOnQueue(id: id)
            })
        }
    }

    private func startOnQueue() throws {
        cancelDurationStopWorkItem()
        if phase == .stopped || phase == .failed || phase == .ready {
            activeRunPacketCount = 0
            startedAt = Date()
            cancelPacketBatchFlushWorkItem()
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
            eventBox.yield(.liveStateChanged(phase: .failed, message: packetryError.message))
            throw packetryError
        }
    }

    private func pauseOnQueue() throws {
        cancelDurationStopWorkItem()
        flushPendingPacketBatch()

        do {
            try nativeSession.pause()
            flushPendingPacketBatch()
        } catch {
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

    private func handlePacketBatch(_ packets: [PCPPNativePacketSummaryDescriptor]) {
        let batch = NativeBridgeMapper.packetBatch(packets, source: .live)
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

    private func handleHealthChange(_ descriptor: PCPPNativeCaptureHealthDescriptor) {
        let snapshot = NativeBridgeMapper.healthSnapshot(descriptor)
        health = snapshot
        eventBox.yield(.healthChanged(snapshot))
    }

    private func handleError(_ error: Error) {
        let packetryError = NativeBridgeMapper.coreError(error, defaultCode: .liveSessionControlFailed)
        phase = .failed
        cancelDurationStopWorkItem()
        flushPendingPacketBatch()
        eventBox.yield(.liveStateChanged(phase: .failed, message: packetryError.message))
        eventBox.finish(throwing: packetryError)
    }

    private func yieldPacketBatch(_ batch: [PacketSummary]) {
        guard !batch.isEmpty else {
            return
        }

        eventBox.yield(.packetBatch(batch, disposition: .append))
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

    private func scheduleDurationStopIfNeeded() {
        guard case .durationMilliseconds(let duration) = stopCondition else {
            return
        }

        cancelDurationStopWorkItem()
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopAfterDuration(duration)
        }
        durationStopWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(min(duration, UInt64(Int.max)))), execute: workItem)
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

    private func cancelDurationStopWorkItem() {
        durationStopWorkItem?.cancel()
        durationStopWorkItem = nil
    }
}
