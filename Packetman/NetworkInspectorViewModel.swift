import AppKit
import Foundation
import PcapPlusPlusCore
import UniformTypeIdentifiers

private struct NetworkInspectorPreferences {
    private enum Key {
        static let displayFilterText = "Packetry.displayFilterText"
        static let inspectorVisible = "Packetry.inspectorVisible"
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

    private let controller: PacketryWindowController
    private let preferences: NetworkInspectorPreferences
    private var packetTableContentCache = PacketTableContentCache()
    private var hasPerformedInitialLoad = false

    private var selectedSidebar: NetworkInspectorSidebarSelection = .liveCapture
    private var workspaceMode: NetworkInspectorWorkspaceMode = .packets
    private var inspectorTab: PacketInspectorTab = .overview
    private var isInspectorVisible: Bool
    private var displayFilterText: String
    private var helperOnboardingDismissed = false

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

    var networkHelperToolSnapshot: PacketryNetworkHelperToolSnapshot {
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

    func relaunchPacketry() {
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

    func cancelDocumentLoading(completion: (() -> Void)? = nil) {
        controller.cancelDocumentLoading { [weak self] in
            self?.rebuildSnapshot()
            completion?()
        }
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
            displayFilterText: displayFilterText,
            packetTableContent: packetTableContent
        )
        guard updatedSnapshot != snapshot else {
            return
        }

        snapshot = updatedSnapshot
    }
}

extension NetworkInspectorViewModel: PacketryWindowControllerDelegate {
    func packetryWindowControllerDidChange(_ controller: PacketryWindowController) {
        rebuildSnapshot()
    }
}
