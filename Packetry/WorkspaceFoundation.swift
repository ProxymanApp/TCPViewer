import AppKit
import Combine
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

struct PacketIngestState: Sendable, Equatable {
    var source: CaptureSource?
    var packets: [PacketSummary]
    var packetRevision: UInt64
    var lastBatchCount: Int
    var truncatedPacketCount: Int
    var decodeIssueCount: Int
    var statusMessage: String

    static let empty = PacketIngestState(
        source: nil,
        packets: [],
        packetRevision: 0,
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
        packetRevision &+= 1
        lastBatchCount = 0
        truncatedPacketCount = 0
        decodeIssueCount = 0
        statusMessage = message
    }

    mutating func replace(with batch: [PacketSummary], source: CaptureSource, message: String? = nil) {
        self.source = source
        packets = batch
        packetRevision &+= 1
        lastBatchCount = batch.count
        recalculateCounters()
        if let message {
            statusMessage = message
        }
    }

    mutating func append(_ batch: [PacketSummary], source: CaptureSource, message: String? = nil) {
        self.source = source
        packets.append(contentsOf: batch)
        if !batch.isEmpty {
            packetRevision &+= 1
        }
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
    var isPartialResult: Bool
    var statusMessage: String
    var lastError: PacketryCoreError?

    static let idle = CaptureDocumentState(
        phase: .idle,
        fileURL: nil,
        format: nil,
        metadata: nil,
        packetCount: 0,
        isDirty: false,
        isPartialResult: false,
        statusMessage: "Open a capture file to inspect packets offline.",
        lastError: nil
    )

    var canReopen: Bool {
        fileURL != nil && phase != .opening && phase != .reopening && phase != .saving
    }

    var canSave: Bool {
        fileURL != nil && packetCount > 0 && phase != .opening && phase != .reopening && phase != .saving && !isPartialResult
    }

    var canSaveAs: Bool {
        packetCount > 0 && phase != .opening && phase != .reopening && phase != .saving && !isPartialResult
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
    var filterState: PacketFilterState
    var inspectionState: PacketInspectionState
    var navigationState: PacketNavigationState
    var loadState: PacketLoadState

    static let foundation = PacketryWindowSnapshot(
        accessState: .unknown,
        documentState: .idle,
        sessionState: .idle,
        packetIngestState: .empty,
        filterState: .empty,
        inspectionState: .empty,
        navigationState: .empty,
        loadState: .idle
    )

    var selectedPacketID: PacketSummary.ID? {
        get { inspectionState.selectedPacketID }
        set { inspectionState.selectedPacketID = newValue }
    }
}

struct PacketFilterState: Sendable, Equatable {
    var captureFilterText: String
    var validation: CaptureFilterValidation
    var recentCaptureFilters: [String]
    var isValidating: Bool
    var statusMessage: String

    static let empty = PacketFilterState(
        captureFilterText: "",
        validation: CaptureFilterValidation(disposition: .unavailable, normalizedExpression: nil, message: nil),
        recentCaptureFilters: [],
        isValidating: false,
        statusMessage: "Capture filter is optional."
    )

    var normalizedCaptureFilter: String? {
        let trimmed = captureFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedExpression = validation.normalizedExpression, !normalizedExpression.isEmpty {
            return normalizedExpression
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasValidationError: Bool {
        validation.disposition == .invalid
    }
}

struct PacketInspectionState: Sendable, Equatable {
    var selectedPacketID: PacketSummary.ID?
    var inspection: PacketInspection?
    var selectedDetailNodeID: String?
    var highlightedByteRange: PacketByteRange?
    var isLoading: Bool
    var statusMessage: String

    static let empty = PacketInspectionState(
        selectedPacketID: nil,
        inspection: nil,
        selectedDetailNodeID: nil,
        highlightedByteRange: nil,
        isLoading: false,
        statusMessage: "Select a packet to inspect its decode tree and bytes."
    )
}

struct PacketNavigationState: Sendable, Equatable {
    var visiblePackets: [PacketSummary]
    var jumpText: String
    var jumpErrorMessage: String?
    var statusMessage: String

    static let empty = PacketNavigationState(
        visiblePackets: [],
        jumpText: "",
        jumpErrorMessage: nil,
        statusMessage: "No packets available."
    )
}

struct PacketLoadState: Sendable, Equatable {
    var progress: PacketLoadProgress

    static let idle = PacketLoadState(progress: .idle)

    var canCancel: Bool {
        progress.phase == .loading
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

private struct PacketryPreferences {
    private enum Key {
        static let captureFilterText = "Packetry.captureFilterText"
        static let recentCaptureFilters = "Packetry.recentCaptureFilters"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var captureFilterText: String {
        defaults.string(forKey: Key.captureFilterText) ?? ""
    }

    var recentCaptureFilters: [String] {
        defaults.stringArray(forKey: Key.recentCaptureFilters) ?? []
    }

    func persistCaptureFilter(_ value: String?) {
        defaults.set(value ?? "", forKey: Key.captureFilterText)
    }

    func persistRecentCaptureFilters(_ values: [String]) {
        defaults.set(values, forKey: Key.recentCaptureFilters)
    }
}

@MainActor
private final class PacketryWindowControllerRegistry {
    static let shared = PacketryWindowControllerRegistry()

    private var controllers: [WeakPacketryWindowController] = []

    func register(_ controller: PacketryWindowController) {
        pruneReleasedControllers()
        guard !controllers.contains(where: { $0.controller === controller }) else {
            return
        }

        controllers.append(WeakPacketryWindowController(controller))
    }

    func prepareForApplicationTermination() async -> Bool {
        pruneReleasedControllers()
        let activeControllers = controllers.compactMap(\.controller)
        var shouldTerminate = true

        for controller in activeControllers {
            let didPrepare = await controller.prepareForApplicationTermination()
            shouldTerminate = shouldTerminate && didPrepare
        }

        pruneReleasedControllers()
        return shouldTerminate
    }

    private func pruneReleasedControllers() {
        controllers.removeAll { $0.controller == nil }
    }
}

private final class WeakPacketryWindowController {
    weak var controller: PacketryWindowController?

    init(_ controller: PacketryWindowController) {
        self.controller = controller
    }
}

@MainActor
final class PacketryWindowController: ObservableObject {
    @Published private(set) var snapshot: PacketryWindowSnapshot

    let services: PacketryServiceRegistry
    private let backgroundCoordinator: PacketryBackgroundCoordinator
    private let preferences: PacketryPreferences

    private var hasPerformedInitialLoad = false
    private var liveSession: (any LiveCaptureSessionProviding)?
    private var liveSessionConfiguration: LiveSessionConfiguration?
    private var liveEventsTask: Task<Void, Never>?
    private var document: (any OfflineCaptureDocumentProviding)?
    private var documentEventsTask: Task<Void, Never>?
    private var documentEventGeneration = 0
    private var inspectionTask: Task<Void, Never>?
    private var filterValidationTask: Task<Void, Never>?

    init(
        services: PacketryServiceRegistry? = nil,
        backgroundCoordinator: PacketryBackgroundCoordinator = PacketryBackgroundCoordinator(),
        snapshot: PacketryWindowSnapshot? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.services = services ?? .foundation
        self.backgroundCoordinator = backgroundCoordinator
        self.preferences = PacketryPreferences(defaults: userDefaults)
        var resolvedSnapshot = snapshot ?? .foundation
        resolvedSnapshot.filterState.captureFilterText = preferences.captureFilterText
        resolvedSnapshot.filterState.recentCaptureFilters = preferences.recentCaptureFilters
        self.snapshot = resolvedSnapshot
        PacketryWindowControllerRegistry.shared.register(self)
    }

    deinit {
        liveEventsTask?.cancel()
        documentEventsTask?.cancel()
        inspectionTask?.cancel()
        filterValidationTask?.cancel()
    }

    static func prepareAllForApplicationTermination() async -> Bool {
        await PacketryWindowControllerRegistry.shared.prepareForApplicationTermination()
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
            snapshot.sessionState.options = options(for: nil)
            snapshot.sessionState.statusMessage = "Cleared interface selection."
            snapshot.sessionState.lastError = nil
            return
        }

        guard let interface = snapshot.sessionState.interfaceInventory.first(where: { $0.id == identifier }) else {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = options(for: nil)
            snapshot.sessionState.statusMessage = "The selected interface is no longer present."
            snapshot.sessionState.lastError = PacketryCoreError(
                code: .unsupportedInterface,
                message: "The selected interface is no longer present."
            )
            return
        }

        guard interface.isSelectable else {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = options(for: nil)
            snapshot.sessionState.statusMessage = interface.availabilityReason ?? "This interface is not currently available for capture."
            snapshot.sessionState.lastError = PacketryCoreError(
                code: .unsupportedInterface,
                message: snapshot.sessionState.statusMessage
            )
            return
        }

        snapshot.sessionState.selectedInterfaceID = interface.id
        snapshot.sessionState.options = options(for: interface)
        snapshot.sessionState.lastError = nil

        if snapshot.sessionState.phase == .idle || snapshot.sessionState.phase == .failed || snapshot.sessionState.phase == .stopped {
            snapshot.sessionState.phase = .ready
        }

        snapshot.sessionState.statusMessage = "Selected \(displayName(for: interface))."
    }

    func updateCaptureFilterText(_ text: String) {
        snapshot.filterState.captureFilterText = text
        snapshot.filterState.statusMessage = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Capture filter is optional."
            : "Capture filter will be validated before live capture starts."
        snapshot.filterState.validation = CaptureFilterValidation(
            disposition: .unavailable,
            normalizedExpression: text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            message: nil
        )
        preferences.persistCaptureFilter(text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    }

    func applyRecentCaptureFilter(_ value: String) {
        updateCaptureFilterText(value)
    }

    func validateCaptureFilter() async {
        let trimmedFilter = snapshot.filterState.captureFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty else {
            snapshot.filterState.validation = CaptureFilterValidation(
                disposition: .unavailable,
                normalizedExpression: nil,
                message: nil
            )
            snapshot.filterState.isValidating = false
            snapshot.filterState.statusMessage = "Capture filter is optional."
            return
        }

        filterValidationTask?.cancel()
        snapshot.filterState.isValidating = true
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            let validation = await self.services.core.validateCaptureFilter(trimmedFilter)
            await MainActor.run {
                self.snapshot.filterState.isValidating = false
                self.snapshot.filterState.validation = validation
                self.snapshot.filterState.statusMessage = validation.message ?? "Capture filter is ready."
                if validation.disposition == .valid {
                    let normalizedExpression = validation.normalizedExpression ?? trimmedFilter
                    self.snapshot.filterState.captureFilterText = normalizedExpression
                    self.persistCaptureFilter(normalizedExpression)
                }
            }
        }

        filterValidationTask = task
        await task.value
    }

    func updateJumpText(_ text: String) {
        snapshot.navigationState.jumpText = text
        snapshot.navigationState.jumpErrorMessage = nil
    }

    func jumpToPacketNumber() {
        let trimmedValue = snapshot.navigationState.jumpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let packetNumber = UInt64(trimmedValue) else {
            snapshot.navigationState.jumpErrorMessage = "Enter a valid packet number."
            return
        }

        guard let packet = snapshot.navigationState.visiblePackets.first(where: { $0.packetNumber == packetNumber }) else {
            snapshot.navigationState.jumpErrorMessage = "Packet \(packetNumber) is not visible right now."
            return
        }

        snapshot.navigationState.jumpErrorMessage = nil
        selectPacket(packet.id)
    }

    func selectPreviousPacket() {
        guard let currentIndex = selectedVisiblePacketIndex(), currentIndex > 0 else {
            return
        }

        selectPacket(snapshot.navigationState.visiblePackets[currentIndex - 1].id)
    }

    func selectNextPacket() {
        guard let currentIndex = selectedVisiblePacketIndex(),
              currentIndex < snapshot.navigationState.visiblePackets.count - 1 else {
            return
        }

        selectPacket(snapshot.navigationState.visiblePackets[currentIndex + 1].id)
    }

    func selectDetailNode(_ identifier: String?) {
        snapshot.inspectionState.selectedDetailNodeID = identifier
        snapshot.inspectionState.highlightedByteRange = detailNode(with: identifier)?.byteRange
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
            await validateCaptureFilter()
            if snapshot.filterState.hasValidationError {
                let message = snapshot.filterState.validation.message ?? "Packetry could not compile this capture filter."
                snapshot.sessionState.lastError = PacketryCoreError(code: .invalidCaptureFilter, message: message)
                snapshot.sessionState.statusMessage = message
                snapshot.sessionState.phase = .ready
                return
            }

            let configuredOptions = options(for: interface)
            let validatedOptions = try services.core.validateCaptureOptions(configuredOptions, for: interface)
            snapshot.sessionState.options = validatedOptions
            persistCaptureFilter(validatedOptions.captureFilterExpression)

            if liveSession == nil || liveSessionConfiguration != LiveSessionConfiguration(interfaceID: interface.id, options: validatedOptions) {
                try await resetLiveSession()
                let session = try await services.core.makeLiveCaptureSession(interfaceID: interface.id, options: validatedOptions)
                liveSession = session
                liveSessionConfiguration = LiveSessionConfiguration(interfaceID: interface.id, options: validatedOptions)
                observeLiveSessionEvents(session)
            }

            releaseDocumentContext(resetState: true)
            resetInspectionState()
            snapshot.loadState = .idle

            snapshot.selectedPacketID = nil
            snapshot.packetIngestState.reset(
                source: .live,
                message: "Starting live capture on \(displayName(for: interface))..."
            )
            synchronizeVisiblePackets(message: "Waiting for live packets…")
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
            releaseDocumentContext()

            resetInspectionState()
            snapshot.selectedPacketID = nil
            snapshot.documentState = CaptureDocumentState(
                phase: .opening,
                fileURL: fileURL,
                format: nil,
                metadata: nil,
                packetCount: 0,
                isDirty: false,
                isPartialResult: false,
                statusMessage: "Opening \(fileURL.lastPathComponent)...",
                lastError: nil
            )
            snapshot.packetIngestState.reset(source: .offline, message: "Opening \(fileURL.lastPathComponent)...")
            synchronizeVisiblePackets(message: "Opening \(fileURL.lastPathComponent)...")
            snapshot.loadState.progress = PacketLoadProgress(
                phase: .loading,
                loadedPacketCount: 0,
                message: "Opening \(fileURL.lastPathComponent)..."
            )

            let document = try await services.core.openOfflineCaptureDocument(at: fileURL)
            self.document = document
            observeDocumentEvents(document)

            _ = try await document.open()
            await refreshDocumentSnapshotFromHandle(
                document,
                phase: .loaded,
                message: "Loaded \(snapshot.packetIngestState.totalPacketCount) packets from \(fileURL.lastPathComponent)."
            )
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .offlineFileOpenFailed)
            if packetryError.code == .operationCancelled {
                if let document {
                    await refreshDocumentSnapshotFromHandle(
                        document,
                        phase: .loaded,
                        message: packetryError.message
                    )
                } else {
                    snapshot.documentState.phase = .loaded
                    snapshot.documentState.isPartialResult = true
                    snapshot.documentState.statusMessage = snapshot.loadState.progress.message
                    snapshot.documentState.lastError = nil
                }
            } else {
                snapshot.documentState.phase = .failed
                snapshot.documentState.lastError = packetryError
                snapshot.documentState.statusMessage = packetryError.message
            }
        }
    }

    func reopenDocument() async {
        guard let document else {
            return
        }

        let fileName = snapshot.documentState.fileURL?.lastPathComponent ?? "capture"
        snapshot.documentState.phase = .reopening
        snapshot.documentState.statusMessage = "Reopening \(fileName)..."
        snapshot.documentState.isPartialResult = false
        snapshot.packetIngestState.reset(source: .offline, message: "Reopening \(fileName)...")
        synchronizeVisiblePackets(message: "Reopening \(fileName)...")
        resetInspectionState()
        snapshot.loadState.progress = PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "Reopening \(fileName)..."
        )

        do {
            _ = try await document.reopen()
            await refreshDocumentSnapshotFromHandle(
                document,
                phase: .loaded,
                message: "Reloaded \(snapshot.packetIngestState.totalPacketCount) packets from \(fileName)."
            )
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .offlineFileOpenFailed)
            if packetryError.code == .operationCancelled {
                await refreshDocumentSnapshotFromHandle(
                    document,
                    phase: .loaded,
                    message: packetryError.message
                )
            } else {
                snapshot.documentState.phase = .failed
                snapshot.documentState.lastError = packetryError
                snapshot.documentState.statusMessage = packetryError.message
            }
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

    func cancelDocumentLoading() async {
        guard let document else {
            return
        }

        await document.cancelLoading()
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
        snapshot.inspectionState.selectedDetailNodeID = nil
        snapshot.inspectionState.highlightedByteRange = nil
        snapshot.navigationState.jumpErrorMessage = nil
        scheduleInspection(for: identifier)
    }

    func cancelBackgroundWork() {
        cancelControllerTasks()

        let currentDocument = document
        Task {
            await backgroundCoordinator.cancelAll()
            await currentDocument?.cancelLoading()
        }

        snapshot.sessionState.statusMessage = "Cancelled background work."
        snapshot.documentState.statusMessage = "Cancelled background work."
    }

    func prepareForApplicationTermination() async -> Bool {
        do {
            try await stopRetainedLiveSessionIfNeeded()
        } catch {
            let packetryError = packetryError(from: error, defaultCode: .liveSessionControlFailed)
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = packetryError
            snapshot.sessionState.statusMessage = packetryError.message
            return false
        }

        releaseLiveSession()
        await cancelBackgroundWorkForTermination()
        return true
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
            snapshot.sessionState.options = options(for: previousInterface)
            snapshot.sessionState.statusMessage = "Refreshed \(interfaces.count) interfaces. Keeping \(displayName(for: previousInterface))."
        } else if previousSelectionID != nil {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = options(for: nil)
            snapshot.sessionState.statusMessage = "The previously selected interface is no longer available. Choose another interface before starting capture."
        } else if snapshot.sessionState.selectedInterfaceID == nil, let firstSelectable = selectableInterfaces.first {
            snapshot.sessionState.selectedInterfaceID = firstSelectable.id
            snapshot.sessionState.options = options(for: firstSelectable)
            snapshot.sessionState.statusMessage = "Discovered \(interfaces.count) interfaces. Selected \(displayName(for: firstSelectable))."
        } else if let selectedInterface = snapshot.sessionState.selectedInterface {
            snapshot.sessionState.options = options(for: selectedInterface)
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

    private func options(for interface: CaptureInterfaceSummary?) -> CaptureOptions {
        let baseOptions = validatedOptions(
            CaptureOptions.defaults(for: interface),
            for: interface
        )
        let configuredOptions = CaptureOptions(
            promiscuousMode: baseOptions.promiscuousMode,
            snapshotLength: baseOptions.snapshotLength,
            kernelBufferSizeBytes: baseOptions.kernelBufferSizeBytes,
            readTimeoutMilliseconds: baseOptions.readTimeoutMilliseconds,
            captureFilterExpression: snapshot.filterState.normalizedCaptureFilter,
            stopCondition: baseOptions.stopCondition,
            fileWriting: baseOptions.fileWriting
        )
        return validatedOptions(configuredOptions, for: interface)
    }

    private func persistCaptureFilter(_ value: String?) {
        let normalizedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        preferences.persistCaptureFilter(normalizedValue)

        guard let normalizedValue else {
            snapshot.filterState.recentCaptureFilters = preferences.recentCaptureFilters
            return
        }

        let updatedRecents = ([normalizedValue] + snapshot.filterState.recentCaptureFilters)
            .removingDuplicates()
            .prefix(8)
        let recents = Array(updatedRecents)
        snapshot.filterState.recentCaptureFilters = recents
        preferences.persistRecentCaptureFilters(recents)
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
        documentEventGeneration += 1
        let generation = documentEventGeneration

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await event in document.events() {
                    await MainActor.run {
                        guard self.documentEventGeneration == generation else {
                            return
                        }
                        self.applyPacketIngestEvent(event)
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard self.documentEventGeneration == generation else {
                        return
                    }
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
        case .packetBatch(let packets, let disposition):
            let source = packets.first?.source ?? snapshot.packetIngestState.source
            let isOfflineStreaming = snapshot.documentState.phase == .opening || snapshot.documentState.phase == .reopening

            if source == .offline && !isOfflineStreaming {
                return
            }

            switch disposition {
            case .replace:
                snapshot.packetIngestState.reset(
                    source: source,
                    message: source == .live ? "Waiting for live packets…" : "Loading packets from disk…"
                )
                if let source, !packets.isEmpty {
                    snapshot.packetIngestState.replace(
                        with: packets,
                        source: source,
                        message: source == .live
                            ? "Captured \(packets.count) packets."
                            : "Loaded \(packets.count) packets from disk."
                    )
                }
            case .append:
                if let source {
                    snapshot.packetIngestState.append(
                        packets,
                        source: source,
                        message: source == .live
                            ? "Captured \(snapshot.packetIngestState.totalPacketCount + packets.count) packets."
                            : "Loaded \(snapshot.packetIngestState.totalPacketCount + packets.count) packets from disk."
                    )
                }
            @unknown default:
                if let source {
                    snapshot.packetIngestState.append(packets, source: source)
                }
            }

            if let source {
                switch source {
                case .live:
                    snapshot.sessionState.capturedPacketCount = snapshot.packetIngestState.totalPacketCount
                    synchronizeVisiblePackets(message: "Showing \(snapshot.packetIngestState.totalPacketCount) captured packets.")
                case .offline:
                    snapshot.documentState.packetCount = snapshot.packetIngestState.totalPacketCount
                    synchronizeVisiblePackets(message: "Showing \(snapshot.packetIngestState.totalPacketCount) packets from disk.")
                @unknown default:
                    synchronizeVisiblePackets(message: "Showing \(snapshot.packetIngestState.totalPacketCount) packets.")
                }
            } else {
                synchronizeVisiblePackets(message: "No packets available.")
            }
        case .loadProgressChanged(let progress):
            guard snapshot.documentState.phase == .opening || snapshot.documentState.phase == .reopening else {
                return
            }
            snapshot.loadState.progress = progress
            snapshot.documentState.isPartialResult = progress.isPartialResult
            snapshot.documentState.packetCount = max(snapshot.documentState.packetCount, progress.loadedPacketCount)
            if progress.phase == .loading || progress.phase == .cancelled {
                snapshot.documentState.statusMessage = progress.message
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
            if packetryError.code == .operationCancelled {
                snapshot.documentState.phase = .loaded
                snapshot.documentState.isPartialResult = true
                snapshot.documentState.statusMessage = snapshot.loadState.progress.message
                snapshot.documentState.lastError = nil
            } else {
                snapshot.documentState.phase = .failed
                snapshot.documentState.lastError = packetryError
                snapshot.documentState.statusMessage = packetryError.message
            }
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
        let progress = await document.loadProgress()
        let resolvedMessage = progress.message.isEmpty ? message : progress.message

        snapshot.loadState.progress = progress
        if packets.isEmpty {
            snapshot.packetIngestState.reset(source: .offline, message: resolvedMessage)
        } else {
            snapshot.packetIngestState.replace(with: packets, source: .offline, message: resolvedMessage)
        }

        snapshot.documentState.phase = phase
        snapshot.documentState.fileURL = url
        snapshot.documentState.metadata = metadata
        snapshot.documentState.format = metadata.format
        snapshot.documentState.packetCount = packets.count
        snapshot.documentState.isDirty = false
        snapshot.documentState.isPartialResult = progress.isPartialResult
        snapshot.documentState.lastError = nil
        snapshot.documentState.statusMessage = resolvedMessage
        synchronizeVisiblePackets(message: "Showing \(packets.count) packets.")
    }

    private func stopLiveCaptureIfNeeded() async throws {
        try await stopRetainedLiveSessionIfNeeded()
        releaseLiveSession()
        snapshot.sessionState.phase = snapshot.accessState.isCaptureReady ? .ready : .idle
        snapshot.sessionState.health = .empty
        snapshot.loadState = .idle
    }

    private func resetLiveSession() async throws {
        try await stopRetainedLiveSessionIfNeeded()
        releaseLiveSession()
    }

    private func stopRetainedLiveSessionIfNeeded() async throws {
        guard let liveSession, snapshot.sessionState.phase != .stopped else {
            return
        }

        do {
            try await liveSession.stop()
        } catch {
            throw packetryError(from: error, defaultCode: .liveSessionControlFailed)
        }
    }

    private func releaseLiveSession() {
        liveEventsTask?.cancel()
        liveEventsTask = nil
        inspectionTask?.cancel()
        inspectionTask = nil
        liveSession = nil
        liveSessionConfiguration = nil

        Task {
            await backgroundCoordinator.endOperation("live-events")
        }
    }

    private func cancelControllerTasks() {
        liveEventsTask?.cancel()
        liveEventsTask = nil
        documentEventsTask?.cancel()
        documentEventsTask = nil
        inspectionTask?.cancel()
        inspectionTask = nil
        filterValidationTask?.cancel()
        filterValidationTask = nil
    }

    private func cancelBackgroundWorkForTermination() async {
        cancelControllerTasks()
        let currentDocument = document
        document = nil
        await backgroundCoordinator.cancelAll()
        await currentDocument?.cancelLoading()
    }

    private func releaseDocumentContext(resetState: Bool = false) {
        let currentDocument = document
        documentEventGeneration += 1
        documentEventsTask?.cancel()
        documentEventsTask = nil
        inspectionTask?.cancel()
        inspectionTask = nil
        document = nil

        Task {
            await backgroundCoordinator.endOperation("document-events")
            await currentDocument?.cancelLoading()
        }

        if resetState {
            snapshot.documentState = .idle
            snapshot.loadState = .idle
        }
    }

    private func synchronizeVisiblePackets(message: String) {
        snapshot.navigationState.visiblePackets = snapshot.packetIngestState.packets
        snapshot.navigationState.statusMessage = message

        if let selectedPacketID = snapshot.selectedPacketID,
           !snapshot.navigationState.visiblePackets.contains(where: { $0.id == selectedPacketID }) {
            resetInspectionState()
        }
    }

    private func resetInspectionState() {
        inspectionTask?.cancel()
        inspectionTask = nil
        snapshot.inspectionState = .empty
        snapshot.selectedPacketID = nil
    }

    private func selectedVisiblePacketIndex() -> Int? {
        guard let selectedPacketID = snapshot.selectedPacketID else {
            return nil
        }

        return snapshot.navigationState.visiblePackets.firstIndex(where: { $0.id == selectedPacketID })
    }

    private func scheduleInspection(for identifier: PacketSummary.ID?) {
        inspectionTask?.cancel()
        inspectionTask = nil

        guard let identifier else {
            snapshot.inspectionState = .empty
            return
        }

        snapshot.inspectionState.selectedPacketID = identifier
        snapshot.inspectionState.inspection = nil
        snapshot.inspectionState.selectedDetailNodeID = nil
        snapshot.inspectionState.highlightedByteRange = nil
        snapshot.inspectionState.isLoading = true
        snapshot.inspectionState.statusMessage = "Inspecting packet \(identifier)..."

        let liveSession = self.liveSession
        let document = self.document
        let visiblePackets = snapshot.navigationState.visiblePackets

        let task = Task { [weak self] in
            guard let self,
                  let packet = visiblePackets.first(where: { $0.id == identifier }) else {
                return
            }

            do {
                let inspection: PacketInspection
                switch packet.source {
                case .live:
                    guard let liveSession else {
                        return
                    }
                    inspection = try await liveSession.inspectPacket(id: identifier)
                case .offline:
                    guard let document else {
                        return
                    }
                    inspection = try await document.inspectPacket(id: identifier)
                @unknown default:
                    return
                }

                await MainActor.run {
                    guard self.snapshot.selectedPacketID == identifier else {
                        return
                    }

                    self.snapshot.inspectionState.selectedPacketID = identifier
                    self.snapshot.inspectionState.inspection = inspection
                    self.snapshot.inspectionState.isLoading = false
                    self.snapshot.inspectionState.statusMessage = "Inspecting packet \(inspection.packetNumber)."
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard self.snapshot.selectedPacketID == identifier else {
                        return
                    }

                    let packetryError = self.packetryError(from: error, defaultCode: .offlineFileOpenFailed)
                    self.snapshot.inspectionState.inspection = nil
                    self.snapshot.inspectionState.isLoading = false
                    self.snapshot.inspectionState.statusMessage = packetryError.message
                }
            }
        }

        inspectionTask = task
    }

    private func detailNode(with identifier: String?) -> PacketDetailNode? {
        guard let identifier,
              let inspection = snapshot.inspectionState.inspection else {
            return nil
        }

        return detailNode(in: inspection.detailNodes, matching: identifier)
    }

    private func detailNode(in nodes: [PacketDetailNode], matching identifier: String) -> PacketDetailNode? {
        for node in nodes {
            if node.id == identifier {
                return node
            }

            if let match = detailNode(in: node.children, matching: identifier) {
                return match
            }
        }

        return nil
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

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
