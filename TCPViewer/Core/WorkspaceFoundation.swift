//
//  WorkspaceFoundation.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore
import SystemConfiguration
import UniformTypeIdentifiers

enum PacketIngestMutation: Sendable, Equatable {
    case none
    case reset
    case replace
    case append(Range<Int>)
    case appendWithMetadataUpdates(range: Range<Int>, updatedPacketIDs: [PacketSummary.ID])
    case metadataUpdate(packetIDs: [PacketSummary.ID])
}

struct PacketIngestState: Sendable, Equatable {
    var source: CaptureSource?
    var backingIdentity: String?
    var packets: [PacketSummary]
    var packetIndexByID: [PacketSummary.ID: Int]
    var packetRevision: UInt64
    var packetLineageRevision: UInt64
    var lastMutation: PacketIngestMutation
    var lastBatchCount: Int
    var truncatedPacketCount: Int
    var decodeIssueCount: Int
    var statusMessage: String

    static let empty = PacketIngestState(
        source: nil,
        backingIdentity: nil,
        packets: [],
        packetIndexByID: [:],
        packetRevision: 0,
        packetLineageRevision: 0,
        lastMutation: .none,
        lastBatchCount: 0,
        truncatedPacketCount: 0,
        decodeIssueCount: 0,
        statusMessage: "No packets loaded yet."
    )

    var totalPacketCount: Int {
        packets.count
    }

    func packet(withID identifier: PacketSummary.ID?) -> PacketSummary? {
        guard let identifier,
              let packetIndex = packetIndexByID[identifier],
              packets.indices.contains(packetIndex) else {
            return nil
        }

        return packets[packetIndex]
    }

    mutating func reset(source: CaptureSource? = nil, message: String) {
        self.source = source
        backingIdentity = source == nil ? nil : UUID().uuidString
        packets = []
        packetIndexByID = [:]
        packetRevision &+= 1
        packetLineageRevision &+= 1
        lastMutation = .reset
        lastBatchCount = 0
        truncatedPacketCount = 0
        decodeIssueCount = 0
        statusMessage = message
    }

    // Replace and fold metadata back-fills into the same mutation, so consumers see one .replace
    // event instead of a .replace immediately followed by a .metadataUpdate.
    mutating func replaceAndApplyMetadataUpdates(
        with batch: [PacketSummary],
        metadataUpdates: [PacketMetadataUpdate],
        source: CaptureSource,
        message: String? = nil
    ) {
        replace(with: batch, source: source, message: message)
        _ = applyMetadataUpdatesInPlace(metadataUpdates)
    }

    mutating func replace(with batch: [PacketSummary], source: CaptureSource, message: String? = nil) {
        self.source = source
        packets = batch
        rebuildPacketIndex()
        packetRevision &+= 1
        packetLineageRevision &+= 1
        lastMutation = .replace
        lastBatchCount = batch.count
        recalculateCounters()
        if let message {
            statusMessage = message
        }
    }

    mutating func append(_ batch: [PacketSummary], source: CaptureSource, message: String? = nil) {
        self.source = source
        let startIndex = packets.count
        packets.append(contentsOf: batch)
        if !batch.isEmpty {
            for (offset, packet) in batch.enumerated() {
                packetIndexByID[packet.id] = startIndex + offset
            }
            packetRevision &+= 1
            lastMutation = .append(startIndex..<packets.count)
            addCounters(for: batch)
        } else {
            lastMutation = .none
        }
        lastBatchCount = batch.count
        if let message {
            statusMessage = message
        }
    }

    mutating func delete(packetIDs: Set<PacketSummary.ID>, message: String? = nil) {
        guard !packetIDs.isEmpty else {
            lastMutation = .none
            return
        }

        let originalCount = packets.count
        packets.removeAll { packetIDs.contains($0.id) }
        guard packets.count != originalCount else {
            lastMutation = .none
            return
        }

        rebuildPacketIndex()
        packetRevision &+= 1
        packetLineageRevision &+= 1
        lastMutation = .replace
        lastBatchCount = 0
        recalculateCounters()
        if let message {
            statusMessage = message
        }
    }

    mutating func applyMetadataUpdates(_ updates: [PacketMetadataUpdate]) {
        let updatedIDs = applyMetadataUpdatesInPlace(updates)
        guard !updatedIDs.isEmpty else {
            return
        }

        packetRevision &+= 1
        lastMutation = .metadataUpdate(packetIDs: updatedIDs)
    }

    mutating func applySummaryUpdates(_ updates: [PacketSummaryUpdate]) {
        var updatedIDs: [PacketSummary.ID] = []
        for update in updates {
            guard let packetIndex = packetIndexByID[update.packetID] else {
                continue
            }

            let currentPacket = packets[packetIndex]
            let updatedPacket = currentPacket.tcpviewerApplying(summaryUpdate: update)
            guard updatedPacket != currentPacket else {
                continue
            }

            packets[packetIndex] = updatedPacket
            updatedIDs.append(update.packetID)
        }

        guard !updatedIDs.isEmpty else {
            return
        }

        packetRevision &+= 1
        lastMutation = .metadataUpdate(packetIDs: updatedIDs)
    }

    // Append a batch and fold metadata updates that target older packets into a single mutation,
    // so consumers can take their cheap append paths without a redundant didSet fire.
    mutating func appendAndApplyMetadataUpdates(
        _ batch: [PacketSummary],
        metadataUpdates: [PacketMetadataUpdate],
        source: CaptureSource,
        message: String? = nil
    ) {
        guard !batch.isEmpty || !metadataUpdates.isEmpty else {
            lastMutation = .none
            return
        }

        let appendStart = packets.count
        let appendedIDs: Set<PacketSummary.ID>
        let appendedRange: Range<Int>?
        if !batch.isEmpty {
            self.source = source
            packets.append(contentsOf: batch)
            for (offset, packet) in batch.enumerated() {
                packetIndexByID[packet.id] = appendStart + offset
            }
            addCounters(for: batch)
            appendedIDs = Set(batch.map(\.id))
            appendedRange = appendStart..<packets.count
            lastBatchCount = batch.count
        } else {
            appendedIDs = []
            appendedRange = nil
        }

        let allUpdatedIDs = applyMetadataUpdatesInPlace(metadataUpdates)
        // Updates that target packets just appended don't need to be reported as a separate
        // metadata update — those packets are already in their correct buckets/rows.
        let priorUpdatedIDs = allUpdatedIDs.filter { !appendedIDs.contains($0) }

        if let appendedRange {
            if priorUpdatedIDs.isEmpty {
                lastMutation = .append(appendedRange)
            } else {
                lastMutation = .appendWithMetadataUpdates(range: appendedRange, updatedPacketIDs: priorUpdatedIDs)
            }
        } else if !priorUpdatedIDs.isEmpty {
            lastMutation = .metadataUpdate(packetIDs: priorUpdatedIDs)
        } else {
            lastMutation = .none
        }

        if appendedRange != nil || !priorUpdatedIDs.isEmpty {
            packetRevision &+= 1
        }

        if let message {
            statusMessage = message
        }
    }

    @discardableResult
    private mutating func applyMetadataUpdatesInPlace(_ updates: [PacketMetadataUpdate]) -> [PacketSummary.ID] {
        var updatedIDs: [PacketSummary.ID] = []
        for update in updates {
            for packetID in update.packetIDs {
                guard let packetIndex = packetIndexByID[packetID] else {
                    continue
                }

                let currentPacket = packets[packetIndex]
                let updatedPacket = currentPacket.tcpviewerApplying(
                    sniDomainName: update.sniDomainName,
                    client: update.client,
                    direction: update.direction
                )
                guard updatedPacket != currentPacket else {
                    continue
                }

                packets[packetIndex] = updatedPacket
                updatedIDs.append(packetID)
            }
        }
        return updatedIDs
    }

    static func == (lhs: PacketIngestState, rhs: PacketIngestState) -> Bool {
        lhs.source == rhs.source &&
            lhs.packetRevision == rhs.packetRevision &&
            lhs.packetLineageRevision == rhs.packetLineageRevision &&
            lhs.lastMutation == rhs.lastMutation &&
            lhs.lastBatchCount == rhs.lastBatchCount &&
            lhs.truncatedPacketCount == rhs.truncatedPacketCount &&
            lhs.decodeIssueCount == rhs.decodeIssueCount &&
            lhs.statusMessage == rhs.statusMessage &&
            lhs.packets.count == rhs.packets.count
    }

    private mutating func addCounters(for batch: [PacketSummary]) {
        for packet in batch {
            if packet.captureMetadata.isTruncated {
                truncatedPacketCount += 1
            }

            if packet.decodeStatus.kind != .complete {
                decodeIssueCount += 1
            }
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

    private mutating func rebuildPacketIndex() {
        packetIndexByID = Dictionary(uniqueKeysWithValues: packets.enumerated().map { index, packet in
            (packet.id, index)
        })
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
    var lastError: TCPViewerCoreError?

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
    var lastUsedInterfaceIDs: [String]
    var activeInterfaceID: String?
    var options: CaptureOptions
    var health: CaptureHealthSnapshot
    var capturedPacketCount: Int
    var statusMessage: String
    var lastError: TCPViewerCoreError?

    static let idle = CaptureSessionState(
        phase: .idle,
        interfaceInventory: [],
        selectedInterfaceID: nil,
        lastUsedInterfaceIDs: [],
        activeInterfaceID: nil,
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

struct TCPViewerWindowSnapshot: Sendable, Equatable {
    var accessState: CaptureAccessState
    var documentState: CaptureDocumentState
    var sessionState: CaptureSessionState
    var packetIngestState: PacketIngestState
    var filterState: PacketFilterState
    var inspectionState: PacketInspectionState
    var navigationState: PacketNavigationState
    var loadState: PacketLoadState

    static let foundation = TCPViewerWindowSnapshot(
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
    var visiblePacketIDs: [PacketSummary.ID]
    var jumpText: String
    var jumpErrorMessage: String?
    var statusMessage: String

    static let empty = PacketNavigationState(
        visiblePacketIDs: [],
        jumpText: "",
        jumpErrorMessage: nil,
        statusMessage: "No packets available."
    )

    static func == (lhs: PacketNavigationState, rhs: PacketNavigationState) -> Bool {
        lhs.visiblePacketIDs.count == rhs.visiblePacketIDs.count &&
            lhs.visiblePacketIDs.first == rhs.visiblePacketIDs.first &&
            lhs.visiblePacketIDs.last == rhs.visiblePacketIDs.last &&
            lhs.jumpText == rhs.jumpText &&
            lhs.jumpErrorMessage == rhs.jumpErrorMessage &&
            lhs.statusMessage == rhs.statusMessage
    }
}

struct PacketLoadState: Sendable, Equatable {
    var progress: PacketLoadProgress

    static let idle = PacketLoadState(progress: .idle)

    var canCancel: Bool {
        progress.phase == .loading
    }
}

final class TCPViewerBackgroundCoordinator {
    private var activeOperations: Set<String> = []

    func replaceOperation(_ identifier: String) {
        activeOperations.insert(identifier)
    }

    func endOperation(_ identifier: String) {
        activeOperations.remove(identifier)
    }

    func cancelAll() {
        activeOperations.removeAll()
    }

    func activeOperationCount() -> Int {
        activeOperations.count
    }
}

struct TCPViewerServiceRegistry {
    let core: any TCPViewerCoreProviding
    let networkHelperTool: any TCPViewerNetworkHelperToolManaging
    let packetMetadataEnricher: any PacketMetadataEnriching

    init(
        core: any TCPViewerCoreProviding,
        networkHelperTool: any TCPViewerNetworkHelperToolManaging,
        packetMetadataEnricher: any PacketMetadataEnriching = PacketMetadataEnrichmentService()
    ) {
        self.core = core
        self.networkHelperTool = networkHelperTool
        self.packetMetadataEnricher = packetMetadataEnricher
    }

    init(
        core: any TCPViewerCoreProviding,
        packetMetadataEnricher: any PacketMetadataEnriching = PacketMetadataEnrichmentService()
    ) {
        self.init(
            core: core,
            networkHelperTool: ReadyTCPViewerNetworkHelperToolManager(),
            packetMetadataEnricher: packetMetadataEnricher
        )
    }

    static let foundation = TCPViewerServiceRegistry(
        core: NativeTCPViewerCore(),
        networkHelperTool: TCPViewerNetworkHelperToolManager(),
        packetMetadataEnricher: PacketMetadataEnrichmentService()
    )
}

private struct TCPViewerPreferences {
    private enum Key {
        static let captureFilterText = "TCPViewer.captureFilterText"
        static let recentCaptureFilters = "TCPViewer.recentCaptureFilters"
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

private final class TCPViewerWorkspaceControllerRegistry {
    static let shared = TCPViewerWorkspaceControllerRegistry()

    private var controllers: [WeakTCPViewerWorkspaceController] = []

    func register(_ controller: TCPViewerWorkspaceController) {
        pruneReleasedControllers()
        guard !controllers.contains(where: { $0.controller === controller }) else {
            return
        }

        controllers.append(WeakTCPViewerWorkspaceController(controller))
    }

    func prepareForApplicationTermination(completion: @escaping (Bool) -> Void) {
        pruneReleasedControllers()
        let activeControllers = controllers.compactMap(\.controller)
        prepare(activeControllers, index: 0, shouldTerminate: true, completion: completion)
    }

    private func prepare(
        _ controllers: [TCPViewerWorkspaceController],
        index: Int,
        shouldTerminate: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < controllers.count else {
            pruneReleasedControllers()
            completion(shouldTerminate)
            return
        }

        controllers[index].prepareForApplicationTermination { didPrepare in
            self.prepare(
                controllers,
                index: index + 1,
                shouldTerminate: shouldTerminate && didPrepare,
                completion: completion
            )
        }
    }

    private func pruneReleasedControllers() {
        controllers.removeAll { $0.controller == nil }
    }
}

private final class WeakTCPViewerWorkspaceController {
    weak var controller: TCPViewerWorkspaceController?

    init(_ controller: TCPViewerWorkspaceController) {
        self.controller = controller
    }
}

protocol TCPViewerWorkspaceControllerDelegate: AnyObject {
    func tcpViewerWorkspaceControllerDidChange(_ controller: TCPViewerWorkspaceController)
}

private enum CurrentNetworkInterfaceResolver {
    private static let dynamicStoreKeys = [
        "State:/Network/Global/IPv4",
        "State:/Network/Global/IPv6",
    ]

    static func primaryInterfaceID() -> String? {
        // Read macOS routing state so startup selection follows the active network service.
        guard let store = SCDynamicStoreCreate(nil, "TCP Viewer" as CFString, nil, nil) else {
            return nil
        }

        for key in dynamicStoreKeys {
            if let interfaceID = primaryInterfaceID(in: store, key: key) {
                return interfaceID
            }
        }

        return nil
    }

    private static func primaryInterfaceID(in store: SCDynamicStore, key: String) -> String? {
        // Return a trimmed BSD interface name such as en0 from the dynamic store.
        guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
              let rawInterfaceID = state["PrimaryInterface"] as? String else {
            return nil
        }

        let interfaceID = rawInterfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceID.isEmpty ? nil : interfaceID
    }
}

#if DEBUG
struct TCPViewerWorkspaceMemoryDebugSnapshot: Equatable {
    let ingestPacketCount: Int
    let packetIndexCount: Int
    let navigationVisibleIDCount: Int
    let metadata: PacketMetadataEnrichmentDebugSnapshot
    let liveSession: LiveCaptureSessionDebugSnapshot?
}
#endif

final class TCPViewerWorkspaceController {
    weak var delegate: TCPViewerWorkspaceControllerDelegate?

    private(set) var snapshot: TCPViewerWindowSnapshot {
        didSet {
            guard snapshotUpdateDepth == 0 else {
                snapshotNeedsNotification = true
                return
            }

            delegate?.tcpViewerWorkspaceControllerDidChange(self)
        }
    }

    let services: TCPViewerServiceRegistry
    private let backgroundCoordinator: TCPViewerBackgroundCoordinator
    private let preferences: TCPViewerPreferences
    private let interfaceHistoryStore: InterfaceSelectionHistoryStore
    private let activeInterfaceIDProvider: () -> String?

    private var hasPerformedInitialLoad = false
    private var liveSession: (any LiveCaptureSessionProviding)?
    private var liveSessionConfiguration: LiveSessionConfiguration?
    private var liveEventGeneration = 0
    private var document: (any OfflineCaptureDocumentProviding)?
    private var documentEventGeneration = 0
    private var inspectionGeneration = 0
    private var filterValidationGeneration = 0
    private var snapshotUpdateDepth = 0
    private var snapshotNeedsNotification = false

    init(
        services: TCPViewerServiceRegistry? = nil,
        backgroundCoordinator: TCPViewerBackgroundCoordinator? = nil,
        snapshot: TCPViewerWindowSnapshot? = nil,
        userDefaults: UserDefaults = .standard,
        interfaceHistoryStore: InterfaceSelectionHistoryStore? = nil,
        activeInterfaceIDProvider: @escaping () -> String? = CurrentNetworkInterfaceResolver.primaryInterfaceID
    ) {
        self.services = services ?? .foundation
        self.backgroundCoordinator = backgroundCoordinator ?? TCPViewerBackgroundCoordinator()
        self.preferences = TCPViewerPreferences(defaults: userDefaults)
        self.interfaceHistoryStore = interfaceHistoryStore ?? InterfaceSelectionHistoryStore(defaults: userDefaults)
        self.activeInterfaceIDProvider = activeInterfaceIDProvider
        var resolvedSnapshot = snapshot ?? .foundation
        resolvedSnapshot.filterState.captureFilterText = preferences.captureFilterText
        resolvedSnapshot.filterState.recentCaptureFilters = preferences.recentCaptureFilters
        resolvedSnapshot.sessionState.lastUsedInterfaceIDs = self.interfaceHistoryStore.lastUsedInterfaceIDs
        self.snapshot = resolvedSnapshot
        TCPViewerWorkspaceControllerRegistry.shared.register(self)
    }

    deinit {
        cancelControllerTasks()
    }

    // Coalesce related snapshot writes so AppKit renders one coherent state.
    private func batchSnapshotUpdates(_ updates: () -> Void) {
        snapshotUpdateDepth += 1
        updates()
        snapshotUpdateDepth -= 1

        guard snapshotUpdateDepth == 0, snapshotNeedsNotification else {
            return
        }

        snapshotNeedsNotification = false
        delegate?.tcpViewerWorkspaceControllerDidChange(self)
    }

    static func prepareAllForApplicationTermination(completion: @escaping (Bool) -> Void) {
        TCPViewerWorkspaceControllerRegistry.shared.prepareForApplicationTermination(completion: completion)
    }

    func performInitialLoadIfNeeded(completion: (() -> Void)? = nil) {
        guard !hasPerformedInitialLoad else {
            completion?()
            return
        }

        hasPerformedInitialLoad = true
        refreshInterfaces(completion: completion)
    }

    func refreshInterfaces(completion: (() -> Void)? = nil) {
        snapshot.accessState = .checking
        snapshot.sessionState.lastError = nil
        snapshot.sessionState.statusMessage = "Refreshing interface inventory..."

        let previousSelectionID = snapshot.sessionState.selectedInterfaceID
        services.networkHelperTool.refreshStatus { [weak self] helperSnapshot in
            guard let self else {
                completion?()
                return
            }

            guard helperSnapshot.status.allowsLiveCapture else {
                self.applyNetworkHelperBlocker(helperSnapshot)
                completion?()
                return
            }

            self.services.core.listInterfaces { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        completion?()
                        return
                    }

                    switch result {
                    case .success(let interfaces):
                        self.applyInterfaceInventory(
                            interfaces,
                            previousSelectionID: previousSelectionID
                        )
                    case .failure(let error):
                        let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .interfaceDiscoveryFailed)
                        self.snapshot.accessState = tcpviewerError.code == .capturePermissionDenied ? .blocked(.accessDenied) : .recovering
                        self.snapshot.sessionState.interfaceInventory = []
                        self.snapshot.sessionState.selectedInterfaceID = nil
                        self.snapshot.sessionState.activeInterfaceID = nil
                        self.snapshot.sessionState.phase = .idle
                        self.snapshot.sessionState.lastError = tcpviewerError
                        self.snapshot.sessionState.statusMessage = tcpviewerError.message
                    }

                    completion?()
                }
            }
        }
    }

    func refreshNetworkHelperToolStatus(completion: (() -> Void)? = nil) {
        services.networkHelperTool.refreshStatus { [weak self] helperSnapshot in
            guard let self else {
                completion?()
                return
            }

            if helperSnapshot.status.allowsLiveCapture {
                self.refreshInterfaces(completion: completion)
            } else {
                self.applyNetworkHelperBlocker(helperSnapshot)
                completion?()
            }
        }
    }

    func installNetworkHelperTool(completion: (() -> Void)? = nil) {
        services.networkHelperTool.install { [weak self] helperSnapshot in
            guard let self else {
                completion?()
                return
            }

            if helperSnapshot.status.allowsLiveCapture {
                self.refreshInterfaces(completion: completion)
            } else {
                self.applyNetworkHelperBlocker(helperSnapshot)
                completion?()
            }
        }
    }

    func repairNetworkHelperTool(completion: (() -> Void)? = nil) {
        services.networkHelperTool.repair { [weak self] helperSnapshot in
            guard let self else {
                completion?()
                return
            }

            if helperSnapshot.status.allowsLiveCapture {
                self.refreshInterfaces(completion: completion)
            } else {
                self.applyNetworkHelperBlocker(helperSnapshot)
                completion?()
            }
        }
    }

    func openNetworkHelperSystemSettings() {
        services.networkHelperTool.openSystemSettings()
    }

    var networkHelperToolSnapshot: TCPViewerNetworkHelperToolSnapshot {
        services.networkHelperTool.snapshot
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
            snapshot.sessionState.lastError = TCPViewerCoreError(
                code: .unsupportedInterface,
                message: "The selected interface is no longer present."
            )
            return
        }

        guard interface.isSelectable else {
            snapshot.sessionState.selectedInterfaceID = nil
            snapshot.sessionState.options = options(for: nil)
            snapshot.sessionState.statusMessage = interface.availabilityReason ?? "This interface is not currently available for capture."
            snapshot.sessionState.lastError = TCPViewerCoreError(
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

    func validateCaptureFilter(completion: (() -> Void)? = nil) {
        let trimmedFilter = snapshot.filterState.captureFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty else {
            snapshot.filterState.validation = CaptureFilterValidation(
                disposition: .unavailable,
                normalizedExpression: nil,
                message: nil
            )
            snapshot.filterState.isValidating = false
            snapshot.filterState.statusMessage = "Capture filter is optional."
            completion?()
            return
        }

        filterValidationGeneration += 1
        let generation = filterValidationGeneration
        snapshot.filterState.isValidating = true
        services.core.validateCaptureFilter(trimmedFilter) { [weak self] validation in
            DispatchQueue.main.async {
                guard let self, self.filterValidationGeneration == generation else {
                    completion?()
                    return
                }

                self.snapshot.filterState.isValidating = false
                self.snapshot.filterState.validation = validation
                self.snapshot.filterState.statusMessage = validation.message ?? "Capture filter is ready."
                if validation.disposition == .valid {
                    let normalizedExpression = validation.normalizedExpression ?? trimmedFilter
                    self.snapshot.filterState.captureFilterText = normalizedExpression
                    self.persistCaptureFilter(normalizedExpression)
                }
                completion?()
            }
        }
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

        guard let packet = snapshot.packetIngestState.packets.first(where: { $0.packetNumber == packetNumber }) else {
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

        selectPacket(snapshot.navigationState.visiblePacketIDs[currentIndex - 1])
    }

    func selectNextPacket() {
        guard let currentIndex = selectedVisiblePacketIndex(),
              currentIndex < snapshot.navigationState.visiblePacketIDs.count - 1 else {
            return
        }

        selectPacket(snapshot.navigationState.visiblePacketIDs[currentIndex + 1])
    }

    func selectDetailNode(_ identifier: String?) {
        snapshot.inspectionState.selectedDetailNodeID = identifier
        snapshot.inspectionState.highlightedByteRange = detailNode(with: identifier)?.byteRange
    }

    func startLiveCapture(completion: (() -> Void)? = nil) {
        guard let interface = snapshot.sessionState.selectedInterface else {
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = TCPViewerCoreError(
                code: .unsupportedInterface,
                message: "Select an interface before starting live capture."
            )
            snapshot.sessionState.statusMessage = snapshot.sessionState.lastError?.message ?? "No interface selected."
            completion?()
            return
        }

        validateCaptureFilter { [weak self] in
            guard let self else {
                completion?()
                return
            }

            if snapshot.filterState.hasValidationError {
                let message = snapshot.filterState.validation.message ?? "TCP Viewer could not compile this capture filter."
                snapshot.sessionState.lastError = TCPViewerCoreError(code: .invalidCaptureFilter, message: message)
                snapshot.sessionState.statusMessage = message
                snapshot.sessionState.phase = .ready
                completion?()
                return
            }

            do {
                let configuredOptions = self.options(for: interface)
                let validatedOptions = try self.services.core.validateCaptureOptions(configuredOptions, for: interface)
                self.snapshot.sessionState.options = validatedOptions
                self.persistCaptureFilter(validatedOptions.captureFilterExpression)

                let configuration = LiveSessionConfiguration(interfaceID: interface.id, options: validatedOptions)
                // A new capture run must not inherit delayed packet callbacks from the stopped session.
                let needsFreshSession = self.liveSession == nil ||
                    self.liveSessionConfiguration != configuration ||
                    self.snapshot.sessionState.phase == .stopped ||
                    self.snapshot.sessionState.phase == .failed
                if needsFreshSession {
                    self.resetLiveSession { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self else {
                                completion?()
                                return
                            }

                            switch result {
                            case .success:
                                self.makeAndStartLiveSession(interface: interface, options: validatedOptions, configuration: configuration, completion: completion)
                            case .failure(let error):
                                let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed)
                                self.snapshot.sessionState.phase = .failed
                                self.snapshot.sessionState.lastError = tcpviewerError
                                self.snapshot.sessionState.statusMessage = tcpviewerError.message
                                completion?()
                            }
                        }
                    }
                } else {
                    self.prepareAndStartLiveSession(interface: interface, completion: completion)
                }
            } catch {
                let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionStartFailed)
                self.snapshot.sessionState.phase = .failed
                self.snapshot.sessionState.lastError = tcpviewerError
                self.snapshot.sessionState.statusMessage = tcpviewerError.message
                completion?()
            }
        }
    }

    func pauseLiveCapture(completion: (() -> Void)? = nil) {
        guard let liveSession else {
            completion?()
            return
        }

        snapshot.sessionState.statusMessage = "Pausing live capture..."
        liveSession.pause { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                if case .failure(let error) = result {
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed)
                    self.snapshot.sessionState.phase = .failed
                    self.snapshot.sessionState.lastError = tcpviewerError
                    self.snapshot.sessionState.statusMessage = tcpviewerError.message
                }
                completion?()
            }
        }
    }

    func resumeLiveCapture(completion: (() -> Void)? = nil) {
        guard let liveSession else {
            completion?()
            return
        }

        snapshot.sessionState.statusMessage = "Resuming live capture..."
        liveSession.resume { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                if case .failure(let error) = result {
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed)
                    self.snapshot.sessionState.phase = .failed
                    self.snapshot.sessionState.lastError = tcpviewerError
                    self.snapshot.sessionState.statusMessage = tcpviewerError.message
                }
                completion?()
            }
        }
    }

    func stopLiveCapture(completion: (() -> Void)? = nil) {
        guard let liveSession else {
            completion?()
            return
        }

        snapshot.sessionState.phase = .stopping
        snapshot.sessionState.statusMessage = "Stopping live capture..."
        liveSession.stop { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                if case .failure(let error) = result {
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed)
                    self.snapshot.sessionState.phase = .failed
                    self.snapshot.sessionState.lastError = tcpviewerError
                    self.snapshot.sessionState.statusMessage = tcpviewerError.message
                }
                completion?()
            }
        }
    }

    func openDocument(at fileURL: URL, completion: (() -> Void)? = nil) {
        stopLiveCaptureIfNeeded { [weak self] stopResult in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                if case .failure(let error) = stopResult {
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed)
                    self.snapshot.sessionState.phase = .failed
                    self.snapshot.sessionState.lastError = tcpviewerError
                    self.snapshot.sessionState.statusMessage = tcpviewerError.message
                    completion?()
                    return
                }

                self.releaseDocumentContext()
                self.resetInspectionState()
                self.snapshot.selectedPacketID = nil
                self.snapshot.documentState = CaptureDocumentState(
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
                self.services.packetMetadataEnricher.reset()
                self.snapshot.packetIngestState.reset(source: .offline, message: "Opening \(fileURL.lastPathComponent)...")
                self.synchronizeVisiblePackets(message: "Opening \(fileURL.lastPathComponent)...")
                self.snapshot.loadState.progress = PacketLoadProgress(
                    phase: .loading,
                    loadedPacketCount: 0,
                    message: "Opening \(fileURL.lastPathComponent)..."
                )

                self.services.core.openOfflineCaptureDocument(at: fileURL) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else {
                            completion?()
                            return
                        }

                        switch result {
                        case .success(let document):
                            self.document = document
                            self.observeDocumentEvents(document)
                            document.open { [weak self] result in
                                DispatchQueue.main.async {
                                    guard let self else {
                                        completion?()
                                        return
                                    }

                                    switch result {
                                    case .success:
                                        self.refreshDocumentSnapshotFromHandle(
                                            document,
                                            phase: .loaded,
                                            message: "Loaded \(self.snapshot.packetIngestState.totalPacketCount) packets from \(fileURL.lastPathComponent)."
                                        )
                                    case .failure(let error):
                                        self.handleDocumentLoadFailure(error, document: document)
                                    }
                                    completion?()
                                }
                            }
                        case .failure(let error):
                            self.handleDocumentLoadFailure(error, document: nil)
                            completion?()
                        }
                    }
                }
            }
        }
    }

    func reopenDocument(completion: (() -> Void)? = nil) {
        guard let document else {
            completion?()
            return
        }

        let fileName = snapshot.documentState.fileURL?.lastPathComponent ?? "capture"
        snapshot.documentState.phase = .reopening
        snapshot.documentState.statusMessage = "Reopening \(fileName)..."
        snapshot.documentState.isPartialResult = false
        services.packetMetadataEnricher.reset()
        snapshot.packetIngestState.reset(source: .offline, message: "Reopening \(fileName)...")
        synchronizeVisiblePackets(message: "Reopening \(fileName)...")
        resetInspectionState()
        snapshot.loadState.progress = PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "Reopening \(fileName)..."
        )

        document.reopen { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                switch result {
                case .success:
                    self.refreshDocumentSnapshotFromHandle(
                        document,
                        phase: .loaded,
                        message: "Reloaded \(self.snapshot.packetIngestState.totalPacketCount) packets from \(fileName)."
                    )
                case .failure(let error):
                    self.handleDocumentLoadFailure(error, document: document)
                }
                completion?()
            }
        }
    }

    func saveDocument(completion: (() -> Void)? = nil) {
        guard let document else {
            completion?()
            return
        }

        snapshot.documentState.phase = .saving
        snapshot.documentState.statusMessage = "Saving \(snapshot.documentState.fileURL?.lastPathComponent ?? "capture")..."

        document.save { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                switch result {
                case .success:
                    self.refreshDocumentSnapshotFromHandle(
                        document,
                        phase: .saved,
                        message: "Saved \(self.snapshot.documentState.fileURL?.lastPathComponent ?? "capture")."
                    )
                case .failure(let error):
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .offlineFileSaveFailed)
                    self.snapshot.documentState.phase = .failed
                    self.snapshot.documentState.lastError = tcpviewerError
                    self.snapshot.documentState.statusMessage = tcpviewerError.message
                }
                completion?()
            }
        }
    }

    func saveDocument(to url: URL, format: CaptureFileFormat, completion: (() -> Void)? = nil) {
        guard let document else {
            completion?()
            return
        }

        snapshot.documentState.phase = .saving
        snapshot.documentState.statusMessage = "Saving as \(url.lastPathComponent)..."

        document.save(to: url, format: format) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                switch result {
                case .success:
                    self.refreshDocumentSnapshotFromHandle(
                        document,
                        phase: .saved,
                        message: "Saved as \(url.lastPathComponent)."
                    )
                case .failure(let error):
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .offlineFileSaveFailed)
                    self.snapshot.documentState.phase = .failed
                    self.snapshot.documentState.lastError = tcpviewerError
                    self.snapshot.documentState.statusMessage = tcpviewerError.message
                }
                completion?()
            }
        }
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler? = nil,
        shouldCancel: PacketExportCancellationCheck? = nil,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        guard !identifiers.isEmpty else {
            completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "There are no packets to export.")))
            return
        }

        let cancellationCheck = shouldCancel ?? { false }
        guard !cancellationCheck() else {
            completion(.failure(Self.exportCancelledError()))
            return
        }

        switch snapshot.packetIngestState.source {
        case .live:
            guard let liveSession else {
                completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "The live capture backing store is not available for export.")))
                return
            }

            let shouldResumeCapture = snapshot.sessionState.phase == .running
            let beginLiveExport = { [weak self] in
                guard let self else {
                    completion(.failure(Self.exportCancelledError()))
                    return
                }

                guard !cancellationCheck() else {
                    self.resumeLiveSessionAfterExportIfNeeded(liveSession, shouldResumeCapture: shouldResumeCapture, exportResult: .failure(Self.exportCancelledError()), url: url, completion: completion)
                    return
                }

                self.snapshot.sessionState.statusMessage = "Exporting \(url.lastPathComponent)..."
                liveSession.exportPackets(withIDs: identifiers, to: url, format: format, progress: progress, shouldCancel: cancellationCheck) { [weak self] result in
                    DispatchQueue.main.async {
                        self?.resumeLiveSessionAfterExportIfNeeded(liveSession, shouldResumeCapture: shouldResumeCapture, exportResult: result, url: url, completion: completion)
                    }
                }
            }

            guard shouldResumeCapture else {
                beginLiveExport()
                return
            }

            snapshot.sessionState.statusMessage = "Pausing capture for export..."
            liveSession.pause { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        completion(result)
                        return
                    }

                    switch result {
                    case .success:
                        beginLiveExport()
                    case .failure(let error):
                        let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed)
                        self.snapshot.sessionState.lastError = tcpviewerError
                        self.snapshot.sessionState.statusMessage = tcpviewerError.message
                        completion(.failure(tcpviewerError))
                    }
                }
            }
        case .offline:
            guard let document else {
                completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "The capture document is not available for export.")))
                return
            }

            snapshot.documentState.statusMessage = "Exporting \(url.lastPathComponent)..."
            document.exportPackets(withIDs: identifiers, to: url, format: format, progress: progress, shouldCancel: cancellationCheck) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        completion(result)
                        return
                    }

                    switch result {
                    case .success:
                        self.snapshot.documentState.lastError = nil
                        self.snapshot.documentState.statusMessage = "Exported \(url.lastPathComponent)."
                    case .failure(let error):
                        let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .offlineFileSaveFailed)
                        self.snapshot.documentState.lastError = tcpviewerError
                        self.snapshot.documentState.statusMessage = tcpviewerError.message
                        completion(.failure(tcpviewerError))
                        return
                    }
                    completion(result)
                }
            }
        case nil:
            completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "There is no active capture to export.")))
        @unknown default:
            completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "TCP Viewer cannot export packets from this capture source.")))
        }
    }

    private static func exportCancelledError() -> TCPViewerCoreError {
        TCPViewerCoreError(code: .operationCancelled, message: "Packet export was cancelled.")
    }

    private func resumeLiveSessionAfterExportIfNeeded(
        _ liveSession: any LiveCaptureSessionProviding,
        shouldResumeCapture: Bool,
        exportResult: Result<Void, Error>,
        url: URL,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        guard shouldResumeCapture else {
            completeLiveExport(exportResult, url: url, completion: completion)
            return
        }

        snapshot.sessionState.statusMessage = "Resuming capture..."
        liveSession.resume { [weak self] resumeResult in
            DispatchQueue.main.async {
                guard let self else {
                    completion(exportResult)
                    return
                }

                switch (exportResult, resumeResult) {
                case (.success, .success):
                    self.completeLiveExport(.success(()), url: url, completion: completion)
                case (.failure, .success):
                    self.completeLiveExport(exportResult, url: url, completion: completion)
                case (.success, .failure(let resumeError)):
                    let tcpviewerError = self.tcpviewerError(from: resumeError, defaultCode: .liveSessionControlFailed)
                    self.completeLiveExport(.failure(tcpviewerError), url: url, completion: completion)
                case (.failure(let exportError), .failure):
                    self.completeLiveExport(.failure(exportError), url: url, completion: completion)
                }
            }
        }
    }

    private func completeLiveExport(_ result: Result<Void, Error>, url: URL, completion: @escaping TCPViewerVoidCompletion) {
        switch result {
        case .success:
            snapshot.sessionState.lastError = nil
            snapshot.sessionState.statusMessage = "Exported \(url.lastPathComponent)."
            completion(.success(()))
        case .failure(let error):
            let tcpviewerError = tcpviewerError(from: error, defaultCode: .offlineFileSaveFailed)
            snapshot.sessionState.lastError = tcpviewerError
            snapshot.sessionState.statusMessage = tcpviewerError.code == .operationCancelled ? "Export cancelled." : tcpviewerError.message
            completion(.failure(tcpviewerError))
        }
    }

    func cancelDocumentLoading(completion: (() -> Void)? = nil) {
        guard let document else {
            completion?()
            return
        }

        document.cancelLoading(completion: completion)
    }

    func clearPackets() {
        let source = snapshot.packetIngestState.source
        let shouldReleaseStoppedLiveSession = snapshot.sessionState.phase == .stopped ||
            snapshot.sessionState.phase == .failed
        snapshot.packetIngestState.reset(source: source, message: "Cleared.")
        snapshot.navigationState = PacketNavigationState(
            visiblePacketIDs: [],
            jumpText: "",
            jumpErrorMessage: nil,
            statusMessage: "Cleared."
        )
        resetInspectionState()
        snapshot.documentState.packetCount = 0
        snapshot.sessionState.capturedPacketCount = 0
        services.packetMetadataEnricher.reset()
        if shouldReleaseStoppedLiveSession {
            releaseLiveSession()
        }
    }

    func deletePackets(_ packetIDs: Set<PacketSummary.ID>) {
        guard !packetIDs.isEmpty else {
            return
        }

        batchSnapshotUpdates {
            let source = snapshot.packetIngestState.source
            snapshot.packetIngestState.delete(packetIDs: packetIDs, message: "Deleted \(packetIDs.count) packet(s).")
            synchronizeVisiblePackets(message: snapshot.packetIngestState.statusMessage)

            switch source {
            case .some(.live):
                snapshot.sessionState.capturedPacketCount = snapshot.packetIngestState.totalPacketCount
            case .some(.offline):
                snapshot.documentState.packetCount = snapshot.packetIngestState.totalPacketCount
            case nil:
                break
            case .some:
                break
            }
        }
    }

    #if DEBUG
    func debugMemorySnapshot() -> TCPViewerWorkspaceMemoryDebugSnapshot {
        TCPViewerWorkspaceMemoryDebugSnapshot(
            ingestPacketCount: snapshot.packetIngestState.packets.count,
            packetIndexCount: snapshot.packetIngestState.packetIndexByID.count,
            navigationVisibleIDCount: snapshot.navigationState.visiblePacketIDs.count,
            metadata: services.packetMetadataEnricher.debugMemorySnapshot(),
            liveSession: liveSession?.debugMemorySnapshot()
        )
    }
    #endif

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

        openDocument(at: url)
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

        saveDocument(to: url, format: format)
    }

    func selectPacket(_ identifier: PacketSummary.ID?) {
        scheduleInspection(for: identifier)
    }

    func cancelBackgroundWork() {
        cancelControllerTasks()

        let currentDocument = document
        backgroundCoordinator.cancelAll()
        currentDocument?.cancelLoading(completion: nil)

        snapshot.sessionState.statusMessage = "Cancelled background work."
        snapshot.documentState.statusMessage = "Cancelled background work."
    }

    func prepareForApplicationTermination(completion: @escaping (Bool) -> Void) {
        stopRetainedLiveSessionIfNeeded { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion(true)
                    return
                }

                if case .failure(let error) = result {
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed)
                    self.snapshot.sessionState.phase = .failed
                    self.snapshot.sessionState.lastError = tcpviewerError
                    self.snapshot.sessionState.statusMessage = tcpviewerError.message
                    completion(false)
                    return
                }

                self.releaseLiveSession()
                self.cancelBackgroundWorkForTermination(completion: {
                    completion(true)
                })
            }
        }
    }

    private func applyInterfaceInventory(_ interfaces: [CaptureInterfaceSummary], previousSelectionID: String?) {
        // Prefer a valid current selection, then a proven capture interface, then the active route.
        snapshot.sessionState.interfaceInventory = interfaces
        let activeInterfaceID = normalizedActiveInterfaceID()
        snapshot.sessionState.activeInterfaceID = activeInterfaceID
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
        } else if snapshot.sessionState.selectedInterfaceID == nil,
                  let preferredInterface = preferredInterface(from: selectableInterfaces, activeInterfaceID: activeInterfaceID) {
            snapshot.sessionState.selectedInterfaceID = preferredInterface.id
            snapshot.sessionState.options = options(for: preferredInterface)
            snapshot.sessionState.statusMessage = "Discovered \(interfaces.count) interfaces. Selected \(displayName(for: preferredInterface))."
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

    private func preferredInterface(from selectableInterfaces: [CaptureInterfaceSummary], activeInterfaceID: String?) -> CaptureInterfaceSummary? {
        // Honor the most recent capture-start interface before choosing the active route.
        let inventory = snapshot.sessionState.interfaceInventory
        for interfaceID in snapshot.sessionState.lastUsedInterfaceIDs {
            if let interface = inventory.first(where: { $0.id == interfaceID }) {
                return interface
            }
        }

        if let activeInterface = activeInterface(from: selectableInterfaces, activeInterfaceID: activeInterfaceID) {
            return activeInterface
        }

        return selectableInterfaces.first
    }

    private func normalizedActiveInterfaceID() -> String? {
        // Normalize the route interface once per refresh so selection and UI stay in sync.
        guard let activeInterfaceID = activeInterfaceIDProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activeInterfaceID.isEmpty else {
            return nil
        }

        return activeInterfaceID
    }

    private func activeInterface(from selectableInterfaces: [CaptureInterfaceSummary], activeInterfaceID: String?) -> CaptureInterfaceSummary? {
        // Match both capture ID and BSD name because native inventories currently use BSD names.
        guard let activeInterfaceID else {
            return nil
        }

        return selectableInterfaces.first {
            $0.id.caseInsensitiveCompare(activeInterfaceID) == .orderedSame ||
                $0.technicalName.caseInsensitiveCompare(activeInterfaceID) == .orderedSame
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

    private func persistLastUsedInterface(_ interfaceID: String) {
        // Promote the started interface while preserving a short, unique MRU list.
        let normalizedID = interfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return
        }

        snapshot.sessionState.lastUsedInterfaceIDs = interfaceHistoryStore.recordInterfaceUsage(normalizedID)
    }

    private func makeAndStartLiveSession(
        interface: CaptureInterfaceSummary,
        options: CaptureOptions,
        configuration: LiveSessionConfiguration,
        completion: (() -> Void)?
    ) {
        services.core.makeLiveCaptureSession(interfaceID: interface.id, options: options) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                switch result {
                case .success(let session):
                    self.liveSession = session
                    self.liveSessionConfiguration = configuration
                    self.observeLiveSessionEvents(session)
                    self.prepareAndStartLiveSession(interface: interface, completion: completion)
                case .failure(let error):
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionStartFailed)
                    self.snapshot.sessionState.phase = .failed
                    self.snapshot.sessionState.lastError = tcpviewerError
                    self.snapshot.sessionState.statusMessage = tcpviewerError.message
                    completion?()
                }
            }
        }
    }

    private func prepareAndStartLiveSession(interface: CaptureInterfaceSummary, completion: (() -> Void)?) {
        releaseDocumentContext(resetState: true)
        resetInspectionState()
        snapshot.loadState = .idle

        snapshot.selectedPacketID = nil
        services.packetMetadataEnricher.reset()
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
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = TCPViewerCoreError(code: .liveSessionStartFailed, message: "TCP Viewer could not create a live capture session.")
            snapshot.sessionState.statusMessage = snapshot.sessionState.lastError?.message ?? "TCP Viewer could not create a live capture session."
            completion?()
            return
        }

        liveSession.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }

                if case .success = result {
                    self.persistLastUsedInterface(interface.id)
                } else if case .failure(let error) = result {
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .liveSessionStartFailed)
                    self.snapshot.sessionState.phase = .failed
                    self.snapshot.sessionState.lastError = tcpviewerError
                    self.snapshot.sessionState.statusMessage = tcpviewerError.message
                }
                completion?()
            }
        }
    }

    private func observeLiveSessionEvents(_ session: any LiveCaptureSessionProviding) {
        liveEventGeneration += 1
        let generation = liveEventGeneration
        backgroundCoordinator.replaceOperation("live-events")

        session.eventHandler = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.liveEventGeneration == generation else {
                    return
                }

                switch result {
                case .success(let event):
                    self.applyPacketIngestEvent(event)
                case .failure(let error):
                    self.handleStreamFailure(error, context: .live)
                }
            }
        }
    }

    private func observeDocumentEvents(_ document: any OfflineCaptureDocumentProviding) {
        documentEventGeneration += 1
        let generation = documentEventGeneration
        backgroundCoordinator.replaceOperation("document-events")

        document.eventHandler = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.documentEventGeneration == generation else {
                    return
                }

                switch result {
                case .success(let event):
                    self.applyPacketIngestEvent(event)
                case .failure(let error):
                    self.handleStreamFailure(error, context: .document)
                }
            }
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
                services.packetMetadataEnricher.reset()
                snapshot.packetIngestState.reset(
                    source: source,
                    message: source == .live ? "Waiting for live packets…" : "Loading packets from disk…"
                )
                if let source, !packets.isEmpty {
                    let enrichmentResult = services.packetMetadataEnricher.enrich(packets, source: source)
                    snapshot.packetIngestState.replaceAndApplyMetadataUpdates(
                        with: enrichmentResult.packets,
                        metadataUpdates: enrichmentResult.updates,
                        source: source,
                        message: source == .live
                            ? "Captured \(packets.count) packets."
                            : "Loaded \(packets.count) packets from disk."
                    )
                }
            case .append:
                if let source {
                    let enrichmentResult = services.packetMetadataEnricher.enrich(packets, source: source)
                    snapshot.packetIngestState.appendAndApplyMetadataUpdates(
                        enrichmentResult.packets,
                        metadataUpdates: enrichmentResult.updates,
                        source: source,
                        message: source == .live
                            ? "Captured \(snapshot.packetIngestState.totalPacketCount + packets.count) packets."
                            : "Loaded \(snapshot.packetIngestState.totalPacketCount + packets.count) packets from disk."
                    )
                }
            @unknown default:
                if let source {
                    let enrichmentResult = services.packetMetadataEnricher.enrich(packets, source: source)
                    snapshot.packetIngestState.appendAndApplyMetadataUpdates(
                        enrichmentResult.packets,
                        metadataUpdates: enrichmentResult.updates,
                        source: source
                    )
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
        case .packetSummaryUpdates(let updates):
            let beforeRevision = snapshot.packetIngestState.packetRevision
            snapshot.packetIngestState.applySummaryUpdates(updates)
            guard snapshot.packetIngestState.packetRevision != beforeRevision else {
                return
            }

            synchronizeVisiblePackets(message: "Updated \(updates.count) packet summaries.")
            if let selectedPacketID = snapshot.selectedPacketID,
               updates.contains(where: { $0.packetID == selectedPacketID }) {
                scheduleInspection(for: selectedPacketID)
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
        let defaultCode: TCPViewerCoreError.Code = context == .live ? .liveSessionControlFailed : .offlineFileOpenFailed
        let tcpviewerError = tcpviewerError(from: error, defaultCode: defaultCode)

        switch context {
        case .live:
            snapshot.sessionState.phase = .failed
            snapshot.sessionState.lastError = tcpviewerError
            snapshot.sessionState.statusMessage = tcpviewerError.message
        case .document:
            if tcpviewerError.code == .operationCancelled {
                snapshot.documentState.phase = .loaded
                snapshot.documentState.isPartialResult = true
                snapshot.documentState.statusMessage = snapshot.loadState.progress.message
                snapshot.documentState.lastError = nil
            } else {
                snapshot.documentState.phase = .failed
                snapshot.documentState.lastError = tcpviewerError
                snapshot.documentState.statusMessage = tcpviewerError.message
            }
        }
    }

    private func handleDocumentLoadFailure(_ error: Error, document: (any OfflineCaptureDocumentProviding)?) {
        let tcpviewerError = tcpviewerError(from: error, defaultCode: .offlineFileOpenFailed)
        if tcpviewerError.code == .operationCancelled {
            if let document {
                refreshDocumentSnapshotFromHandle(
                    document,
                    phase: .loaded,
                    message: tcpviewerError.message
                )
            } else {
                snapshot.documentState.phase = .loaded
                snapshot.documentState.isPartialResult = true
                snapshot.documentState.statusMessage = snapshot.loadState.progress.message
                snapshot.documentState.lastError = nil
            }
        } else {
            snapshot.documentState.phase = .failed
            snapshot.documentState.lastError = tcpviewerError
            snapshot.documentState.statusMessage = tcpviewerError.message
        }
    }

    private func refreshDocumentSnapshotFromHandle(
        _ document: any OfflineCaptureDocumentProviding,
        phase: CaptureDocumentState.Phase,
        message: String
    ) {
        let url = document.currentURL()
        let metadata = document.currentMetadata()
        let packets = document.packetSummaries()
        let progress = document.loadProgress()
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

    private func stopLiveCaptureIfNeeded(completion: @escaping TCPViewerVoidCompletion) {
        stopRetainedLiveSessionIfNeeded { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion(result)
                    return
                }

                if case .success = result {
                    self.releaseLiveSession()
                    self.snapshot.sessionState.phase = self.snapshot.accessState.isCaptureReady ? .ready : .idle
                    self.snapshot.sessionState.health = .empty
                    self.snapshot.loadState = .idle
                }
                completion(result)
            }
        }
    }

    private func resetLiveSession(completion: @escaping TCPViewerVoidCompletion) {
        stopRetainedLiveSessionIfNeeded { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion(result)
                    return
                }

                if case .success = result {
                    self.releaseLiveSession()
                }
                completion(result)
            }
        }
    }

    private func stopRetainedLiveSessionIfNeeded(completion: @escaping TCPViewerVoidCompletion) {
        guard let liveSession, snapshot.sessionState.phase != .stopped else {
            completion(.success(()))
            return
        }

        liveSession.stop { [weak self] result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                let tcpviewerError = self?.tcpviewerError(from: error, defaultCode: .liveSessionControlFailed) ?? TCPViewerCoreError(code: .liveSessionControlFailed, message: error.localizedDescription)
                completion(.failure(tcpviewerError))
            }
        }
    }

    private func releaseLiveSession() {
        liveEventGeneration += 1
        liveSession?.eventHandler = nil
        inspectionGeneration += 1
        liveSession = nil
        liveSessionConfiguration = nil

        backgroundCoordinator.endOperation("live-events")
    }

    private func cancelControllerTasks() {
        liveEventGeneration += 1
        documentEventGeneration += 1
        inspectionGeneration += 1
        filterValidationGeneration += 1
        liveSession?.eventHandler = nil
        document?.eventHandler = nil
    }

    private func cancelBackgroundWorkForTermination(completion: @escaping () -> Void) {
        cancelControllerTasks()
        let currentDocument = document
        document = nil
        backgroundCoordinator.cancelAll()
        currentDocument?.cancelLoading(completion: completion) ?? completion()
    }

    private func releaseDocumentContext(resetState: Bool = false) {
        let currentDocument = document
        documentEventGeneration += 1
        document?.eventHandler = nil
        inspectionGeneration += 1
        document = nil
        backgroundCoordinator.endOperation("document-events")
        currentDocument?.cancelLoading(completion: nil)

        if resetState {
            snapshot.documentState = .idle
            snapshot.loadState = .idle
        }
    }

    private func synchronizeVisiblePackets(message: String) {
        let mutation = snapshot.packetIngestState.lastMutation
        var shouldValidateSelection = true

        let appendRange: Range<Int>?
        switch mutation {
        case .append(let range):
            appendRange = range
        case .appendWithMetadataUpdates(let range, _):
            appendRange = range
        default:
            appendRange = nil
        }

        if let range = appendRange,
           snapshot.navigationState.visiblePacketIDs.count == range.lowerBound,
           range.upperBound <= snapshot.packetIngestState.packets.count {
            snapshot.navigationState.visiblePacketIDs.append(
                contentsOf: snapshot.packetIngestState.packets[range].map(\.id)
            )
            shouldValidateSelection = false
        } else {
            snapshot.navigationState.visiblePacketIDs = snapshot.packetIngestState.packets.map(\.id)
        }
        snapshot.navigationState.statusMessage = message

        if shouldValidateSelection,
           let selectedPacketID = snapshot.selectedPacketID,
           !snapshot.navigationState.visiblePacketIDs.contains(selectedPacketID) {
            resetInspectionState()
        }
    }

    private func resetInspectionState() {
        inspectionGeneration += 1
        snapshot.inspectionState = .empty
    }

    private func selectedVisiblePacketIndex() -> Int? {
        guard let selectedPacketID = snapshot.selectedPacketID else {
            return nil
        }

        return snapshot.navigationState.visiblePacketIDs.firstIndex(of: selectedPacketID)
    }

    private func scheduleInspection(for identifier: PacketSummary.ID?) {
        inspectionGeneration += 1
        let generation = inspectionGeneration
        var packetForInspection: PacketSummary?

        batchSnapshotUpdates {
            snapshot.navigationState.jumpErrorMessage = nil
            guard let identifier,
                  let packet = snapshot.packetIngestState.packet(withID: identifier),
                  snapshot.navigationState.visiblePacketIDs.contains(identifier) else {
                snapshot.inspectionState = .empty
                return
            }

            packetForInspection = packet
            snapshot.inspectionState = PacketInspectionState(
                selectedPacketID: identifier,
                inspection: nil,
                selectedDetailNodeID: nil,
                highlightedByteRange: nil,
                isLoading: true,
                statusMessage: "Inspecting packet \(identifier)..."
            )
        }

        guard let packet = packetForInspection,
              let identifier = snapshot.selectedPacketID else {
            return
        }

        let liveSession = self.liveSession
        let document = self.document
        let completion: TCPViewerCompletion<PacketInspection> = { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.inspectionGeneration == generation,
                      self.snapshot.selectedPacketID == identifier else {
                    return
                }

                switch result {
                case .success(let inspection):
                    self.batchSnapshotUpdates {
                        self.snapshot.inspectionState.selectedPacketID = identifier
                        self.snapshot.inspectionState.inspection = inspection
                        self.snapshot.inspectionState.isLoading = false
                        self.snapshot.inspectionState.statusMessage = "Inspecting packet \(inspection.packetNumber)."
                    }
                case .failure(let error):
                    let tcpviewerError = self.tcpviewerError(from: error, defaultCode: .offlineFileOpenFailed)
                    self.batchSnapshotUpdates {
                        self.snapshot.inspectionState.inspection = nil
                        self.snapshot.inspectionState.isLoading = false
                        self.snapshot.inspectionState.statusMessage = tcpviewerError.message
                    }
                }
            }
        }

        switch packet.source {
        case .live:
            liveSession?.inspectPacket(id: identifier, completion: completion)
        case .offline:
            document?.inspectPacket(id: identifier, completion: completion)
        @unknown default:
            break
        }
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

    private func tcpviewerError(from error: Error, defaultCode: TCPViewerCoreError.Code) -> TCPViewerCoreError {
        if let tcpviewerError = error as? TCPViewerCoreError {
            return tcpviewerError
        }

        return TCPViewerCoreError(code: defaultCode, message: error.localizedDescription)
    }

    private func applyNetworkHelperBlocker(_ helperSnapshot: TCPViewerNetworkHelperToolSnapshot) {
        snapshot.accessState = .blocked(captureAccessBlocker(for: helperSnapshot.status))
        snapshot.sessionState.interfaceInventory = []
        snapshot.sessionState.selectedInterfaceID = nil
        snapshot.sessionState.activeInterfaceID = nil
        snapshot.sessionState.phase = .idle
        snapshot.sessionState.lastError = TCPViewerCoreError(
            code: .capturePermissionDenied,
            message: helperSnapshot.message
        )
        snapshot.sessionState.statusMessage = helperSnapshot.message
    }

    private func captureAccessBlocker(for status: TCPViewerNetworkHelperToolStatus) -> CaptureAccessBlocker {
        switch status {
        case .notInstalled, .waitingForApproval, .installing:
            .helperMissing
        case .installedNeedsRelaunch:
            .helperNeedsRelaunch
        case .broken:
            .helperBroken
        case .unsupported:
            .accessDenied
        case .ready:
            .upgradeRevalidation
        }
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
