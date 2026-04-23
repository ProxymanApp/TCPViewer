import Foundation
@_implementationOnly import PacketryNativeBridge

public final class NativeOfflineCaptureDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    private let streamBox = EventStreamBox<PacketIngestEvent>()
    private let state: NativeOfflineCaptureDocumentState

    init(fileURL: URL) throws {
        self.state = try NativeOfflineCaptureDocumentState(fileURL: fileURL, streamBox: streamBox)
    }

    public func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        streamBox.stream
    }

    public func open() async throws -> [PacketSummary] {
        try await state.open()
    }

    public func reopen() async throws -> [PacketSummary] {
        try await state.reopen()
    }

    public func cancelLoading() async {
        await state.cancelLoading()
    }

    public func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        try await state.inspectPacket(id: id)
    }

    public func save() async throws {
        try await state.save()
    }

    public func save(to url: URL, format: CaptureFileFormat) async throws {
        try await state.save(to: url, format: format)
    }

    public func currentURL() async -> URL {
        await state.currentURL()
    }

    public func currentMetadata() async -> CaptureDocumentMetadata {
        await state.currentMetadata()
    }

    public func packetSummaries() async -> [PacketSummary] {
        await state.packetSummaries()
    }

    public func loadProgress() async -> PacketLoadProgress {
        await state.loadProgress()
    }
}

private final class LockedValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        let value = value
        lock.unlock()
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func withValue(_ update: (inout Value) -> Void) {
        lock.lock()
        update(&value)
        lock.unlock()
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let cancelled = cancelled
        lock.unlock()
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

actor NativeOfflineCaptureDocumentState {
    private enum LoadOperation {
        case open
        case reopen

        var initialPhase: OfflineCaptureDocumentPhase {
            switch self {
            case .open:
                .opening
            case .reopen:
                .reopening
            }
        }

        func initialMessage(for fileName: String) -> String {
            switch self {
            case .open:
                "Opening \(fileName)..."
            case .reopen:
                "Reopening \(fileName)..."
            }
        }
    }

    private struct ActiveLoad {
        let task: Task<[PacketSummary], Error>
        let cancellationFlag: CancellationFlag
    }

    private let nativeDocument: PCPPNativeOfflineDocument
    private let streamBox: EventStreamBox<PacketIngestEvent>
    private let packetCache = LockedValueBox<[PacketSummary]>([])
    private let loadProgressBox = LockedValueBox<PacketLoadProgress>(.idle)

    private var activeLoad: ActiveLoad?

    init(fileURL: URL, streamBox: EventStreamBox<PacketIngestEvent>) throws {
        self.streamBox = streamBox
        var nativeError: NSError?
        self.nativeDocument = PCPPNativeOfflineDocument(url: fileURL, error: &nativeError)

        if let nativeError {
            throw NativeBridgeMapper.coreError(
                nativeError,
                defaultCode: .offlineFileOpenFailed
            )
        }
    }

    func open() async throws -> [PacketSummary] {
        if let activeLoad {
            return try await activeLoad.task.value
        }

        return try await performLoad(.open)
    }

    func reopen() async throws -> [PacketSummary] {
        if let activeLoad {
            activeLoad.cancellationFlag.cancel()
            _ = try? await activeLoad.task.value
            self.activeLoad = nil
        }

        return try await performLoad(.reopen)
    }

    func cancelLoading() {
        activeLoad?.cancellationFlag.cancel()
    }

    func inspectPacket(id: PacketSummary.ID) throws -> PacketInspection {
        do {
            let descriptor = try nativeDocument.inspectPacket(withIdentifier: id)
            return NativeBridgeMapper.packetInspection(descriptor)
        } catch {
            throw NativeBridgeMapper.coreError(error, defaultCode: .offlineFileOpenFailed)
        }
    }

    func save() throws {
        try ensureDocumentCanSave()
        streamBox.yield(.documentStateChanged(phase: .saving, message: "Saving \(nativeDocument.currentURL.lastPathComponent)..."))

        do {
            try nativeDocument.save()
            let metadata = NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
            streamBox.yield(.documentMetadataChanged(metadata))
            streamBox.yield(.documentStateChanged(phase: .saved, message: "Saved \(nativeDocument.currentURL.lastPathComponent)."))
        } catch {
            throw handleFailure(error, code: .offlineFileSaveFailed)
        }
    }

    func save(to url: URL, format: CaptureFileFormat) throws {
        try ensureDocumentCanSave()
        streamBox.yield(.documentStateChanged(phase: .saving, message: "Saving as \(url.lastPathComponent)..."))

        do {
            try nativeDocument.save(to: url, format: format.rawValue)
            let metadata = NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
            streamBox.yield(.documentMetadataChanged(metadata))
            streamBox.yield(.documentStateChanged(phase: .saved, message: "Saved as \(url.lastPathComponent)."))
        } catch {
            throw handleFailure(error, code: .offlineFileSaveFailed)
        }
    }

    func currentURL() -> URL {
        nativeDocument.currentURL as URL
    }

    func currentMetadata() -> CaptureDocumentMetadata {
        NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
    }

    func packetSummaries() -> [PacketSummary] {
        packetCache.get()
    }

    func loadProgress() -> PacketLoadProgress {
        loadProgressBox.get()
    }

    private func performLoad(_ operation: LoadOperation) async throws -> [PacketSummary] {
        let fileName = nativeDocument.currentURL.lastPathComponent
        packetCache.set([])
        loadProgressBox.set(
            PacketLoadProgress(
                phase: .loading,
                loadedPacketCount: 0,
                processedBytes: nil,
                totalBytes: nil,
                isPartialResult: false,
                message: operation.initialMessage(for: fileName)
            )
        )

        streamBox.yield(.packetBatch([], disposition: .replace))
        streamBox.yield(.documentStateChanged(phase: operation.initialPhase, message: operation.initialMessage(for: fileName)))

        let loadTask = makeLoadTask(for: operation)
        activeLoad = loadTask

        do {
            let packets = try await loadTask.task.value
            activeLoad = nil

            let metadata = NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
            streamBox.yield(.documentMetadataChanged(metadata))
            streamBox.yield(.documentStateChanged(phase: .loaded, message: loadProgressBox.get().message))
            return packets
        } catch {
            activeLoad = nil
            let packetryError = NativeBridgeMapper.coreError(error, defaultCode: .offlineFileOpenFailed)
            let metadata = NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
            streamBox.yield(.documentMetadataChanged(metadata))

            if packetryError.code == .operationCancelled {
                streamBox.yield(.documentStateChanged(phase: .loaded, message: loadProgressBox.get().message))
            } else {
                let latestProgress = loadProgressBox.get()
                if latestProgress.phase != .failed {
                    let failureProgress = PacketLoadProgress(
                        phase: .failed,
                        loadedPacketCount: packetCache.get().count,
                        processedBytes: latestProgress.processedBytes,
                        totalBytes: latestProgress.totalBytes,
                        isPartialResult: !packetCache.get().isEmpty,
                        message: packetryError.message
                    )
                    loadProgressBox.set(failureProgress)
                    streamBox.yield(.loadProgressChanged(failureProgress))
                }
                streamBox.yield(.documentStateChanged(phase: .failed, message: packetryError.message))
            }

            throw packetryError
        }
    }

    private func makeLoadTask(for operation: LoadOperation) -> ActiveLoad {
        let cancellationFlag = CancellationFlag()
        let nativeDocument = self.nativeDocument
        let streamBox = self.streamBox
        let packetCache = self.packetCache
        let loadProgressBox = self.loadProgressBox

        let task = Task.detached(priority: .userInitiated) { () throws -> [PacketSummary] in
            var nativeError: NSError?

            let batchHandler: ([PCPPNativePacketSummaryDescriptor]) -> Void = { descriptors in
                let batch = NativeBridgeMapper.packetBatch(descriptors, source: .offline)
                packetCache.withValue { packets in
                    packets.append(contentsOf: batch)
                }
                streamBox.yield(.packetBatch(batch, disposition: .append))
            }

            let progressHandler: (PCPPNativePacketLoadProgressDescriptor) -> Void = { descriptor in
                let progress = NativeBridgeMapper.loadProgress(descriptor)
                loadProgressBox.set(progress)
                streamBox.yield(.loadProgressChanged(progress))
            }

            let descriptors: [PCPPNativePacketSummaryDescriptor]
            switch operation {
            case .open:
                descriptors = nativeDocument.openIncrementally(
                    withBatchSize: 128,
                    batchHandler: batchHandler,
                    progressHandler: progressHandler,
                    cancellationCheck: { cancellationFlag.isCancelled },
                    error: &nativeError
                )
            case .reopen:
                descriptors = nativeDocument.reopenIncrementally(
                    withBatchSize: 128,
                    batchHandler: batchHandler,
                    progressHandler: progressHandler,
                    cancellationCheck: { cancellationFlag.isCancelled },
                    error: &nativeError
                )
            }

            if let nativeError {
                throw nativeError
            }

            let packets = NativeBridgeMapper.packetBatch(descriptors, source: .offline)
            packetCache.set(packets)
            return packets
        }

        return ActiveLoad(task: task, cancellationFlag: cancellationFlag)
    }

    private func ensureDocumentCanSave() throws {
        let progress = loadProgressBox.get()
        if progress.phase == .loading {
            throw PacketryCoreError(
                code: .offlineFileSaveFailed,
                message: "Packetry cannot save while the capture is still loading."
            )
        }

        if progress.isPartialResult {
            throw PacketryCoreError(
                code: .offlineFileSaveFailed,
                message: "Packetry cannot save a partially loaded capture. Reload the file to finish loading first."
            )
        }
    }

    private func handleFailure(_ error: Error, code: PacketryCoreError.Code) -> PacketryCoreError {
        let packetryError = NativeBridgeMapper.coreError(error, defaultCode: code)
        streamBox.yield(.documentStateChanged(phase: .failed, message: packetryError.message))
        return packetryError
    }
}
