//
//  ContentView.swift
//  Packetry
//
//  Created by nghiatran on 23/4/26.
//

import SwiftUI
import PcapPlusPlusCore

struct ContentView: View {
    @StateObject private var controller: PacketryWindowController

    init(services: PacketryServiceRegistry = .foundation) {
        _controller = StateObject(wrappedValue: PacketryWindowController(services: services))
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard
                    actionCard
                    interfaceCard
                    documentCard
                    if controller.snapshot.accessState.requiresGuidance {
                        guidanceCard
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 360, idealWidth: 400)

            VStack(alignment: .leading, spacing: 0) {
                packetHeader
                Divider()
                packetList
            }
            .frame(minWidth: 720)
        }
        .frame(minWidth: 1_120, minHeight: 760)
        .task {
            await controller.performInitialLoadIfNeeded()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Packetry v0.2 Capture Core")
                .font(.title2.weight(.semibold))

            Text("This build is exercising the first real native capture bridge, live session control, offline file I/O, and packet-summary ingest.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                stateRow("Capture Access", controller.snapshot.accessState.title)
                stateRow("Session", controller.snapshot.sessionState.phase.rawValue.capitalized)
                stateRow("Document", controller.snapshot.documentState.phase.rawValue.capitalized)
                stateRow("Visible Packets", "\(controller.snapshot.visiblePacketCount)")
                stateRow("Decode Issues", "\(controller.snapshot.packetIngestState.decodeIssueCount)")
                stateRow("Dropped", "\(controller.snapshot.sessionState.health.packetsDropped)")
                stateRow("Core Pin", PcapPlusPlusCoreModule.pinnedTag)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Actions")
                .font(.headline)

            Text(controller.snapshot.accessState.detail)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Refresh Interfaces") {
                        Task {
                            await controller.refreshInterfaces()
                        }
                    }
                    Button("Open Capture…") {
                        controller.presentOpenCapturePanel()
                    }
                    Button("Cancel Background Work") {
                        controller.cancelBackgroundWork()
                    }
                }

                HStack {
                    Button("Start Live Capture") {
                        Task {
                            await controller.startLiveCapture()
                        }
                    }
                    .disabled(!controller.snapshot.sessionState.canStart)

                    Button("Pause") {
                        Task {
                            await controller.pauseLiveCapture()
                        }
                    }
                    .disabled(!controller.snapshot.sessionState.canPause)

                    Button("Resume") {
                        Task {
                            await controller.resumeLiveCapture()
                        }
                    }
                    .disabled(!controller.snapshot.sessionState.canResume)

                    Button("Stop") {
                        Task {
                            await controller.stopLiveCapture()
                        }
                    }
                    .disabled(!controller.snapshot.sessionState.canStop)
                }

                HStack {
                    Button("Reopen") {
                        Task {
                            await controller.reopenDocument()
                        }
                    }
                    .disabled(!controller.snapshot.documentState.canReopen)

                    Button("Save") {
                        Task {
                            await controller.saveDocument()
                        }
                    }
                    .disabled(!controller.snapshot.documentState.canSave)

                    Button("Save As pcap") {
                        controller.presentSaveCapturePanel(format: .pcap)
                    }
                    .disabled(!controller.snapshot.documentState.canSaveAs)

                    Button("Save As pcapng") {
                        controller.presentSaveCapturePanel(format: .pcapng)
                    }
                    .disabled(!controller.snapshot.documentState.canSaveAs)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Interfaces")
                .font(.headline)

            Text(controller.snapshot.sessionState.statusMessage)
                .foregroundStyle(.secondary)

            if controller.snapshot.sessionState.interfaceInventory.isEmpty {
                Text("No interface inventory loaded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.snapshot.sessionState.interfaceInventory) { interface in
                    Button {
                        controller.selectInterface(interface.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(interface.friendlyName ?? interface.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(interface.availability.rawValue.capitalized)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(badgeColor(for: interface).opacity(0.18), in: Capsule())
                                    .foregroundStyle(badgeColor(for: interface))
                            }

                            Text(interface.technicalName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            if let interfaceDescription = interface.interfaceDescription, !interfaceDescription.isEmpty {
                                Text(interfaceDescription)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Text(interfaceDetailLine(interface))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let availabilityReason = interface.availabilityReason {
                                Text(availabilityReason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(interfaceBackground(for: interface), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!interface.isSelectable)
                }
            }

            if let selectedInterface = controller.snapshot.sessionState.selectedInterface {
                Divider()
                Text("Options: \(controller.snapshot.sessionState.optionsSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Selected Interface: \(selectedInterface.friendlyName ?? selectedInterface.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
    }

    private var documentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Document")
                .font(.headline)

            stateRow("Status", controller.snapshot.documentState.statusMessage)
            stateRow("File", controller.snapshot.documentState.fileURL?.lastPathComponent ?? "None")
            stateRow("Format", controller.snapshot.documentState.format?.rawValue.uppercased() ?? "N/A")
            stateRow("Packets", "\(controller.snapshot.documentState.packetCount)")
            stateRow("Observed", "\(controller.snapshot.sessionState.health.packetsObserved)")
            stateRow("Dropped By Interface", "\(controller.snapshot.sessionState.health.packetsDroppedByInterface)")

            if let metadata = controller.snapshot.documentState.metadata {
                if let captureApplication = metadata.captureApplication {
                    stateRow("Capture App", captureApplication)
                }
                if let operatingSystem = metadata.operatingSystem {
                    stateRow("Operating System", operatingSystem)
                }
                if let fileComment = metadata.fileComment {
                    stateRow("Comment", fileComment)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
    }

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Guidance")
                .font(.headline)

            Text(controller.snapshot.accessState.detail)
                .foregroundStyle(.secondary)

            ForEach(controller.snapshot.accessState.recommendedSteps) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                    Text(step.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(step.actionLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
    }

    private var packetHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Packet Ingest")
                .font(.title3.weight(.semibold))

            Text(controller.snapshot.packetIngestState.statusMessage)
                .foregroundStyle(.secondary)

            HStack {
                stateChip("Source", controller.snapshot.packetIngestState.source?.rawValue.capitalized ?? "None")
                stateChip("Last Batch", "\(controller.snapshot.packetIngestState.lastBatchCount)")
                stateChip("Truncated", "\(controller.snapshot.packetIngestState.truncatedPacketCount)")
                stateChip("Decode Issues", "\(controller.snapshot.packetIngestState.decodeIssueCount)")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private var packetList: some View {
        List(controller.snapshot.packetIngestState.packets, selection: packetSelection) { packet in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("#\(packet.packetNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(packet.transportHint.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(packet.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(endpointLine(for: packet))
                    .font(.subheadline.weight(.medium))

                Text(packet.infoSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(lengthLine(for: packet))
                    if let streamID = packet.streamID {
                        Text("stream \(streamID)")
                    }
                    if packet.decodeStatus.kind != .complete {
                        Text(packet.decodeStatus.kind.rawValue.capitalized)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .tag(packet.id)
        }
        .overlay {
            if controller.snapshot.packetIngestState.packets.isEmpty {
                ContentUnavailableView(
                    "No Packets Yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Open a capture file or start a live capture to stream packet summaries here.")
                )
            }
        }
    }

    private var packetSelection: Binding<PacketSummary.ID?> {
        Binding(
            get: { controller.snapshot.selectedPacketID },
            set: { controller.selectPacket($0) }
        )
    }

    @ViewBuilder
    private func stateRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func stateChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func interfaceDetailLine(_ interface: CaptureInterfaceSummary) -> String {
        let addressText = interface.addresses.prefix(3).map(\.value).joined(separator: ", ")
        let capabilityText = interface.capabilities.supportsPromiscuousMode ? "promiscuous" : "no promiscuous"
        let loopbackText = interface.isLoopback ? "loopback" : interface.linkType.rawValue

        if addressText.isEmpty {
            return "\(loopbackText), \(capabilityText)"
        }

        return "\(loopbackText), \(capabilityText), \(addressText)"
    }

    private func interfaceBackground(for interface: CaptureInterfaceSummary) -> Color {
        if controller.snapshot.sessionState.selectedInterfaceID == interface.id {
            return .accentColor.opacity(0.14)
        }

        return interface.isSelectable ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04)
    }

    private func badgeColor(for interface: CaptureInterfaceSummary) -> Color {
        switch interface.availability {
        case .available:
            return .green
        case .hidden:
            return .orange
        case .unavailable, .unsupported:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private func endpointLine(for packet: PacketSummary) -> String {
        "\(endpointText(packet.endpoints.source)) -> \(endpointText(packet.endpoints.destination))"
    }

    private func endpointText(_ endpoint: PacketEndpoint) -> String {
        switch (endpoint.address, endpoint.port) {
        case let (address?, port?):
            "\(address):\(port)"
        case let (address?, nil):
            address
        case let (nil, port?):
            "port \(port)"
        case (nil, nil):
            "unknown"
        }
    }

    private func lengthLine(for packet: PacketSummary) -> String {
        "\(packet.capturedLength)/\(packet.originalLength) bytes"
    }
}

#Preview {
    ContentView(services: PacketryServiceRegistry(core: UnconfiguredPacketryCore()))
}
