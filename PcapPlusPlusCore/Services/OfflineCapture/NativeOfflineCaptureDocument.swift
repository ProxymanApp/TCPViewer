import Foundation
@_implementationOnly import TCPViewerNativeBridge

public final class NativeOfflineCaptureDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    private let eventBox = EventCallbackBox<PacketIngestEvent>()
    private let state: NativeOfflineCaptureDocumentState

    public var eventHandler: PacketIngestEventHandler? {
        get { eventBox.handler }
        set { eventBox.handler = newValue }
    }

    init(fileURL: URL, disablesWireshark: Bool = false) throws {
        self.state = try NativeOfflineCaptureDocumentState(fileURL: fileURL, disablesWireshark: disablesWireshark, eventBox: eventBox)
    }

    public func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        state.open(completion: completion)
    }

    public func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        state.reopen(completion: completion)
    }

    public func cancelLoading(completion: (() -> Void)?) {
        state.cancelLoading(completion: completion)
    }

    public func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        state.inspectPacket(id: id, completion: completion)
    }

    public func save(completion: @escaping TCPViewerVoidCompletion) {
        state.save(completion: completion)
    }

    public func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        state.save(to: url, format: format, completion: completion)
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

    public func currentURL() -> URL {
        state.currentURL()
    }

    public func currentMetadata() -> CaptureDocumentMetadata {
        state.currentMetadata()
    }

    public func packetSummaries() -> [PacketSummary] {
        state.packetSummaries()
    }

    public func loadProgress() -> PacketLoadProgress {
        state.loadProgress()
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

private final class NativeOfflineCaptureDocumentState: @unchecked Sendable {
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

    private final class ActiveLoad {
        let cancellationFlag: CancellationFlag
        var completions: [TCPViewerCompletion<[PacketSummary]>]

        init(
            cancellationFlag: CancellationFlag,
            completions: [TCPViewerCompletion<[PacketSummary]>]
        ) {
            self.cancellationFlag = cancellationFlag
            self.completions = completions
        }
    }

    private let stateQueue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.NativeOfflineCaptureDocument.state", qos: .userInitiated)
    private let loadQueue = DispatchQueue(label: "com.proxyman.tcpviewer.PcapPlusPlusCore.NativeOfflineCaptureDocument.load", qos: .userInitiated)
    private let nativeDocument: PCPPNativeOfflineDocument
    private let eventBox: EventCallbackBox<PacketIngestEvent>
    private let packetCache = LockedValueBox<[PacketSummary]>([])
    private let loadProgressBox = LockedValueBox<PacketLoadProgress>(.idle)

    private var activeLoad: ActiveLoad?
    private var queuedReopenCompletions: [TCPViewerCompletion<[PacketSummary]>] = []

    init(fileURL: URL, disablesWireshark: Bool, eventBox: EventCallbackBox<PacketIngestEvent>) throws {
        self.eventBox = eventBox
        var nativeError: NSError?
        self.nativeDocument = PCPPNativeOfflineDocument(url: fileURL, disablesWireshark: disablesWireshark, error: &nativeError)

        if let nativeError {
            throw NativeBridgeMapper.coreError(
                nativeError,
                defaultCode: .offlineFileOpenFailed
            )
        }
    }

    func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        stateQueue.async {
            if let activeLoad = self.activeLoad {
                activeLoad.completions.append(completion)
                return
            }

            self.performLoad(.open, completions: [completion])
        }
    }

    func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        stateQueue.async {
            if let activeLoad = self.activeLoad {
                activeLoad.cancellationFlag.cancel()
                self.queuedReopenCompletions.append(completion)
                return
            }

            self.performLoad(.reopen, completions: [completion])
        }
    }

    func cancelLoading(completion: (() -> Void)?) {
        stateQueue.async {
            self.activeLoad?.cancellationFlag.cancel()
            completion?()
        }
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        stateQueue.async {
            completion(Result {
                do {
                    let descriptor = try self.nativeDocument.inspectPacket(withIdentifier: id)
                    return NativeBridgeMapper.packetInspection(descriptor)
                } catch {
                    throw NativeBridgeMapper.coreError(error, defaultCode: .offlineFileOpenFailed)
                }
            })
        }
    }

    func save(completion: @escaping TCPViewerVoidCompletion) {
        stateQueue.async {
            completion(Result {
                try self.ensureDocumentCanSave()
                self.eventBox.yield(.documentStateChanged(phase: .saving, message: "Saving \(self.nativeDocument.currentURL.lastPathComponent)..."))

                do {
                    try self.nativeDocument.save()
                    let metadata = NativeBridgeMapper.documentMetadata(self.nativeDocument.documentMetadata)
                    self.eventBox.yield(.documentMetadataChanged(metadata))
                    self.eventBox.yield(.documentStateChanged(phase: .saved, message: "Saved \(self.nativeDocument.currentURL.lastPathComponent)."))
                } catch {
                    throw self.handleFailure(error, code: .offlineFileSaveFailed)
                }
            })
        }
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        stateQueue.async {
            completion(Result {
                try self.ensureDocumentCanSave()
                self.eventBox.yield(.documentStateChanged(phase: .saving, message: "Saving as \(url.lastPathComponent)..."))

                do {
                    try self.nativeDocument.save(to: url, format: format.rawValue)
                    let metadata = NativeBridgeMapper.documentMetadata(self.nativeDocument.documentMetadata)
                    self.eventBox.yield(.documentMetadataChanged(metadata))
                    self.eventBox.yield(.documentStateChanged(phase: .saved, message: "Saved as \(url.lastPathComponent)."))
                } catch {
                    throw self.handleFailure(error, code: .offlineFileSaveFailed)
                }
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
        stateQueue.async {
            completion(Result {
                guard !identifiers.isEmpty else {
                    throw TCPViewerCoreError(code: .offlineFileSaveFailed, message: "There are no packets to export.")
                }

                do {
                    try self.nativeDocument.exportPackets(
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

    private func performLoad(_ operation: LoadOperation, completions: [TCPViewerCompletion<[PacketSummary]>]) {
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

        eventBox.yield(.packetBatch([], disposition: .replace))
        eventBox.yield(.documentStateChanged(phase: operation.initialPhase, message: operation.initialMessage(for: fileName)))

        let activeLoad = ActiveLoad(cancellationFlag: CancellationFlag(), completions: completions)
        self.activeLoad = activeLoad
        let nativeDocument = self.nativeDocument
        let eventBox = self.eventBox
        let packetCache = self.packetCache
        let loadProgressBox = self.loadProgressBox

        loadQueue.async { [weak self] in
            let result: Result<[PacketSummary], Error> = Result {
                var nativeError: NSError?

                let batchHandler: ([PCPPNativePacketSummaryDescriptor]) -> Void = { descriptors in
                    let batch = NativeBridgeMapper.packetBatch(descriptors, source: .offline)
                    packetCache.withValue { packets in
                        packets.append(contentsOf: batch)
                    }
                    eventBox.yield(.packetBatch(batch, disposition: .append))
                }

                let progressHandler: (PCPPNativePacketLoadProgressDescriptor) -> Void = { descriptor in
                    let progress = NativeBridgeMapper.loadProgress(descriptor)
                    loadProgressBox.set(progress)
                    eventBox.yield(.loadProgressChanged(progress))
                }

                let descriptors: [PCPPNativePacketSummaryDescriptor]
                switch operation {
                case .open:
                    descriptors = nativeDocument.openIncrementally(
                        withBatchSize: 128,
                        batchHandler: batchHandler,
                        progressHandler: progressHandler,
                        cancellationCheck: { activeLoad.cancellationFlag.isCancelled },
                        error: &nativeError
                    )
                case .reopen:
                    descriptors = nativeDocument.reopenIncrementally(
                        withBatchSize: 128,
                        batchHandler: batchHandler,
                        progressHandler: progressHandler,
                        cancellationCheck: { activeLoad.cancellationFlag.isCancelled },
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

            self?.stateQueue.async {
                self?.finishLoad(activeLoad, result: result)
            }
        }
    }

    private func finishLoad(_ activeLoad: ActiveLoad, result: Result<[PacketSummary], Error>) {
        guard self.activeLoad === activeLoad else {
            return
        }

        self.activeLoad = nil
        let finalResult = finalizeLoadResult(result)
        let completions = activeLoad.completions
        completions.forEach { $0(finalResult) }

        if !queuedReopenCompletions.isEmpty {
            let completions = queuedReopenCompletions
            queuedReopenCompletions = []
            performLoad(.reopen, completions: completions)
        }
    }

    private func finalizeLoadResult(_ result: Result<[PacketSummary], Error>) -> Result<[PacketSummary], Error> {
        switch result {
        case .success(let packets):
            let metadata = NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
            eventBox.yield(.documentMetadataChanged(metadata))
            eventBox.yield(.documentStateChanged(phase: .loaded, message: loadProgressBox.get().message))
            return .success(packets)
        case .failure(let error):
            let tcpviewerError = NativeBridgeMapper.coreError(error, defaultCode: .offlineFileOpenFailed)
            let metadata = NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
            eventBox.yield(.documentMetadataChanged(metadata))

            if tcpviewerError.code == .operationCancelled {
                eventBox.yield(.documentStateChanged(phase: .loaded, message: loadProgressBox.get().message))
            } else {
                let latestProgress = loadProgressBox.get()
                if latestProgress.phase != .failed {
                    let failureProgress = PacketLoadProgress(
                        phase: .failed,
                        loadedPacketCount: packetCache.get().count,
                        processedBytes: latestProgress.processedBytes,
                        totalBytes: latestProgress.totalBytes,
                        isPartialResult: !packetCache.get().isEmpty,
                        message: tcpviewerError.message
                    )
                    loadProgressBox.set(failureProgress)
                    eventBox.yield(.loadProgressChanged(failureProgress))
                }
                eventBox.yield(.documentStateChanged(phase: .failed, message: tcpviewerError.message))
            }

            return .failure(tcpviewerError)
        }
    }

    private func ensureDocumentCanSave() throws {
        let progress = loadProgressBox.get()
        if progress.phase == .loading {
            throw TCPViewerCoreError(
                code: .offlineFileSaveFailed,
                message: "TCP Viewer cannot save while the capture is still loading."
            )
        }

        if progress.isPartialResult {
            throw TCPViewerCoreError(
                code: .offlineFileSaveFailed,
                message: "TCP Viewer cannot save a partially loaded capture. Reload the file to finish loading first."
            )
        }
    }

    private func handleFailure(_ error: Error, code: TCPViewerCoreError.Code) -> TCPViewerCoreError {
        let tcpviewerError = NativeBridgeMapper.coreError(error, defaultCode: code)
        eventBox.yield(.documentStateChanged(phase: .failed, message: tcpviewerError.message))
        return tcpviewerError
    }
}
