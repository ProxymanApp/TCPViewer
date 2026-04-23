import SwiftUI
import PcapPlusPlusCore

struct NetworkInspectorWindow: View {
    @StateObject private var viewModel: NetworkInspectorViewModel
    @State private var isCaptureFilterPopoverPresented = false

    init(services: PacketryServiceRegistry = .foundation) {
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
                        PacketInspectorPane(viewModel: viewModel)
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
                Button {
                    Task {
                        await viewModel.refreshInterfaces()
                    }
                } label: {
                    Label("Refresh Interfaces", systemImage: "arrow.clockwise")
                }
                .packetryToolbarButtonStyle()

                CaptureSourceMenu(viewModel: viewModel)

                Button {
                    Task {
                        await viewModel.toggleLiveCapture()
                    }
                } label: {
                    Label(viewModel.captureButtonTitle(), systemImage: viewModel.captureButtonSystemImage())
                }
                .disabled(!viewModel.snapshot.base.sessionState.canStart && !viewModel.snapshot.base.sessionState.canStop)
                .packetryToolbarButtonStyle(prominent: true)
            }

            ToolbarItemGroup(placement: .principal) {
                DisplayFilterToolbarField(viewModel: viewModel)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.presentOpenCapturePanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .packetryToolbarButtonStyle()

                Button {
                    isCaptureFilterPopoverPresented.toggle()
                } label: {
                    Label("Capture Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $isCaptureFilterPopoverPresented, arrowEdge: .bottom) {
                    CaptureFilterPopover(viewModel: viewModel)
                        .frame(width: 420)
                        .padding(16)
                }
                .packetryToolbarButtonStyle()

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
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .packetryToolbarButtonStyle()

                LayoutMenu(viewModel: viewModel)

                Button {
                    viewModel.toggleInspector()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .packetryToolbarButtonStyle()
            }
        }
        .task {
            await viewModel.performInitialLoadIfNeeded()
        }
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
                        Label(interfaceTitle(interface), systemImage: interface.id == viewModel.snapshot.base.sessionState.selectedInterfaceID ? "checkmark" : "network")
                    }
                    .disabled(!interface.isSelectable || viewModel.snapshot.isCaptureLocked)
                    .help(interfaceHelp(interface))
                }
            }
        } label: {
            Label("Capture: \(viewModel.selectedInterfaceTitle())", systemImage: "network")
                .lineLimit(1)
        }
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

private struct DisplayFilterToolbarField: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                "Filter packets...",
                text: Binding(
                    get: { viewModel.snapshot.displayFilterText },
                    set: { viewModel.updateDisplayFilterText($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320, idealWidth: 460, maxWidth: 560)

            if !viewModel.snapshot.displayFilterText.isEmpty {
                Button {
                    viewModel.clearDisplayFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear packet filter")
            }
        }
    }
}

private struct LayoutMenu: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        Menu {
            Picker(
                "Density",
                selection: Binding(
                    get: { viewModel.snapshot.tableDensity },
                    set: { viewModel.setTableDensity($0) }
                )
            ) {
                ForEach(PacketTableDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }

            Divider()

            Toggle(
                "Show Inspector",
                isOn: Binding(
                    get: { viewModel.snapshot.isInspectorVisible },
                    set: { viewModel.setInspectorVisible($0) }
                )
            )
        } label: {
            Label("Layout", systemImage: "rectangle.split.3x1")
        }
        .packetryToolbarButtonStyle()
    }
}

private struct CaptureFilterPopover: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Filter")
                .font(.headline)

            CaptureFilterToolbarView(
                text: Binding(
                    get: { viewModel.snapshot.base.filterState.captureFilterText },
                    set: { viewModel.updateCaptureFilterText($0) }
                ),
                validation: viewModel.snapshot.base.filterState.validation,
                isValidating: viewModel.snapshot.base.filterState.isValidating,
                recentFilters: viewModel.snapshot.base.filterState.recentCaptureFilters,
                onSubmit: {
                    Task {
                        await viewModel.validateCaptureFilter()
                    }
                },
                onPickRecent: { viewModel.applyRecentCaptureFilter($0) }
            )

            Text(viewModel.snapshot.base.filterState.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

            Section("Interfaces") {
                ForEach(viewModel.snapshot.base.sessionState.interfaceInventory) { interface in
                    SidebarInterfaceRow(interface: interface)
                        .tag(NetworkInspectorSidebarSelection.interface(interface.id))
                        .disabled(!interface.isSelectable || viewModel.snapshot.isCaptureLocked)
                }
            }

            Section("Views") {
                ForEach(NetworkInspectorWorkspaceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(NetworkInspectorSidebarSelection.view(mode))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarInterfaceRow: View {
    let interface: CaptureInterfaceSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: interface.isLoopback ? "arrow.triangle.2.circlepath" : "network")
                .foregroundStyle(interface.isSelectable ? .secondary : .tertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(interface.friendlyName ?? interface.displayName)
                    .lineLimit(1)

                Text(interfaceDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var interfaceDetail: String {
        if let reason = interface.availabilityReason, !interface.isSelectable {
            return reason
        }

        return interface.technicalName
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
                    density: viewModel.snapshot.tableDensity,
                    selectedPacketID: Binding(
                        get: { viewModel.snapshot.selectedPacketID },
                        set: { viewModel.selectPacket($0) }
                    ),
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

private struct PacketInspectorPane: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader

            Divider()

            switch viewModel.snapshot.inspectorTab {
            case .overview:
                PacketOverviewInspector(snapshot: viewModel.snapshot)
            case .layers:
                PacketLayersInspector(viewModel: viewModel)
            case .hex:
                PacketHexInspector(snapshot: viewModel.snapshot)
            case .stream:
                PacketStreamInspector(snapshot: viewModel.snapshot)
            case .notes:
                PacketNotesInspector(snapshot: viewModel.snapshot)
            }
        }
        .background(.regularMaterial)
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Packet Inspector")
                        .font(.headline)

                    if let packet = viewModel.snapshot.selectedPacket {
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
                    get: { viewModel.snapshot.inspectorTab },
                    set: { viewModel.selectInspectorTab($0) }
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
    let snapshot: NetworkInspectorSnapshot

    var body: some View {
        if let packet = snapshot.selectedPacket {
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
                description: Text(snapshot.base.inspectionState.statusMessage)
            )
        }
    }
}

private struct PacketLayersInspector: View {
    @ObservedObject var viewModel: NetworkInspectorViewModel

    var body: some View {
        if viewModel.snapshot.base.inspectionState.isLoading {
            ProgressView("Decoding packet...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let inspection = viewModel.snapshot.base.inspectionState.inspection {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(inspection.detailNodes) { node in
                        PacketDetailNodeInspectorRow(
                            node: node,
                            depth: 0,
                            selectedNodeID: viewModel.snapshot.base.inspectionState.selectedDetailNodeID,
                            onSelect: { viewModel.selectDetailNode($0) }
                        )
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Layers",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text(viewModel.snapshot.base.inspectionState.statusMessage)
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
    let snapshot: NetworkInspectorSnapshot

    var body: some View {
        if let inspection = snapshot.base.inspectionState.inspection {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(hexRows(for: inspection.rawBytes)) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Text(String(format: "%04X", row.offset))
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)

                            HStack(spacing: 4) {
                                ForEach(0..<16, id: \.self) { column in
                                    if let byte = row.byte(at: column) {
                                        Text(String(format: "%02X", byte))
                                            .foregroundStyle(isHighlighted(row.offset + column) ? .primary : .secondary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(isHighlighted(row.offset + column) ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    } else {
                                        Text("  ")
                                            .foregroundStyle(.clear)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                    }
                                }
                            }

                            Text(row.ascii)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Hex",
                systemImage: "binary",
                description: Text("Select a packet to inspect raw bytes.")
            )
        }
    }

    private func isHighlighted(_ offset: Int) -> Bool {
        guard let range = snapshot.base.inspectionState.highlightedByteRange else {
            return false
        }

        return offset >= range.offset && offset < range.upperBound
    }

    private func hexRows(for data: Data) -> [NetworkHexDumpRow] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let chunk = Array(bytes[offset..<min(offset + 16, bytes.count)])
            return NetworkHexDumpRow(offset: offset, bytes: chunk)
        }
    }
}

private struct NetworkHexDumpRow: Identifiable {
    let offset: Int
    let bytes: [UInt8]

    var id: Int { offset }

    func byte(at index: Int) -> UInt8? {
        guard bytes.indices.contains(index) else {
            return nil
        }

        return bytes[index]
    }

    var ascii: String {
        String(bytes.map { byte in
            switch byte {
            case 32...126:
                Character(UnicodeScalar(byte))
            default:
                "."
            }
        })
    }
}

private struct PacketStreamInspector: View {
    let snapshot: NetworkInspectorSnapshot

    var body: some View {
        if let packet = snapshot.selectedPacket {
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
    let snapshot: NetworkInspectorSnapshot

    var body: some View {
        if let packet = snapshot.selectedPacket {
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
