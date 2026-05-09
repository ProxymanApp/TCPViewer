//
//  NetworkInspectorViewModel.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

private struct NetworkInspectorPreferences {
    private enum Key {
        static let displayFilterText = "TCPViewer.displayFilterText"
        static let inspectorVisible = "TCPViewer.inspectorVisible"
        static let sidebarLeadingThickness = "TCPViewer.sidebarLeadingThickness"
        static let sidebarVisible = "TCPViewer.sidebarVisible"
        static let structuredFilterVisible = "TCPViewer.structuredFilterVisible"
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

    var isSidebarVisible: Bool {
        guard defaults.object(forKey: Key.sidebarVisible) != nil else {
            return true
        }

        return defaults.bool(forKey: Key.sidebarVisible)
    }

    var isStructuredFilterVisible: Bool {
        guard defaults.object(forKey: Key.structuredFilterVisible) != nil else {
            return false
        }

        return defaults.bool(forKey: Key.structuredFilterVisible)
    }

    var sidebarThickness: CGFloat? {
        guard defaults.object(forKey: Key.sidebarLeadingThickness) != nil else {
            return nil
        }

        return CGFloat(defaults.double(forKey: Key.sidebarLeadingThickness))
    }

    func persistDisplayFilter(_ text: String) {
        defaults.set(text, forKey: Key.displayFilterText)
    }

    func persistInspectorVisible(_ isVisible: Bool) {
        defaults.set(isVisible, forKey: Key.inspectorVisible)
    }

    func persistSidebarThickness(_ thickness: CGFloat) {
        defaults.set(Double(thickness), forKey: Key.sidebarLeadingThickness)
    }

    func persistSidebarVisible(_ isVisible: Bool) {
        defaults.set(isVisible, forKey: Key.sidebarVisible)
    }

    func persistStructuredFilterVisible(_ isVisible: Bool) {
        defaults.set(isVisible, forKey: Key.structuredFilterVisible)
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

private final class PacketTableFilterCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        return cancelled
    }
}

private struct PacketTableFilterSignature: Equatable, Sendable {
    let displayFilterText: String
    let quickFilterSelection: PacketQuickFilterSelection
    let structuredFilterGroup: PacketStructuredFilterGroup
    let sourceListSelection: PacketSourceListSelection
    let pinnedItems: [PacketPin]
    let savedRecords: [SavedPacketRecord]
}

private struct PacketTableBuildInput: Sendable {
    let ingestState: PacketIngestState
    let signature: PacketTableFilterSignature

    var sourcePacketCount: Int {
        switch signature.sourceListSelection {
        case .saved:
            return signature.savedRecords.count
        default:
            return ingestState.packets.count
        }
    }
}

private struct PacketTableBuildOutput: Sendable {
    let displayFilter: PacketDisplayFilter
    let store: PacketTableRowStore
    let malformedPacketCount: Int
    let rowTimingState: PacketTableRowTimingState
}

private enum PacketTableContentResolution {
    case ready(PacketTableContent)
    case deferred(PacketTableContent, PacketTableBuildInput)
}

private enum PacketTableContentBuilder {
    static func rebuildContent(
        input: PacketTableBuildInput,
        shouldCancel: (() -> Bool)? = nil
    ) -> PacketTableBuildOutput? {
        let displayFilter = PacketDisplayFilter(input.signature.displayFilterText)
        let quickFilterService = PacketQuickFilterService(selection: input.signature.quickFilterSelection)
        let structuredFilterService = PacketStructuredFilterService()
        let structuredFilterContext = structuredFilterService.evaluationContext(for: input.signature.structuredFilterGroup)
        let store = PacketTableRowStore()
        let sourcePackets = packets(from: input)

        store.rows.reserveCapacity(sourcePackets.count)
        store.visiblePacketRowIndexByID.reserveCapacity(sourcePackets.count)

        var malformedPacketCount = 0
        var rowTimingState = PacketTableRowTimingState()

        for (index, packet) in sourcePackets.enumerated() {
            if index.isMultiple(of: 512), shouldCancel?() == true {
                return nil
            }

            if NetworkInspectorFormatters.severity(for: packet) == .malformed {
                malformedPacketCount += 1
            }

            guard matches(packet, selection: input.signature.sourceListSelection, pinnedItems: input.signature.pinnedItems),
                  displayFilter.isEmpty || displayFilter.matches(packet),
                  quickFilterService.matches(packet, selection: input.signature.quickFilterSelection),
                  structuredFilterService.matches(packet, context: structuredFilterContext) else {
                continue
            }

            let rowIndex = store.rows.count
            store.rows.append(rowTimingState.row(for: packet))
            store.visiblePacketRowIndexByID[packet.id] = rowIndex
        }

        return PacketTableBuildOutput(
            displayFilter: displayFilter,
            store: store,
            malformedPacketCount: malformedPacketCount,
            rowTimingState: rowTimingState
        )
    }

    private static func packets(from input: PacketTableBuildInput) -> [PacketSummary] {
        switch input.signature.sourceListSelection {
        case .saved:
            return input.signature.savedRecords.map(\.packet)
        case .pinned, .pinnedItem:
            return input.ingestState.packets.filter {
                matches($0, selection: input.signature.sourceListSelection, pinnedItems: input.signature.pinnedItems)
            }
        default:
            return input.ingestState.packets
        }
    }

    static func matches(
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

private extension PacketIngestMutation {
    func isAppendOnly(after packetCount: Int) -> Bool {
        switch self {
        case .append(let range):
            return range.lowerBound >= packetCount
        default:
            return false
        }
    }
}

private struct PacketTableFilterJob {
    let generation: Int
    let input: PacketTableBuildInput
    let cancellationToken: PacketTableFilterCancellationToken
}

private struct PacketTableContentCache {
    private var packetRevision: UInt64?
    private var packetLineageRevision: UInt64?
    private var sourcePacketCount = 0
    private var displayFilterText: String?
    private var quickFilterSelection: PacketQuickFilterSelection?
    private var structuredFilterGroup: PacketStructuredFilterGroup?
    private var sourceListSelection: PacketSourceListSelection?
    private var pinnedItems: [PacketPin] = []
    private var savedRecords: [SavedPacketRecord] = []
    private var generation: UInt64 = 0
    private var cachedContent = PacketTableContent.empty
    private var cachedRowTimingState = PacketTableRowTimingState()
    private var requiresReloadForAsyncBaseline = false

    mutating func reset() {
        packetRevision = nil
        packetLineageRevision = nil
        sourcePacketCount = 0
        displayFilterText = nil
        quickFilterSelection = nil
        structuredFilterGroup = nil
        sourceListSelection = nil
        pinnedItems = []
        savedRecords = []
        generation &+= 1
        cachedContent = .empty
        cachedRowTimingState = PacketTableRowTimingState()
        requiresReloadForAsyncBaseline = false
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
        quickFilterSelection: PacketQuickFilterSelection,
        quickFilterService: PacketQuickFilterService,
        structuredFilterGroup: PacketStructuredFilterGroup,
        structuredFilterService: PacketStructuredFilterService,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord],
        allowsAsyncRebuild: Bool,
        asyncRebuildThreshold: Int
    ) -> PacketTableContentResolution {
        guard shouldRebuildContent(
            ingestState: ingestState,
            displayFilterText: displayFilterText,
            quickFilterSelection: quickFilterSelection,
            structuredFilterGroup: structuredFilterGroup,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        ) else {
            requiresReloadForAsyncBaseline = false
            return .ready(cachedContent)
        }

        let displayFilter = PacketDisplayFilter(displayFilterText)
        let isStateStable = sourceListSelection != .saved &&
            self.displayFilterText == displayFilterText &&
            self.quickFilterSelection == quickFilterSelection &&
            self.structuredFilterGroup == structuredFilterGroup &&
            self.sourceListSelection == sourceListSelection &&
            self.pinnedItems == pinnedItems &&
            self.savedRecords == savedRecords &&
            packetLineageRevision == ingestState.packetLineageRevision &&
            sourcePacketCount <= ingestState.packets.count

        if isStateStable {
            let forceReload = requiresReloadForAsyncBaseline
            requiresReloadForAsyncBaseline = false
            switch ingestState.lastMutation {
            case .append:
                return .ready(appendContent(
                    from: ingestState.packets[sourcePacketCount...],
                    ingestState: ingestState,
                    displayFilter: displayFilter,
                    displayFilterText: displayFilterText,
                    quickFilterSelection: quickFilterSelection,
                    quickFilterService: quickFilterService,
                    structuredFilterGroup: structuredFilterGroup,
                    structuredFilterService: structuredFilterService,
                    sourceListSelection: sourceListSelection,
                    pinnedItems: pinnedItems,
                    savedRecords: savedRecords,
                    forceReload: forceReload
                ))
            case .appendWithMetadataUpdates(_, let updatedIDs):
                if let content = appendAndUpdateContent(
                    from: ingestState.packets[sourcePacketCount...],
                    updatedPacketIDs: updatedIDs,
                    ingestState: ingestState,
                    displayFilter: displayFilter,
                    displayFilterText: displayFilterText,
                    quickFilterSelection: quickFilterSelection,
                    quickFilterService: quickFilterService,
                    structuredFilterGroup: structuredFilterGroup,
                    structuredFilterService: structuredFilterService,
                    sourceListSelection: sourceListSelection,
                    pinnedItems: pinnedItems,
                    savedRecords: savedRecords,
                    forceReload: forceReload
                ) {
                    return .ready(content)
                }
            case .metadataUpdate(let updatedIDs):
                if let content = updateContent(
                    updatedPacketIDs: updatedIDs,
                    ingestState: ingestState,
                    displayFilter: displayFilter,
                    displayFilterText: displayFilterText,
                    quickFilterSelection: quickFilterSelection,
                    quickFilterService: quickFilterService,
                    structuredFilterGroup: structuredFilterGroup,
                    structuredFilterService: structuredFilterService,
                    sourceListSelection: sourceListSelection,
                    pinnedItems: pinnedItems,
                    savedRecords: savedRecords
                ) {
                    return .ready(content)
                }
            default:
                break
            }
        }

        let signature = PacketTableFilterSignature(
            displayFilterText: displayFilterText,
            quickFilterSelection: quickFilterSelection,
            structuredFilterGroup: structuredFilterGroup,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        )
        let input = PacketTableBuildInput(ingestState: ingestState, signature: signature)
        if allowsAsyncRebuild, input.sourcePacketCount >= asyncRebuildThreshold {
            return .deferred(loadingContent(displayFilter: displayFilter), input)
        }

        return .ready(rebuildContent(input: input))
    }

    func loadingContent(displayFilterText: String) -> PacketTableContent {
        loadingContent(displayFilter: PacketDisplayFilter(displayFilterText))
    }

    private func shouldRebuildContent(
        ingestState: PacketIngestState,
        displayFilterText: String,
        quickFilterSelection: PacketQuickFilterSelection,
        structuredFilterGroup: PacketStructuredFilterGroup,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> Bool {
        let dependsOnIngestPackets = sourceListSelection != .saved
        return (dependsOnIngestPackets && packetRevision != ingestState.packetRevision) ||
            self.displayFilterText != displayFilterText ||
            self.quickFilterSelection != quickFilterSelection ||
            self.structuredFilterGroup != structuredFilterGroup ||
            self.sourceListSelection != sourceListSelection ||
            self.pinnedItems != pinnedItems ||
            self.savedRecords != savedRecords
    }

    mutating func storeAsyncRebuild(_ output: PacketTableBuildOutput, input: PacketTableBuildInput) -> PacketTableContent {
        let content = storeRebuildOutput(output, input: input)
        requiresReloadForAsyncBaseline = true
        return content
    }

    private mutating func rebuildContent(input: PacketTableBuildInput) -> PacketTableContent {
        guard let output = PacketTableContentBuilder.rebuildContent(input: input) else {
            return loadingContent(displayFilterText: input.signature.displayFilterText)
        }

        return storeRebuildOutput(output, input: input)
    }

    private mutating func storeRebuildOutput(_ output: PacketTableBuildOutput, input: PacketTableBuildInput) -> PacketTableContent {
        generation &+= 1
        let updatePlan: PacketTableUpdatePlan = output.store.rows.isEmpty ? .none : .reload
        let content = PacketTableContent(
            displayFilter: output.displayFilter,
            displayFilterChips: output.displayFilter.chips,
            store: output.store,
            generation: generation,
            updatePlan: updatePlan,
            malformedPacketCount: output.malformedPacketCount
        )
        return store(
            content,
            input: input,
            rowTimingState: output.rowTimingState
        )
    }

    private func loadingContent(displayFilter: PacketDisplayFilter) -> PacketTableContent {
        PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            store: cachedContent.store,
            generation: cachedContent.generation,
            updatePlan: .none,
            malformedPacketCount: cachedContent.malformedPacketCount
        )
    }

    private mutating func appendContent(
        from newPackets: ArraySlice<PacketSummary>,
        ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        displayFilterText: String,
        quickFilterSelection: PacketQuickFilterSelection,
        quickFilterService: PacketQuickFilterService,
        structuredFilterGroup: PacketStructuredFilterGroup,
        structuredFilterService: PacketStructuredFilterService,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord],
        forceReload: Bool = false
    ) -> PacketTableContent {
        guard !newPackets.isEmpty else {
            return store(
                cachedContent,
                ingestState: ingestState,
                displayFilterText: displayFilterText,
                quickFilterSelection: quickFilterSelection,
                structuredFilterGroup: structuredFilterGroup,
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
        let structuredFilterContext = structuredFilterService.evaluationContext(for: structuredFilterGroup)

        for packet in newPackets {
            if NetworkInspectorFormatters.severity(for: packet) == .malformed {
                malformedPacketCount += 1
            }

            guard matches(packet, selection: sourceListSelection, pinnedItems: pinnedItems),
                  displayFilter.isEmpty || displayFilter.matches(packet),
                  quickFilterService.matches(packet, selection: quickFilterSelection),
                  structuredFilterService.matches(packet, context: structuredFilterContext) else {
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
        let updatePlan: PacketTableUpdatePlan = forceReload
            ? .reload
            : (didAppendVisibleRows ? .append(appendStartIndex..<store.rows.count) : .none)

        let content = PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            store: store,
            generation: generation,
            updatePlan: updatePlan,
            malformedPacketCount: malformedPacketCount
        )
        return self.store(
            content,
            ingestState: ingestState,
            displayFilterText: displayFilterText,
            quickFilterSelection: quickFilterSelection,
            structuredFilterGroup: structuredFilterGroup,
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
        quickFilterSelection: PacketQuickFilterSelection,
        quickFilterService: PacketQuickFilterService,
        structuredFilterGroup: PacketStructuredFilterGroup,
        structuredFilterService: PacketStructuredFilterService,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord]
    ) -> PacketTableContent? {
        guard let result = computeRowUpdates(
            updatedPacketIDs: updatedPacketIDs,
            ingestState: ingestState,
            displayFilter: displayFilter,
            quickFilterSelection: quickFilterSelection,
            quickFilterService: quickFilterService,
            structuredFilterGroup: structuredFilterGroup,
            structuredFilterService: structuredFilterService,
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
            quickFilterSelection: quickFilterSelection,
            structuredFilterGroup: structuredFilterGroup,
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
        quickFilterSelection: PacketQuickFilterSelection,
        quickFilterService: PacketQuickFilterService,
        structuredFilterGroup: PacketStructuredFilterGroup,
        structuredFilterService: PacketStructuredFilterService,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord],
        forceReload: Bool = false
    ) -> PacketTableContent? {
        // Run the existing append path first so older-row updates apply on top of the new rows.
        let appendedContent = appendContent(
            from: newPackets,
            ingestState: ingestState,
            displayFilter: displayFilter,
            displayFilterText: displayFilterText,
            quickFilterSelection: quickFilterSelection,
            quickFilterService: quickFilterService,
            structuredFilterGroup: structuredFilterGroup,
            structuredFilterService: structuredFilterService,
            sourceListSelection: sourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords,
            forceReload: forceReload
        )

        guard !updatedPacketIDs.isEmpty else {
            return appendedContent
        }

        guard let result = computeRowUpdates(
            updatedPacketIDs: updatedPacketIDs,
            ingestState: ingestState,
            displayFilter: displayFilter,
            quickFilterSelection: quickFilterSelection,
            quickFilterService: quickFilterService,
            structuredFilterGroup: structuredFilterGroup,
            structuredFilterService: structuredFilterService,
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
            plan = forceReload ? .reload : .none
        case (let range?, false):
            plan = forceReload ? .reload : .append(range)
        case (nil, true):
            plan = forceReload ? .reload : .reloadRows(result.reloadIndexes)
        case (let range?, true):
            plan = forceReload ? .reload : .appendAndReloadRows(append: range, reload: result.reloadIndexes)
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
            quickFilterSelection: quickFilterSelection,
            structuredFilterGroup: structuredFilterGroup,
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
        quickFilterSelection: PacketQuickFilterSelection,
        quickFilterService: PacketQuickFilterService,
        structuredFilterGroup: PacketStructuredFilterGroup,
        structuredFilterService: PacketStructuredFilterService,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        store: PacketTableRowStore,
        existingTimingState: PacketTableRowTimingState
    ) -> RowUpdateResult? {
        var reloadIndexes = IndexSet()
        var rowTimingState = existingTimingState
        let structuredFilterContext = structuredFilterService.evaluationContext(for: structuredFilterGroup)

        for packetID in updatedPacketIDs {
            guard let packet = ingestState.packet(withID: packetID) else {
                continue
            }
            let isVisibleNow = matches(packet, selection: sourceListSelection, pinnedItems: pinnedItems) &&
                (displayFilter.isEmpty || displayFilter.matches(packet)) &&
                quickFilterService.matches(packet, selection: quickFilterSelection) &&
                structuredFilterService.matches(packet, context: structuredFilterContext)
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
        input: PacketTableBuildInput,
        rowTimingState: PacketTableRowTimingState
    ) -> PacketTableContent {
        packetRevision = input.ingestState.packetRevision
        packetLineageRevision = input.ingestState.packetLineageRevision
        sourcePacketCount = input.sourcePacketCount
        displayFilterText = input.signature.displayFilterText
        quickFilterSelection = input.signature.quickFilterSelection
        structuredFilterGroup = input.signature.structuredFilterGroup
        sourceListSelection = input.signature.sourceListSelection
        pinnedItems = input.signature.pinnedItems
        savedRecords = input.signature.savedRecords
        cachedContent = content
        cachedRowTimingState = rowTimingState
        return content
    }

    private mutating func store(
        _ content: PacketTableContent,
        ingestState: PacketIngestState,
        displayFilterText: String,
        quickFilterSelection: PacketQuickFilterSelection,
        structuredFilterGroup: PacketStructuredFilterGroup,
        sourceListSelection: PacketSourceListSelection,
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord],
        rowTimingState: PacketTableRowTimingState? = nil
    ) -> PacketTableContent {
        packetRevision = ingestState.packetRevision
        packetLineageRevision = ingestState.packetLineageRevision
        sourcePacketCount = ingestState.packets.count
        self.displayFilterText = displayFilterText
        self.quickFilterSelection = quickFilterSelection
        self.structuredFilterGroup = structuredFilterGroup
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
    private let quickFilterService: PacketQuickFilterService
    private let structuredFilterService: PacketStructuredFilterService
    private let structuredFilterStore: PacketStructuredFilterStore
    private let packetExportService: PacketExportService
    private let packetTableFilterQueue = DispatchQueue(label: "com.proxyman.TCPViewer.packet-table-filter")
    private let packetTableAsyncRebuildThreshold: Int
    private let packetTableFilterBuildHook: (@Sendable () -> Void)?
    private var packetTableContentCache = PacketTableContentCache()
    private var hasPerformedInitialLoad = false
    private var pendingRebuildWorkItem: DispatchWorkItem?
    private var rebuildGeneration = 0
    private var activePacketTableFilterJob: PacketTableFilterJob?
    private var packetTableFilterGeneration = 0
    private var isPacketTableFiltering = false
    private var selectsFirstVisiblePacketAfterFiltering = false

    // Trailing-edge debounce for delegate-driven rebuilds. Live ingest fires the controller delegate
    // up to ~10 Hz; coalescing to ~12 Hz keeps the UI feeling live without burning CPU on redundant
    // rebuilds. User-driven actions bypass this and rebuild synchronously.
    private static let rebuildCoalesceInterval: TimeInterval = 0.08

    private var selectedSidebar: NetworkInspectorSidebarSelection = .liveCapture
    private var selectedSourceListSelection: PacketSourceListSelection = .allPackets
    private var sourceListFilterText = ""
    private var workspaceMode: NetworkInspectorWorkspaceMode = .packets
    private var inspectorTab: PacketInspectorTab = .summary
    private var inspectorPlacement: NetworkInspectorPlacement
    private var isInspectorVisible: Bool
    private var isStructuredFilterVisible: Bool
    private var displayFilterText: String
    private var structuredFilterGroup: PacketStructuredFilterGroup
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
        quickFilterService: PacketQuickFilterService = PacketQuickFilterService(),
        structuredFilterService: PacketStructuredFilterService = PacketStructuredFilterService(),
        packetExportService: PacketExportService? = nil,
        packetTableAsyncRebuildThreshold: Int = 5_000,
        packetTableFilterBuildHook: (@Sendable () -> Void)? = nil
    ) {
        self.controller = TCPViewerWorkspaceController(
            services: services,
            userDefaults: userDefaults,
            interfaceHistoryStore: interfaceHistoryStore
        )
        self.preferences = NetworkInspectorPreferences(defaults: userDefaults)
        self.pinService = pinService
        self.savedPacketService = savedPacketService
        self.quickFilterService = quickFilterService
        self.structuredFilterService = structuredFilterService
        self.structuredFilterStore = PacketStructuredFilterStore(defaults: userDefaults)
        self.packetExportService = packetExportService ?? PacketExportService(defaults: userDefaults)
        self.packetTableAsyncRebuildThreshold = max(1, packetTableAsyncRebuildThreshold)
        self.packetTableFilterBuildHook = packetTableFilterBuildHook
        self.inspectorPlacement = .trailing
        self.isInspectorVisible = preferences.isInspectorVisible
        self.isStructuredFilterVisible = preferences.isStructuredFilterVisible
        self.displayFilterText = preferences.displayFilterText
        self.structuredFilterGroup = structuredFilterStore.load()
        let sourceListSnapshot = sourceListService.snapshot(
            for: controller.snapshot.packetIngestState,
            pinnedItems: pinService.pins(),
            savedPacketCount: savedPacketService.records().count
        )
        let activeStructuredFilterGroup = isStructuredFilterVisible ? structuredFilterGroup : .default
        let packetTableResolution = packetTableContentCache.content(
            for: controller.snapshot.packetIngestState,
            displayFilterText: displayFilterText,
            quickFilterSelection: quickFilterService.selection,
            quickFilterService: quickFilterService,
            structuredFilterGroup: activeStructuredFilterGroup,
            structuredFilterService: structuredFilterService,
            sourceListSelection: selectedSourceListSelection,
            pinnedItems: pinService.pins(),
            savedRecords: savedPacketService.records(),
            allowsAsyncRebuild: false,
            asyncRebuildThreshold: self.packetTableAsyncRebuildThreshold
        )
        let packetTableContent: PacketTableContent
        switch packetTableResolution {
        case .ready(let content), .deferred(let content, _):
            packetTableContent = content
        }
        self.snapshot = NetworkInspectorSnapshot.make(
            base: controller.snapshot,
            selectedSidebar: selectedSidebar,
            selectedSourceListSelection: selectedSourceListSelection,
            sourceListSnapshot: sourceListSnapshot,
            sourceListFilterText: sourceListFilterText,
            quickFilterItems: quickFilterService.items(),
            quickFilterSelection: quickFilterService.selection,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            inspectorPlacement: inspectorPlacement,
            isInspectorVisible: isInspectorVisible,
            isStructuredFilterVisible: isStructuredFilterVisible,
            displayFilterText: displayFilterText,
            structuredFilterGroup: structuredFilterGroup,
            isPacketTableFiltering: isPacketTableFiltering,
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

    func updateStructuredFilterGroup(_ group: PacketStructuredFilterGroup) {
        structuredFilterGroup = PacketStructuredFilterGroup(filters: group.filters, operator: group.operator)
        structuredFilterStore.save(structuredFilterGroup)
        rebuildSnapshot()
    }

    func setStructuredFilterVisible(_ isVisible: Bool) {
        guard isStructuredFilterVisible != isVisible else {
            return
        }

        isStructuredFilterVisible = isVisible
        preferences.persistStructuredFilterVisible(isVisible)
        rebuildSnapshot()
    }

    func toggleQuickFilter(_ id: PacketQuickFilterID) {
        quickFilterService.toggle(id)
        rebuildSnapshot(selectsFirstVisiblePacketForQuickFilter: true)
    }

    func resetQuickFilters() {
        quickFilterService.reset()
        rebuildSnapshot(clearsSelectedPacket: true)
    }

    func clearPackets() {
        #if DEBUG
        logClearMemorySnapshot("before")
        #endif
        cancelActivePacketTableFilterJob()
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
        guard isVisible != isInspectorVisible else {
            return
        }

        isInspectorVisible = isVisible
        preferences.persistInspectorVisible(isVisible)
        rebuildSnapshot()
    }

    func toggleInspector() {
        setInspectorVisible(!isInspectorVisible)
    }

    // Persist the sidebar's visibility so the root split view can restore it on the next launch.
    func setSidebarVisible(_ isVisible: Bool) {
        preferences.persistSidebarVisible(isVisible)
    }

    // Keep the last usable leading sidebar width for future launches and reopen actions.
    func rememberSidebarThickness(_ thickness: CGFloat) {
        guard thickness.isFinite, thickness > 0 else {
            return
        }

        preferences.persistSidebarThickness(thickness)
    }

    // Reject invalid saved widths so the root controller can keep AppKit's default when needed.
    func preferredSidebarThickness(for availableLength: CGFloat) -> CGFloat? {
        guard availableLength.isFinite, availableLength > 0,
              let thickness = preferences.sidebarThickness,
              thickness.isFinite, thickness > 0, thickness < availableLength else {
            return nil
        }

        return thickness
    }

    // Expose the launch preference without adding sidebar layout state to the main snapshot.
    func prefersSidebarVisibleOnLaunch() -> Bool {
        preferences.isSidebarVisible
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

    private func rebuildSnapshot(
        selectsFirstVisiblePacketForQuickFilter: Bool = false,
        clearsSelectedPacket: Bool = false
    ) {
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

        // A hidden structured filter panel behaves like no structured filter, but keeps row state for restore.
        let activeStructuredFilterGroup = isStructuredFilterVisible ? structuredFilterGroup : .default
        let packetTableInput = makePacketTableBuildInput(
            pinnedItems: pinnedItems,
            savedRecords: savedRecords,
            activeStructuredFilterGroup: activeStructuredFilterGroup
        )
        let packetTableContent: PacketTableContent
        if shouldKeepActivePacketTableFilterJob(for: packetTableInput) {
            packetTableContent = packetTableContentCache.loadingContent(displayFilterText: displayFilterText)
            isPacketTableFiltering = true
        } else {
            cancelActivePacketTableFilterJob()
            switch packetTableContentCache.content(
                for: controller.snapshot.packetIngestState,
                displayFilterText: displayFilterText,
                quickFilterSelection: quickFilterService.selection,
                quickFilterService: quickFilterService,
                structuredFilterGroup: activeStructuredFilterGroup,
                structuredFilterService: structuredFilterService,
                sourceListSelection: selectedSourceListSelection,
                pinnedItems: pinnedItems,
                savedRecords: savedRecords,
                allowsAsyncRebuild: true,
                asyncRebuildThreshold: packetTableAsyncRebuildThreshold
            ) {
            case .ready(let content):
                packetTableContent = content
                isPacketTableFiltering = false
            case .deferred(let content, let input):
                packetTableContent = content
                startPacketTableFilterJob(input)
                isPacketTableFiltering = true
            }
        }
        if isPacketTableFiltering, selectsFirstVisiblePacketForQuickFilter {
            selectsFirstVisiblePacketAfterFiltering = true
        }
        if clearsSelectedPacket {
            applyPacketSelectionDuringRebuild(nil)
        } else if selectsFirstVisiblePacketForQuickFilter, !isPacketTableFiltering {
            let firstVisiblePacketID = quickFilterService.selection.isActive ? packetTableContent.rows.first?.id : nil
            applyPacketSelectionDuringRebuild(firstVisiblePacketID)
            if firstVisiblePacketID != nil {
                inspectorTab = .summary
            }
        }
        let updatedSnapshot = NetworkInspectorSnapshot.make(
            base: controller.snapshot,
            selectedSidebar: selectedSidebar,
            selectedSourceListSelection: selectedSourceListSelection,
            sourceListSnapshot: sourceListSnapshot,
            sourceListFilterText: sourceListFilterText,
            quickFilterItems: quickFilterService.items(),
            quickFilterSelection: quickFilterService.selection,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            inspectorPlacement: inspectorPlacement,
            isInspectorVisible: isInspectorVisible,
            isStructuredFilterVisible: isStructuredFilterVisible,
            displayFilterText: displayFilterText,
            structuredFilterGroup: structuredFilterGroup,
            isPacketTableFiltering: isPacketTableFiltering,
            packetTableContent: packetTableContent
        )
        guard updatedSnapshot != snapshot else {
            return
        }

        snapshot = updatedSnapshot
    }

    private func makePacketTableBuildInput(
        pinnedItems: [PacketPin],
        savedRecords: [SavedPacketRecord],
        activeStructuredFilterGroup: PacketStructuredFilterGroup
    ) -> PacketTableBuildInput {
        let signature = PacketTableFilterSignature(
            displayFilterText: displayFilterText,
            quickFilterSelection: quickFilterService.selection,
            structuredFilterGroup: activeStructuredFilterGroup,
            sourceListSelection: selectedSourceListSelection,
            pinnedItems: pinnedItems,
            savedRecords: savedRecords
        )
        return PacketTableBuildInput(
            ingestState: controller.snapshot.packetIngestState,
            signature: signature
        )
    }

    private func shouldKeepActivePacketTableFilterJob(for input: PacketTableBuildInput) -> Bool {
        guard let job = activePacketTableFilterJob,
              job.input.signature == input.signature,
              canApplyPacketTableFilterResult(from: job.input, to: input) else {
            return false
        }

        return !job.cancellationToken.isCancelled()
    }

    private func canApplyPacketTableFilterResult(
        from originalInput: PacketTableBuildInput,
        to currentInput: PacketTableBuildInput
    ) -> Bool {
        guard originalInput.signature == currentInput.signature else {
            return false
        }

        if originalInput.signature.sourceListSelection == .saved {
            return true
        }

        let originalState = originalInput.ingestState
        let currentState = currentInput.ingestState
        if currentState.packetRevision == originalState.packetRevision {
            return true
        }

        return currentState.packetLineageRevision == originalState.packetLineageRevision &&
            currentState.packets.count >= originalState.packets.count &&
            currentState.lastMutation.isAppendOnly(after: originalState.packets.count)
    }

    private func startPacketTableFilterJob(_ input: PacketTableBuildInput) {
        if shouldKeepActivePacketTableFilterJob(for: input) {
            return
        }

        cancelActivePacketTableFilterJob()
        packetTableFilterGeneration += 1
        let cancellationToken = PacketTableFilterCancellationToken()
        let job = PacketTableFilterJob(
            generation: packetTableFilterGeneration,
            input: input,
            cancellationToken: cancellationToken
        )
        activePacketTableFilterJob = job

        let buildHook = packetTableFilterBuildHook
        packetTableFilterQueue.async { [weak self] in
            // Tests can hold the worker here without slowing production builds.
            buildHook?()
            let output = PacketTableContentBuilder.rebuildContent(
                input: input,
                shouldCancel: cancellationToken.isCancelled
            )
            DispatchQueue.main.async {
                self?.completePacketTableFilterJob(job, output: output)
            }
        }
    }

    private func completePacketTableFilterJob(_ job: PacketTableFilterJob, output: PacketTableBuildOutput?) {
        guard let activeJob = activePacketTableFilterJob,
              activeJob.generation == job.generation,
              !job.cancellationToken.isCancelled() else {
            return
        }

        guard let output else {
            activePacketTableFilterJob = nil
            isPacketTableFiltering = false
            rebuildSnapshot()
            return
        }

        let pinnedItems = pinService.pins()
        let savedRecords = savedPacketService.records()
        let activeStructuredFilterGroup = isStructuredFilterVisible ? structuredFilterGroup : .default
        let currentInput = makePacketTableBuildInput(
            pinnedItems: pinnedItems,
            savedRecords: savedRecords,
            activeStructuredFilterGroup: activeStructuredFilterGroup
        )
        guard canApplyPacketTableFilterResult(from: job.input, to: currentInput) else {
            activePacketTableFilterJob = nil
            isPacketTableFiltering = false
            rebuildSnapshot()
            return
        }

        _ = packetTableContentCache.storeAsyncRebuild(output, input: job.input)
        activePacketTableFilterJob = nil
        isPacketTableFiltering = false
        let shouldSelectFirst = selectsFirstVisiblePacketAfterFiltering
        selectsFirstVisiblePacketAfterFiltering = false
        rebuildSnapshot(selectsFirstVisiblePacketForQuickFilter: shouldSelectFirst)
    }

    private func cancelActivePacketTableFilterJob() {
        activePacketTableFilterJob?.cancellationToken.cancel()
        activePacketTableFilterJob = nil
        isPacketTableFiltering = false
        selectsFirstVisiblePacketAfterFiltering = false
    }

    private func applyPacketSelectionDuringRebuild(_ identifier: PacketSummary.ID?) {
        guard controller.snapshot.selectedPacketID != identifier else {
            return
        }

        // Model-driven selection emits a workspace callback; this rebuild already owns the update.
        controller.selectPacket(identifier)
        cancelPendingRebuild()
    }

    private func scheduleCoalescedRebuild() {
        guard pendingRebuildWorkItem == nil else {
            return
        }
        let generation = rebuildGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            // Skip canceled coalesced ticks that were queued before a user-driven rebuild.
            guard self.rebuildGeneration == generation else {
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
        rebuildGeneration += 1
    }

    deinit {
        pendingRebuildWorkItem?.cancel()
        activePacketTableFilterJob?.cancellationToken.cancel()
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
