//
//  EndpointStatisticsWindowController.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import AppKit
import PcapPlusPlusCore

final class EndpointStatisticsWindowController: NSWindowController, NSWindowDelegate {
    var closeHandler: (() -> Void)?

    private let statisticsViewController: EndpointStatisticsViewController

    init(
        configuration: AppConfiguration,
        packetProvider: @escaping ([PacketSummary.ID]) -> [PacketSummary],
        showRelatedPackets: @escaping (EndpointStatisticsRow.ID) -> Void,
        latestIngestStateProvider: @escaping () -> PacketIngestState? = { nil }
    ) {
        statisticsViewController = EndpointStatisticsViewController(
            configuration: configuration,
            packetProvider: packetProvider,
            showRelatedPackets: showRelatedPackets,
            latestIngestStateProvider: latestIngestStateProvider
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 940, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("TCPViewer.EndpointStatisticsWindow")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = statisticsViewController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Forward every raw ingest mutation so the service remains incremental between UI refreshes.
    func consume(ingestState: PacketIngestState) {
        statisticsViewController.consume(ingestState: ingestState)
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        statisticsViewController.render(snapshot: snapshot)
    }

    func updateTitle(_ title: String) {
        window?.title = title
    }

    func present(title: String) {
        updateTitle(title)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @IBAction func focusStructuredFilter(_ sender: Any?) {
        statisticsViewController.focusSearch()
    }

    func windowWillClose(_ notification: Notification) {
        statisticsViewController.cancel()
        closeHandler?()
    }

    deinit {
        statisticsViewController.cancel()
    }
}

private protocol EndpointStatisticsTableKeyboardActionHandling: AnyObject {
    func endpointStatisticsTableDidRequestCopy(_ tableView: NSTableView)
}

private final class EndpointStatisticsTableView: NSTableView {
    weak var keyboardActionHandler: EndpointStatisticsTableKeyboardActionHandling?

    @objc func copy(_ sender: Any?) {
        keyboardActionHandler?.endpointStatisticsTableDidRequestCopy(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return
        }
        super.keyDown(with: event)
    }
}

struct EndpointStatisticsSourceIdentity: Equatable, Sendable {
    let backingIdentity: String?
    let packetLineageRevision: UInt64
}

struct EndpointStatisticsRenderedSource {
    let identity: EndpointStatisticsSourceIdentity
    let packetTableGeneration: UInt64
    let visiblePacketCount: Int
    let updatePlan: PacketTableUpdatePlan
    let isFiltering: Bool

    private let packetIDLoader: (EndpointStatisticsPacketIDSelection) -> [PacketSummary.ID]

    init(snapshot: NetworkInspectorSnapshot) {
        let rowStore = snapshot.packetTableRowStore
        let visiblePacketCount = snapshot.visiblePacketCount
        self.init(
            identity: EndpointStatisticsSourceIdentity(
                backingIdentity: snapshot.base.packetIngestState.backingIdentity,
                packetLineageRevision: snapshot.base.packetIngestState.packetLineageRevision
            ),
            packetTableGeneration: snapshot.packetTableGeneration,
            visiblePacketCount: visiblePacketCount,
            updatePlan: snapshot.packetTableUpdatePlan,
            isFiltering: snapshot.isPacketTableFiltering,
            packetIDLoader: { selection in
                switch selection {
                case .range(let range):
                    guard range.upperBound <= rowStore.rowIDs.count else {
                        return []
                    }
                    return Array(rowStore.rowIDs[range])
                case .indexes(let indexes):
                    guard indexes.last.map({ $0 < rowStore.rowIDs.count }) != false else {
                        return []
                    }
                    return indexes.map { rowStore.rowIDs[$0] }
                }
            }
        )
    }

    init(
        identity: EndpointStatisticsSourceIdentity,
        packetTableGeneration: UInt64,
        visiblePacketCount: Int,
        updatePlan: PacketTableUpdatePlan,
        isFiltering: Bool,
        packetIDLoader: @escaping (EndpointStatisticsPacketIDSelection) -> [PacketSummary.ID]
    ) {
        self.identity = identity
        self.packetTableGeneration = packetTableGeneration
        self.visiblePacketCount = visiblePacketCount
        self.updatePlan = updatePlan
        self.isFiltering = isFiltering
        self.packetIDLoader = packetIDLoader
    }

    // Load only the IDs needed by the displayed-scope delta instead of aliasing the table's buffer.
    func packetIDs(in range: Range<Int>) -> [PacketSummary.ID]? {
        guard range.lowerBound >= 0,
              range.upperBound <= visiblePacketCount else {
            return nil
        }
        let packetIDs = packetIDLoader(.range(range))
        return packetIDs.count == range.count ? packetIDs : nil
    }

    func packetIDs(at indexes: IndexSet) -> [PacketSummary.ID]? {
        guard indexes.last.map({ $0 < visiblePacketCount }) != false else {
            return nil
        }
        let packetIDs = packetIDLoader(.indexes(indexes))
        return packetIDs.count == indexes.count ? packetIDs : nil
    }
}

enum EndpointStatisticsDisplayedSourcePolicy {
    static func canLoadReplacement(
        source: EndpointStatisticsRenderedSource,
        latestSource: EndpointStatisticsRenderedSource?,
        expectedIdentity: EndpointStatisticsSourceIdentity,
        usesDisplayedPackets: Bool
    ) -> Bool {
        guard usesDisplayedPackets,
              !source.isFiltering,
              source.identity == expectedIdentity,
              let latestSource,
              !latestSource.isFiltering else {
            return false
        }
        return latestSource.identity == source.identity &&
            latestSource.packetTableGeneration == source.packetTableGeneration &&
            latestSource.visiblePacketCount == source.visiblePacketCount
    }

    // Finish the UI refresh when a display-filter job settles without changing the visible packet set.
    static func shouldPresentAfterFiltering(wasWaitingForFilter: Bool, didForward: Bool) -> Bool {
        wasWaitingForFilter && !didForward
    }
}

enum EndpointStatisticsPacketIDSelection {
    case range(Range<Int>)
    case indexes(IndexSet)

    var count: Int {
        switch self {
        case .range(let range): range.count
        case .indexes(let indexes): indexes.count
        }
    }
}

enum EndpointStatisticsDisplayedScopeForwardingResult {
    case none
    case update(EndpointStatisticsIngestUpdate)
    case replacementRequired
}

struct EndpointStatisticsDisplayedDeferredUpdate {
    let packetTableGeneration: UInt64
    let totalPacketCount: Int
    let kind: EndpointStatisticsIngestUpdate.Kind
}

struct EndpointStatisticsDisplayedReplacementAccumulator {
    struct PacketChunk: Sendable {
        let startIndex: Int
        var packets: [PacketSummary]
    }

    static let defaultChunkSize = 2_048

    private(set) var packetCount: Int
    let chunkSize: Int
    private(set) var packetChunks: [PacketChunk] = []
    private(set) var nextPacketIndex = 0

    init(packetCount: Int, chunkSize: Int = defaultChunkSize) {
        precondition(packetCount >= 0)
        precondition(chunkSize > 0)
        self.packetCount = packetCount
        self.chunkSize = chunkSize
    }

    var nextRange: Range<Int>? {
        guard nextPacketIndex < packetCount else {
            return nil
        }
        return nextPacketIndex..<min(packetCount, nextPacketIndex + chunkSize)
    }

    var isComplete: Bool {
        nextPacketIndex == packetCount
    }

    mutating func append(packetIDs: [PacketSummary.ID], packets: [PacketSummary]) -> Bool {
        guard let range = nextRange,
              packetIDs.count == range.count,
              packets.map(\.id) == packetIDs else {
            return false
        }
        packetChunks.append(PacketChunk(startIndex: range.lowerBound, packets: packets))
        nextPacketIndex = range.upperBound
        return true
    }

    mutating func extend(to packetCount: Int) -> Bool {
        guard packetCount >= self.packetCount else {
            return false
        }
        self.packetCount = packetCount
        return true
    }

    mutating func replaceLoadedPacket(at packetIndex: Int, with packet: PacketSummary) {
        guard packetIndex >= 0, packetIndex < nextPacketIndex else {
            return
        }
        guard let chunkIndex = loadedChunkIndex(containing: packetIndex) else {
            return
        }
        let indexInChunk = packetIndex - packetChunks[chunkIndex].startIndex
        guard packetChunks[chunkIndex].packets.indices.contains(indexInChunk) else {
            return
        }
        packetChunks[chunkIndex].packets[indexInChunk] = packet
    }

    private func loadedChunkIndex(containing packetIndex: Int) -> Int? {
        var lowerBound = 0
        var upperBound = packetChunks.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if packetChunks[midpoint].startIndex <= packetIndex {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound > 0 ? lowerBound - 1 : nil
    }
}

private struct EndpointStatisticsPresentationRequest: Sendable {
    let generation: UInt64
    let intent: EndpointStatisticsPresentationIntent
    let usesDisplayedPackets: Bool
    let sourceIdentity: EndpointStatisticsSourceIdentity
    let ingestCursor: EndpointStatisticsIngestCursor?
    let displayedCursor: EndpointStatisticsIngestCursor?
    let classificationRevision: UInt64
    let group: EndpointStatisticsGroup
    let searchText: String
    let sort: EndpointStatisticsTableSort

    var context: EndpointStatisticsPresentationContext {
        EndpointStatisticsPresentationContext(
            usesDisplayedPackets: usesDisplayedPackets,
            sourceIdentity: sourceIdentity,
            group: group,
            searchText: searchText,
            sort: sort
        )
    }
}

private struct EndpointStatisticsPresentationResult: Sendable {
    let request: EndpointStatisticsPresentationRequest
    let cancellationToken: EndpointStatisticsCancellationToken
    let endpointCounts: [EndpointStatisticsGroup: Int]
    let scopeTotals: EndpointStatisticsTotals
    let table: EndpointStatisticsTablePresentation
    let processingDuration: TimeInterval
}

enum EndpointStatisticsPresentationCadence {
    static let maximumRefreshRateInterval: TimeInterval = 0.25
    static let maximumCooldown: TimeInterval = 2

    static func cooldown(after processingDuration: TimeInterval) -> TimeInterval {
        guard processingDuration > maximumRefreshRateInterval else {
            return 0
        }
        return min(maximumCooldown, max(maximumRefreshRateInterval, processingDuration))
    }
}

enum EndpointStatisticsPresentationIntent: Equatable, Sendable {
    case automatic
    case explicit

    func merging(_ other: EndpointStatisticsPresentationIntent?) -> EndpointStatisticsPresentationIntent {
        self == .explicit || other == .explicit ? .explicit : .automatic
    }
}

struct EndpointStatisticsAutomaticRefreshPolicy {
    static let maximumLiveEndpointCount = 10_000

    private(set) var isPaused = false

    func accepts(_ intent: EndpointStatisticsPresentationIntent) -> Bool {
        intent == .explicit || !isPaused
    }

    mutating func didCommit(unfilteredEndpointCount: Int) {
        isPaused = unfilteredEndpointCount > Self.maximumLiveEndpointCount
    }
}

struct EndpointStatisticsDisplayedReplacementRecoveryState {
    var isPaused = false
    var pendingSourceReplacement = false

    var shouldResumeAutomatically: Bool {
        pendingSourceReplacement
    }

    // An overloaded replacement must wait for Refresh instead of retrying on every render.
    mutating func pauseForOverflow() {
        isPaused = true
        pendingSourceReplacement = false
    }

    mutating func replacementWasAccepted() {
        isPaused = false
        pendingSourceReplacement = false
    }
}

enum EndpointStatisticsFooterFormatter {
    static func trafficParts(
        totals: EndpointStatisticsTotals,
        formatBytes: (UInt64) -> String
    ) -> [String] {
        var parts = [
            formatBytes(totals.bytes),
            "Tx \(formatBytes(totals.txBytes))",
            "Rx \(formatBytes(totals.rxBytes))",
        ]
        if totals.unclassifiedBytes > 0 {
            parts.append("Unclassified \(formatBytes(totals.unclassifiedBytes))")
        }
        return parts
    }
}

struct EndpointStatisticsPresentationContext: Equatable, Sendable {
    let usesDisplayedPackets: Bool
    let sourceIdentity: EndpointStatisticsSourceIdentity
    let group: EndpointStatisticsGroup
    let searchText: String
    let sort: EndpointStatisticsTableSort
}

enum EndpointStatisticsPresentationCommitDecision: Equatable {
    case discard
    case commit
    case commitAndRefresh
}

enum EndpointStatisticsPresentationCommitPolicy {
    // Older append snapshots are coherent enough to show; lineage or query changes are not.
    static func decision(
        requestContext: EndpointStatisticsPresentationContext,
        currentContext: EndpointStatisticsPresentationContext,
        requestIngestCursor: EndpointStatisticsIngestCursor?,
        currentIngestCursor: EndpointStatisticsIngestCursor?,
        requestDisplayedCursor: EndpointStatisticsIngestCursor?,
        currentDisplayedCursor: EndpointStatisticsIngestCursor?,
        requestClassificationRevision: UInt64,
        currentClassificationRevision: UInt64,
        isWaitingForDisplayFilter: Bool
    ) -> EndpointStatisticsPresentationCommitDecision {
        guard !isWaitingForDisplayFilter,
              requestContext == currentContext,
              requestClassificationRevision == currentClassificationRevision else {
            return .discard
        }

        let requestCursor = requestContext.usesDisplayedPackets
            ? requestDisplayedCursor
            : requestIngestCursor
        let currentCursor = currentContext.usesDisplayedPackets
            ? currentDisplayedCursor
            : currentIngestCursor
        switch (requestCursor, currentCursor) {
        case (nil, nil):
            return .commit
        case (.some(let requestCursor), .some(let currentCursor)):
            guard requestCursor.packetLineageRevision == currentCursor.packetLineageRevision else {
                return .discard
            }
            return requestCursor == currentCursor ? .commit : .commitAndRefresh
        case (.none, .some), (.some, .none):
            return .discard
        }
    }
}

struct EndpointStatisticsActionState: Equatable {
    let context: EndpointStatisticsPresentationContext
    let classificationRevision: UInt64
}

enum EndpointStatisticsRowActionPolicy {
    static func isEnabled(
        committedState: EndpointStatisticsActionState?,
        currentState: EndpointStatisticsActionState,
        isWaitingForDisplayFilter: Bool
    ) -> Bool {
        !isWaitingForDisplayFilter && committedState == currentState
    }
}

struct EndpointStatisticsExportCommitToken: Equatable, Sendable {
    let generation: UInt64
    let pasteboardChangeCount: Int
}

enum EndpointStatisticsExportCommitPolicy {
    static func shouldCommit(
        _ token: EndpointStatisticsExportCommitToken,
        currentGeneration: UInt64,
        currentPasteboardChangeCount: Int
    ) -> Bool {
        token.generation == currentGeneration &&
            token.pasteboardChangeCount == currentPasteboardChangeCount
    }
}

struct EndpointStatisticsScopeUpdatePipeline {
    private var coordinator: EndpointStatisticsUpdateDrainCoordinator
    private var inFlightClassificationRevision: UInt64 = 0
    private var pendingClassificationRevision: UInt64 = 0

    private(set) var latestClassificationRevision: UInt64 = 0
    private(set) var consumedClassificationRevision: UInt64 = 0

    var isPaused: Bool {
        coordinator.isPaused
    }

    var canResume: Bool {
        coordinator.isPaused && !coordinator.isDrainInFlight
    }

    var isDrainInFlight: Bool {
        coordinator.isDrainInFlight
    }

    init(maximumPendingPacketCount: Int = 10_000) {
        coordinator = EndpointStatisticsUpdateDrainCoordinator(
            maximumPendingPacketCount: maximumPendingPacketCount
        )
    }

    mutating func enqueue(
        _ update: EndpointStatisticsIngestUpdate
    ) -> EndpointStatisticsUpdateDrainCoordinator.Action {
        if update.changesEndpointClassification {
            latestClassificationRevision &+= 1
        }
        let action = coordinator.enqueue(update)
        recordEnqueueAction(action)
        return action
    }

    // Paused pipelines track semantic changes without retaining the dropped packet payload.
    mutating func recordDroppedMutation(changesEndpointClassification: Bool) {
        if changesEndpointClassification {
            latestClassificationRevision &+= 1
        }
    }

    mutating func drainCompleted(
        result: EndpointStatisticsConsumeResult
    ) -> EndpointStatisticsUpdateDrainCoordinator.Action {
        if result == .consumed {
            consumedClassificationRevision = inFlightClassificationRevision
        }
        let action = coordinator.drainCompleted(didConsume: result == .consumed)
        recordCompletionAction(action)
        return action
    }

    mutating func resume(
        withReplacement update: EndpointStatisticsIngestUpdate
    ) -> EndpointStatisticsUpdateDrainCoordinator.Action {
        guard canResume else {
            return isPaused ? .paused : .none
        }
        latestClassificationRevision &+= 1
        let action = coordinator.resume(withReplacement: update)
        if case .drain = action {
            inFlightClassificationRevision = latestClassificationRevision
            pendingClassificationRevision = 0
        }
        return action
    }

    mutating func cancel() {
        coordinator.cancel()
        inFlightClassificationRevision = 0
        pendingClassificationRevision = 0
    }

    private mutating func recordEnqueueAction(
        _ action: EndpointStatisticsUpdateDrainCoordinator.Action
    ) {
        switch action {
        case .drain:
            inFlightClassificationRevision = latestClassificationRevision
        case .none:
            if !coordinator.isPaused {
                pendingClassificationRevision = latestClassificationRevision
            }
        case .paused:
            pendingClassificationRevision = 0
        }
    }


    private mutating func recordCompletionAction(
        _ action: EndpointStatisticsUpdateDrainCoordinator.Action
    ) {
        if case .drain = action {
            inFlightClassificationRevision = pendingClassificationRevision
        }
        pendingClassificationRevision = 0
    }
}

private extension EndpointStatisticsIngestUpdate {
    var changesEndpointClassification: Bool {
        switch kind {
        case .replace, .metadata, .appendWithMetadata:
            true
        case .append:
            false
        }
    }
}

private extension EndpointStatisticsIngestUpdate.Kind {
    var retainedPacketCountUpperBound: Int {
        switch self {
        case .replace(let packets), .append(let packets), .metadata(let packets):
            packets.count
        case .appendWithMetadata(let newPackets, let updatedPackets):
            newPackets.count + updatedPackets.count
        }
    }
}

private extension PacketIngestMutation {
    var changesEndpointClassification: Bool {
        switch self {
        case .reset, .replace, .metadataUpdate, .appendWithMetadataUpdates:
            true
        case .none, .append:
            false
        }
    }
}

private extension PacketTableUpdatePlan {
    var changesEndpointClassification: Bool {
        switch self {
        case .reload, .reloadRows, .appendAndReloadRows:
            true
        case .none, .append:
            false
        }
    }
}

struct EndpointStatisticsDisplayedScopeForwarder {
    static let maximumDeltaPacketCount = 10_000

    private(set) var cursor: EndpointStatisticsIngestCursor?
    private(set) var sourceIdentity: EndpointStatisticsSourceIdentity?
    private(set) var packetTableGeneration: UInt64?
    private(set) var packetCount = 0

    private var nextPacketRevision: UInt64 = 1
    private var nextLineageRevision: UInt64 = 1

    // Turn exact packet-table update plans into small statistics updates on the main thread.
    mutating func forwardingResult(
        from source: EndpointStatisticsRenderedSource,
        expectedSourceIdentity: EndpointStatisticsSourceIdentity,
        forceReplacement: Bool,
        packetProvider: ([PacketSummary.ID]) -> [PacketSummary]
    ) -> EndpointStatisticsDisplayedScopeForwardingResult {
        guard !source.isFiltering, source.identity == expectedSourceIdentity else {
            return .none
        }

        let sourceChanged = sourceIdentity != source.identity
        guard !forceReplacement,
              !sourceChanged,
              let currentPacketTableGeneration = packetTableGeneration else {
            return .replacementRequired
        }
        if source.packetTableGeneration == currentPacketTableGeneration {
            return source.visiblePacketCount == packetCount ? .none : .replacementRequired
        }
        guard source.packetTableGeneration == currentPacketTableGeneration &+ 1 else {
            return .replacementRequired
        }

        switch source.updatePlan {
        case .none:
            guard source.visiblePacketCount == packetCount else {
                return .replacementRequired
            }
            packetTableGeneration = source.packetTableGeneration
            return .none
        case .append(let range):
            return appendResult(
                from: source,
                appendRange: range,
                reloadIndexes: [],
                packetProvider: packetProvider
            )
        case .reload:
            return .replacementRequired
        case .reloadRows(let indexes):
            return metadataResult(from: source, indexes: indexes, packetProvider: packetProvider)
        case .appendAndReloadRows(let range, let indexes):
            return appendResult(
                from: source,
                appendRange: range,
                reloadIndexes: indexes,
                packetProvider: packetProvider
            )
        }
    }

    mutating func replacementUpdate(
        from source: EndpointStatisticsRenderedSource,
        packets: [PacketSummary]
    ) -> EndpointStatisticsIngestUpdate? {
        guard packets.count == source.visiblePacketCount else {
            return nil
        }
        nextPacketRevision &+= 1
        nextLineageRevision &+= 1
        sourceIdentity = source.identity
        packetTableGeneration = source.packetTableGeneration
        packetCount = source.visiblePacketCount
        let update = EndpointStatisticsIngestUpdate(
            packetRevision: nextPacketRevision,
            packetLineageRevision: nextLineageRevision,
            totalPacketCount: packetCount,
            kind: .replace(packets)
        )
        cursor = update.cursor
        return update
    }

    mutating func deferredUpdate(
        _ deferredUpdate: EndpointStatisticsDisplayedDeferredUpdate
    ) -> EndpointStatisticsIngestUpdate? {
        guard sourceIdentity != nil,
              packetTableGeneration.map({ deferredUpdate.packetTableGeneration == $0 &+ 1 }) == true else {
            return nil
        }
        let expectedPacketCount: Int
        switch deferredUpdate.kind {
        case .append(let packets):
            expectedPacketCount = packetCount + packets.count
        case .appendWithMetadata(let newPackets, _):
            expectedPacketCount = packetCount + newPackets.count
        case .metadata:
            expectedPacketCount = packetCount
        case .replace:
            return nil
        }
        guard deferredUpdate.totalPacketCount == expectedPacketCount else {
            return nil
        }
        nextPacketRevision &+= 1
        packetTableGeneration = deferredUpdate.packetTableGeneration
        packetCount = deferredUpdate.totalPacketCount
        let update = EndpointStatisticsIngestUpdate(
            packetRevision: nextPacketRevision,
            packetLineageRevision: nextLineageRevision,
            totalPacketCount: packetCount,
            kind: deferredUpdate.kind
        )
        cursor = update.cursor
        return update
    }

    private mutating func appendResult(
        from source: EndpointStatisticsRenderedSource,
        appendRange: Range<Int>,
        reloadIndexes: IndexSet,
        packetProvider: ([PacketSummary.ID]) -> [PacketSummary]
    ) -> EndpointStatisticsDisplayedScopeForwardingResult {
        guard appendRange.count <= Self.maximumDeltaPacketCount,
              reloadIndexes.count <= Self.maximumDeltaPacketCount - appendRange.count else {
            return .replacementRequired
        }
        guard appendRange.lowerBound == packetCount,
              appendRange.upperBound == source.visiblePacketCount,
              appendRange.lowerBound >= 0,
              appendRange.lowerBound < appendRange.upperBound else {
            return .replacementRequired
        }

        guard let appendedIDs = source.packetIDs(in: appendRange) else {
            return .replacementRequired
        }
        let appendedPackets = packetProvider(appendedIDs)
        guard appendedPackets.map(\.id) == appendedIDs else {
            return .replacementRequired
        }
        let validReloadIndexes = IndexSet(reloadIndexes.filter { $0 >= 0 && $0 < source.visiblePacketCount })
        let updatedIDs: [PacketSummary.ID]
        if validReloadIndexes.isEmpty {
            updatedIDs = []
        } else {
            guard let loadedIDs = source.packetIDs(at: validReloadIndexes) else {
                return .replacementRequired
            }
            updatedIDs = loadedIDs
        }
        let updatedPackets = packetProvider(updatedIDs)
        guard updatedPackets.map(\.id) == updatedIDs else {
            return .replacementRequired
        }
        nextPacketRevision &+= 1
        packetTableGeneration = source.packetTableGeneration
        packetCount = source.visiblePacketCount
        let kind: EndpointStatisticsIngestUpdate.Kind = updatedPackets.isEmpty
            ? .append(appendedPackets)
            : .appendWithMetadata(newPackets: appendedPackets, updatedPackets: updatedPackets)
        let update = EndpointStatisticsIngestUpdate(
            packetRevision: nextPacketRevision,
            packetLineageRevision: nextLineageRevision,
            totalPacketCount: packetCount,
            kind: kind
        )
        cursor = update.cursor
        return .update(update)
    }

    private mutating func metadataResult(
        from source: EndpointStatisticsRenderedSource,
        indexes: IndexSet,
        packetProvider: ([PacketSummary.ID]) -> [PacketSummary]
    ) -> EndpointStatisticsDisplayedScopeForwardingResult {
        guard indexes.count <= Self.maximumDeltaPacketCount else {
            return .replacementRequired
        }
        let validIndexes = IndexSet(indexes.filter { $0 >= 0 && $0 < source.visiblePacketCount })
        guard !validIndexes.isEmpty else {
            packetTableGeneration = source.packetTableGeneration
            return .none
        }
        guard let updatedIDs = source.packetIDs(at: validIndexes) else {
            return .replacementRequired
        }
        let updatedPackets = packetProvider(updatedIDs)
        guard updatedPackets.map(\.id) == updatedIDs else {
            return .replacementRequired
        }
        nextPacketRevision &+= 1
        packetTableGeneration = source.packetTableGeneration
        packetCount = source.visiblePacketCount
        let update = EndpointStatisticsIngestUpdate(
            packetRevision: nextPacketRevision,
            packetLineageRevision: nextLineageRevision,
            totalPacketCount: packetCount,
            kind: .metadata(updatedPackets)
        )
        cursor = update.cursor
        return .update(update)
    }
}

enum EndpointStatisticsRawDeltaPolicy {
    static let maximumPacketCount = 10_000

    static func exceedsAutomaticLimit(_ mutation: PacketIngestMutation) -> Bool {
        switch mutation {
        case .append(let range):
            return range.count > maximumPacketCount
        case .appendWithMetadataUpdates(let range, let packetIDs):
            return range.count > maximumPacketCount ||
                packetIDs.count > maximumPacketCount - range.count
        case .metadataUpdate(let packetIDs):
            return packetIDs.count > maximumPacketCount
        case .none, .reset, .replace:
            return false
        }
    }
}

enum EndpointStatisticsReplacementMode: Equatable {
    case enqueue
    case resume
}

enum EndpointStatisticsDisplayedReplacementUpdateResult: Equatable {
    case updated
    case incompatible
    case overflow
}

final class EndpointStatisticsDisplayedReplacementWork {
    static let maximumMetadataPatchCount = 10_000

    private(set) var source: EndpointStatisticsRenderedSource
    let mode: EndpointStatisticsReplacementMode
    private(set) var cancellationToken = EndpointStatisticsCancellationToken()
    var accumulator: EndpointStatisticsDisplayedReplacementAccumulator
    var isContinuationScheduled = false
    var isFlattening = false
    private(set) var deferredUpdates: [EndpointStatisticsDisplayedDeferredUpdate] = []
    private(set) var retainedDeferredPacketCount = 0
    private var logicalPacketCount: Int

    init(source: EndpointStatisticsRenderedSource, mode: EndpointStatisticsReplacementMode) {
        self.source = source
        self.mode = mode
        accumulator = EndpointStatisticsDisplayedReplacementAccumulator(
            packetCount: source.visiblePacketCount
        )
        logicalPacketCount = source.visiblePacketCount
    }

    // Preserve loaded chunks across exact append/reload deltas so a busy table cannot starve replacement.
    func update(
        to nextSource: EndpointStatisticsRenderedSource,
        packetProvider: ([PacketSummary.ID]) -> [PacketSummary]
    ) -> EndpointStatisticsDisplayedReplacementUpdateResult {
        guard !nextSource.isFiltering,
              nextSource.identity == source.identity else {
            return .incompatible
        }
        if nextSource.packetTableGeneration == source.packetTableGeneration {
            guard nextSource.visiblePacketCount == source.visiblePacketCount else {
                return .incompatible
            }
            source = nextSource
            return .updated
        }
        guard nextSource.packetTableGeneration == source.packetTableGeneration &+ 1 else {
            return .incompatible
        }

        let appendRange: Range<Int>?
        let reloadIndexes: IndexSet
        switch nextSource.updatePlan {
        case .none:
            appendRange = nil
            reloadIndexes = []
        case .append(let range):
            appendRange = range
            reloadIndexes = []
        case .reloadRows(let indexes):
            appendRange = nil
            reloadIndexes = indexes
        case .appendAndReloadRows(let range, let indexes):
            appendRange = range
            reloadIndexes = indexes
        case .reload:
            return .incompatible
        }
        guard reloadIndexes.count <= Self.maximumMetadataPatchCount else {
            return .overflow
        }
        if isFlattening {
            return deferUpdate(
                from: nextSource,
                appendRange: appendRange,
                reloadIndexes: reloadIndexes,
                packetProvider: packetProvider
            )
        }
        if let appendRange {
            guard appendRange.lowerBound == accumulator.packetCount,
                  appendRange.upperBound == nextSource.visiblePacketCount,
                  accumulator.extend(to: nextSource.visiblePacketCount) else {
                return .incompatible
            }
        } else if nextSource.visiblePacketCount != accumulator.packetCount {
            return .incompatible
        }

        let loadedIndexes = IndexSet(reloadIndexes.filter { $0 >= 0 && $0 < accumulator.nextPacketIndex })
        if !loadedIndexes.isEmpty {
            guard let packetIDs = nextSource.packetIDs(at: loadedIndexes) else {
                return .incompatible
            }
            let packets = packetProvider(packetIDs)
            guard packets.map(\.id) == packetIDs else {
                return .incompatible
            }
            for (packetIndex, packet) in zip(loadedIndexes, packets) {
                accumulator.replaceLoadedPacket(at: packetIndex, with: packet)
            }
        }

        cancellationToken.cancel()
        cancellationToken = EndpointStatisticsCancellationToken()
        isFlattening = false
        source = nextSource
        logicalPacketCount = nextSource.visiblePacketCount
        return .updated
    }

    func acceptsFlattenedPackets(
        token: EndpointStatisticsCancellationToken,
        packetCount: Int,
        flattenedPacketCount: Int
    ) -> Bool {
        cancellationToken === token &&
            accumulator.packetCount == packetCount &&
            flattenedPacketCount == packetCount &&
            !token.isCancelled()
    }

    private func deferUpdate(
        from nextSource: EndpointStatisticsRenderedSource,
        appendRange: Range<Int>?,
        reloadIndexes: IndexSet,
        packetProvider: ([PacketSummary.ID]) -> [PacketSummary]
    ) -> EndpointStatisticsDisplayedReplacementUpdateResult {
        let appendCount = appendRange?.count ?? 0
        if let appendRange {
            guard appendRange.lowerBound == logicalPacketCount,
                  appendRange.upperBound == nextSource.visiblePacketCount else {
                return .incompatible
            }
        } else if nextSource.visiblePacketCount != logicalPacketCount {
            return .incompatible
        }
        guard appendCount <= Self.maximumMetadataPatchCount,
              reloadIndexes.count <= Self.maximumMetadataPatchCount - appendCount,
              appendCount + reloadIndexes.count <= Self.maximumMetadataPatchCount - retainedDeferredPacketCount else {
            return .overflow
        }
        if let appendRange {
            guard let packetIDs = nextSource.packetIDs(in: appendRange) else {
                return .incompatible
            }
            let newPackets = packetProvider(packetIDs)
            guard newPackets.map(\.id) == packetIDs else {
                return .incompatible
            }
            guard let updatedPackets = resolvedPackets(
                at: reloadIndexes,
                from: nextSource,
                packetProvider: packetProvider
            ) else {
                return .incompatible
            }
            let kind: EndpointStatisticsIngestUpdate.Kind = updatedPackets.isEmpty
                ? .append(newPackets)
                : .appendWithMetadata(newPackets: newPackets, updatedPackets: updatedPackets)
            appendDeferredUpdate(kind, source: nextSource, retainedPacketCount: appendCount + reloadIndexes.count)
            return .updated
        }
        guard let updatedPackets = resolvedPackets(
                at: reloadIndexes,
                from: nextSource,
                packetProvider: packetProvider
              ) else {
            return .incompatible
        }
        appendDeferredUpdate(
            .metadata(updatedPackets),
            source: nextSource,
            retainedPacketCount: reloadIndexes.count
        )
        return .updated
    }

    private func resolvedPackets(
        at indexes: IndexSet,
        from source: EndpointStatisticsRenderedSource,
        packetProvider: ([PacketSummary.ID]) -> [PacketSummary]
    ) -> [PacketSummary]? {
        guard !indexes.isEmpty else {
            return []
        }
        let validIndexes = IndexSet(indexes.filter { $0 >= 0 && $0 < source.visiblePacketCount })
        guard validIndexes.count == indexes.count,
              let packetIDs = source.packetIDs(at: validIndexes) else {
            return nil
        }
        let packets = packetProvider(packetIDs)
        return packets.map(\.id) == packetIDs ? packets : nil
    }

    private func appendDeferredUpdate(
        _ kind: EndpointStatisticsIngestUpdate.Kind,
        source: EndpointStatisticsRenderedSource,
        retainedPacketCount: Int
    ) {
        deferredUpdates.append(EndpointStatisticsDisplayedDeferredUpdate(
            packetTableGeneration: source.packetTableGeneration,
            totalPacketCount: source.visiblePacketCount,
            kind: kind
        ))
        self.retainedDeferredPacketCount += retainedPacketCount
        logicalPacketCount = source.visiblePacketCount
        self.source = source
    }
}

final class EndpointStatisticsRawReplacementWork {
    let sourceIdentity: EndpointStatisticsSourceIdentity
    let mode: EndpointStatisticsReplacementMode
    var packetRevision: UInt64
    var cancellationToken = EndpointStatisticsCancellationToken()
    var accumulator: EndpointStatisticsDisplayedReplacementAccumulator
    var isContinuationScheduled = false
    var isFlattening = false
    private(set) var deferredUpdates: [EndpointStatisticsIngestUpdate] = []
    private(set) var retainedDeferredPacketCount = 0
    private(set) var logicalPacketCount: Int

    init(
        sourceIdentity: EndpointStatisticsSourceIdentity,
        packetRevision: UInt64,
        packetCount: Int,
        mode: EndpointStatisticsReplacementMode
    ) {
        self.sourceIdentity = sourceIdentity
        self.packetRevision = packetRevision
        self.mode = mode
        accumulator = EndpointStatisticsDisplayedReplacementAccumulator(packetCount: packetCount)
        logicalPacketCount = packetCount
    }

    func prepareForMorePackets(packetRevision: UInt64, packetCount: Int) -> Bool {
        guard accumulator.extend(to: packetCount) else {
            return false
        }
        cancellationToken.cancel()
        cancellationToken = EndpointStatisticsCancellationToken()
        isFlattening = false
        self.packetRevision = packetRevision
        logicalPacketCount = packetCount
        return true
    }

    func prepareForMetadata(packetRevision: UInt64) {
        cancellationToken.cancel()
        cancellationToken = EndpointStatisticsCancellationToken()
        isFlattening = false
        self.packetRevision = packetRevision
    }

    func deferUpdate(_ update: EndpointStatisticsIngestUpdate, maximumPacketCount: Int) -> Bool {
        guard update.previousPacketRevision == packetRevision,
              update.packetLineageRevision == sourceIdentity.packetLineageRevision else {
            return false
        }
        let expectedPacketCount: Int
        switch update.kind {
        case .append(let packets):
            expectedPacketCount = logicalPacketCount + packets.count
        case .appendWithMetadata(let newPackets, _):
            expectedPacketCount = logicalPacketCount + newPackets.count
        case .metadata:
            expectedPacketCount = logicalPacketCount
        case .replace:
            return false
        }
        let retainedPacketCount = update.kind.retainedPacketCountUpperBound
        guard update.totalPacketCount == expectedPacketCount,
              retainedPacketCount <= maximumPacketCount - retainedDeferredPacketCount else {
            return false
        }
        deferredUpdates.append(update)
        retainedDeferredPacketCount += retainedPacketCount
        packetRevision = update.packetRevision
        logicalPacketCount = update.totalPacketCount
        return true
    }

    func acceptsFlattenedPackets(
        token: EndpointStatisticsCancellationToken,
        packetRevision: UInt64,
        packetCount: Int,
        flattenedPacketCount: Int
    ) -> Bool {
        cancellationToken === token &&
            packetRevision <= self.packetRevision &&
            accumulator.packetCount == packetCount &&
            flattenedPacketCount == packetCount &&
            !token.isCancelled()
    }
}

private final class EndpointStatisticsViewController: NSViewController {
    private let configuration: AppConfiguration
    private let packetProvider: ([PacketSummary.ID]) -> [PacketSummary]
    private let showRelatedPackets: (EndpointStatisticsRow.ID) -> Void
    private let latestIngestStateProvider: () -> PacketIngestState?
    private let allPacketsQueue = DispatchQueue(
        label: "com.proxyman.tcpviewer.endpoint-statistics.all",
        qos: .userInitiated
    )
    private let displayedPacketsQueue = DispatchQueue(
        label: "com.proxyman.tcpviewer.endpoint-statistics.displayed",
        qos: .userInitiated
    )
    private let exportQueue = DispatchQueue(
        label: "com.proxyman.tcpviewer.endpoint-statistics.export",
        qos: .userInitiated
    )
    private let allPacketsService = EndpointStatisticsService()
    private let displayedPacketsService = EndpointStatisticsService()
    private let allPacketsCancellationToken = EndpointStatisticsCancellationToken()
    private let displayedPacketsCancellationToken = EndpointStatisticsCancellationToken()

    private let segmentControl = NSSegmentedControl()
    private let displayedPacketsCheckbox = NSButton(checkboxWithTitle: "Displayed packets only", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = EndpointStatisticsTableView()
    private let footerLabel = NSTextField(labelWithString: "No endpoints")
    private let progressIndicator = NSProgressIndicator()
    private let calculatingLabel = NSTextField(labelWithString: "Calculating…")
    private let refreshNoticeLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let numberFormatter: NumberFormatter
    private let byteCountFormatter: ByteCountFormatter

    private let columnServices: [EndpointStatisticsGroup: PacketTableColumnService]
    private let columnStores: [EndpointStatisticsGroup: PacketTableColumnLayoutStore]
    private var columnVisibilityMenuController: PacketTableColumnVisibilityMenuController?
    private var isApplyingColumnLayout = false
    private var sortByGroup = Dictionary(
        uniqueKeysWithValues: EndpointStatisticsGroup.allCases.map { ($0, EndpointStatisticsTableSort.busiestFirst) }
    )

    private var selectedGroup: EndpointStatisticsGroup = .apps
    private var rows: [EndpointStatisticsRow] = []
    private var rowIndexByID: [EndpointStatisticsRow.ID: Int] = [:]
    private var latestRenderedSource: EndpointStatisticsRenderedSource?
    private var latestSourceIdentity = EndpointStatisticsSourceIdentity(backingIdentity: nil, packetLineageRevision: 0)
    private var ingestCursor: EndpointStatisticsIngestCursor?
    private var consumedIngestCursor: EndpointStatisticsIngestCursor?
    private var rawReplacementWork: EndpointStatisticsRawReplacementWork?
    private var isRawReplacementPaused = false
    private var displayedForwarder = EndpointStatisticsDisplayedScopeForwarder()
    private var displayedReplacementWork: EndpointStatisticsDisplayedReplacementWork?
    private var displayedReplacementRecoveryState = EndpointStatisticsDisplayedReplacementRecoveryState()
    private var isDisplayedReplacementPaused: Bool {
        get { displayedReplacementRecoveryState.isPaused }
        set { displayedReplacementRecoveryState.isPaused = newValue }
    }
    private var consumedDisplayedCursor: EndpointStatisticsIngestCursor?
    private var allPacketsPipeline = EndpointStatisticsScopeUpdatePipeline()
    private var displayedPacketsPipeline = EndpointStatisticsScopeUpdatePipeline()
    private var needsDisplayedReplacement = true
    private var pendingAllPacketsSourceReplacement = false
    private var pendingDisplayedPacketsSourceReplacement: Bool {
        get { displayedReplacementRecoveryState.pendingSourceReplacement }
        set { displayedReplacementRecoveryState.pendingSourceReplacement = newValue }
    }
    private var waitsForAllPacketsManualRefresh = false
    private var waitsForDisplayedPacketsManualRefresh = false
    private var allPacketsPresentationIntentAfterDrain: EndpointStatisticsPresentationIntent?
    private var displayedPacketsPresentationIntentAfterDrain: EndpointStatisticsPresentationIntent?

    private var presentationGeneration: UInt64 = 0
    private var scheduledPresentationWorkItem: DispatchWorkItem?
    private var isPresentationInFlight = false
    private var activePresentationCancellationToken: EndpointStatisticsCancellationToken?
    private var pendingPresentationIntent: EndpointStatisticsPresentationIntent?
    private var lastPresentationStartTime: TimeInterval = 0
    private var nextPresentationAllowedTime: TimeInterval = 0
    private var automaticRefreshPolicy = EndpointStatisticsAutomaticRefreshPolicy()
    private var contextTarget = EndpointStatisticsContextTarget.none
    private var exportGeneration: UInt64 = 0
    private var activeExportCancellationToken: EndpointStatisticsCancellationToken?
    private var isWaitingForDisplayFilter = false
    private var committedActionState: EndpointStatisticsActionState?
    private var isCancelled = false

    init(
        configuration: AppConfiguration,
        packetProvider: @escaping ([PacketSummary.ID]) -> [PacketSummary],
        showRelatedPackets: @escaping (EndpointStatisticsRow.ID) -> Void,
        latestIngestStateProvider: @escaping () -> PacketIngestState?
    ) {
        self.configuration = configuration
        self.packetProvider = packetProvider
        self.showRelatedPackets = showRelatedPackets
        self.latestIngestStateProvider = latestIngestStateProvider

        var services: [EndpointStatisticsGroup: PacketTableColumnService] = [:]
        var stores: [EndpointStatisticsGroup: PacketTableColumnLayoutStore] = [:]
        for group in EndpointStatisticsGroup.allCases {
            let service = PacketTableColumnService(definitions: Self.columnDefinitions(for: group))
            let store = PacketTableColumnLayoutStore(
                defaults: configuration.userDefaults,
                key: "TCPViewer.endpointStatistics.columns.v1.\(group.rawValue)"
            )
            if let layout = store.load() {
                service.applyVisibility(from: layout)
            }
            services[group] = service
            stores[group] = store
        }
        columnServices = services
        columnStores = stores

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.maximumFractionDigits = 0
        self.numberFormatter = numberFormatter

        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.countStyle = .file
        byteCountFormatter.allowedUnits = [.useAll]
        byteCountFormatter.includesUnit = true
        self.byteCountFormatter = byteCountFormatter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        activeExportCancellationToken?.cancel()
        activeExportCancellationToken = nil
        exportGeneration &+= 1
        scheduledPresentationWorkItem?.cancel()
        scheduledPresentationWorkItem = nil
        rawReplacementWork?.cancellationToken.cancel()
        rawReplacementWork = nil
        displayedReplacementWork?.cancellationToken.cancel()
        displayedReplacementWork = nil
        allPacketsCancellationToken.cancel()
        displayedPacketsCancellationToken.cancel()
        activePresentationCancellationToken?.cancel()
        activePresentationCancellationToken = nil
        allPacketsPipeline.cancel()
        displayedPacketsPipeline.cancel()
    }

    override func loadView() {
        view = NSView()
        setupControls()
        setupTable()
        setupLayout()
        applyColumnLayout(for: selectedGroup)
        applySortDescriptor(currentSort)
        updateSegmentLabels(counts: [:])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appConfigurationDidChange(_:)),
            name: AppConfiguration.didChangeNotification,
            object: configuration
        )
    }

    // Convert a main-thread ingest state into a small owned update before crossing queues.
    func consume(ingestState: PacketIngestState) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCancelled else {
            return
        }
        let sourceIdentity = EndpointStatisticsSourceIdentity(
            backingIdentity: ingestState.backingIdentity,
            packetLineageRevision: ingestState.packetLineageRevision
        )
        if ingestCursor?.packetRevision == ingestState.packetRevision,
           latestSourceIdentity == sourceIdentity {
            return
        }
        let sourceChanged = latestSourceIdentity != sourceIdentity
        if sourceChanged {
            needsDisplayedReplacement = true
            displayedReplacementWork?.cancellationToken.cancel()
            displayedReplacementWork = nil
            if usesDisplayedPackets {
                scheduledPresentationWorkItem?.cancel()
                scheduledPresentationWorkItem = nil
                presentationGeneration &+= 1
                pendingPresentationIntent = .explicit
                abandonActivePresentation()
                setCalculating(true, text: "Updating displayed packets…")
            }
        }
        if sourceChanged, displayedPacketsPipeline.isPaused || isDisplayedReplacementPaused {
            pendingDisplayedPacketsSourceReplacement = true
        }
        let previousIngestCursor = ingestCursor
        ingestCursor = EndpointStatisticsIngestCursor(
            packetRevision: ingestState.packetRevision,
            packetLineageRevision: ingestState.packetLineageRevision,
            totalPacketCount: ingestState.packets.count
        )
        latestSourceIdentity = sourceIdentity

        if let rawReplacementWork {
            updateRawReplacement(
                rawReplacementWork,
                from: ingestState,
                sourceIdentity: sourceIdentity
            )
            if sourceChanged {
                recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: false)
            }
            return
        }
        if isRawReplacementPaused {
            allPacketsPipeline.recordDroppedMutation(
                changesEndpointClassification: ingestState.lastMutation.changesEndpointClassification
            )
            if sourceChanged {
                pendingAllPacketsSourceReplacement = true
                startRawReplacement(
                    from: ingestState,
                    mode: allPacketsPipeline.canResume ? .resume : .enqueue
                )
                recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: false)
            } else {
                updateRefreshNotice()
            }
            return
        }
        if allPacketsPipeline.isPaused {
            if sourceChanged {
                pendingAllPacketsSourceReplacement = true
                allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
                if allPacketsPipeline.canResume {
                    startRawReplacement(from: ingestState, mode: .resume)
                }
            } else {
                allPacketsPipeline.recordDroppedMutation(
                    changesEndpointClassification: ingestState.lastMutation.changesEndpointClassification
                )
            }
            updateRefreshNotice()
            return
        }

        if !sourceChanged,
           EndpointStatisticsRawDeltaPolicy.exceedsAutomaticLimit(ingestState.lastMutation) {
            allPacketsPipeline.recordDroppedMutation(
                changesEndpointClassification: ingestState.lastMutation.changesEndpointClassification
            )
            isRawReplacementPaused = true
            waitsForAllPacketsManualRefresh = false
            updateRefreshNotice()
            return
        }

        let update = EndpointStatisticsIngestUpdate(
            ingestState: ingestState,
            previousCursor: previousIngestCursor
        )
        if case .replace = update.kind {
            allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            startRawReplacement(from: ingestState, mode: .enqueue)
            if sourceChanged {
                recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: false)
            }
            return
        }
        let action = allPacketsPipeline.enqueue(update)
        if sourceChanged, case .paused = action {
            pendingAllPacketsSourceReplacement = true
        }
        handleAllPacketsDrainAction(action)
        if sourceChanged {
            recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: false)
        }
    }

    func render(snapshot: NetworkInspectorSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCancelled else {
            return
        }
        // This descriptor retains the row store, not its Array value, so all-packet renders stay CoW-free.
        let source = EndpointStatisticsRenderedSource(snapshot: snapshot)
        latestRenderedSource = source
        if usesDisplayedPackets {
            if source.isFiltering {
                isWaitingForDisplayFilter = true
                presentationGeneration &+= 1
                pendingPresentationIntent = nil
                abandonActivePresentation()
                setCalculating(true, text: "Updating displayed packets…")
            } else {
                let wasWaitingForFilter = isWaitingForDisplayFilter
                isWaitingForDisplayFilter = false
                if displayedPacketsPipeline.isPaused || isDisplayedReplacementPaused {
                    displayedPacketsPipeline.recordDroppedMutation(
                        changesEndpointClassification: source.updatePlan.changesEndpointClassification
                    )
                    if waitsForDisplayedPacketsManualRefresh ||
                        displayedReplacementRecoveryState.shouldResumeAutomatically {
                        resumeDisplayedPacketsForSourceReplacement(source)
                    }
                    updateRefreshNotice()
                    return
                }
                let forcedReplacement = needsDisplayedReplacement
                let didForward = consumeDisplayedSource(source, forceReplacement: forcedReplacement)
                if forcedReplacement && didForward {
                    recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: true)
                } else if EndpointStatisticsDisplayedSourcePolicy.shouldPresentAfterFiltering(
                    wasWaitingForFilter: wasWaitingForFilter,
                    didForward: didForward
                ) {
                    requestPresentation(intent: .explicit)
                }
            }
        }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    private var usesDisplayedPackets: Bool {
        displayedPacketsCheckbox.state == .on
    }

    private var currentPipelineIsPaused: Bool {
        usesDisplayedPackets
            ? displayedPacketsPipeline.isPaused || isDisplayedReplacementPaused
            : allPacketsPipeline.isPaused || isRawReplacementPaused
    }

    private var currentPipelineIsDraining: Bool {
        usesDisplayedPackets
            ? displayedPacketsPipeline.isDrainInFlight || displayedReplacementWork != nil
            : allPacketsPipeline.isDrainInFlight || rawReplacementWork != nil
    }

    private var currentSort: EndpointStatisticsTableSort {
        sortByGroup[selectedGroup] ?? .busiestFirst
    }

    private var currentPresentationContext: EndpointStatisticsPresentationContext {
        EndpointStatisticsPresentationContext(
            usesDisplayedPackets: usesDisplayedPackets,
            sourceIdentity: latestSourceIdentity,
            group: selectedGroup,
            searchText: searchField.stringValue,
            sort: currentSort
        )
    }

    private var currentActionState: EndpointStatisticsActionState {
        return EndpointStatisticsActionState(
            context: currentPresentationContext,
            classificationRevision: usesDisplayedPackets
                ? displayedPacketsPipeline.latestClassificationRevision
                : allPacketsPipeline.latestClassificationRevision
        )
    }

    private var rowsAreActionable: Bool {
        EndpointStatisticsRowActionPolicy.isEnabled(
            committedState: committedActionState,
            currentState: currentActionState,
            isWaitingForDisplayFilter: isWaitingForDisplayFilter
        )
    }

    private var currentColumnService: PacketTableColumnService? {
        columnServices[selectedGroup]
    }

    private func setupControls() {
        segmentControl.segmentCount = EndpointStatisticsGroup.allCases.count
        segmentControl.trackingMode = .selectOne
        segmentControl.segmentStyle = .rounded
        segmentControl.selectedSegment = 0
        segmentControl.target = self
        segmentControl.action = #selector(groupChanged(_:))
        segmentControl.setAccessibilityLabel("Endpoint type")

        displayedPacketsCheckbox.target = self
        displayedPacketsCheckbox.action = #selector(displayedPacketsScopeChanged(_:))
        displayedPacketsCheckbox.toolTip = "Use the packets currently shown in the main table."

        searchField.placeholderString = "Search endpoints"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search endpoints")

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        calculatingLabel.textColor = .secondaryLabelColor
        calculatingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        calculatingLabel.isHidden = true

        footerLabel.textColor = .secondaryLabelColor
        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.lineBreakMode = .byTruncatingTail

        refreshNoticeLabel.textColor = .secondaryLabelColor
        refreshNoticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        refreshNoticeLabel.lineBreakMode = .byTruncatingTail
        refreshNoticeLabel.isHidden = true
        refreshButton.controlSize = .small
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshStatistics(_:))
        refreshButton.isHidden = true
    }

    private func setupTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.keyboardActionHandler = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.rowHeight = configuration.packetRowHeight
        tableView.intercellSpacing = .zero
        tableView.target = self
        tableView.doubleAction = #selector(showRelatedPacketsFromDoubleClick(_:))
        tableView.menu = makeContextMenu()

        Self.columnDefinitions(for: .tcp).forEach(addColumn)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
    }

    // Keep the common controls visible while the table consumes the flexible window area.
    private func setupLayout() {
        let topStack = NSStackView(views: [segmentControl, displayedPacketsCheckbox, searchField])
        topStack.orientation = .horizontal
        topStack.alignment = .centerY
        topStack.spacing = 12
        segmentControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentHuggingPriority(.required, for: .horizontal)

        let calculationStack = NSStackView(views: [progressIndicator, calculatingLabel])
        calculationStack.orientation = .horizontal
        calculationStack.alignment = .centerY
        calculationStack.spacing = 5

        let refreshStack = NSStackView(views: [refreshNoticeLabel, refreshButton])
        refreshStack.orientation = .horizontal
        refreshStack.alignment = .centerY
        refreshStack.spacing = 6

        let footerStack = NSStackView(views: [footerLabel, refreshStack, calculationStack])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshNoticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        calculationStack.setContentHuggingPriority(.required, for: .horizontal)

        [topStack, scrollView, footerStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -6),

            footerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            footerStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
    }

    private func addColumn(_ definition: PacketTableColumnDefinition) {
        guard let column = EndpointStatisticsTableColumn(rawValue: definition.identifier) else {
            return
        }
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.identifier))
        tableColumn.title = definition.title
        tableColumn.width = CGFloat(definition.defaultWidth)
        tableColumn.minWidth = CGFloat(definition.minimumWidth)
        tableColumn.resizingMask = column == .summary
            ? [.userResizingMask, .autoresizingMask]
            : .userResizingMask
        tableColumn.dataCell = cell(for: definition)
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(
            key: column.rawValue,
            ascending: !column.isNumeric
        )
        tableView.addTableColumn(tableColumn)
    }

    private func cell(for definition: PacketTableColumnDefinition) -> NSCell {
        let cell: NSCell
        switch definition.cellKind {
        case .text:
            cell = PacketTextCell()
        case .client:
            cell = PacketClientCell()
        case .protocol:
            cell = PacketProtocolCell()
        }
        if let column = EndpointStatisticsTableColumn(rawValue: definition.identifier) {
            cell.alignment = Self.alignment(for: column)
        }
        return cell
    }

    private func consumeDisplayedSource(
        _ source: EndpointStatisticsRenderedSource,
        forceReplacement: Bool
    ) -> Bool {
        let result = displayedForwarder.forwardingResult(
            from: source,
            expectedSourceIdentity: latestSourceIdentity,
            forceReplacement: forceReplacement,
            packetProvider: packetProvider
        )
        switch result {
        case .none:
            return false
        case .replacementRequired:
            if source.updatePlan.changesEndpointClassification,
               displayedReplacementWork?.source.packetTableGeneration != source.packetTableGeneration {
                displayedPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            }
            return startDisplayedReplacement(from: source, mode: .enqueue)
        case .update(let update):
            let action = displayedPacketsPipeline.enqueue(update)
            handleDisplayedPacketsDrainAction(action)
            return true
        }
    }

    // Resolve a large displayed replacement in run-loop chunks, then flatten its chunks off-main.
    private func startDisplayedReplacement(
        from source: EndpointStatisticsRenderedSource,
        mode: EndpointStatisticsReplacementMode
    ) -> Bool {
        guard isCurrentDisplayedSource(source) else {
            needsDisplayedReplacement = true
            return false
        }
        if let work = displayedReplacementWork, work.mode == mode {
            switch work.update(to: source, packetProvider: packetProvider) {
            case .updated:
                scheduleDisplayedReplacementContinuation(work)
                return true
            case .overflow:
                pauseDisplayedReplacement(work)
                return false
            case .incompatible:
                break
            }
        }

        displayedReplacementWork?.cancellationToken.cancel()
        let work = EndpointStatisticsDisplayedReplacementWork(source: source, mode: mode)
        displayedReplacementWork = work
        isDisplayedReplacementPaused = false
        needsDisplayedReplacement = true
        setCalculating(true, text: "Loading displayed endpoints…")
        scheduleDisplayedReplacementContinuation(work)
        return true
    }

    private func continueDisplayedReplacement(_ work: EndpointStatisticsDisplayedReplacementWork) {
        guard displayedReplacementWork === work,
              !work.cancellationToken.isCancelled(),
              isCurrentDisplayedSource(work.source) else {
            cancelDisplayedReplacement(work)
            return
        }
        guard let range = work.accumulator.nextRange else {
            flattenDisplayedReplacement(work)
            return
        }
        guard let packetIDs = work.source.packetIDs(in: range) else {
            cancelDisplayedReplacement(work)
            return
        }
        let packets = packetProvider(packetIDs)
        guard work.accumulator.append(packetIDs: packetIDs, packets: packets) else {
            cancelDisplayedReplacement(work)
            return
        }
        scheduleDisplayedReplacementContinuation(work)
    }

    private func flattenDisplayedReplacement(_ work: EndpointStatisticsDisplayedReplacementWork) {
        guard !work.isFlattening else {
            return
        }
        work.isFlattening = true
        let chunks = work.accumulator.packetChunks
        let packetCount = work.accumulator.packetCount
        let source = work.source
        let cancellationToken = work.cancellationToken
        displayedPacketsQueue.async { [weak self, weak work] in
            var packets: [PacketSummary] = []
            packets.reserveCapacity(packetCount)
            for chunk in chunks {
                guard !cancellationToken.isCancelled() else {
                    return
                }
                packets.append(contentsOf: chunk.packets)
            }
            DispatchQueue.main.async {
                guard let self, let work else {
                    return
                }
                self.finishDisplayedReplacement(
                    work,
                    source: source,
                    cancellationToken: cancellationToken,
                    packetCount: packetCount,
                    packets: packets
                )
            }
        }
    }

    private func finishDisplayedReplacement(
        _ work: EndpointStatisticsDisplayedReplacementWork,
        source: EndpointStatisticsRenderedSource,
        cancellationToken: EndpointStatisticsCancellationToken,
        packetCount: Int,
        packets: [PacketSummary]
    ) {
        guard displayedReplacementWork === work,
              work.acceptsFlattenedPackets(
                token: cancellationToken,
                packetCount: packetCount,
                flattenedPacketCount: packets.count
              ) else {
            return
        }
        guard source.identity == work.source.identity,
              isCurrentDisplayedSource(work.source),
              let update = displayedForwarder.replacementUpdate(from: source, packets: packets) else {
            cancelDisplayedReplacement(work)
            return
        }
        var deferredUpdates: [EndpointStatisticsIngestUpdate] = []
        deferredUpdates.reserveCapacity(work.deferredUpdates.count)
        for deferredUpdate in work.deferredUpdates {
            guard let update = displayedForwarder.deferredUpdate(deferredUpdate) else {
                cancelDisplayedReplacement(work)
                return
            }
            deferredUpdates.append(update)
        }
        displayedReplacementWork = nil

        let action: EndpointStatisticsUpdateDrainCoordinator.Action
        switch work.mode {
        case .enqueue:
            if displayedPacketsPipeline.canResume {
                action = displayedPacketsPipeline.resume(withReplacement: update)
                pendingDisplayedPacketsSourceReplacement = false
                waitsForDisplayedPacketsManualRefresh = true
            } else {
                guard !displayedPacketsPipeline.isPaused else {
                    needsDisplayedReplacement = true
                    pendingDisplayedPacketsSourceReplacement = true
                    updateRefreshNotice()
                    return
                }
                action = displayedPacketsPipeline.enqueue(update)
            }
            if case .paused = action {
                needsDisplayedReplacement = true
                pendingDisplayedPacketsSourceReplacement = true
            }
        case .resume:
            guard displayedPacketsPipeline.canResume else {
                needsDisplayedReplacement = true
                pendingDisplayedPacketsSourceReplacement = true
                updateRefreshNotice()
                return
            }
            action = displayedPacketsPipeline.resume(withReplacement: update)
            if case .drain = action {
                pendingDisplayedPacketsSourceReplacement = false
                waitsForDisplayedPacketsManualRefresh = true
            }
        }
        if case .drain = action {
            displayedReplacementRecoveryState.replacementWasAccepted()
            needsDisplayedReplacement = false
        }
        handleDisplayedPacketsDrainAction(action)
        guard case .drain = action else {
            return
        }
        for deferredUpdate in deferredUpdates {
            let deferredAction = displayedPacketsPipeline.enqueue(deferredUpdate)
            if case .paused = deferredAction {
                needsDisplayedReplacement = true
                waitsForDisplayedPacketsManualRefresh = false
            }
            handleDisplayedPacketsDrainAction(deferredAction)
            if case .paused = deferredAction {
                break
            }
        }
    }

    private func cancelDisplayedReplacement(_ work: EndpointStatisticsDisplayedReplacementWork) {
        work.cancellationToken.cancel()
        if displayedReplacementWork === work {
            displayedReplacementWork = nil
        }
        needsDisplayedReplacement = true
    }

    private func pauseDisplayedReplacement(_ work: EndpointStatisticsDisplayedReplacementWork) {
        cancelDisplayedReplacement(work)
        displayedReplacementRecoveryState.pauseForOverflow()
        waitsForDisplayedPacketsManualRefresh = false
        updateRefreshNotice()
    }

    private func scheduleDisplayedReplacementContinuation(
        _ work: EndpointStatisticsDisplayedReplacementWork
    ) {
        guard !work.isContinuationScheduled else {
            return
        }
        work.isContinuationScheduled = true
        DispatchQueue.main.async { [weak self, weak work] in
            guard let work else {
                return
            }
            work.isContinuationScheduled = false
            self?.continueDisplayedReplacement(work)
        }
    }

    private func isCurrentDisplayedSource(_ source: EndpointStatisticsRenderedSource) -> Bool {
        !isCancelled && EndpointStatisticsDisplayedSourcePolicy.canLoadReplacement(
            source: source,
            latestSource: latestRenderedSource,
            expectedIdentity: latestSourceIdentity,
            usesDisplayedPackets: usesDisplayedPackets
        )
    }

    private func startRawReplacement(
        from ingestState: PacketIngestState,
        mode: EndpointStatisticsReplacementMode
    ) {
        rawReplacementWork?.cancellationToken.cancel()
        let work = EndpointStatisticsRawReplacementWork(
            sourceIdentity: EndpointStatisticsSourceIdentity(
                backingIdentity: ingestState.backingIdentity,
                packetLineageRevision: ingestState.packetLineageRevision
            ),
            packetRevision: ingestState.packetRevision,
            packetCount: ingestState.packets.count,
            mode: mode
        )
        rawReplacementWork = work
        isRawReplacementPaused = false
        if !usesDisplayedPackets {
            setCalculating(true, text: "Loading endpoints…")
        }
        scheduleRawReplacementContinuation(work)
    }

    // Copy only one producer range per main turn so live appends retain their unique Array buffer.
    private func continueRawReplacement(_ work: EndpointStatisticsRawReplacementWork) {
        guard rawReplacementWork === work,
              !work.cancellationToken.isCancelled(),
              !isRawReplacementPaused,
              let ingestState = latestIngestStateProvider() else {
            return
        }
        let currentIdentity = EndpointStatisticsSourceIdentity(
            backingIdentity: ingestState.backingIdentity,
            packetLineageRevision: ingestState.packetLineageRevision
        )
        guard currentIdentity == work.sourceIdentity,
              ingestState.packetRevision == work.packetRevision,
              ingestState.packets.count == work.accumulator.packetCount else {
            startRawReplacement(from: ingestState, mode: work.mode)
            return
        }
        guard let range = work.accumulator.nextRange else {
            flattenRawReplacement(work)
            return
        }
        let packets = Array(ingestState.packets[range])
        guard work.accumulator.append(packetIDs: packets.map(\.id), packets: packets) else {
            pauseRawReplacement(work)
            return
        }
        scheduleRawReplacementContinuation(work)
    }

    private func flattenRawReplacement(_ work: EndpointStatisticsRawReplacementWork) {
        guard !work.isFlattening else {
            return
        }
        work.isFlattening = true
        let chunks = work.accumulator.packetChunks
        let packetCount = work.accumulator.packetCount
        let packetRevision = work.packetRevision
        let cancellationToken = work.cancellationToken
        allPacketsQueue.async { [weak self, weak work] in
            var packets: [PacketSummary] = []
            packets.reserveCapacity(packetCount)
            for chunk in chunks {
                guard !cancellationToken.isCancelled() else {
                    return
                }
                packets.append(contentsOf: chunk.packets)
            }
            DispatchQueue.main.async {
                guard let self, let work else {
                    return
                }
                self.finishRawReplacement(
                    work,
                    cancellationToken: cancellationToken,
                    packetRevision: packetRevision,
                    packetCount: packetCount,
                    packets: packets
                )
            }
        }
    }

    private func finishRawReplacement(
        _ work: EndpointStatisticsRawReplacementWork,
        cancellationToken: EndpointStatisticsCancellationToken,
        packetRevision: UInt64,
        packetCount: Int,
        packets: [PacketSummary]
    ) {
        guard rawReplacementWork === work,
              work.acceptsFlattenedPackets(
                token: cancellationToken,
                packetRevision: packetRevision,
                packetCount: packetCount,
                flattenedPacketCount: packets.count
              ),
              !isRawReplacementPaused,
              latestSourceIdentity == work.sourceIdentity,
              ingestCursor?.packetRevision == work.packetRevision,
              ingestCursor?.packetLineageRevision == work.sourceIdentity.packetLineageRevision,
              ingestCursor?.totalPacketCount == work.logicalPacketCount else {
            return
        }
        rawReplacementWork = nil
        let deferredUpdates = work.deferredUpdates
        let replacement = EndpointStatisticsIngestUpdate(
            packetRevision: packetRevision,
            packetLineageRevision: work.sourceIdentity.packetLineageRevision,
            totalPacketCount: packetCount,
            kind: .replace(packets)
        )
        let action: EndpointStatisticsUpdateDrainCoordinator.Action
        switch work.mode {
        case .enqueue:
            if allPacketsPipeline.canResume {
                action = allPacketsPipeline.resume(withReplacement: replacement)
                pendingAllPacketsSourceReplacement = false
                waitsForAllPacketsManualRefresh = true
            } else {
                guard !allPacketsPipeline.isPaused else {
                    pendingAllPacketsSourceReplacement = true
                    updateRefreshNotice()
                    return
                }
                action = allPacketsPipeline.enqueue(replacement)
            }
            if case .paused = action {
                pendingAllPacketsSourceReplacement = true
            }
        case .resume:
            guard allPacketsPipeline.canResume else {
                pendingAllPacketsSourceReplacement = true
                updateRefreshNotice()
                return
            }
            action = allPacketsPipeline.resume(withReplacement: replacement)
            if case .drain = action {
                pendingAllPacketsSourceReplacement = false
                waitsForAllPacketsManualRefresh = true
            }
        }
        if case .drain = action {
            isRawReplacementPaused = false
            pendingAllPacketsSourceReplacement = false
        }
        handleAllPacketsDrainAction(action)
        guard case .drain = action else {
            return
        }
        for deferredUpdate in deferredUpdates {
            let deferredAction = allPacketsPipeline.enqueue(deferredUpdate)
            if case .paused = deferredAction {
                isRawReplacementPaused = true
                waitsForAllPacketsManualRefresh = false
            }
            handleAllPacketsDrainAction(deferredAction)
            if case .paused = deferredAction {
                break
            }
        }
    }

    private func updateRawReplacement(
        _ work: EndpointStatisticsRawReplacementWork,
        from ingestState: PacketIngestState,
        sourceIdentity: EndpointStatisticsSourceIdentity
    ) {
        let nextRevision = work.packetRevision &+ 1
        guard sourceIdentity == work.sourceIdentity,
              ingestState.packetRevision == nextRevision else {
            allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            startRawReplacement(from: ingestState, mode: work.mode)
            return
        }
        if work.isFlattening {
            deferRawMutationDuringFlatten(work, from: ingestState)
            return
        }

        switch ingestState.lastMutation {
        case .append(let range):
            guard range.lowerBound == work.accumulator.packetCount,
                  range.upperBound == ingestState.packets.count,
                  work.prepareForMorePackets(
                    packetRevision: ingestState.packetRevision,
                    packetCount: ingestState.packets.count
                  ) else {
                startRawReplacement(from: ingestState, mode: work.mode)
                return
            }
        case .appendWithMetadataUpdates(let range, let packetIDs):
            guard range.count <= EndpointStatisticsRawDeltaPolicy.maximumPacketCount,
                  packetIDs.count <= EndpointStatisticsRawDeltaPolicy.maximumPacketCount - range.count,
                  range.lowerBound == work.accumulator.packetCount,
                  range.upperBound == ingestState.packets.count,
                  work.prepareForMorePackets(
                    packetRevision: ingestState.packetRevision,
                    packetCount: ingestState.packets.count
                  ) else {
                allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
                pauseRawReplacement(work)
                return
            }
            allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            applyRawMetadata(packetIDs, from: ingestState, to: work)
        case .metadataUpdate(let packetIDs):
            guard packetIDs.count <= EndpointStatisticsRawDeltaPolicy.maximumPacketCount,
                  ingestState.packets.count == work.accumulator.packetCount else {
                allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
                pauseRawReplacement(work)
                return
            }
            work.prepareForMetadata(packetRevision: ingestState.packetRevision)
            allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            applyRawMetadata(packetIDs, from: ingestState, to: work)
        case .none, .reset, .replace:
            allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            startRawReplacement(from: ingestState, mode: work.mode)
            return
        }
        scheduleRawReplacementContinuation(work)
    }

    private func deferRawMutationDuringFlatten(
        _ work: EndpointStatisticsRawReplacementWork,
        from ingestState: PacketIngestState
    ) {
        guard !EndpointStatisticsRawDeltaPolicy.exceedsAutomaticLimit(ingestState.lastMutation) else {
            if ingestState.lastMutation.changesEndpointClassification {
                allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            }
            pauseRawReplacement(work)
            return
        }
        let previousCursor = EndpointStatisticsIngestCursor(
            packetRevision: work.packetRevision,
            packetLineageRevision: work.sourceIdentity.packetLineageRevision,
            totalPacketCount: work.logicalPacketCount
        )
        let update = EndpointStatisticsIngestUpdate(
            ingestState: ingestState,
            previousCursor: previousCursor
        )
        guard update.previousPacketRevision != nil,
              work.deferUpdate(
                update,
                maximumPacketCount: EndpointStatisticsRawDeltaPolicy.maximumPacketCount
              ) else {
            if ingestState.lastMutation.changesEndpointClassification {
                allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
            }
            pauseRawReplacement(work)
            return
        }
        if ingestState.lastMutation.changesEndpointClassification {
            allPacketsPipeline.recordDroppedMutation(changesEndpointClassification: true)
        }
    }

    private func applyRawMetadata(
        _ packetIDs: [PacketSummary.ID],
        from ingestState: PacketIngestState,
        to work: EndpointStatisticsRawReplacementWork
    ) {
        for packetID in packetIDs {
            guard let packetIndex = ingestState.packetIndexByID[packetID],
                  ingestState.packets.indices.contains(packetIndex) else {
                continue
            }
            work.accumulator.replaceLoadedPacket(
                at: packetIndex,
                with: ingestState.packets[packetIndex]
            )
        }
    }

    private func pauseRawReplacement(_ work: EndpointStatisticsRawReplacementWork) {
        work.cancellationToken.cancel()
        if rawReplacementWork === work {
            rawReplacementWork = nil
        }
        isRawReplacementPaused = true
        waitsForAllPacketsManualRefresh = false
        updateRefreshNotice()
    }

    private func scheduleRawReplacementContinuation(_ work: EndpointStatisticsRawReplacementWork) {
        guard !work.isContinuationScheduled else {
            return
        }
        work.isContinuationScheduled = true
        DispatchQueue.main.async { [weak self, weak work] in
            guard let work else {
                return
            }
            work.isContinuationScheduled = false
            self?.continueRawReplacement(work)
        }
    }

    // Keep one raw-ingest drain in flight and pause without retaining more deltas after overload.
    private func handleAllPacketsDrainAction(_ action: EndpointStatisticsUpdateDrainCoordinator.Action) {
        switch action {
        case .none:
            break
        case .drain(let update):
            let service = allPacketsService
            let cancellationToken = allPacketsCancellationToken
            allPacketsQueue.async {
                let result = service.consume(update, cancellationToken: cancellationToken)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isCancelled else {
                        return
                    }
                    if result == .consumed {
                        self.consumedIngestCursor = update.cursor
                    }
                    let nextAction = self.allPacketsPipeline.drainCompleted(result: result)
                    let pipelineIsIdle: Bool
                    if case .none = nextAction {
                        pipelineIsIdle = true
                    } else {
                        pipelineIsIdle = false
                    }
                    self.handleAllPacketsDrainAction(nextAction)
                    guard pipelineIsIdle else {
                        return
                    }
                    if result == .consumed, self.waitsForAllPacketsManualRefresh {
                        self.waitsForAllPacketsManualRefresh = false
                        if !self.usesDisplayedPackets {
                            self.allPacketsPresentationIntentAfterDrain = nil
                            self.requestPresentation(intent: .explicit)
                        }
                    } else if result == .consumed, !self.usesDisplayedPackets {
                        let intent = self.allPacketsPresentationIntentAfterDrain ?? .automatic
                        self.allPacketsPresentationIntentAfterDrain = nil
                        self.requestPresentation(intent: intent)
                    }
                }
            }
        case .paused:
            if waitsForAllPacketsManualRefresh, allPacketsPipeline.canResume {
                attemptAllPacketsManualRefresh()
            } else if pendingAllPacketsSourceReplacement, allPacketsPipeline.canResume {
                attemptPendingAllPacketsSourceReplacement()
            }
            updateRefreshNotice()
        }
    }

    // The displayed scope uses the same bounded drain while resolving replacement IDs on main.
    private func handleDisplayedPacketsDrainAction(_ action: EndpointStatisticsUpdateDrainCoordinator.Action) {
        switch action {
        case .none:
            break
        case .drain(let update):
            let service = displayedPacketsService
            let cancellationToken = displayedPacketsCancellationToken
            displayedPacketsQueue.async {
                let result = service.consume(update, cancellationToken: cancellationToken)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isCancelled else {
                        return
                    }
                    if result == .consumed {
                        self.consumedDisplayedCursor = update.cursor
                    }
                    let nextAction = self.displayedPacketsPipeline.drainCompleted(result: result)
                    let pipelineIsIdle: Bool
                    if case .none = nextAction {
                        pipelineIsIdle = true
                    } else {
                        pipelineIsIdle = false
                    }
                    self.handleDisplayedPacketsDrainAction(nextAction)
                    guard pipelineIsIdle else {
                        return
                    }
                    if result == .consumed, self.waitsForDisplayedPacketsManualRefresh {
                        self.waitsForDisplayedPacketsManualRefresh = false
                        if self.usesDisplayedPackets, !self.isWaitingForDisplayFilter {
                            self.displayedPacketsPresentationIntentAfterDrain = nil
                            self.requestPresentation(intent: .explicit)
                        }
                    } else if result == .consumed,
                              self.usesDisplayedPackets,
                              !self.isWaitingForDisplayFilter {
                        let intent = self.displayedPacketsPresentationIntentAfterDrain ?? .automatic
                        self.displayedPacketsPresentationIntentAfterDrain = nil
                        self.requestPresentation(intent: intent)
                    }
                }
            }
        case .paused:
            if waitsForDisplayedPacketsManualRefresh,
               displayedPacketsPipeline.canResume,
               let latestRenderedSource {
                resumeDisplayedPacketsForSourceReplacement(latestRenderedSource)
            } else if displayedReplacementRecoveryState.shouldResumeAutomatically,
                      displayedPacketsPipeline.canResume,
                      let latestRenderedSource {
                resumeDisplayedPacketsForSourceReplacement(latestRenderedSource)
            }
            updateRefreshNotice()
        }
    }

    private func recoverDisplayedScope() {
        needsDisplayedReplacement = true
        guard usesDisplayedPackets,
              let latestRenderedSource,
              !latestRenderedSource.isFiltering else {
            if usesDisplayedPackets {
                setCalculating(true, text: "Refreshing displayed packets…")
            }
            return
        }
        setCalculating(true, text: "Refreshing displayed packets…")
        if consumeDisplayedSource(latestRenderedSource, forceReplacement: true) {
            recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: true)
        } else {
            requestPresentation(intent: .explicit)
        }
    }

    private func recordPresentationIntentAfterDrain(
        _ intent: EndpointStatisticsPresentationIntent,
        usesDisplayedPackets: Bool
    ) {
        if intent == .explicit {
            presentationGeneration &+= 1
            abandonActivePresentation()
        }
        if usesDisplayedPackets {
            if displayedPacketsPresentationIntentAfterDrain != .explicit {
                displayedPacketsPresentationIntentAfterDrain = intent
            }
        } else if allPacketsPresentationIntentAfterDrain != .explicit {
            allPacketsPresentationIntentAfterDrain = intent
        }
        setCalculating(true, text: "Calculating…")
    }

    private func attemptPendingAllPacketsSourceReplacement() {
        guard pendingAllPacketsSourceReplacement,
              allPacketsPipeline.canResume,
              let ingestState = latestIngestStateProvider() else {
            return
        }
        startRawReplacement(from: ingestState, mode: .resume)
    }

    private func attemptAllPacketsManualRefresh() {
        guard waitsForAllPacketsManualRefresh,
              allPacketsPipeline.canResume || isRawReplacementPaused else {
            return
        }
        guard let ingestState = latestIngestStateProvider() else {
            waitsForAllPacketsManualRefresh = false
            updateRefreshNotice()
            return
        }
        if let ingestCursor,
           ingestState.packetLineageRevision == ingestCursor.packetLineageRevision,
           ingestState.packetRevision < ingestCursor.packetRevision {
            waitsForAllPacketsManualRefresh = false
            updateRefreshNotice()
            return
        }
        ingestCursor = EndpointStatisticsIngestCursor(
            packetRevision: ingestState.packetRevision,
            packetLineageRevision: ingestState.packetLineageRevision,
            totalPacketCount: ingestState.packets.count
        )
        latestSourceIdentity = EndpointStatisticsSourceIdentity(
            backingIdentity: ingestState.backingIdentity,
            packetLineageRevision: ingestState.packetLineageRevision
        )
        startRawReplacement(
            from: ingestState,
            mode: allPacketsPipeline.canResume ? .resume : .enqueue
        )
    }

    private func resumeDisplayedPacketsForSourceReplacement(_ source: EndpointStatisticsRenderedSource) {
        guard displayedPacketsPipeline.canResume || isDisplayedReplacementPaused else {
            return
        }
        let mode: EndpointStatisticsReplacementMode = displayedPacketsPipeline.canResume
            ? .resume
            : .enqueue
        _ = startDisplayedReplacement(from: source, mode: mode)
    }

    // Coalesce live changes, while explicit controls may request one refresh of a large table.
    private func requestPresentation(intent: EndpointStatisticsPresentationIntent = .automatic) {
        guard !isCancelled else {
            return
        }
        guard !currentPipelineIsPaused else {
            updateRefreshNotice()
            return
        }
        // A control change queued during a drain must outrank the automatic idle callback.
        let effectiveIntent = intent.merging(pendingPresentationIntent)
        guard automaticRefreshPolicy.accepts(effectiveIntent) else {
            updateRefreshNotice()
            return
        }
        if !currentPipelineIsDraining {
            if usesDisplayedPackets {
                displayedPacketsPresentationIntentAfterDrain = nil
            } else {
                allPacketsPresentationIntentAfterDrain = nil
            }
        }
        if effectiveIntent == .explicit {
            abandonActivePresentation()
        }
        presentationGeneration &+= 1
        pendingPresentationIntent = effectiveIntent
        setCalculating(true, text: "Calculating…")
        guard !usesDisplayedPackets || (
            !needsDisplayedReplacement && latestRenderedSource?.identity == latestSourceIdentity
        ) else {
            return
        }
        guard !usesDisplayedPackets || !isWaitingForDisplayFilter else {
            return
        }
        guard !currentPipelineIsDraining else {
            return
        }
        guard !isPresentationInFlight, scheduledPresentationWorkItem == nil else {
            return
        }

        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - lastPresentationStartTime
        let rateLimitDelay = EndpointStatisticsPresentationCadence.maximumRefreshRateInterval - elapsed
        let backpressureDelay = nextPresentationAllowedTime - now
        let delay = max(0, rateLimitDelay, backpressureDelay)
        let workItem = DispatchWorkItem { [weak self] in
            self?.beginPresentation()
        }
        scheduledPresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func abandonActivePresentation() {
        activePresentationCancellationToken?.cancel()
        activePresentationCancellationToken = nil
        isPresentationInFlight = false
    }

    private func beginPresentation() {
        scheduledPresentationWorkItem = nil
        guard let intent = pendingPresentationIntent,
              !isPresentationInFlight,
              !currentPipelineIsPaused,
              !currentPipelineIsDraining else {
            return
        }
        guard !usesDisplayedPackets || (
            !needsDisplayedReplacement &&
                !isWaitingForDisplayFilter &&
                latestRenderedSource?.identity == latestSourceIdentity
        ) else {
            return
        }
        pendingPresentationIntent = nil
        isPresentationInFlight = true
        let presentationCancellationToken = EndpointStatisticsCancellationToken()
        activePresentationCancellationToken = presentationCancellationToken
        lastPresentationStartTime = Date.timeIntervalSinceReferenceDate

        let request = EndpointStatisticsPresentationRequest(
            generation: presentationGeneration,
            intent: intent,
            usesDisplayedPackets: usesDisplayedPackets,
            sourceIdentity: latestSourceIdentity,
            ingestCursor: consumedIngestCursor,
            displayedCursor: consumedDisplayedCursor,
            classificationRevision: usesDisplayedPackets
                ? displayedPacketsPipeline.consumedClassificationRevision
                : allPacketsPipeline.consumedClassificationRevision,
            group: selectedGroup,
            searchText: searchField.stringValue,
            sort: currentSort
        )
        let service = request.usesDisplayedPackets ? displayedPacketsService : allPacketsService
        let processingQueue = request.usesDisplayedPackets ? displayedPacketsQueue : allPacketsQueue
        processingQueue.async {
            let processingStartTime = ProcessInfo.processInfo.systemUptime
            guard let snapshot = service.currentSnapshot(
                for: request.group,
                cancellationToken: presentationCancellationToken
            ),
            let table = EndpointStatisticsTablePresenter.presentation(
                rows: snapshot.rows,
                searchText: request.searchText,
                sort: request.sort,
                cancellationToken: presentationCancellationToken
            ) else {
                DispatchQueue.main.async { [weak self] in
                    self?.presentationDidCancel(presentationCancellationToken)
                }
                return
            }
            let result = EndpointStatisticsPresentationResult(
                request: request,
                cancellationToken: presentationCancellationToken,
                endpointCounts: snapshot.endpointCounts,
                scopeTotals: snapshot.footerTotals,
                table: table,
                processingDuration: ProcessInfo.processInfo.systemUptime - processingStartTime
            )
            DispatchQueue.main.async { [weak self] in
                self?.finishPresentation(result)
            }
        }
    }

    private func finishPresentation(_ result: EndpointStatisticsPresentationResult) {
        guard activePresentationCancellationToken === result.cancellationToken else {
            return
        }
        activePresentationCancellationToken = nil
        isPresentationInFlight = false
        nextPresentationAllowedTime = Date.timeIntervalSinceReferenceDate +
            EndpointStatisticsPresentationCadence.cooldown(after: result.processingDuration)
        let request = result.request
        let decision = EndpointStatisticsPresentationCommitPolicy.decision(
            requestContext: request.context,
            currentContext: currentPresentationContext,
            requestIngestCursor: request.ingestCursor,
            currentIngestCursor: ingestCursor,
            requestDisplayedCursor: request.displayedCursor,
            currentDisplayedCursor: displayedForwarder.cursor,
            requestClassificationRevision: request.classificationRevision,
            currentClassificationRevision: usesDisplayedPackets
                ? displayedPacketsPipeline.latestClassificationRevision
                : allPacketsPipeline.latestClassificationRevision,
            isWaitingForDisplayFilter: isWaitingForDisplayFilter
        )
        if decision != .discard {
            let selectedRowIDs = EndpointStatisticsSelectionRestoration.selectedRowIDs(
                rows: rows,
                selectedIndexes: tableView.selectedRowIndexes
            )
            rows = result.table.rows
            rowIndexByID = result.table.rowIndexByID
            tableView.reloadData()
            let selectedIndexes = EndpointStatisticsSelectionRestoration.rowIndexes(
                for: selectedRowIDs,
                rowIndexByID: result.table.rowIndexByID
            )
            if selectedIndexes.isEmpty {
                tableView.deselectAll(nil)
            } else {
                tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
            }
            updateSegmentLabels(counts: result.endpointCounts)
            updateFooter(table: result.table, scopeTotals: result.scopeTotals)
            committedActionState = EndpointStatisticsActionState(
                context: request.context,
                classificationRevision: request.classificationRevision
            )
            automaticRefreshPolicy.didCommit(
                unfilteredEndpointCount: result.table.unfilteredRowCount
            )
            setCalculating(false, text: "")
            updateRefreshNotice()
        }

        if !isWaitingForDisplayFilter &&
            (pendingPresentationIntent != nil || decision == .discard || decision == .commitAndRefresh) {
            let nextIntent = pendingPresentationIntent ?? .automatic
            requestPresentation(intent: nextIntent)
        }
    }

    private func presentationDidCancel(_ cancellationToken: EndpointStatisticsCancellationToken) {
        guard activePresentationCancellationToken === cancellationToken else {
            return
        }
        activePresentationCancellationToken = nil
        isPresentationInFlight = false
        if pendingPresentationIntent != nil {
            requestPresentation(intent: pendingPresentationIntent ?? .automatic)
        }
    }

    private func updateSegmentLabels(counts: [EndpointStatisticsGroup: Int]) {
        for (index, group) in EndpointStatisticsGroup.allCases.enumerated() {
            segmentControl.setLabel("\(group.title) (\(counts[group] ?? 0))", forSegment: index)
        }
    }

    private func updateFooter(
        table: EndpointStatisticsTablePresentation,
        scopeTotals: EndpointStatisticsTotals
    ) {
        let endpointText: String
        if table.rows.count == table.unfilteredRowCount {
            endpointText = countText(table.rows.count, singular: "endpoint")
        } else {
            endpointText = "\(formatNumber(UInt64(table.rows.count))) of \(formatNumber(UInt64(table.unfilteredRowCount))) endpoints"
        }
        footerLabel.stringValue = ([
            endpointText,
            countText(scopeTotals.packets, singular: "packet"),
        ] + EndpointStatisticsFooterFormatter.trafficParts(
            totals: scopeTotals,
            formatBytes: byteCountText
        )).joined(separator: " · ")
    }

    private func setCalculating(_ isCalculating: Bool, text: String) {
        calculatingLabel.stringValue = text
        calculatingLabel.isHidden = !isCalculating
        if isCalculating {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func updateRefreshNotice() {
        let message: String?
        if currentPipelineIsPaused {
            message = "Statistics updates paused to keep capture responsive."
        } else if automaticRefreshPolicy.isPaused {
            message = "Live updates paused for tables over 10,000 endpoints."
        } else {
            message = nil
        }
        refreshNoticeLabel.stringValue = message ?? ""
        refreshNoticeLabel.isHidden = message == nil
        refreshButton.isHidden = message == nil
        let waitsForCurrentScope = usesDisplayedPackets
            ? waitsForDisplayedPacketsManualRefresh
            : waitsForAllPacketsManualRefresh
        refreshButton.isEnabled = !isPresentationInFlight &&
            !currentPipelineIsDraining &&
            !waitsForCurrentScope
    }

    @objc private func refreshStatistics(_ sender: Any?) {
        guard !isCancelled, !currentPipelineIsDraining else {
            return
        }
        if currentPipelineIsPaused {
            setCalculating(true, text: "Refreshing…")
            if usesDisplayedPackets {
                waitsForDisplayedPacketsManualRefresh = true
                pendingDisplayedPacketsSourceReplacement = false
                guard let latestRenderedSource, !latestRenderedSource.isFiltering else {
                    setCalculating(true, text: "Updating displayed packets…")
                    return
                }
                resumeDisplayedPacketsForSourceReplacement(latestRenderedSource)
            } else {
                waitsForAllPacketsManualRefresh = true
                pendingAllPacketsSourceReplacement = false
                attemptAllPacketsManualRefresh()
            }
            updateRefreshNotice()
            return
        }
        requestPresentation(intent: .explicit)
    }

    private func countText(_ count: Int, singular: String) -> String {
        countText(UInt64(max(count, 0)), singular: singular)
    }

    private func countText(_ count: UInt64, singular: String) -> String {
        "\(formatNumber(count)) \(singular)\(count == 1 ? "" : "s")"
    }

    private func formatNumber(_ value: UInt64) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func byteCountText(_ value: UInt64) -> String {
        let clampedValue = value > UInt64(Int64.max) ? Int64.max : Int64(value)
        return byteCountFormatter.string(fromByteCount: clampedValue)
    }

    private func displayText(
        for column: EndpointStatisticsTableColumn,
        row: EndpointStatisticsRow
    ) -> String {
        switch column {
        case .packets: formatNumber(row.packets)
        case .bytes: formatNumber(row.bytes)
        case .txPackets: formatNumber(row.txPackets)
        case .txBytes: formatNumber(row.txBytes)
        case .rxPackets: formatNumber(row.rxPackets)
        case .rxBytes: formatNumber(row.rxBytes)
        default: column.stringValue(in: row)
        }
    }

    @objc private func groupChanged(_ sender: NSSegmentedControl) {
        guard EndpointStatisticsGroup.allCases.indices.contains(sender.selectedSegment) else {
            return
        }
        saveCurrentColumnLayout()
        selectedGroup = EndpointStatisticsGroup.allCases[sender.selectedSegment]
        applyColumnLayout(for: selectedGroup)
        applySortDescriptor(currentSort)
        requestPresentation(intent: .explicit)
    }

    @objc private func displayedPacketsScopeChanged(_ sender: NSButton) {
        var waitsForAggregation = false
        if usesDisplayedPackets {
            needsDisplayedReplacement = true
            if let latestRenderedSource, latestRenderedSource.isFiltering {
                isWaitingForDisplayFilter = true
                waitsForAggregation = true
                recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: true)
                setCalculating(true, text: "Updating displayed packets…")
            } else if displayedPacketsPipeline.isPaused || isDisplayedReplacementPaused {
                isWaitingForDisplayFilter = false
                waitsForAggregation = true
                recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: true)
                updateRefreshNotice()
            } else if let latestRenderedSource {
                isWaitingForDisplayFilter = false
                if consumeDisplayedSource(latestRenderedSource, forceReplacement: true) {
                    waitsForAggregation = true
                    recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: true)
                }
            }
        } else {
            displayedReplacementWork?.cancellationToken.cancel()
            displayedReplacementWork = nil
            waitsForDisplayedPacketsManualRefresh = false
            needsDisplayedReplacement = true
            isWaitingForDisplayFilter = false
            if allPacketsPipeline.isDrainInFlight || allPacketsPipeline.isPaused {
                waitsForAggregation = true
                recordPresentationIntentAfterDrain(.explicit, usesDisplayedPackets: false)
            }
        }
        updateRefreshNotice()
        if !waitsForAggregation {
            requestPresentation(intent: .explicit)
        }
    }

    @objc private func showRelatedPacketsFromDoubleClick(_ sender: Any?) {
        guard rowsAreActionable else {
            return
        }
        let rowIndex = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard rows.indices.contains(rowIndex) else {
            return
        }
        showRelatedPackets(rows[rowIndex].id)
    }

    @objc private func showRelatedPacketsFromMenu(_ sender: Any?) {
        guard rowsAreActionable else {
            return
        }
        let rowIndex: Int?
        if contextTarget.rowID != nil {
            rowIndex = contextTarget.resolvedRowIndex(
                rowIndexByID: rowIndexByID,
                rowCount: rows.count
            )
        } else {
            rowIndex = targetSelection().firstIndex(rowCount: rows.count)
        }
        guard let rowIndex, rows.indices.contains(rowIndex) else {
            return
        }
        showRelatedPackets(rows[rowIndex].id)
    }

    @objc private func copyCellFromMenu(_ sender: Any?) {
        guard rowsAreActionable,
              let rowIndex = contextTarget.resolvedRowIndex(
                rowIndexByID: rowIndexByID,
                rowCount: rows.count
              ),
              let column = contextTarget.column else {
            return
        }
        guard let value = EndpointStatisticsSemanticCopyPolicy.copyableValue(
            column.stringValue(in: rows[rowIndex]),
            isAggregatePlaceholder: column.isAggregatePlaceholder(in: rows[rowIndex])
        ) else {
            return
        }
        writeToPasteboard(value)
    }

    @objc private func copyAddressFromMenu(_ sender: Any?) {
        copyValues(field: .address, selection: targetSelection())
    }

    @objc private func copyDomainFromMenu(_ sender: Any?) {
        copyValues(field: .domain, selection: targetSelection())
    }

    @objc private func copyClientFromMenu(_ sender: Any?) {
        copyValues(field: .client, selection: targetSelection())
    }

    @objc private func copySelectedCSVFromMenu(_ sender: Any?) {
        copy(selection: targetSelection(), asJSON: false)
    }

    @objc private func copySelectedJSONFromMenu(_ sender: Any?) {
        copy(selection: targetSelection(), asJSON: true)
    }

    @objc private func copyAllCSVFromMenu(_ sender: Any?) {
        copy(selection: .all, asJSON: false)
    }

    @objc private func copyAllJSONFromMenu(_ sender: Any?) {
        copy(selection: .all, asJSON: true)
    }

    // Capture only the immutable row buffer and selection descriptor before formatting off-main.
    private func copy(selection: EndpointStatisticsRowSelection, asJSON: Bool) {
        guard rowsAreActionable, !selection.isEmpty(rowCount: rows.count) else {
            return
        }
        let rowSnapshot = rows
        let columns = visibleColumns()
        let (cancellationToken, commitToken) = beginExport()
        exportQueue.async {
            guard let selectedRows = selection.resolvedRows(
                from: rowSnapshot,
                cancellationToken: cancellationToken
            ) else {
                return
            }
            let value = asJSON
                ? EndpointStatisticsTableExportFormatter.json(
                    rows: selectedRows,
                    columns: columns,
                    cancellationToken: cancellationToken
                )
                : EndpointStatisticsTableExportFormatter.csv(
                    rows: selectedRows,
                    columns: columns,
                    cancellationToken: cancellationToken
                )
            guard let value, !value.isEmpty else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.commitExport(value, cancellationToken: cancellationToken, commitToken: commitToken)
            }
        }
    }

    private func copyValues(
        field: EndpointStatisticsSemanticCopyField,
        selection: EndpointStatisticsRowSelection
    ) {
        guard rowsAreActionable, !selection.isEmpty(rowCount: rows.count) else {
            return
        }
        let rowSnapshot = rows
        let (cancellationToken, commitToken) = beginExport()
        exportQueue.async {
            guard let selectedRows = selection.resolvedRows(
                from: rowSnapshot,
                cancellationToken: cancellationToken
            ),
            let value = EndpointStatisticsSemanticValueFormatter.joinedValues(
                rows: selectedRows,
                field: field,
                cancellationToken: cancellationToken
            ),
            !value.isEmpty else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.commitExport(value, cancellationToken: cancellationToken, commitToken: commitToken)
            }
        }
    }

    private func beginExport() -> (
        cancellationToken: EndpointStatisticsCancellationToken,
        commitToken: EndpointStatisticsExportCommitToken
    ) {
        activeExportCancellationToken?.cancel()
        exportGeneration &+= 1
        let cancellationToken = EndpointStatisticsCancellationToken()
        activeExportCancellationToken = cancellationToken
        return (
            cancellationToken,
            EndpointStatisticsExportCommitToken(
                generation: exportGeneration,
                pasteboardChangeCount: NSPasteboard.general.changeCount
            )
        )
    }

    private func commitExport(
        _ value: String,
        cancellationToken: EndpointStatisticsCancellationToken,
        commitToken: EndpointStatisticsExportCommitToken
    ) {
        guard activeExportCancellationToken === cancellationToken,
              !cancellationToken.isCancelled(),
              EndpointStatisticsExportCommitPolicy.shouldCommit(
                commitToken,
                currentGeneration: exportGeneration,
                currentPasteboardChangeCount: NSPasteboard.general.changeCount
              ) else {
            return
        }
        activeExportCancellationToken = nil
        writeToPasteboard(value, invalidatesPendingExports: false)
    }

    private func writeToPasteboard(_ value: String, invalidatesPendingExports: Bool = true) {
        guard !value.isEmpty else {
            return
        }
        if invalidatesPendingExports {
            activeExportCancellationToken?.cancel()
            activeExportCancellationToken = nil
            exportGeneration &+= 1
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func targetSelection() -> EndpointStatisticsRowSelection {
        guard rowsAreActionable else {
            return .indexes([])
        }
        let indexes: IndexSet
        if contextTarget.rowID != nil {
            guard let contextRow = contextTarget.resolvedRowIndex(
                rowIndexByID: rowIndexByID,
                rowCount: rows.count
            ) else {
                return .indexes([])
            }
            indexes = tableView.selectedRowIndexes.contains(contextRow)
                ? tableView.selectedRowIndexes
                : IndexSet(integer: contextRow)
        } else {
            indexes = tableView.selectedRowIndexes
        }
        return .indexes(indexes)
    }

    private func visibleColumns() -> [EndpointStatisticsTableColumn] {
        tableView.tableColumns.compactMap { column in
            guard !column.isHidden else {
                return nil
            }
            return EndpointStatisticsTableColumn(rawValue: column.identifier.rawValue)
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Endpoints")
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    // Build row-sensitive actions only when the native context menu opens.
    private func updateContextMenu(_ menu: NSMenu) {
        updateContextPosition()
        menu.removeAllItems()
        let selection = targetSelection()
        let hasRows = rowsAreActionable && !selection.isEmpty(rowCount: rows.count)

        menu.addItem(menuItem("Show Related Packets", action: #selector(showRelatedPacketsFromMenu(_:)), isEnabled: hasRows))
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy Cell", action: #selector(copyCellFromMenu(_:)), isEnabled: contextCellValue() != nil))
        menu.addItem(menuItem(
            "Copy Address",
            action: #selector(copyAddressFromMenu(_:)),
            isEnabled: hasRows && selection.containsCopyableValue(in: rows, field: .address)
        ))
        menu.addItem(menuItem(
            "Copy Domain",
            action: #selector(copyDomainFromMenu(_:)),
            isEnabled: hasRows && selection.containsCopyableValue(in: rows, field: .domain)
        ))
        menu.addItem(menuItem(
            "Copy App",
            action: #selector(copyClientFromMenu(_:)),
            isEnabled: hasRows && selection.containsCopyableValue(in: rows, field: .client)
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy Selected Rows as CSV", action: #selector(copySelectedCSVFromMenu(_:)), isEnabled: hasRows))
        menu.addItem(menuItem("Copy Selected Rows as JSON", action: #selector(copySelectedJSONFromMenu(_:)), isEnabled: hasRows))
        menu.addItem(menuItem("Copy All Rows as CSV", action: #selector(copyAllCSVFromMenu(_:)), isEnabled: rowsAreActionable && !rows.isEmpty))
        menu.addItem(menuItem("Copy All Rows as JSON", action: #selector(copyAllJSONFromMenu(_:)), isEnabled: rowsAreActionable && !rows.isEmpty))
    }

    private func menuItem(_ title: String, action: Selector, isEnabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        return item
    }

    private func updateContextPosition() {
        guard let event = NSApp.currentEvent, let window = tableView.window, event.window === window else {
            contextTarget = .none
            return
        }
        let point = tableView.convert(event.locationInWindow, from: nil)
        let rowIndex = tableView.row(at: point)
        let columnIndex = tableView.column(at: point)
        let rowID = rows.indices.contains(rowIndex) ? rows[rowIndex].id : nil
        let column = tableView.tableColumns.indices.contains(columnIndex)
            ? EndpointStatisticsTableColumn(
                rawValue: tableView.tableColumns[columnIndex].identifier.rawValue
            )
            : nil
        contextTarget = EndpointStatisticsContextTarget(rowID: rowID, column: column)
    }

    private func contextCellValue() -> String? {
        guard rowsAreActionable,
              let rowIndex = contextTarget.resolvedRowIndex(
                rowIndexByID: rowIndexByID,
                rowCount: rows.count
              ),
              let column = contextTarget.column else {
            return nil
        }
        let value = column.stringValue(in: rows[rowIndex])
        return EndpointStatisticsSemanticCopyPolicy.copyableValue(
            value,
            isAggregatePlaceholder: column.isAggregatePlaceholder(in: rows[rowIndex])
        )
    }

    // Restore each protocol tab's own visible columns, order, and widths.
    private func applyColumnLayout(for group: EndpointStatisticsGroup) {
        guard let service = columnServices[group] else {
            return
        }
        isApplyingColumnLayout = true
        defer { isApplyingColumnLayout = false }

        let savedLayout = columnStores[group]?.load()
        var seenIdentifiers = Set<String>()
        let savedOrder = savedLayout?.columns.compactMap { column in
            service.definition(identifier: column.identifier) != nil && seenIdentifiers.insert(column.identifier).inserted
                ? column.identifier
                : nil
        } ?? []
        let missingIdentifiers = service.definitions.compactMap { definition in
            seenIdentifiers.insert(definition.identifier).inserted ? definition.identifier : nil
        }
        for (targetIndex, identifier) in (savedOrder + missingIdentifiers).enumerated() {
            guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == identifier
            }), currentIndex != targetIndex else {
                continue
            }
            tableView.moveColumn(currentIndex, toColumn: targetIndex)
        }
        var savedWidths: [String: Double] = [:]
        for column in savedLayout?.columns ?? [] where savedWidths[column.identifier] == nil {
            savedWidths[column.identifier] = column.width
        }
        for column in tableView.tableColumns {
            let identifier = column.identifier.rawValue
            column.isHidden = !service.isColumnVisible(identifier: identifier)
            if let width = savedWidths[identifier], width.isFinite {
                column.width = max(column.minWidth, CGFloat(width))
            } else if let definition = service.definition(identifier: identifier) {
                column.width = max(column.minWidth, CGFloat(definition.defaultWidth))
            }
        }

        let menuController = PacketTableColumnVisibilityMenuController(columnService: service)
        menuController.actionHandler = self
        columnVisibilityMenuController = menuController
        tableView.headerView?.menu = menuController.makeMenu()
        tableView.reloadData()
    }

    private func saveCurrentColumnLayout() {
        guard !isApplyingColumnLayout,
              let service = currentColumnService,
              let store = columnStores[selectedGroup] else {
            return
        }
        for column in tableView.tableColumns {
            service.syncColumnVisibility(
                identifier: column.identifier.rawValue,
                isVisible: !column.isHidden
            )
        }
        store.save(PacketTableColumnLayout(columns: tableView.tableColumns.map { column in
            PacketTableColumnLayout.Column(
                identifier: column.identifier.rawValue,
                isVisible: !column.isHidden,
                width: Double(column.width)
            )
        }))
    }

    private func applySortDescriptor(_ sort: EndpointStatisticsTableSort) {
        tableView.sortDescriptors = [NSSortDescriptor(
            key: sort.column.rawValue,
            ascending: sort.isAscending
        )]
    }

    @objc private func appConfigurationDidChange(_ notification: Notification) {
        tableView.rowHeight = configuration.packetRowHeight
        tableView.reloadData()
    }

    private static func columnDefinitions(
        for group: EndpointStatisticsGroup
    ) -> [PacketTableColumnDefinition] {
        EndpointStatisticsTableColumn.allCases.map { column in
            PacketTableColumnDefinition.custom(
                identifier: column.rawValue,
                title: column.title,
                defaultWidth: defaultWidth(for: column),
                minimumWidth: minimumWidth(for: column),
                cellKind: column == .client ? .client : (column == .protocolName ? .protocol : .text),
                isDefaultVisible: isDefaultVisible(column, group: group),
                canUserHide: true
            )
        }
    }

    private static func alignment(for column: EndpointStatisticsTableColumn) -> NSTextAlignment {
        column.isNumeric ? .right : (column == .protocolName ? .center : .left)
    }

    private static func isDefaultVisible(
        _ column: EndpointStatisticsTableColumn,
        group: EndpointStatisticsGroup
    ) -> Bool {
        switch column {
        case .address:
            group != .apps && group != .domains
        case .port:
            group == .tcp || group == .udp
        default:
            true
        }
    }

    private static func defaultWidth(for column: EndpointStatisticsTableColumn) -> Double {
        switch column {
        case .address: 190
        case .port: 72
        case .protocolName: 100
        case .client: 150
        case .domain: 190
        case .packets, .bytes: 98
        case .txPackets, .rxPackets: 105
        case .txBytes, .rxBytes: 100
        case .summary: 190
        }
    }

    private static func minimumWidth(for column: EndpointStatisticsTableColumn) -> Double {
        switch column {
        case .address, .domain: 110
        case .client: 90
        case .summary: 130
        default: 68
        }
    }
}

extension EndpointStatisticsViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        requestPresentation(intent: .explicit)
    }
}

extension EndpointStatisticsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        guard rows.indices.contains(row),
              let identifier = tableColumn?.identifier.rawValue,
              let column = EndpointStatisticsTableColumn(rawValue: identifier) else {
            return nil
        }
        return displayText(for: column, row: rows[row])
    }

    func tableView(
        _ tableView: NSTableView,
        willDisplayCell cell: Any,
        for tableColumn: NSTableColumn?,
        row: Int
    ) {
        guard rows.indices.contains(row),
              let identifier = tableColumn?.identifier.rawValue,
              let column = EndpointStatisticsTableColumn(rawValue: identifier) else {
            return
        }
        let endpoint = rows[row]
        if let cell = cell as? PacketProtocolCell {
            cell.configure(
                protocolText: endpoint.protocolName ?? "",
                severity: .normal,
                textStyle: .plain,
                configuration: configuration
            )
        } else if let cell = cell as? PacketClientCell {
            cell.configure(
                displayName: endpoint.client ?? "",
                iconFilePath: nil,
                textStyle: .plain,
                configuration: configuration
            )
        } else if let cell = cell as? PacketTextCell {
            let value = column.stringValue(in: endpoint)
            let style: PacketTextCell.Style = value.isEmpty || column.isAggregatePlaceholder(in: endpoint)
                ? .secondary
                : .primary
            cell.configure(style: style, textStyle: .plain, configuration: configuration)
        }
        if let cell = cell as? NSCell {
            cell.alignment = Self.alignment(for: column)
        }
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = EndpointStatisticsTableColumn(rawValue: key) else {
            sortByGroup[selectedGroup] = .busiestFirst
            requestPresentation(intent: .explicit)
            return
        }
        sortByGroup[selectedGroup] = EndpointStatisticsTableSort(
            column: column,
            isAscending: descriptor.ascending
        )
        requestPresentation(intent: .explicit)
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        saveCurrentColumnLayout()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        saveCurrentColumnLayout()
    }
}

extension EndpointStatisticsViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableView.menu {
            updateContextMenu(menu)
        }
    }
}

extension EndpointStatisticsViewController: EndpointStatisticsTableKeyboardActionHandling {
    func endpointStatisticsTableDidRequestCopy(_ tableView: NSTableView) {
        contextTarget = .none
        copy(selection: targetSelection(), asJSON: false)
    }
}

extension EndpointStatisticsViewController: PacketTableColumnVisibilityMenuActionHandling {
    func togglePacketTableColumnVisibilityFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let identifier = item.representedObject as? String,
              let service = currentColumnService,
              service.toggleColumnVisibility(identifier: identifier),
              let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)) else {
            return
        }
        column.isHidden = !service.isColumnVisible(identifier: identifier)
        saveCurrentColumnLayout()
        tableView.headerView?.menu?.cancelTracking()
    }

    func resetPacketTableColumnsFromMenu(_ sender: Any?) {
        guard let service = currentColumnService, let store = columnStores[selectedGroup] else {
            return
        }
        service.resetToDefaults()
        store.clear()
        applyColumnLayout(for: selectedGroup)
        tableView.headerView?.menu?.cancelTracking()
    }
}
