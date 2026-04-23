import AppKit
import Combine
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

struct PacketIngestState: Sendable, Equatable {
    var source: CaptureSource?
    var packets: [PacketSummary]
    var lastBatchCount: Int
    var truncatedPacketCount: Int
    var decodeIssueCount: Int
    var statusMessage: String

    static let empty = PacketIngestState(
        source: nil,
        packets: [],
        lastBatchCount: 0,
        truncatedPacketCount: 0,
        decodeIssueCount: 0,
        statusMessage: "No packets loaded yet."
    )

    var totalPacketCount: Int {
        packets.count
    }

    mutating func reset(source: CaptureSource? = nil, message: String) {
        self.source = source
        packets = []
        lastBatchCount = 0
        truncatedPacketCount = 0
        decodeIssueCount = 0
        statusMessage = message
    }

    mutating func replace(with batch: [PacketSummary], source: CaptureSource, message: String? = nil) {
        self.source = source
        packets = batch
        lastBatchCount = batch.count
        recalculateCounters()
        if let message {
            statusMessage = message
        }
    }

    mutating func append(_ batch: [PacketSummary], source: CaptureSource, message: String? = nil) {
        self.source = source
        packets.append(contentsOf: batch)
        lastBatchCount = batch.count
        recalculateCounters()
        if let message {
            statusMessage = message
        }
    }

    private mutating func recalculateCounters() {
        truncatedPacketCount = packets.reduce(into: 0) { partialResult, packet in
            if packet.captureMetadata.isTruncated {
                partialResult += 1
            }
        }
        decodeIssueCount = packets.reduce(into: 0) { partialResult, packet in
            if packet.decodeStatus.kind != .complete {
                partialResult += 1
            }
        }
    }
}

struct CaptureDocumentState: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle
        case opening
        case loaded
        case saving
        case saved
        case reopening
        case failed
    }

    var phase: Phase
    var fileURL: URL?
    var format: CaptureFileFormat?
    var metadata: CaptureDocumentMetadata?
    var packetCount: Int
    var isDirty: Bool
    var statusMessage: String
    var lastError: PacketryCoreError?

    static let idle = CaptureDocumentState(
        phase: .idle,
        fileURL: nil,
        format: nil,
        metadata: nil,
        packetCount: 0,
        isDirty: false,
        statusMessage: "Open a capture file to inspect packets offline.",
        lastError: nil
    )

    var canReopen: Bool {
        fileURL != nil && phase != .opening && phase != .reopening && phase != .saving
    }

    var canSave: Bool {
        fileURL != nil && packetCount > 0 && phase != .opening && phase != .reopening && phase != .saving
    }

    var canSaveAs: Bool {
        packetCount > 0 && phase != .opening && phase != .reopening && phase != .saving
    }
}

struct CaptureSessionState: Sendable, Equatable {
    enum Phase: String, Sendable {
        case idle
        case ready
        case starting
        case running
        case paused
        case stopping
        case stopped
        case failed
    }

    var phase: Phase
    var interfaceInventory: [CaptureInterfaceSummary]
    var selectedInterfaceID: String?
    var options: CaptureOptions
    var health: CaptureHealthSnapshot
    var capturedPacketCount: Int
    var statusMessage: String
    var lastError: PacketryCoreError?

    static let idle = CaptureSessionState(
        phase: .idle,
        interfaceInventory: [],
        selectedInterfaceID: nil,
        options: CaptureOptions.defaults(),
        health: .empty,
        capturedPacketCount: 0,
        statusMessage: "Refresh interfaces to prepare a live capture session.",
        lastError: nil
    )

    var selectedInterface: CaptureInterfaceSummary? {
        interfaceInventory.first(where: { $0.id == selectedInterfaceID })
    }

    var canStart: Bool {
        selectedInterface?.isSelectable == true && [.ready, .stopped, .failed].contains(phase)
    }

    var canPause: Bool {
        phase == .running
    }

    var canResume: Bool {
        phase == .paused
    }

    var canStop: Bool {
        [.starting, .running, .paused, .stopping].contains(phase)
    }

    var optionsSummary: String {
        let stopSummary: String
        switch options.stopCondition {
        case .manual:
            stopSummary = "manual stop"
        case .packetCount(let count):
            stopSummary = "stop after \(count) packets"
        case .durationMilliseconds(let duration):
            stopSummary = "stop after \(duration) ms"
        @unknown default:
            stopSummary = "custom stop rule"
        }

        let writerSummary: String
        switch options.fileWriting.mode {
        case .disabled:
            writerSummary = "no file writing"
        case .single:
            writerSummary = "single \(options.fileWriting.format?.rawValue ?? "capture")"
        case .rotating:
            writerSummary = "rotating \(options.fileWriting.format?.rawValue ?? "pcapng")"
        case .ring:
            writerSummary = "ring \(options.fileWriting.format?.rawValue ?? "pcapng")"
        @unknown default:
            writerSummary = "custom writer"
        }

        return "snaplen \(options.snapshotLength), timeout \(options.readTimeoutMilliseconds) ms, \(stopSummary), \(writerSummary)"
    }
}

struct PacketryWindowSnapshot: Sendable, Equatable {
    var accessState: CaptureAccessState
    var documentState: CaptureDocumentState
    var sessionState: CaptureSessionState
    var packetIngestState: PacketIngestState
    var selectedPacketID: PacketSummary.ID?

    static let foundation = PacketryWindowSnapshot(
        accessState: .unknown,
        documentState: .idle,
        sessionState: .idle,
        packetIngestState: .empty,
        selectedPacketID: nil
    )

    var visiblePacketCount: Int {
        packetIngestState.totalPacketCount
    }
}

actor PacketryBackgroundCoordinator {
    private var activeOperations: [String: Task<Void, Never>] = [:]

    func replaceOperation(_ identifier: String, with task: Task<Void, Never>) {
        activeOperations[identifier]?.cancel()
        activeOperations[identifier] = task
    }

    func endOperation(_ identifier: String) {
        activeOperations.removeValue(forKey: identifier)
    }

    func cancelAll() {
        let operations = activeOperations.values
        activeOperations.removeAll()
        operations.forEach { $0.cancel() }
    }

    func activeOperationCount() -> Int {
        activeOperations.count
    }
}

struct PacketryServiceRegistry {
    let core: any PacketryCoreProviding

    init(core: any PacketryCoreProviding = NativePacketryCore()) {
        self.core = core
    }

    static let foundation = PacketryServiceRegistry()
}

@MainActor
final class PacketryWindowController: ObservableObject {
    @Published private(set) var snapshot: PacketryWindowSnapshot

    let services: PacketryServiceRegistry
    private let backgroundCoordinator: PacketryBackgroundCoordinator

    private var hasPerformedInitialLoad = false
    private var liveSession: (any LiveCaptureSessionProviding)?
    private var liveSessionConfiguration: LiveSessionConfiguration?
    private var liveEventsTask: Task<Void, Never>?
    private var document: (any OfflineCaptureDocumentProviding)?
    private var documentEventsTask: Task<Void, Never>?

    init(
        services: PacketryServiceRegistry? = nil,
        backgroundCoordinator: PacketryBackgroundCoordinator = PacketryBackgroundCoordinator(),
        snapshot: PacketryWindowSnapshot? = nil
    ) {
        self.services = services ?? .foundation
        self.backgroundCoordinator = backgroundCoordinator
        self.snapshot = snapshot ?? .foundation
    }

    deinit {
        liveEventsTask?.cancel()
        documentEventsTask?.cancel()
    }

    func performInitialLoadIfNeeded() async {
        guard !hasPerformedInitialLoad else {
            return
        }

        hasPerformedInitialLoad = true
        await refreshInterfaces()
    }

    func refreshInterfaces() async {
        snapshot.accessState = .checking
        snapshot.sessionState.lastError = nil
        snapshot.sessionState.statusMessage = "Refreshing interface inventory..."

        let previousSelectionID = snapshot.sessionState.selectedInterfaceID

        do {
            let interfaces = try await services.core.listInterfaces()
            applyInterfaceInventory(
                interfaces,
                previousSelectionID: previousSelectionID
            )
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .interfaceDiscoveryFailed)
            snapshot.accessState = packetryError.code == .capturePermissionDenied ? .blocked(.accessDenied) : .recovering
            snapshot.sessionState.interfaceInventory = []
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.phase = .idle
            snapshot.sessionState.lastError = packetryError
            snapshot.sessionState.statusMessage = packetryError.message
        }
    }

    func selectInterface(_ identifier: String?) {
        guard let identifier else {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = CaptureOptions.defaults()
            snapshot.sessionState.statusMessage = "Cleared interface selection."
            snapshot.sessionState.lastError = nil
            return
        }

        guard let interface = snapshot.sessionState.interfaceInventory.first(where: { $0.id == identifier }) else {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = CaptureOptions.defaults()
            snapshot.sessionState.statusMessage = "The selected interface is no longer present."
            snapshot.sessionState.lastError = PacketryCoreError(
                code: .unsupportedInterface,
                message: "The selected interface is no longer present."
            )
            return
        }

        guard interface.isSelectable else {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = CaptureOptions.defaults()
            snapshot.sessionState.statusMessage = interface.availabilityReason ?? "This interface is not currently available for capture."
            snapshot.sessionState.lastError = PacketryCoreError(
                code: .unsupportedInterface,
                message: snapshot.sessionState.statusMessage
            )
            return
        }

        snapshot.sessionState.selectedInterfaceID = interface.id
        snapshot.sessionState.options = (try? services.core.validateCaptureOptions(
            CaptureOptions.defaults(for: interface),
            for: interface
        )) ?? CaptureOptions.defaults(for: interface)
        snapshot.sessionState.lastError = nil

        if snapshot.sessionState.phase == .idle || snapshot.sessionState.phase == .failed || snapshot.sessionState.phase == .stopped {
            snapshot.sessionState.phase = .ready
        }

        snapshot.sessionState.statusMessage = "Selected \(displayName(for: interface))."
    }

    func startLiveCapture() async {
        guard let interface = snapshot.sessionState.selectedInterface else {
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = PacketryCoreError(
                code: .unsupportedInterface,
                message: "Select an interface before starting live capture."
            )
            snapshot.sessionState.statusMessage = snapshot.sessionState.lastError?.message ?? "No interface selected."
            return
        }

        do {
            let validatedOptions = try services.core.validateCaptureOptions(snapshot.sessionState.options, for: interface)
            snapshot.sessionState.options = validatedOptions

            if liveSession == nil || liveSessionConfiguration != LiveSessionConfiguration(interfaceID: interface.id, options: validatedOptions) {
                try await resetLiveSession()
                let session = try await services.core.makeLiveCaptureSession(interfaceID: interface.id, options: validatedOptions)
                liveSession = session
                liveSessionConfiguration = LiveSessionConfiguration(interfaceID: interface.id, options: validatedOptions)
                observeLiveSessionEvents(session)
            }

            releaseDocumentContext(resetState: true)

            snapshot.selectedPacketID = nil
            snapshot.packetIngestState.reset(
                source: .live,
                message: "Starting live capture on \(displayName(for: interface))..."
            )
            snapshot.sessionState.phase = .starting
            snapshot.sessionState.health = .empty
            snapshot.sessionState.capturedPacketCount = 0
            snapshot.sessionState.lastError = nil
            snapshot.sessionState.statusMessage = "Starting live capture on \(displayName(for: interface))..."

            guard let liveSession else {
                throw PacketryCoreError(code: .liveSessionStartFailed, message: "Packetry could not create a live capture session.")
            }

            try await liveSession.start()
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .liveSessionStartFailed)
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = packetryError
            snapshot.sessionState.statusMessage = packetryError.message
        }
    }

    func pauseLiveCapture() async {
        guard let liveSession else {
            return
        }

        snapshot.sessionState.statusMessage = "Pausing live capture..."

        do {
            try await liveSession.pause()
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .liveSessionControlFailed)
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = packetryError
            snapshot.sessionState.statusMessage = packetryError.message
        }
    }

    func resumeLiveCapture() async {
        guard let liveSession else {
            return
        }

        snapshot.sessionState.statusMessage = "Resuming live capture..."

        do {
            try await liveSession.resume()
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .liveSessionControlFailed)
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = packetryError
            snapshot.sessionState.statusMessage = packetryError.message
        }
    }

    func stopLiveCapture() async {
        guard let liveSession else {
            return
        }

        snapshot.sessionState.phase = .stopping
        snapshot.sessionState.statusMessage = "Stopping live capture..."

        do {
            try await liveSession.stop()
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .liveSessionControlFailed)
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = packetryError
            snapshot.sessionState.statusMessage = packetryError.message
        }
    }

    func openDocument(at fileURL: URL) async {
        do {
            try await stopLiveCaptureIfNeeded()

            snapshot.selectedPacketID = nil
            snapshot.documentState = CaptureDocumentState(
                phase: .opening,
                fileURL: fileURL,
                format: nil,
                metadata: nil,
                packetCount: 0,
                isDirty: false,
                statusMessage: "Opening \(fileURL.lastPathComponent)...",
                lastError: nil
            )
            snapshot.packetIngestState.reset(source: .offline, message: "Opening \(fileURL.lastPathComponent)...")

            let document = try await services.core.openOfflineCaptureDocument(at: fileURL)
            releaseDocumentContext()
            self.document = document
            observeDocumentEvents(document)

            let packets = try await document.open()
            snapshot.packetIngestState.replace(
                with: packets,
                source: .offline,
                message: "Loaded \(packets.count) packets from \(fileURL.lastPathComponent)."
            )
            await refreshDocumentSnapshotFromHandle(document, phase: .loaded, message: "Loaded \(packets.count) packets from \(fileURL.lastPathComponent).")
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .offlineFileOpenFailed)
            snapshot.documentState.phase = .failed
            snapshot.documentState.lastError = packetryError
            snapshot.documentState.statusMessage = packetryError.message
        }
    }

    func reopenDocument() async {
        guard let document else {
            return
        }

        let fileName = snapshot.documentState.fileURL?.lastPathComponent ?? "capture"
        snapshot.documentState.phase = .reopening
        snapshot.documentState.statusMessage = "Reopening \(fileName)..."
        snapshot.packetIngestState.reset(source: .offline, message: "Reopening \(fileName)...")

        do {
            let packets = try await document.reopen()
            snapshot.packetIngestState.replace(
                with: packets,
                source: .offline,
                message: "Reloaded \(packets.count) packets from \(fileName)."
            )
            await refreshDocumentSnapshotFromHandle(document, phase: .loaded, message: "Reloaded \(packets.count) packets from \(fileName).")
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .offlineFileOpenFailed)
            snapshot.documentState.phase = .failed
            snapshot.documentState.lastError = packetryError
            snapshot.documentState.statusMessage = packetryError.message
        }
    }

    func saveDocument() async {
        guard let document else {
            return
        }

        snapshot.documentState.phase = .saving
        snapshot.documentState.statusMessage = "Saving \(snapshot.documentState.fileURL?.lastPathComponent ?? "capture")..."

        do {
            try await document.save()
            await refreshDocumentSnapshotFromHandle(
                document,
                phase: .saved,
                message: "Saved \(snapshot.documentState.fileURL?.lastPathComponent ?? "capture")."
            )
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .offlineFileSaveFailed)
            snapshot.documentState.phase = .failed
            snapshot.documentState.lastError = packetryError
            snapshot.documentState.statusMessage = packetryError.message
        }
    }

    func saveDocument(to url: URL, format: CaptureFileFormat) async {
        guard let document else {
            return
        }

        snapshot.documentState.phase = .saving
        snapshot.documentState.statusMessage = "Saving as \(url.lastPathComponent)..."

        do {
            try await document.save(to: url, format: format)
            await refreshDocumentSnapshotFromHandle(
                document,
                phase: .saved,
                message: "Saved as \(url.lastPathComponent)."
            )
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .offlineFileSaveFailed)
            snapshot.documentState.phase = .failed
            snapshot.documentState.lastError = packetryError
            snapshot.documentState.statusMessage = packetryError.message
        }
    }

    func presentOpenCapturePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Capture File"
        panel.message = "Choose a pcap or pcapng file to inspect."
        panel.allowedContentTypes = [
            UTType(filenameExtension: "pcap"),
            UTType(filenameExtension: "pcapng"),
        ].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            await openDocument(at: url)
        }
    }

    func presentSaveCapturePanel(format: CaptureFileFormat) {
        guard snapshot.documentState.canSaveAs else {
            return
        }

        let panel = NSSavePanel()
        let currentURL = snapshot.documentState.fileURL
        let suggestedBaseName = currentURL?.deletingPathExtension().lastPathComponent ?? "capture"
        panel.title = "Save Capture As"
        panel.nameFieldStringValue = "\(suggestedBaseName).\(format.rawValue)"
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue)].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            await saveDocument(to: url, format: format)
        }
    }

    func selectPacket(_ identifier: PacketSummary.ID?) {
        snapshot.selectedPacketID = identifier
    }

    func cancelBackgroundWork() {
        liveEventsTask?.cancel()
        liveEventsTask = nil
        documentEventsTask?.cancel()
        documentEventsTask = nil

        Task {
            await backgroundCoordinator.cancelAll()
        }

        snapshot.sessionState.statusMessage = "Cancelled background work."
        snapshot.documentState.statusMessage = "Cancelled background work."
    }

    private func applyInterfaceInventory(_ interfaces: [CaptureInterfaceSummary], previousSelectionID: String?) {
        snapshot.sessionState.interfaceInventory = interfaces
        snapshot.sessionState.lastError = nil

        let selectableInterfaces = interfaces.filter(\.isSelectable)
        let isActiveCapture = snapshot.sessionState.canStop || snapshot.sessionState.canResume

        if let previousSelectionID,
           let previousInterface = interfaces.first(where: { $0.id == previousSelectionID }),
           previousInterface.isSelectable || isActiveCapture {
            snapshot.sessionState.selectedInterfaceID = previousSelectionID
            snapshot.sessionState.options = validatedOptions(
                snapshot.sessionState.options,
                for: previousInterface
            )
            snapshot.sessionState.statusMessage = "Refreshed \(interfaces.count) interfaces. Keeping \(displayName(for: previousInterface))."
        } else if previousSelectionID != nil {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = CaptureOptions.defaults()
            snapshot.sessionState.statusMessage = "The previously selected interface is no longer available. Choose another interface before starting capture."
        } else if snapshot.sessionState.selectedInterfaceID == nil, let firstSelectable = selectableInterfaces.first {
            snapshot.sessionState.selectedInterfaceID = firstSelectable.id
            snapshot.sessionState.options = validatedOptions(
                CaptureOptions.defaults(for: firstSelectable),
                for: firstSelectable
            )
            snapshot.sessionState.statusMessage = "Discovered \(interfaces.count) interfaces. Selected \(displayName(for: firstSelectable))."
        } else if let selectedInterface = snapshot.sessionState.selectedInterface {
            snapshot.sessionState.options = validatedOptions(snapshot.sessionState.options, for: selectedInterface)
            snapshot.sessionState.statusMessage = "Refreshed \(interfaces.count) interfaces."
        } else {
            snapshot.sessionState.statusMessage = selectableInterfaces.isEmpty
                ? "No currently eligible capture interfaces were found."
                : "Discovered \(interfaces.count) interfaces."
        }

        if selectableInterfaces.isEmpty {
            snapshot.accessState = .blocked(.noEligibleInterfaces)
            if !isActiveCapture {
                snapshot.sessionState.phase = .idle
            }
        } else {
            snapshot.accessState = .ready
            if !isActiveCapture {
                snapshot.sessionState.phase = .ready
            }
        }
    }

    private func validatedOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) -> CaptureOptions {
        (try? services.core.validateCaptureOptions(options, for: interface)) ?? CaptureOptions.defaults(for: interface)
    }

    private func observeLiveSessionEvents(_ session: any LiveCaptureSessionProviding) {
        liveEventsTask?.cancel()

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await event in session.events() {
                    await MainActor.run {
                        self.applyPacketIngestEvent(event)
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self.handleStreamFailure(error, context: .live)
                }
            }
        }

        liveEventsTask = task

        Task {
            await backgroundCoordinator.replaceOperation("live-events", with: task)
        }
    }

    private func observeDocumentEvents(_ document: any OfflineCaptureDocumentProviding) {
        documentEventsTask?.cancel()

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await event in document.events() {
                    await MainActor.run {
                        self.applyPacketIngestEvent(event)
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self.handleStreamFailure(error, context: .document)
                }
            }
        }

        documentEventsTask = task

        Task {
            await backgroundCoordinator.replaceOperation("document-events", with: task)
        }
    }

    private func applyPacketIngestEvent(_ event: PacketIngestEvent) {
        switch event {
        case .liveStateChanged(let phase, let message):
            snapshot.sessionState.phase = mappedPhase(phase)
            snapshot.sessionState.statusMessage = message
            if mappedPhase(phase) != .failed {
                snapshot.sessionState.lastError = nil
            }
        case .documentStateChanged(let phase, let message):
            snapshot.documentState.phase = mappedPhase(phase)
            snapshot.documentState.statusMessage = message
            if mappedPhase(phase) != .failed {
                snapshot.documentState.lastError = nil
            }
        case .packetBatch(let packets):
            guard let firstPacket = packets.first else {
                return
            }

            switch firstPacket.source {
            case .live:
                snapshot.packetIngestState.append(
                    packets,
                    source: .live,
                    message: "Captured \(snapshot.packetIngestState.totalPacketCount + packets.count) packets."
                )
                snapshot.sessionState.capturedPacketCount = snapshot.packetIngestState.totalPacketCount
            case .offline:
                snapshot.packetIngestState.replace(
                    with: packets,
                    source: .offline,
                    message: "Loaded \(packets.count) packets from disk."
                )
                snapshot.documentState.packetCount = packets.count
            @unknown default:
                break
            }
        case .healthChanged(let health):
            snapshot.sessionState.health = health
        case .documentMetadataChanged(let metadata):
            snapshot.documentState.metadata = metadata
            snapshot.documentState.format = metadata.format
        @unknown default:
            break
        }
    }

    private func handleStreamFailure(_ error: Error, context: StreamContext) {
        let defaultCode: PacketryCoreError.Code = context == .live ? .liveSessionControlFailed : .offlineFileOpenFailed
        let packetryError = packetryError(from: error, defaultCode: defaultCode)

        switch context {
        case .live:
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = packetryError
            snapshot.sessionState.statusMessage = packetryError.message
        case .document:
            snapshot.documentState.phase = .failed
            snapshot.documentState.lastError = packetryError
            snapshot.documentState.statusMessage = packetryError.message
        }
    }

    private func refreshDocumentSnapshotFromHandle(
        _ document: any OfflineCaptureDocumentProviding,
        phase: CaptureDocumentState.Phase,
        message: String
    ) async {
        let url = await document.currentURL()
        let metadata = await document.currentMetadata()
        let packets = await document.packetSummaries()

        snapshot.documentState.phase = phase
        snapshot.documentState.fileURL = url
        snapshot.documentState.metadata = metadata
        snapshot.documentState.format = metadata.format
        snapshot.documentState.packetCount = packets.count
        snapshot.documentState.isDirty = false
        snapshot.documentState.lastError = nil
        snapshot.documentState.statusMessage = message
    }

    private func stopLiveCaptureIfNeeded() async throws {
        guard let liveSession, snapshot.sessionState.canStop else {
            releaseLiveSession()
            return
        }

        do {
            try await liveSession.stop()
        } catch {
            throw packetryError(from: error, defaultCode: .liveSessionControlFailed)
        }

        releaseLiveSession()
        snapshot.sessionState.phase = snapshot.accessState.isCaptureReady ? .ready : .idle
        snapshot.sessionState.health = .empty
    }

    private func resetLiveSession() async throws {
        if let liveSession, snapshot.sessionState.canStop {
            try await liveSession.stop()
        }

        releaseLiveSession()
    }

    private func releaseLiveSession() {
        liveEventsTask?.cancel()
        liveEventsTask = nil
        liveSession = nil
        liveSessionConfiguration = nil

        Task {
            await backgroundCoordinator.endOperation("live-events")
        }
    }

    private func releaseDocumentContext(resetState: Bool = false) {
        documentEventsTask?.cancel()
        documentEventsTask = nil
        document = nil

        Task {
            await backgroundCoordinator.endOperation("document-events")
        }

        if resetState {
            snapshot.documentState = .idle
        }
    }

    private func mappedPhase(_ phase: LiveCaptureSessionPhase) -> CaptureSessionState.Phase {
        switch phase {
        case .ready:
            .ready
        case .starting:
            .starting
        case .running:
            .running
        case .paused:
            .paused
        case .stopping:
            .stopping
        case .stopped:
            .stopped
        case .failed:
            .failed
        @unknown default:
            .failed
        }
    }

    private func mappedPhase(_ phase: OfflineCaptureDocumentPhase) -> CaptureDocumentState.Phase {
        switch phase {
        case .opening:
            .opening
        case .loaded:
            .loaded
        case .saving:
            .saving
        case .saved:
            .saved
        case .reopening:
            .reopening
        case .failed:
            .failed
        @unknown default:
            .failed
        }
    }

    private func packetryError(from error: Error, defaultCode: PacketryCoreError.Code) -> PacketryCoreError {
        if let packetryError = error as? PacketryCoreError {
            return packetryError
        }

        return PacketryCoreError(code: defaultCode, message: error.localizedDescription)
    }

    private func displayName(for interface: CaptureInterfaceSummary) -> String {
        interface.friendlyName ?? interface.displayName
    }
}

private struct LiveSessionConfiguration: Equatable {
    let interfaceID: String
    let options: CaptureOptions
}

private enum StreamContext {
    case live
    case document
}
