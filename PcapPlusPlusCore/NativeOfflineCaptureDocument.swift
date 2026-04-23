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
}

actor NativeOfflineCaptureDocumentState {
    private let nativeDocument: PCPPNativeOfflineDocument
    private let streamBox: EventStreamBox<PacketIngestEvent>

    private var cachedPackets: [PacketSummary] = []

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

    func open() throws -> [PacketSummary] {
        streamBox.yield(.documentStateChanged(phase: .opening, message: "Opening \(nativeDocument.currentURL.lastPathComponent)..."))

        do {
            var nativeError: NSError?
            let packets = nativeDocument.openAndReturnError(&nativeError)
            if let nativeError {
                throw nativeError
            }
            return try finalizeLoad(
                packets,
                phase: .loaded,
                message: "Loaded \(packets.count) packets from \(nativeDocument.currentURL.lastPathComponent)."
            )
        } catch {
            throw handleFailure(error, code: .offlineFileOpenFailed)
        }
    }

    func reopen() throws -> [PacketSummary] {
        streamBox.yield(.documentStateChanged(phase: .reopening, message: "Reopening \(nativeDocument.currentURL.lastPathComponent)..."))

        do {
            var nativeError: NSError?
            let packets = nativeDocument.reopenAndReturnError(&nativeError)
            if let nativeError {
                throw nativeError
            }
            return try finalizeLoad(
                packets,
                phase: .loaded,
                message: "Reloaded \(packets.count) packets from \(nativeDocument.currentURL.lastPathComponent)."
            )
        } catch {
            throw handleFailure(error, code: .offlineFileOpenFailed)
        }
    }

    func save() throws {
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
        cachedPackets
    }

    private func finalizeLoad(
        _ descriptors: [PCPPNativePacketSummaryDescriptor],
        phase: OfflineCaptureDocumentPhase,
        message: String
    ) throws -> [PacketSummary] {
        let packets = NativeBridgeMapper.packetBatch(descriptors, source: .offline)
        cachedPackets = packets

        let metadata = NativeBridgeMapper.documentMetadata(nativeDocument.documentMetadata)
        streamBox.yield(.documentMetadataChanged(metadata))
        streamBox.yield(.packetBatch(packets))
        streamBox.yield(.documentStateChanged(phase: phase, message: message))

        return packets
    }

    private func handleFailure(_ error: Error, code: PacketryCoreError.Code) -> PacketryCoreError {
        let packetryError = NativeBridgeMapper.coreError(error, defaultCode: code)
        streamBox.yield(.documentStateChanged(phase: .failed, message: packetryError.message))
        return packetryError
    }
}
