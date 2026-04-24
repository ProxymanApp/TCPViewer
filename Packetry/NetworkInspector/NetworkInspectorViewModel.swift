import AppKit
import Combine
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

private struct NetworkInspectorPreferences {
    private enum Key {
        static let displayFilterText = "Packetry.displayFilterText"
        static let tableDensity = "Packetry.tableDensity"
        static let inspectorVisible = "Packetry.inspectorVisible"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var displayFilterText: String {
        defaults.string(forKey: Key.displayFilterText) ?? ""
    }

    var tableDensity: PacketTableDensity {
        guard let rawValue = defaults.string(forKey: Key.tableDensity),
              let density = PacketTableDensity(rawValue: rawValue) else {
            return .comfortable
        }

        return density
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

    func persistTableDensity(_ density: PacketTableDensity) {
        defaults.set(density.rawValue, forKey: Key.tableDensity)
    }

    func persistInspectorVisible(_ isVisible: Bool) {
        defaults.set(isVisible, forKey: Key.inspectorVisible)
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
    private var generation: UInt64 = 0
    private var cachedContent = PacketTableContent.empty

    mutating func content(
        for ingestState: PacketIngestState,
        displayFilterText: String
    ) -> PacketTableContent {
        guard packetRevision != ingestState.packetRevision || self.displayFilterText != displayFilterText else {
            return cachedContent
        }

        let displayFilter = PacketDisplayFilter(displayFilterText)
        if self.displayFilterText == displayFilterText,
           packetLineageRevision == ingestState.packetLineageRevision,
           sourcePacketCount <= ingestState.packets.count {
            return appendContent(
                from: ingestState.packets[sourcePacketCount...],
                ingestState: ingestState,
                displayFilter: displayFilter,
                displayFilterText: displayFilterText
            )
        }

        return rebuildContent(
            from: ingestState,
            displayFilter: displayFilter,
            displayFilterText: displayFilterText
        )
    }

    private mutating func rebuildContent(
        from ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        displayFilterText: String
    ) -> PacketTableContent {
        var rows: [PacketTableRow] = []
        var rowIDs: [PacketSummary.ID] = []
        var visiblePacketsByID: [PacketSummary.ID: PacketSummary] = [:]
        var visiblePacketRowIndexByID: [PacketSummary.ID: Int] = [:]
        var malformedPacketCount = 0
        rows.reserveCapacity(ingestState.packets.count)
        rowIDs.reserveCapacity(ingestState.packets.count)
        visiblePacketsByID.reserveCapacity(ingestState.packets.count)
        visiblePacketRowIndexByID.reserveCapacity(ingestState.packets.count)

        for packet in ingestState.packets {
            if NetworkInspectorFormatters.severity(for: packet) == .malformed {
                malformedPacketCount += 1
            }

            guard displayFilter.isEmpty || displayFilter.matches(packet) else {
                continue
            }

            let rowIndex = rows.count
            rows.append(PacketTableRow(packet: packet))
            rowIDs.append(packet.id)
            visiblePacketsByID[packet.id] = packet
            visiblePacketRowIndexByID[packet.id] = rowIndex
        }

        generation &+= 1
        let updatePlan: PacketTableUpdatePlan = rows.isEmpty ? .none : .reload
        let content = PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            rows: rows,
            rowIDs: rowIDs,
            generation: generation,
            updatePlan: updatePlan,
            malformedPacketCount: malformedPacketCount,
            visiblePacketsByID: visiblePacketsByID,
            visiblePacketRowIndexByID: visiblePacketRowIndexByID
        )
        return store(content, ingestState: ingestState, displayFilterText: displayFilterText)
    }

    private mutating func appendContent(
        from newPackets: ArraySlice<PacketSummary>,
        ingestState: PacketIngestState,
        displayFilter: PacketDisplayFilter,
        displayFilterText: String
    ) -> PacketTableContent {
        guard !newPackets.isEmpty else {
            return store(cachedContent, ingestState: ingestState, displayFilterText: displayFilterText)
        }

        var rows = cachedContent.rows
        var rowIDs = cachedContent.rowIDs
        var visiblePacketsByID = cachedContent.visiblePacketsByID
        var visiblePacketRowIndexByID = cachedContent.visiblePacketRowIndexByID
        var malformedPacketCount = cachedContent.malformedPacketCount
        let appendStartIndex = rows.count

        rows.reserveCapacity(rows.count + newPackets.count)
        rowIDs.reserveCapacity(rowIDs.count + newPackets.count)
        visiblePacketsByID.reserveCapacity(visiblePacketsByID.count + newPackets.count)
        visiblePacketRowIndexByID.reserveCapacity(visiblePacketRowIndexByID.count + newPackets.count)

        for packet in newPackets {
            if NetworkInspectorFormatters.severity(for: packet) == .malformed {
                malformedPacketCount += 1
            }

            guard displayFilter.isEmpty || displayFilter.matches(packet) else {
                continue
            }

            let rowIndex = rows.count
            rows.append(PacketTableRow(packet: packet))
            rowIDs.append(packet.id)
            visiblePacketsByID[packet.id] = packet
            visiblePacketRowIndexByID[packet.id] = rowIndex
        }

        let didAppendVisibleRows = rows.count > appendStartIndex
        if didAppendVisibleRows {
            generation &+= 1
        }

        let content = PacketTableContent(
            displayFilter: displayFilter,
            displayFilterChips: displayFilter.chips,
            rows: rows,
            rowIDs: rowIDs,
            generation: generation,
            updatePlan: didAppendVisibleRows ? .append(appendStartIndex..<rows.count) : .none,
            malformedPacketCount: malformedPacketCount,
            visiblePacketsByID: visiblePacketsByID,
            visiblePacketRowIndexByID: visiblePacketRowIndexByID
        )
        return store(content, ingestState: ingestState, displayFilterText: displayFilterText)
    }

    private mutating func store(
        _ content: PacketTableContent,
        ingestState: PacketIngestState,
        displayFilterText: String
    ) -> PacketTableContent {
        packetRevision = ingestState.packetRevision
        packetLineageRevision = ingestState.packetLineageRevision
        sourcePacketCount = ingestState.packets.count
        self.displayFilterText = displayFilterText
        cachedContent = content
        return content
    }
}

@MainActor
final class NetworkInspectorViewModel: ObservableObject {
    @Published private(set) var snapshot: NetworkInspectorSnapshot

    private let controller: PacketryWindowController
    private let preferences: NetworkInspectorPreferences
    private var cancellables: Set<AnyCancellable> = []
    private var packetTableContentCache = PacketTableContentCache()
    private var hasPerformedInitialLoad = false

    private var selectedSidebar: NetworkInspectorSidebarSelection = .liveCapture
    private var workspaceMode: NetworkInspectorWorkspaceMode = .packets
    private var inspectorTab: PacketInspectorTab = .overview
    private var isInspectorVisible: Bool
    private var tableDensity: PacketTableDensity
    private var displayFilterText: String

    convenience init(userDefaults: UserDefaults = .standard) {
        self.init(services: .foundation, userDefaults: userDefaults)
    }

    init(services: PacketryServiceRegistry, userDefaults: UserDefaults = .standard) {
        self.controller = PacketryWindowController(
            services: services,
            userDefaults: userDefaults
        )
        self.preferences = NetworkInspectorPreferences(defaults: userDefaults)
        self.isInspectorVisible = preferences.isInspectorVisible
        self.tableDensity = preferences.tableDensity
        self.displayFilterText = preferences.displayFilterText
        let packetTableContent = packetTableContentCache.content(
            for: controller.snapshot.packetIngestState,
            displayFilterText: displayFilterText
        )
        self.snapshot = NetworkInspectorSnapshot.make(
            base: controller.snapshot,
            selectedSidebar: selectedSidebar,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            isInspectorVisible: isInspectorVisible,
            tableDensity: tableDensity,
            displayFilterText: displayFilterText,
            packetTableContent: packetTableContent
        )

        controller.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.rebuildSnapshot()
                }
            }
            .store(in: &cancellables)
    }

    func performInitialLoadIfNeeded() async {
        guard !hasPerformedInitialLoad else {
            return
        }

        hasPerformedInitialLoad = true
        await controller.performInitialLoadIfNeeded()
        rebuildSnapshot()
    }

    func refreshInterfaces() async {
        await controller.refreshInterfaces()
        rebuildSnapshot()
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

    func updateCaptureFilterText(_ text: String) {
        controller.updateCaptureFilterText(text)
        rebuildSnapshot()
    }

    func applyRecentCaptureFilter(_ value: String) {
        controller.applyRecentCaptureFilter(value)
        rebuildSnapshot()
    }

    func validateCaptureFilter() async {
        await controller.validateCaptureFilter()
        rebuildSnapshot()
    }

    func toggleLiveCapture() async {
        if snapshot.base.sessionState.canStop {
            await controller.stopLiveCapture()
        } else {
            await controller.startLiveCapture()
        }

        rebuildSnapshot()
    }

    func pauseLiveCapture() async {
        await controller.pauseLiveCapture()
        rebuildSnapshot()
    }

    func resumeLiveCapture() async {
        await controller.resumeLiveCapture()
        rebuildSnapshot()
    }

    func stopLiveCapture() async {
        await controller.stopLiveCapture()
        rebuildSnapshot()
    }

    func openDocument(at fileURL: URL) async {
        await controller.openDocument(at: fileURL)
        workspaceMode = .packets
        selectedSidebar = .liveCapture
        rebuildSnapshot()
    }

    func presentOpenCapturePanel() {
        controller.presentOpenCapturePanel()
        rebuildSnapshot()
    }

    func saveDocument() async {
        await controller.saveDocument()
        rebuildSnapshot()
    }

    func saveDocument(to url: URL, format: CaptureFileFormat) async {
        await controller.saveDocument(to: url, format: format)
        rebuildSnapshot()
    }

    func presentSaveCapturePanel(format: CaptureFileFormat) {
        controller.presentSaveCapturePanel(format: format)
        rebuildSnapshot()
    }

    func cancelDocumentLoading() async {
        await controller.cancelDocumentLoading()
        rebuildSnapshot()
    }

    func selectPacket(_ identifier: PacketSummary.ID?) {
        print("[Packetry] \(NetworkInspectorDebugLog.timestamp()) 🎯 Packet row selected: \(identifier?.description ?? "nil")")
        controller.selectPacket(identifier)
        if identifier != nil {
            inspectorTab = .overview
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

    func setTableDensity(_ density: PacketTableDensity) {
        tableDensity = density
        preferences.persistTableDensity(density)
        rebuildSnapshot()
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
        let packetTableContent = packetTableContentCache.content(
            for: controller.snapshot.packetIngestState,
            displayFilterText: displayFilterText
        )
        let updatedSnapshot = NetworkInspectorSnapshot.make(
            base: controller.snapshot,
            selectedSidebar: selectedSidebar,
            workspaceMode: workspaceMode,
            inspectorTab: inspectorTab,
            isInspectorVisible: isInspectorVisible,
            tableDensity: tableDensity,
            displayFilterText: displayFilterText,
            packetTableContent: packetTableContent
        )
        guard updatedSnapshot != snapshot else {
            return
        }

        snapshot = updatedSnapshot
    }
}
