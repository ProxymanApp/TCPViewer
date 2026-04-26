import AppKit
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

private struct NetworkInspectorPreferences {
    private enum Key {
        static let displayFilterText = "TCPViewer.displayFilterText"
        static let inspectorVisible = "TCPViewer.inspectorVisible"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var displayFilterText: String {
        defaults.string(forKey: Key.displayFilterText) ?? ""
    }

    var isInspectorVisible: Bool {
        guard defaults.object(forKey: Key.inspectorVisible) != nil else {
            return true
        }

        return defaults.bool(forKey: Key.inspectorVisible)
    }

    func persistDisplayFilter(_ text: String) {
        defaults.set(text, forKey: Key.displayFilterText)
    }

    func persistInspectorVisible(_ isVisible: Bool) {
        defaults.set(isVisible, forKey: Key.inspectorVisible)
    }
}

private extension PacketSummary {
    func backsSavedPacket(_ savedPacket: PacketSummary) -> Bool {
        packetNumber == savedPacket.packetNumber &&
            source == savedPacket.source &&
            transportHint == savedPacket.transportHint &&
            endpoints == savedPacket.endpoints &&
            originalLength == savedPacket.originalLength &&
            capturedLength == savedPacket.capturedLength
    }
}

enum NetworkInspectorDebugLog {
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

private struct PacketTableContentCache {
    private var packetRevision: UInt64?
    private var packetLineageRevision: UInt64?
    private var sourcePacketCount = 0
    private var displayFilterText: String?
    private var sourceListSelection: PacketSourceListSelection?
    private var pinnedItems: [PacketPin] = []
    private var savedRecords: [SavedPacketRecord] = []
    private var generation: UInt64 = 0
    private var cachedContent = PacketTableContent.empty
    private var cachedRowTimingState = PacketTableRowTimingState()

    mutating func reset() {
        packetRevision = nil
        packetLineageRevision = nil
        sourcePacketCount = 0
        displayFilterText = nil
        sourceListSelection = nil
        pinnedItems = []
        savedRecords = []
        generation &+= 1
        cachedContent = .empty
        cachedRowTimingState = PacketTableRowTimingState()
    }

    #if DEBUG
    var debugMemorySnapshot: PacketTableContentCacheDebugSnapshot {
        PacketTableContentCacheDebugSnapshot(
            rowCount: cachedContent.rows.count,
            visiblePacketIndexCount: cachedContent.visiblePacketRowIndexByID.count
        )
    }
    #endif

    mutating func content(
        for ingestState: PacketIngestState,
        displayFilterText: String,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> PacketTableContent {
        guard shouldRebuildContent(
            ingestState: ingestState,
            displayFilterText: displayFilterText,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        ) else {
            return cachedContent
        }

        let displayFilter = PacketDisplayFilter(displayFilterText)
        let isStateStable = sourceListSelection != .saved &&
            self.displayFilterText == displayFilterText &&
            self.sourceListSelection == sourceListSelection &&
            self.pinnedItems == pinnedItems &&
            self.savedRecords == savedRecords &&
            packetLineageRevision == ingestState.packetLineageRevision &&
            sourcePacketCount <= ingestState.packets.count

        if isStateStable {
            switch ingestState.lastMutation {
            case .append:
                return appendContent(
                    from: ingestState.packets[sourcePacketCount...],
                    ingestState: ingestState,
                    displayFilter: displayFilter,
                    displayFilterText: displayFilterText,
                    sourceListSelection: sourceListSelection,
                    pinnedItems: pinnedItems,
                    savedRecords: savedRecords
                )
            case .appendWithMetadataUpdates(_, let updatedIDs):
                if let content = appendAndUpdateContent(
                    from: ingestState.packets[sourcePacketCount...],
                    updatedPacketIDs: updatedIDs,
                    ingestState: ingestState,
                    displayFilter: displayFilter,
                    displayFilterText: displayFilterText,
                    sourceListSelection: sourceListSelection,
                    pinnedItems: pinnedItems,
                    savedRecords: savedRecords
                ) {
                    return content
                }
            case .metadataUpdate(let updatedIDs):
                if let content = updateContent(
                    updatedPacketIDs: updatedIDs,
                    ingestState: ingestState,
                    displayFilter: displayFilter,
                    displayFilterText: displayFilterText,
                    sourceListSelection: sourceListSelection,
                    pinnedItems: pinnedItems,
                    savedRecords: savedRecords
                ) {
                    return content
                }
            default:
                break
            }
        }

        return rebuildContent(
            from: ingestState,
            displayFilter: displayFilter,
            displayFilterText: displayFilterText,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        )
    }

    private func shouldRebuildContent(
        ingestState: PacketIngestState,
        displayFilterText: String,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> Bool {
        let dependsOnIngestPackets = sourceListSelection != .saved
        return (dependsOnIngestPackets && packetRevision != ingestState.packetRevision) ||
            self.displayFilterText != displayFilterText ||
            self.sourceListSelection != sourceListSelection ||
            self.pinnedItems != pinnedItems ||
            self.savedRecords != savedRecords
    }

    private mutating func rebuildContent(
        from ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        displayFilterText: String,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> PacketTableContent {
        // Allocate a fresh store so any snapshots still referencing the previous one keep showing
        // their old rows until the new snapshot is published downstream.
        let newStore = PacketTableRowStore()
        var malformedPacketCount = 0
        let sourcePackets = packets(
            from: ingestState,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        )
        newStore.rows.reserveCapacity(sourcePackets.count)
        newStore.visiblePacketRowIndexByID.reserveCapacity(sourcePackets.count)
        var rowTimingState = PacketTableRowTimingState()

        for packet in sourcePackets {
            if NetworkInspectorFormatters.severity(for: packet) == .malformed {
                malformedPacketCount += 1
            }

            guard matches(packet, selection: sourceListSelection, pinnedItems: pinnedItems),
                  displayFilter.isEmpty || displayFilter.matches(packet) else {
                continue
            }

            let rowIndex = newStore.rows.count
            newStore.rows.append(rowTimingState.row(for: packet))
            newStore.visiblePacketRowIndexByID[packet.id] = rowIndex
        }

        generation &+= 1
        let updatePlan: PacketTableUpdatePlan = newStore.rows.isEmpty ? .none : .reload
        let content = PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            store: newStore,
            generation: generation,
            updatePlan: updatePlan,
            malformedPacketCount: malformedPacketCount
        )
        return store(
            content,
            ingestState: ingestState,
            displayFilterText: displayFilterText,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords,
            rowTimingState: rowTimingState
        )
    }

    private mutating func appendContent(
        from newPackets: ArraySlice<PacketSummary>,
        ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        displayFilterText: String,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> PacketTableContent {
        guard !newPackets.isEmpty else {
            return store(
                cachedContent,
                ingestState: ingestState,
                displayFilterText: displayFilterText,
                sourceListSelection: sourceListSelection,
                pinnedItems: pinnedItems,
                savedRecords: savedRecords
            )
        }

        // Mutate the store in place. The store class is the only owner of its rows array, so
        // append doesn't trigger Swift's Array CoW even though many `PacketTableContent` values
        // (and the published snapshot) reference the same store.
        let store = cachedContent.store
        var malformedPacketCount = cachedContent.malformedPacketCount
        var rowTimingState = cachedRowTimingState
        let appendStartIndex = store.rows.count

        store.rows.reserveCapacity(store.rows.count + newPackets.count)
        store.visiblePacketRowIndexByID.reserveCapacity(store.visiblePacketRowIndexByID.count + newPackets.count)

        for packet in newPackets {
            if NetworkInspectorFormatters.severity(for: packet) == .malformed {
                malformedPacketCount += 1
            }

            guard matches(packet, selection: sourceListSelection, pinnedItems: pinnedItems),
                  displayFilter.isEmpty || displayFilter.matches(packet) else {
                continue
            }

            let rowIndex = store.rows.count
            store.rows.append(rowTimingState.row(for: packet))
            store.visiblePacketRowIndexByID[packet.id] = rowIndex
        }

        let didAppendVisibleRows = store.rows.count > appendStartIndex
        if didAppendVisibleRows {
            generation &+= 1
        }

        let content = PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            store: store,
            generation: generation,
            updatePlan: didAppendVisibleRows ? .append(appendStartIndex..<store.rows.count) : .none,
            malformedPacketCount: malformedPacketCount
        )
        return self.store(
            content,
            ingestState: ingestState,
            displayFilterText: displayFilterText,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords,
            rowTimingState: rowTimingState
        )
    }

    // Apply in-place row updates for a metadata back-fill batch. Returns nil if visibility flipped
    // for any affected packet (caller must fall back to rebuildContent).
    private mutating func updateContent(
        updatedPacketIDs: [PacketSummary.ID],
        ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        displayFilterText: String,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> PacketTableContent? {
        guard let result = computeRowUpdates(
            updatedPacketIDs: updatedPacketIDs,
            ingestState: ingestState,
            displayFilter: displayFilter,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            store: cachedContent.store,
            existingTimingState: cachedRowTimingState
        ) else {
            return nil
        }

        let didChange = !result.reloadIndexes.isEmpty
        if didChange {
            generation &+= 1
        }

        let content = PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            store: cachedContent.store,
            generation: generation,
            updatePlan: didChange ? .reloadRows(result.reloadIndexes) : .none,
            malformedPacketCount: cachedContent.malformedPacketCount
        )
        return store(
            content,
            ingestState: ingestState,
            displayFilterText: displayFilterText,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords,
            rowTimingState: result.rowTimingState
        )
    }

    private mutating func appendAndUpdateContent(
        from newPackets: ArraySlice<PacketSummary>,
        updatedPacketIDs: [PacketSummary.ID],
        ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        displayFilterText: String,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> PacketTableContent? {
        // Run the existing append path first so older-row updates apply on top of the new rows.
        let appendedContent = appendContent(
            from: newPackets,
            ingestState: ingestState,
            displayFilter: displayFilter,
            displayFilterText: displayFilterText,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        )

        guard !updatedPacketIDs.isEmpty else {
            return appendedContent
        }

        guard let result = computeRowUpdates(
            updatedPacketIDs: updatedPacketIDs,
            ingestState: ingestState,
            displayFilter: displayFilter,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            store: appendedContent.store,
            existingTimingState: cachedRowTimingState
        ) else {
            return nil
        }

        let appendRange: Range<Int>?
        if case .append(let range) = appendedContent.updatePlan {
            appendRange = range
        } else {
            appendRange = nil
        }

        let didReloadAny = !result.reloadIndexes.isEmpty
        if didReloadAny {
            generation &+= 1
        }

        let plan: PacketTableUpdatePlan
        switch (appendRange, didReloadAny) {
        case (nil, false):
            plan = .none
        case (let range?, false):
            plan = .append(range)
        case (nil, true):
            plan = .reloadRows(result.reloadIndexes)
        case (let range?, true):
            plan = .appendAndReloadRows(append: range, reload: result.reloadIndexes)
        }

        let content = PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            store: appendedContent.store,
            generation: generation,
            updatePlan: plan,
            malformedPacketCount: appendedContent.malformedPacketCount
        )
        return store(
            content,
            ingestState: ingestState,
            displayFilterText: displayFilterText,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords,
            rowTimingState: result.rowTimingState
        )
    }

    private struct RowUpdateResult {
        var reloadIndexes: IndexSet
        var rowTimingState: PacketTableRowTimingState
    }

    // Walk the affected packet IDs once and update the store's rows in place. Returns nil if any
    // update would flip visibility under the current selection/filter (caller falls back to
    // rebuild). The store may be partially mutated when nil is returned; the caller is expected
    // to discard it via rebuildContent, which allocates a fresh store from scratch.
    private func computeRowUpdates(
        updatedPacketIDs: [PacketSummary.ID],
        ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        store: PacketTableRowStore,
        existingTimingState: PacketTableRowTimingState
    ) -> RowUpdateResult? {
        var reloadIndexes = IndexSet()
        var rowTimingState = existingTimingState

        for packetID in updatedPacketIDs {
            guard let packet = ingestState.packet(withID: packetID) else {
                continue
            }
            let isVisibleNow = matches(packet, selection: sourceListSelection, pinnedItems: pinnedItems) &&
                (displayFilter.isEmpty || displayFilter.matches(packet))
            let wasVisible = store.visiblePacketRowIndexByID[packetID] != nil
            guard wasVisible == isVisibleNow else {
                return nil  // visibility flipped — caller falls back to rebuild
            }
            guard isVisibleNow, let rowIndex = store.visiblePacketRowIndexByID[packetID] else {
                continue
            }
            store.rows[rowIndex] = rowTimingState.row(for: packet)
            reloadIndexes.insert(rowIndex)
        }

        return RowUpdateResult(
            reloadIndexes: reloadIndexes,
            rowTimingState: rowTimingState
        )
    }

    private mutating func store(
        _ content: PacketTableContent,
        ingestState: PacketIngestState,
        displayFilterText: String,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord],
        rowTimingState: PacketTableRowTimingState? = nil
    ) -> PacketTableContent {
        packetRevision = ingestState.packetRevision
        packetLineageRevision = ingestState.packetLineageRevision
        sourcePacketCount = ingestState.packets.count
        self.displayFilterText = displayFilterText
        self.sourceListSelection = sourceListSelection
        self.pinnedItems = pinnedItems
        self.savedRecords = savedRecords
        cachedContent = content
        if let rowTimingState {
            cachedRowTimingState = rowTimingState
        }
        return content
    }

    private func packets(
        from ingestState: PacketIngestState,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> [PacketSummary] {
        switch sourceListSelection {
        case .saved:
            return savedRecords.map(\.packet)
        case .pinned, .pinnedItem:
            return ingestState.packets.filter { matches($0, selection: sourceListSelection, pinnedItems: pinnedItems) }
        default:
            return ingestState.packets
        }
    }

    private func matches(
        _ packet: PacketSummary,
        selection: PacketSourceListSelection,
        pinnedItems: [PacketPin]
    ) -> Bool {
        switch selection {
        case .pinned:
            return pinnedItems.contains { PacketPinMatcher.matches(packet, pin: $0) }
        case .pinnedItem(let pinID):
            guard let pin = pinnedItems.first(where: { $0.id == pinID }) else {
                return false
            }
            return PacketPinMatcher.matches(packet, pin: pin)
        case .saved:
            return true
        default:
            return PacketSourceListClassifier.matches(packet, selection: selection)
        }
    }
}

#if DEBUG
struct PacketTableContentCacheDebugSnapshot: Equatable {
    let rowCount: Int
    let visiblePacketIndexCount: Int
}

struct NetworkInspectorMemoryDebugSnapshot: Equatable {
    let ingestPacketCount: Int
    let packetIndexCount: Int
    let navigationVisibleIDCount: Int
    let tableRowCount: Int
    let tableVisiblePacketIndexCount: Int
    let sourceListAppBucketCount: Int
    let sourceListDomainBucketCount: Int
    let metadata: PacketMetadataEnrichmentDebugSnapshot
    let liveSession: LiveCaptureSessionDebugSnapshot?

    var logDescription: String {
        [
            "ingestPackets=\(ingestPacketCount)",
            "packetIndex=\(packetIndexCount)",
            "navIDs=\(navigationVisibleIDCount)",
            "tableRows=\(tableRowCount)",
            "tableVisibleIndex=\(tableVisiblePacketIndexCount)",
            "sourceApps=\(sourceListAppBucketCount)",
            "sourceDomains=\(sourceListDomainBucketCount)",
            "metadataFlows=\(metadata.flowCount)",
            "metadataPendingIDs=\(metadata.pendingPacketIDCount)",
            "resolverPIDClients=\(metadata.clientResolver.pidClientCount)",
            "resolverProcessIdentities=\(metadata.clientResolver.processIdentityCacheCount)",
            "resolverBundleIdentities=\(metadata.clientResolver.bundleIdentityCacheCount)",
            "livePendingBatch=\(liveSession?.pendingBatchCount.description ?? "nil")",
            "liveActiveRunPackets=\(liveSession?.activeRunPacketCount.description ?? "nil")",
        ].joined(separator: ", ")
    }
}
#endif

protocol NetworkInspectorViewModelDelegate: AnyObject {
    func networkInspectorViewModelDidChange(_ viewModel: NetworkInspectorViewModel)
}

final class NetworkInspectorViewModel {
    weak var delegate: NetworkInspectorViewModelDelegate?

    private(set) var snapshot: NetworkInspectorSnapshot {
        didSet {
            delegate?.networkInspectorViewModelDidChange(self)
        }
    }

    private let controller: TCPViewerWorkspaceController
    private let preferences: NetworkInspectorPreferences
    private let sourceListService = PacketSourceListService()
    private let pinService: PacketPinService
    private let savedPacketService: SavedPacketService
    private let packetExportService: PacketExportService
    private var packetTableContentCache = PacketTableContentCache()
    private var hasPerformedInitialLoad = false
    private var pendingRebuildWorkItem: DispatchWorkItem?

    // Trailing-edge debounce for delegate-driven rebuilds. Live ingest fires the controller delegate
    // up to ~10 Hz; coalescing to ~12 Hz keeps the UI feeling live without burning CPU on redundant
    // rebuilds. User-driven actions bypass this and rebuild synchronously.
    private static let rebuildCoalesceInterval: TimeInterval = 0.08

    private var selectedSidebar: NetworkInspectorSidebarSelection = .liveCapture
    private var selectedSourceListSelection: PacketSourceListSelection = .allPackets
    private var sourceListFilterText = ""
    private var workspaceMode: NetworkInspectorWorkspaceMode = .packets
    private var inspectorTab: PacketInspectorTab = .summary
    private var isInspectorVisible: Bool
    private var displayFilterText: String
    private var helperOnboardingDismissed = false

    convenience init(userDefaults: UserDefaults = .standard) {
        self.init(services: .foundation, userDefaults: userDefaults)
    }

    init(
        services: TCPViewerServiceRegistry,
        userDefaults: UserDefaults = .standard,
        interfaceHistoryStore: InterfaceSelectionHistoryStore? = nil,
        pinService: PacketPinService = PacketPinService(),
        savedPacketService: SavedPacketService = SavedPacketService(),
        packetExportService: PacketExportService? = nil
    ) {
        self.controller = TCPViewerWorkspaceController(
            services: services,
            userDefaults: userDefaults,
            interfaceHistoryStore: interfaceHistoryStore
        )
        self.preferences = NetworkInspectorPreferences(defaults: userDefaults)
        self.pinService = pinService
        self.savedPacketService = savedPacketService
        self.packetExportService = packetExportService ?? PacketExportService(defaults: userDefaults)
        self.isInspectorVisible = preferences.isInspectorVisible
        self.displayFilterText = preferences.displayFilterText
        let sourceListSnapshot = sourceListService.snapshot(
            for: controller.snapshot.packetIngestState,
            pinnedItems: pinService.pins(),
            savedPacketCount: savedPacketService.records().count
        )
        let packetTableContent = packetTableContentCache.content(
            for: controller.snapshot.packetIngestState,
            displayFilterText: displayFilterText,
            sourceListSelection: selectedSourceListSelection,
            pinnedItems: pinService.pins(),
            savedRecords: savedPacketService.records()
        )
        self.snapshot = NetworkInspectorSnapshot.make(
            base: controller.snapshot,
            selectedSidebar: selectedSidebar,
            selectedSourceListSelection: selectedSourceListSelection,
            sourceListSnapshot: sourceListSnapshot,
            sourceListFilterText: sourceListFilterText,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            isInspectorVisible: isInspectorVisible,
            displayFilterText: displayFilterText,
            packetTableContent: packetTableContent
        )

        controller.delegate = self
    }

    func performInitialLoadIfNeeded(completion: (() -> Void)? = nil) {
        guard !hasPerformedInitialLoad else {
            completion?()
            return
        }

        hasPerformedInitialLoad = true
        controller.performInitialLoadIfNeeded { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func refreshInterfaces(completion: (() -> Void)? = nil) {
        controller.refreshInterfaces { [weak self] in
            self?.helperOnboardingDismissed = false
            self?.rebuildSnapshot()
            completion?()
        }
    }

    var shouldPresentNetworkHelperOnboarding: Bool {
        snapshot.base.accessState.requiresGuidance &&
            !snapshot.base.accessState.isCaptureReady &&
            snapshot.base.sessionState.lastError?.code == .capturePermissionDenied &&
            !helperOnboardingDismissed
    }

    var networkHelperToolSnapshot: TCPViewerNetworkHelperToolSnapshot {
        controller.networkHelperToolSnapshot
    }

    func dismissNetworkHelperOnboarding() {
        helperOnboardingDismissed = true
        rebuildSnapshot()
    }

    func installNetworkHelperTool(completion: (() -> Void)? = nil) {
        controller.installNetworkHelperTool { [weak self] in
            self?.helperOnboardingDismissed = false
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func repairNetworkHelperTool(completion: (() -> Void)? = nil) {
        controller.repairNetworkHelperTool { [weak self] in
            self?.helperOnboardingDismissed = false
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func retryNetworkHelperToolStatus(completion: (() -> Void)? = nil) {
        controller.refreshNetworkHelperToolStatus { [weak self] in
            self?.helperOnboardingDismissed = false
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func openNetworkHelperSystemSettings() {
        controller.openNetworkHelperSystemSettings()
    }

    func relaunchTCPViewer() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
    }

    func selectSidebar(_ selection: NetworkInspectorSidebarSelection?) {
        guard let selection else {
            return
        }

        selectedSidebar = selection

        switch selection {
        case .liveCapture:
            workspaceMode = .packets
        case .recentCaptures, .savedSessions:
            workspaceMode = .packets
        case .interface(let identifier):
            controller.selectInterface(identifier)
        case .view(let mode):
            workspaceMode = mode
        }

        rebuildSnapshot()
    }

    func selectSourceList(_ selection: PacketSourceListSelection?) {
        selectedSourceListSelection = selection ?? .allPackets
        workspaceMode = .packets
        rebuildSnapshot()
    }

    func deleteSourceListItem(_ action: PacketSourceListDeletionAction) {
        switch action {
        case .none:
            return
        case .deletePin(let pinID):
            deletePin(pinID)
        case .deletePackets(let selection):
            deletePackets(packetIDs(matching: selection))
        }
    }

    func updateSourceListFilterText(_ text: String) {
        sourceListFilterText = text
        rebuildSnapshot()
    }

    func selectWorkspaceMode(_ mode: NetworkInspectorWorkspaceMode) {
        workspaceMode = mode
        selectedSidebar = .view(mode)
        rebuildSnapshot()
    }

    func selectInterface(_ identifier: String) {
        selectedSidebar = .interface(identifier)
        controller.selectInterface(identifier)
        rebuildSnapshot()
    }

    func updateDisplayFilterText(_ text: String) {
        displayFilterText = text
        preferences.persistDisplayFilter(text)
        rebuildSnapshot()
    }

    func clearDisplayFilter() {
        updateDisplayFilterText("")
    }

    func clearPackets() {
        #if DEBUG
        logClearMemorySnapshot("before")
        #endif
        controller.clearPackets()
        packetTableContentCache.reset()
        sourceListService.reset()
        rebuildSnapshot()
        #if DEBUG
        logClearMemorySnapshot("after")
        #endif
    }

    func clearTablePackets() {
        let identifiers = snapshot.packetRows.map(\.id)
        deletePackets(identifiers)
    }

    func pinPacket(_ identifier: PacketSummary.ID, kind: PacketPinCreationKind, clickedColumn: PacketTableColumnRole) {
        guard let packet = packet(withID: identifier),
              let pin = try? pinService.upsertPin(from: packet, kind: kind, clickedColumn: clickedColumn) else {
            return
        }

        selectedSourceListSelection = .pinnedItem(pin.id)
        workspaceMode = .packets
        rebuildSnapshot()
    }

    func savePackets(_ identifiers: [PacketSummary.ID]) {
        let packets = packets(withIDs: identifiers)
        let activePacketIDs = Set(controller.snapshot.packetIngestState.packets.map(\.id))
        let backingIdentity = identifiers.allSatisfy { activePacketIDs.contains($0) }
            ? controller.snapshot.packetIngestState.backingIdentity
            : nil
        guard !packets.isEmpty, (try? savedPacketService.save(packets, backingIdentity: backingIdentity)) != nil else {
            return
        }

        rebuildSnapshot()
    }

    func deletePackets(_ identifiers: [PacketSummary.ID]) {
        let packetIDs = Set(identifiers)
        guard !packetIDs.isEmpty else {
            return
        }

        let nextSelectionID = nextVisiblePacketIDAfterDeleting(packetIDs)
        if selectedSourceListSelection == .saved {
            guard (try? savedPacketService.deletePacketIDs(packetIDs)) != nil else {
                return
            }
        } else {
            controller.deletePackets(packetIDs)
            packetTableContentCache.reset()
        }

        if let nextSelectionID,
           controller.snapshot.packetIngestState.packet(withID: nextSelectionID) != nil {
            controller.selectPacket(nextSelectionID)
        }
        rebuildSnapshot()
    }

    private func deletePin(_ pinID: PacketPinID) {
        guard (try? pinService.deletePin(id: pinID)) != nil else {
            return
        }

        if selectedSourceListSelection == .pinnedItem(pinID) {
            selectedSourceListSelection = .pinned
        }
        rebuildSnapshot()
    }

    private func presentExportPanel(
        identifiers: [PacketSummary.ID],
        scopeName: String,
        format: CaptureFileFormat,
        requiresSavedBacking: Bool,
        attachedTo window: NSWindow?
    ) {
        do {
            let identifiers = try validatedExportPacketIDs(identifiers, requiresSavedBacking: requiresSavedBacking)
            guard !identifiers.isEmpty else {
                return
            }

            guard let destination = packetExportService.chooseDestination(scopeName: scopeName, format: format) else {
                return
            }

            let cancellationToken = PacketExportCancellationToken()
            let progressSheet = packetExportService.showProgressSheet(
                attachedTo: window,
                fileName: destination.url.lastPathComponent
            ) {
                cancellationToken.cancel()
            }

            exportPackets(
                identifiers,
                to: destination.url,
                format: destination.format,
                requiresSavedBacking: requiresSavedBacking,
                progress: { progress in
                    DispatchQueue.main.async {
                        progressSheet.update(progress)
                    }
                },
                shouldCancel: {
                    cancellationToken.isCancelled()
                }
            ) { [weak self] result in
                DispatchQueue.main.async {
                    progressSheet.dismiss()
                    if case .failure(let error) = result,
                       self?.isExportCancellation(error) != true {
                        self?.packetExportService.presentFailure(error)
                    }
                }
            }
        } catch {
            packetExportService.presentFailure(error)
        }
    }

    private func exportPackets(
        _ identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        requiresSavedBacking: Bool,
        progress: PacketExportProgressHandler? = nil,
        shouldCancel: PacketExportCancellationCheck? = nil,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        do {
            let identifiers = try validatedExportPacketIDs(identifiers, requiresSavedBacking: requiresSavedBacking)
            guard !identifiers.isEmpty else {
                completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "There are no packets to export.")))
                return
            }

            controller.exportPackets(
                withIDs: identifiers,
                to: url,
                format: format,
                progress: progress,
                shouldCancel: shouldCancel
            ) { [weak self] result in
                if case .success = result {
                    self?.packetExportService.rememberDestination(url)
                }
                self?.rebuildSnapshot()
                completion(result)
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func validatedExportPacketIDs(
        _ identifiers: [PacketSummary.ID],
        requiresSavedBacking: Bool
    ) throws -> [PacketSummary.ID] {
        let activePacketsByID = Dictionary(uniqueKeysWithValues: controller.snapshot.packetIngestState.packets.map { ($0.id, $0) })
        let missingActiveIDs = identifiers.filter { activePacketsByID[$0] == nil }
        guard missingActiveIDs.isEmpty else {
            throw TCPViewerCoreError(code: .offlineFileSaveFailed, message: "Some selected packets are no longer available in the active capture.")
        }

        guard requiresSavedBacking else {
            return identifiers
        }

        guard let activeBackingIdentity = controller.snapshot.packetIngestState.backingIdentity else {
            throw TCPViewerCoreError(code: .offlineFileSaveFailed, message: "Saved packets from another session cannot be exported because their raw bytes are not available.")
        }

        let savedRecordsByPacketID = Dictionary(uniqueKeysWithValues: savedPacketService.records().map { ($0.packet.id, $0) })
        for identifier in identifiers {
            guard let record = savedRecordsByPacketID[identifier],
                  record.backingIdentity == activeBackingIdentity,
                  let activePacket = activePacketsByID[identifier],
                  activePacket.backsSavedPacket(record.packet) else {
                throw TCPViewerCoreError(code: .offlineFileSaveFailed, message: "Saved packets from another session cannot be exported because their raw bytes are not available.")
            }
        }

        return identifiers
    }

    private func isExportCancellation(_ error: Error) -> Bool {
        (error as? TCPViewerCoreError)?.code == .operationCancelled
    }

    private func exportPacketIDs(matching selection: PacketSourceListSelection) throws -> [PacketSummary.ID] {
        switch selection {
        case .saved:
            let identifiers = savedPacketService.records().map(\.packet.id)
            return try validatedExportPacketIDs(identifiers, requiresSavedBacking: true)
        case .pinned:
            let pins = pinService.pins()
            return controller.snapshot.packetIngestState.packets.compactMap { packet in
                pins.contains { PacketPinMatcher.matches(packet, pin: $0) } ? packet.id : nil
            }
        case .pinnedItem(let pinID):
            guard let pin = pinService.pins().first(where: { $0.id == pinID }) else {
                return []
            }

            return controller.snapshot.packetIngestState.packets.compactMap { packet in
                PacketPinMatcher.matches(packet, pin: pin) ? packet.id : nil
            }
        default:
            return controller.snapshot.packetIngestState.packets.compactMap { packet in
                PacketSourceListClassifier.matches(packet, selection: selection) ? packet.id : nil
            }
        }
    }

    private func exportScopeName(for selection: PacketSourceListSelection) -> String {
        let title = snapshot.sourceListSnapshot.item(for: selection)?.title ?? "Selection"
        return "TCPViewer-\(title)"
    }

    private func packetIDs(matching selection: PacketSourceListSelection) -> [PacketSummary.ID] {
        controller.snapshot.packetIngestState.packets.compactMap { packet in
            PacketSourceListClassifier.matches(packet, selection: selection) ? packet.id : nil
        }
    }

    func updateCaptureFilterText(_ text: String) {
        controller.updateCaptureFilterText(text)
        rebuildSnapshot()
    }

    func applyRecentCaptureFilter(_ value: String) {
        controller.applyRecentCaptureFilter(value)
        rebuildSnapshot()
    }

    func validateCaptureFilter(completion: (() -> Void)? = nil) {
        controller.validateCaptureFilter { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func toggleLiveCapture(completion: (() -> Void)? = nil) {
        if snapshot.base.sessionState.canStop {
            controller.stopLiveCapture { [weak self] in
                self?.rebuildSnapshot()
                completion?()
            }
        } else {
            controller.startLiveCapture { [weak self] in
                self?.rebuildSnapshot()
                completion?()
            }
        }
    }

    func pauseLiveCapture(completion: (() -> Void)? = nil) {
        controller.pauseLiveCapture { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func resumeLiveCapture(completion: (() -> Void)? = nil) {
        controller.resumeLiveCapture { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func stopLiveCapture(completion: (() -> Void)? = nil) {
        controller.stopLiveCapture { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func openDocument(at fileURL: URL, completion: (() -> Void)? = nil) {
        controller.openDocument(at: fileURL) { [weak self] in
            self?.workspaceMode = .packets
            self?.selectedSidebar = .liveCapture
            self?.selectedSourceListSelection = .allPackets
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func presentOpenCapturePanel() {
        controller.presentOpenCapturePanel()
        rebuildSnapshot()
    }

    func saveDocument(completion: (() -> Void)? = nil) {
        controller.saveDocument { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func saveDocument(to url: URL, format: CaptureFileFormat, completion: (() -> Void)? = nil) {
        controller.saveDocument(to: url, format: format) { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func presentSaveCapturePanel(format: CaptureFileFormat) {
        controller.presentSaveCapturePanel(format: format)
        rebuildSnapshot()
    }

    func presentSessionExportPanel(format: CaptureFileFormat, attachedTo window: NSWindow?) {
        presentExportPanel(
            identifiers: controller.snapshot.packetIngestState.packets.map(\.id),
            scopeName: "TCPViewer-Session",
            format: format,
            requiresSavedBacking: false,
            attachedTo: window
        )
    }

    func presentPacketExportPanel(identifiers: [PacketSummary.ID], format: CaptureFileFormat, attachedTo window: NSWindow?) {
        presentExportPanel(
            identifiers: identifiers,
            scopeName: "TCPViewer-Selection",
            format: format,
            requiresSavedBacking: selectedSourceListSelection == .saved,
            attachedTo: window
        )
    }

    func presentSourceListExportPanel(selection: PacketSourceListSelection, format: CaptureFileFormat, attachedTo window: NSWindow?) {
        do {
            let identifiers = try exportPacketIDs(matching: selection)
            presentExportPanel(
                identifiers: identifiers,
                scopeName: exportScopeName(for: selection),
                format: format,
                requiresSavedBacking: selection == .saved,
                attachedTo: window
            )
        } catch {
            packetExportService.presentFailure(error)
        }
    }

    func exportSession(
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler? = nil,
        shouldCancel: PacketExportCancellationCheck? = nil,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        exportPackets(
            controller.snapshot.packetIngestState.packets.map(\.id),
            to: url,
            format: format,
            requiresSavedBacking: false,
            progress: progress,
            shouldCancel: shouldCancel,
            completion: completion
        )
    }

    func exportPackets(
        _ identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler? = nil,
        shouldCancel: PacketExportCancellationCheck? = nil,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        exportPackets(
            identifiers,
            to: url,
            format: format,
            requiresSavedBacking: selectedSourceListSelection == .saved,
            progress: progress,
            shouldCancel: shouldCancel,
            completion: completion
        )
    }

    func exportSourceList(
        _ selection: PacketSourceListSelection,
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler? = nil,
        shouldCancel: PacketExportCancellationCheck? = nil,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        do {
            let identifiers = try exportPacketIDs(matching: selection)
            exportPackets(
                identifiers,
                to: url,
                format: format,
                requiresSavedBacking: selection == .saved,
                progress: progress,
                shouldCancel: shouldCancel,
                completion: completion
            )
        } catch {
            completion(.failure(error))
        }
    }

    func cancelDocumentLoading(completion: (() -> Void)? = nil) {
        controller.cancelDocumentLoading { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
    }

    func selectPacket(_ identifier: PacketSummary.ID?) {
        print("[TCPViewer] \(NetworkInspectorDebugLog.timestamp()) 🎯 Packet row selected: \(identifier?.description ?? "nil")")
        controller.selectPacket(identifier)
        if identifier != nil {
            inspectorTab = .summary
        }
        rebuildSnapshot()
    }

    func selectDetailNode(_ identifier: String?) {
        controller.selectDetailNode(identifier)
        rebuildSnapshot()
    }

    func selectInspectorTab(_ tab: PacketInspectorTab) {
        inspectorTab = tab
        rebuildSnapshot()
    }

    func setInspectorVisible(_ isVisible: Bool) {
        isInspectorVisible = isVisible
        preferences.persistInspectorVisible(isVisible)
        rebuildSnapshot()
    }

    func toggleInspector() {
        setInspectorVisible(!isInspectorVisible)
    }

    func selectedInterfaceTitle() -> String {
        guard let selectedInterface = snapshot.base.sessionState.selectedInterface else {
            return "Interface"
        }

        return selectedInterface.friendlyName ?? selectedInterface.displayName
    }

    func captureButtonTitle() -> String {
        snapshot.base.sessionState.canStop ? "Stop" : "Start"
    }

    func captureButtonSystemImage() -> String {
        snapshot.base.sessionState.canStop ? "stop.fill" : "play.fill"
    }

    private func rebuildSnapshot() {
        cancelPendingRebuild()
        let pinnedItems = pinService.pins()
        let savedRecords = savedPacketService.records()
        let sourceListSnapshot = sourceListService.snapshot(
            for: controller.snapshot.packetIngestState,
            pinnedItems: pinnedItems,
            savedPacketCount: savedRecords.count
        )
        if !sourceListSnapshot.contains(selection: selectedSourceListSelection) {
            selectedSourceListSelection = .allPackets
        }

        let packetTableContent = packetTableContentCache.content(
            for: controller.snapshot.packetIngestState,
            displayFilterText: displayFilterText,
            sourceListSelection: selectedSourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        )
        let updatedSnapshot = NetworkInspectorSnapshot.make(
            base: controller.snapshot,
            selectedSidebar: selectedSidebar,
            selectedSourceListSelection: selectedSourceListSelection,
            sourceListSnapshot: sourceListSnapshot,
            sourceListFilterText: sourceListFilterText,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            isInspectorVisible: isInspectorVisible,
            displayFilterText: displayFilterText,
            packetTableContent: packetTableContent
        )
        guard updatedSnapshot != snapshot else {
            return
        }

        snapshot = updatedSnapshot
    }

    private func scheduleCoalescedRebuild() {
        guard pendingRebuildWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingRebuildWorkItem = nil
            self.rebuildSnapshot()
        }
        pendingRebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rebuildCoalesceInterval, execute: workItem)
    }

    private func cancelPendingRebuild() {
        pendingRebuildWorkItem?.cancel()
        pendingRebuildWorkItem = nil
    }

    deinit {
        pendingRebuildWorkItem?.cancel()
    }

    #if DEBUG
    var hasPendingCoalescedRebuildForTesting: Bool {
        pendingRebuildWorkItem != nil
    }

    func flushPendingCoalescedRebuildForTesting() {
        guard pendingRebuildWorkItem != nil else {
            return
        }
        rebuildSnapshot()
    }
    #endif

    private func packet(withID identifier: PacketSummary.ID) -> PacketSummary? {
        controller.snapshot.packetIngestState.packet(withID: identifier) ??
            savedPacketService.records().first { $0.packet.id == identifier }?.packet
    }

    private func packets(withIDs identifiers: [PacketSummary.ID]) -> [PacketSummary] {
        var packetsByID: [PacketSummary.ID: PacketSummary] = [:]
        for record in savedPacketService.records() {
            packetsByID[record.packet.id] = record.packet
        }
        for packet in controller.snapshot.packetIngestState.packets {
            packetsByID[packet.id] = packet
        }

        return identifiers.compactMap { packetsByID[$0] }
    }

    private func nextVisiblePacketIDAfterDeleting(_ packetIDs: Set<PacketSummary.ID>) -> PacketSummary.ID? {
        // Prefer the row after the deleted range, then fall back to the previous remaining row.
        let rows = snapshot.packetRows
        let deletedIndexes = rows.indices.filter { packetIDs.contains(rows[$0].id) }
        guard let lastDeletedIndex = deletedIndexes.last else {
            return nil
        }

        let nextIndex = lastDeletedIndex + 1
        if rows.indices.contains(nextIndex) {
            return rows[nextIndex].id
        }

        return rows.indices.reversed()
            .first { $0 < lastDeletedIndex && !packetIDs.contains(rows[$0].id) }
            .map { rows[$0].id }
    }

    #if DEBUG
    func debugMemorySnapshot() -> NetworkInspectorMemoryDebugSnapshot {
        let tableSnapshot = packetTableContentCache.debugMemorySnapshot
        let sourceListSnapshot = sourceListService.debugMemorySnapshot()
        let workspaceSnapshot = controller.debugMemorySnapshot()
        return NetworkInspectorMemoryDebugSnapshot(
            ingestPacketCount: workspaceSnapshot.ingestPacketCount,
            packetIndexCount: workspaceSnapshot.packetIndexCount,
            navigationVisibleIDCount: workspaceSnapshot.navigationVisibleIDCount,
            tableRowCount: tableSnapshot.rowCount,
            tableVisiblePacketIndexCount: tableSnapshot.visiblePacketIndexCount,
            sourceListAppBucketCount: sourceListSnapshot.appBucketCount,
            sourceListDomainBucketCount: sourceListSnapshot.domainBucketCount,
            metadata: workspaceSnapshot.metadata,
            liveSession: workspaceSnapshot.liveSession
        )
    }

    private func logClearMemorySnapshot(_ phase: String) {
        let snapshot = debugMemorySnapshot()
        print("[TCPViewer] 🧹 Clear memory \(phase): \(snapshot.logDescription)")
    }
    #endif
}

extension NetworkInspectorViewModel: TCPViewerWorkspaceControllerDelegate {
    func tcpViewerWorkspaceControllerDidChange(_ controller: TCPViewerWorkspaceController) {
        scheduleCoalescedRebuild()
    }
}
