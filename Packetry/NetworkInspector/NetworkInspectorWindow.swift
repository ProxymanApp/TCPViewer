import PcapPlusPlusCore
import SwiftUI

struct NetworkInspectorWindow: View {
    @StateObject private var viewModel: NetworkInspectorViewModel

    @MainActor
    init() {
        self.init(services: .foundation)
    }

    init(services: PacketryServiceRegistry) {
        _viewModel = StateObject(wrappedValue: NetworkInspectorViewModel(services: services))
    }

    init(viewModel: NetworkInspectorViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                NetworkInspectorSidebar(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } detail: {
                HSplitView {
                    NetworkInspectorCenterPane(viewModel: viewModel)
                        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

                    if viewModel.snapshot.isInspectorVisible {
                        PacketInspectorPane(
                            state: PacketInspectorRenderState(snapshot: viewModel.snapshot),
                            onSelectInspectorTab: { viewModel.selectInspectorTab($0) },
                            onSelectDetailNode: { viewModel.selectDetailNode($0) }
                        )
                        .equatable()
                            .frame(minWidth: 320, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
                    }
                }
            }

            Divider()
            NetworkInspectorStatusStrip(viewModel: viewModel)
        }
        .frame(minWidth: 1_180, minHeight: 760)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                CaptureSourceMenu(viewModel: viewModel)

                Button {
                    Task {
                        await viewModel.toggleLiveCapture()
                    }
                } label: {
                    Image(systemName: viewModel.captureButtonSystemImage())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(captureButtonTint, in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        }
                        .shadow(color: captureButtonTint.opacity(0.25), radius: 3, y: 1)
                }
                .disabled(!viewModel.snapshot.base.sessionState.canStart && !viewModel.snapshot.base.sessionState.canStop)
                .buttonStyle(.plain)
                .opacity(viewModel.snapshot.base.sessionState.canStart || viewModel.snapshot.base.sessionState.canStop ? 1 : 0.45)
                .help(viewModel.captureButtonTitle())
            }

            ToolbarItemGroup(placement: .principal) {
                ToolbarStatusView(snapshot: viewModel.snapshot)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Save") {
                        Task {
                            await viewModel.saveDocument()
                        }
                    }
                    .disabled(!viewModel.snapshot.base.documentState.canSave)

                    Divider()

                    Button("Export as pcap") {
                        viewModel.presentSaveCapturePanel(format: .pcap)
                    }
                    .disabled(!viewModel.snapshot.base.documentState.canSaveAs)

                    Button("Export as pcapng") {
                        viewModel.presentSaveCapturePanel(format: .pcapng)
                    }
                    .disabled(!viewModel.snapshot.base.documentState.canSaveAs)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .packetryToolbarButtonStyle()

                Button {
                    viewModel.toggleInspector()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
                .packetryToolbarButtonStyle()
                .help("Toggle Inspector View")
            }
        }
        .task {
            await viewModel.performInitialLoadIfNeeded()
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.shouldPresentNetworkHelperOnboarding },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissNetworkHelperOnboarding()
                    }
                }
            )
        ) {
            PacketryNetworkHelperOnboardingSheet(
                snapshot: viewModel.networkHelperToolSnapshot,
                onInstall: {
                    Task {
                        await viewModel.installNetworkHelperTool()
                    }
                },
                onRepair: {
                    Task {
                        await viewModel.repairNetworkHelperTool()
                    }
                },
                onRetry: {
                    Task {
                        await viewModel.retryNetworkHelperToolStatus()
                    }
                },
                onOpenSystemSettings: {
                    viewModel.openNetworkHelperSystemSettings()
                },
                onRelaunch: {
                    viewModel.relaunchPacketry()
                },
                onContinueOffline: {
                    viewModel.dismissNetworkHelperOnboarding()
                }
            )
        }
    }

    private var captureButtonTint: Color {
        viewModel.snapshot.base.sessionState.canStop ? .red : .green
    }
}

private struct CaptureSourceMenu: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        Menu {
            if viewModel.snapshot.base.sessionState.interfaceInventory.isEmpty {
                Text("No Interfaces")
            } else {
                ForEach(viewModel.snapshot.base.sessionState.interfaceInventory) { interface in
                    Button {
                        viewModel.selectInterface(interface.id)
                    } label: {
                        Label(interfaceTitle(interface), systemImage: interface.id == viewModel.snapshot.base.sessionState.selectedInterfaceID ? "checkmark.circle.fill" : "network")
                    }
                    .disabled(!interface.isSelectable || viewModel.snapshot.isCaptureLocked)
                    .help(interfaceHelp(interface))
                }
            }
        } label: {
            Label(viewModel.selectedInterfaceTitle(), systemImage: "network")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 180)
        }
        .controlSize(.regular)
        .disabled(viewModel.snapshot.base.sessionState.interfaceInventory.isEmpty || viewModel.snapshot.isCaptureLocked)
        .help(viewModel.snapshot.isCaptureLocked ? "Stop capture before changing interfaces" : "Capture source")
        .packetryToolbarButtonStyle()
    }

    private func interfaceTitle(_ interface: CaptureInterfaceSummary) -> String {
        interface.friendlyName ?? interface.displayName
    }

    private func interfaceHelp(_ interface: CaptureInterfaceSummary) -> String {
        if let reason = interface.availabilityReason, !interface.isSelectable {
            return reason
        }

        return interface.technicalName
    }
}

private struct ToolbarStatusView: View {
    let snapshot: NetworkInspectorSnapshot

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.2))
                    .frame(width: 16, height: 16)

                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let emphasizedText {
                Text(emphasizedText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: Capsule())
        .help(helpText)
    }

    private var tint: Color {
        if snapshot.base.sessionState.phase == .failed || snapshot.base.documentState.phase == .failed {
            return .red
        }

        if snapshot.base.documentState.isPartialResult || snapshot.droppedPacketCount > 0 || snapshot.malformedPacketCount > 0 {
            return .orange
        }

        if [.starting, .running, .paused, .stopping].contains(snapshot.base.sessionState.phase) ||
            [.opening, .loaded, .saving, .saved, .reopening].contains(snapshot.base.documentState.phase) {
            return .green
        }

        return .secondary
    }

    private var statusText: String {
        if snapshot.base.sessionState.phase == .running {
            return "Packetry | Listening on"
        }

        if snapshot.base.loadState.progress.phase == .loading {
            return "Packetry | Loading"
        }

        if snapshot.base.documentState.phase == .loaded || snapshot.base.documentState.phase == .saved {
            return "Packetry | Viewing"
        }

        if snapshot.base.sessionState.phase == .failed || snapshot.base.documentState.phase == .failed {
            return "Packetry | Attention"
        }

        return "Packetry | \(snapshot.base.sessionState.phase.rawValue.capitalized)"
    }

    private var emphasizedText: String? {
        if snapshot.base.sessionState.phase == .running {
            return listeningTarget
        }

        if snapshot.base.loadState.progress.phase == .loading {
            return snapshot.base.loadState.progress.message
        }

        if snapshot.base.documentState.phase == .loaded || snapshot.base.documentState.phase == .saved {
            return snapshot.base.documentState.fileURL?.lastPathComponent ?? "\(snapshot.totalPacketCount) packets"
        }

        if let error = snapshot.base.sessionState.lastError ?? snapshot.base.documentState.lastError {
            return error.message
        }

        return snapshot.base.sessionState.selectedInterface.map(interfaceTitle)
    }

    private var helpText: String {
        [
            snapshot.base.sessionState.statusMessage,
            "\(snapshot.totalPacketCount) packets",
            "\(snapshot.droppedPacketCount) dropped",
            "\(snapshot.malformedPacketCount) malformed",
        ]
        .joined(separator: " | ")
    }

    private var listeningTarget: String {
        guard let interface = snapshot.base.sessionState.selectedInterface else {
            return "selected interface"
        }

        if let ipv4Address = interface.addresses.first(where: { $0.family == .ipv4 })?.value {
            return ipv4Address
        }

        return interfaceTitle(interface)
    }

    private func interfaceTitle(_ interface: CaptureInterfaceSummary) -> String {
        interface.friendlyName ?? interface.displayName
    }
}

private struct NetworkInspectorSidebar: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        List(
            selection: Binding<NetworkInspectorSidebarSelection?>(
                get: { viewModel.snapshot.selectedSidebar },
                set: { viewModel.selectSidebar($0) }
            )
        ) {
            Section("Capture") {
                Label("Live Capture", systemImage: "dot.radiowaves.left.and.right")
                    .tag(NetworkInspectorSidebarSelection.liveCapture)

                Label("Recent Captures", systemImage: "clock")
                    .tag(NetworkInspectorSidebarSelection.recentCaptures)

                Label("Saved Sessions", systemImage: "externaldrive")
                    .tag(NetworkInspectorSidebarSelection.savedSessions)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct NetworkInspectorCenterPane: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        switch viewModel.snapshot.workspaceMode {
        case .packets:
            PacketWorkspace(viewModel: viewModel)
        case .flows, .timeline, .map, .errors:
            PreparedWorkspace(viewModel: viewModel, mode: viewModel.snapshot.workspaceMode)
        }
    }
}

private struct PacketWorkspace: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        VStack(spacing: 0) {
            PacketWorkspaceHeader(snapshot: viewModel.snapshot)

            if viewModel.snapshot.packetRows.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "list.bullet.rectangle",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NetworkPacketTableView(
                    rows: viewModel.snapshot.packetRows,
                    contentGeneration: viewModel.snapshot.packetTableGeneration,
                    updatePlan: viewModel.snapshot.packetTableUpdatePlan,
                    density: viewModel.snapshot.tableDensity,
                    selectedPacketID: viewModel.snapshot.selectedPacketID,
                    selectedRowIndex: viewModel.snapshot.selectedPacketRowIndex,
                    onSelectPacket: { viewModel.selectPacket($0) }
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyTitle: String {
        viewModel.snapshot.totalPacketCount == 0 ? "No Packets" : "No Matching Packets"
    }

    private var emptyDescription: String {
        viewModel.snapshot.totalPacketCount == 0
            ? "Start a live capture or open a pcap/pcapng file."
            : "Adjust the packet filter to show packets again."
    }
}

private struct PacketWorkspaceHeader: View {
    let snapshot: NetworkInspectorSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Text("Packets")
                .font(.headline)

            Text("\(snapshot.visiblePacketCount) visible")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if snapshot.visiblePacketCount != snapshot.totalPacketCount {
                Text("of \(snapshot.totalPacketCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(snapshot.displayFilterChips) { chip in
                Text(chip.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

private struct PreparedWorkspace: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel
    let mode: NetworkInspectorWorkspaceMode

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)

            Text(mode.title)
                .font(.title2.weight(.semibold))

            Text(mode.preparedStateMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                viewModel.selectWorkspaceMode(.packets)
            } label: {
                Label("Back to Packets", systemImage: "list.bullet.rectangle")
            }
            .packetryToolbarButtonStyle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PacketInspectorRenderState: Equatable {
    let inspectorTab: PacketInspectorTab
    let selectedPacket: PacketSummary?
    let selectedPacketID: PacketSummary.ID?
    let inspection: PacketInspection?
    let selectedDetailNodeID: String?
    let highlightedByteRange: PacketByteRange?
    let isLoading: Bool
    let statusMessage: String

    init(snapshot: NetworkInspectorSnapshot) {
        self.inspectorTab = snapshot.inspectorTab
        self.selectedPacket = snapshot.selectedPacket
        self.selectedPacketID = snapshot.selectedPacketID
        self.inspection = snapshot.base.inspectionState.inspection
        self.selectedDetailNodeID = snapshot.base.inspectionState.selectedDetailNodeID
        self.highlightedByteRange = snapshot.base.inspectionState.highlightedByteRange
        self.isLoading = snapshot.base.inspectionState.isLoading
        self.statusMessage = snapshot.base.inspectionState.statusMessage
    }
}

private struct PacketInspectorPane: View, Equatable {
    let state: PacketInspectorRenderState
    let onSelectInspectorTab: (PacketInspectorTab) -> Void
    let onSelectDetailNode: (String?) -> Void

    static func == (lhs: PacketInspectorPane, rhs: PacketInspectorPane) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        let _ = logInspectorRender()

        VStack(spacing: 0) {
            inspectorHeader

            Divider()

            switch state.inspectorTab {
            case .overview:
                PacketOverviewInspector(state: state)
            case .layers:
                PacketLayersInspector(
                    state: state,
                    onSelectDetailNode: onSelectDetailNode
                )
            case .hex:
                PacketHexInspector(state: state)
            case .stream:
                PacketStreamInspector(state: state)
            case .notes:
                PacketNotesInspector(state: state)
            }
        }
        .background(.regularMaterial)
    }

    private func logInspectorRender() {
        let selectedPacketID = state.selectedPacketID?.description ?? "nil"
        let inspectionPacketID = state.inspection?.packetID.description ?? "nil"
        print("[Packetry] \(NetworkInspectorDebugLog.timestamp()) 🧩 Inspector detail render: tab=\(state.inspectorTab.title), selectedPacketID=\(selectedPacketID), inspectionPacketID=\(inspectionPacketID)")
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Packet Inspector")
                        .font(.headline)

                    if let packet = state.selectedPacket {
                        Text("Packet \(packet.packetNumber) - \(NetworkInspectorFormatters.protocolLabel(for: packet))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Select a packet to inspect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            Picker(
                "Inspector Tab",
                selection: Binding(
                    get: { state.inspectorTab },
                    set: { onSelectInspectorTab($0) }
                )
            ) {
                ForEach(PacketInspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(14)
        .background(.bar)
    }
}

private struct PacketOverviewInspector: View {
    let state: PacketInspectorRenderState

    var body: some View {
        if let packet = state.selectedPacket {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InspectorSection("Summary") {
                        InspectorKeyValueRow(label: "Packet", value: "\(packet.packetNumber)")
                        InspectorKeyValueRow(label: "Length", value: NetworkInspectorFormatters.byteCount(packet.capturedLength))
                        InspectorKeyValueRow(label: "Protocol", value: NetworkInspectorFormatters.protocolLabel(for: packet))
                        InspectorKeyValueRow(label: "Status", value: NetworkInspectorFormatters.severity(for: packet).label)
                    }

                    InspectorSection("Source") {
                        InspectorKeyValueRow(label: "Endpoint", value: NetworkInspectorFormatters.endpointLabel(packet.endpoints.source))
                        InspectorKeyValueRow(label: "Interface", value: packet.captureMetadata.interfaceName ?? packet.interfaceID ?? "-")
                    }

                    InspectorSection("Destination") {
                        InspectorKeyValueRow(label: "Endpoint", value: NetworkInspectorFormatters.endpointLabel(packet.endpoints.destination))
                    }

                    InspectorSection("Timing") {
                        InspectorKeyValueRow(label: "Captured", value: NetworkInspectorFormatters.packetTime.string(from: packet.timestamp))
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                "No Packet Selected",
                systemImage: "sidebar.trailing",
                description: Text(state.statusMessage)
            )
        }
    }
}

private struct PacketLayersInspector: View {
    let state: PacketInspectorRenderState
    let onSelectDetailNode: (String?) -> Void

    var body: some View {
        if state.isLoading {
            ProgressView("Decoding packet...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let inspection = state.inspection {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(inspection.detailNodes) { node in
                        PacketDetailNodeInspectorRow(
                            node: node,
                            depth: 0,
                            selectedNodeID: state.selectedDetailNodeID,
                            onSelect: onSelectDetailNode
                        )
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Layers",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text(state.statusMessage)
            )
        }
    }
}

private struct PacketDetailNodeInspectorRow: View {
    let node: PacketDetailNode
    let depth: Int
    let selectedNodeID: String?
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                onSelect(node.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: node.children.isEmpty ? 6 : 12))
                        .foregroundStyle(node.kind == .warning ? .orange : .secondary)
                        .frame(width: 14)

                    Text(node.name)
                        .fontWeight(node.kind == .layer ? .semibold : .regular)
                        .foregroundStyle(node.kind == .warning ? .orange : .primary)

                    Spacer(minLength: 8)

                    if let value = node.value {
                        Text(value)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, CGFloat(depth) * 16)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedNodeID == node.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            ForEach(node.children) { child in
                PacketDetailNodeInspectorRow(
                    node: child,
                    depth: depth + 1,
                    selectedNodeID: selectedNodeID,
                    onSelect: onSelect
                )
            }
        }
    }

    private var iconName: String {
        if !node.children.isEmpty {
            return "chevron.down"
        }

        return node.kind == .warning ? "exclamationmark.triangle.fill" : "circle.fill"
    }
}

private struct PacketHexInspector: View {
    let state: PacketInspectorRenderState

    var body: some View {
        if let inspection = state.inspection {
            PacketHexFiendView(
                data: inspection.rawBytes,
                highlightedByteRange: state.highlightedByteRange
            )
        } else {
            ContentUnavailableView(
                "Hex",
                systemImage: "binary",
                description: Text("Select a packet to inspect raw bytes.")
            )
        }
    }
}

private struct PacketStreamInspector: View {
    let state: PacketInspectorRenderState

    var body: some View {
        if let packet = state.selectedPacket {
            VStack(alignment: .leading, spacing: 12) {
                InspectorSection("Stream") {
                    InspectorKeyValueRow(label: "Stream ID", value: packet.streamID.map(String.init) ?? "-")
                    InspectorKeyValueRow(label: "Protocol", value: NetworkInspectorFormatters.protocolLabel(for: packet))
                }

                Text("Follow-stream workflows are prepared for a future pass.")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Stream",
                systemImage: "arrow.left.arrow.right",
                description: Text("Select a packet to inspect stream context.")
            )
        }
    }
}

private struct PacketNotesInspector: View {
    let state: PacketInspectorRenderState

    var body: some View {
        if let packet = state.selectedPacket {
            VStack(alignment: .leading, spacing: 12) {
                InspectorSection("Notes") {
                    InspectorKeyValueRow(label: "Packet Comment", value: packet.captureMetadata.packetComment ?? "-")
                    InspectorKeyValueRow(label: "Decode Reason", value: packet.decodeStatus.reason ?? "-")
                }

                Text("Editable packet notes are prepared for a future session/profile pass.")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Notes",
                systemImage: "note.text",
                description: Text("Select a packet to view capture comments.")
            )
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}

private struct InspectorKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct NetworkInspectorStatusStrip: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        HStack(spacing: 16) {
            Label(viewModel.snapshot.base.accessState.title, systemImage: accessImageName)
                .foregroundStyle(viewModel.snapshot.base.accessState.isCaptureReady ? .green : .secondary)

            Text(viewModel.snapshot.base.sessionState.phase.rawValue.capitalized)
                .foregroundStyle(.secondary)

            if viewModel.snapshot.base.loadState.progress.phase == .loading {
                ProgressView(value: viewModel.snapshot.base.loadState.progress.fractionCompleted ?? 0)
                    .frame(width: 140)
                Text(viewModel.snapshot.base.loadState.progress.message)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if viewModel.snapshot.base.documentState.isPartialResult {
                Label("Partial Load", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(viewModel.snapshot.base.packetIngestState.statusMessage)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.snapshot.base.loadState.canCancel {
                Button("Cancel Load") {
                    Task {
                        await viewModel.cancelDocumentLoading()
                    }
                }
                .packetryToolbarButtonStyle()
            }

            Text("\(viewModel.snapshot.totalPacketCount) packets")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("\(viewModel.snapshot.malformedPacketCount) malformed")
                .font(.caption.monospacedDigit())
                .foregroundStyle(viewModel.snapshot.malformedPacketCount > 0 ? .orange : .secondary)

            Text("\(viewModel.snapshot.droppedPacketCount) dropped")
                .font(.caption.monospacedDigit())
                .foregroundStyle(viewModel.snapshot.droppedPacketCount > 0 ? .orange : .secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var accessImageName: String {
        switch viewModel.snapshot.base.accessState {
        case .ready:
            "checkmark.circle.fill"
        case .blocked:
            "exclamationmark.triangle.fill"
        case .checking, .recovering, .unknown:
            "bolt.horizontal.circle"
        }
    }
}
