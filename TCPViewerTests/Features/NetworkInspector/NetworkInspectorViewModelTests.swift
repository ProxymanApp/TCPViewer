//
//  NetworkInspectorViewModelTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 23/4/26.
//

import Foundation
import AppKit
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct NetworkInspectorViewModelTests {

    @Test func liveCaptureBuildsPacketRowsSelectionAndFilters() async {
        let packet = makePacket(
            packetNumber: 1,
            source: .live,
            transportHint: .tcp,
            sourcePort: 54_321,
            destinationPort: 443
        )
        let liveSession = InspectorFakeLiveSession()
        liveSession.inspections[packet.id] = makeInspection(for: packet)
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([packet], disposition: .append))

        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .running &&
                viewModel.snapshot.packetRows.count == 1
        }

        #expect(viewModel.snapshot.base.sessionState.selectedInterfaceID == "en0")
        #expect(viewModel.snapshot.packetRows.first?.protocolText == "TCP")
        #expect(viewModel.snapshot.packetRows.first?.destinationText == "10.0.0.2:443")
        #expect(viewModel.snapshot.inspectorTab == .summary)

        viewModel.selectPacket(packet.id)
        await waitUntil {
            viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id
        }

        #expect(viewModel.snapshot.selectedPacket?.id == packet.id)
        #expect(viewModel.snapshot.inspectorTab == .summary)
        #expect(viewModel.snapshot.base.inspectionState.inspection?.rawBytes.count == 16)

        viewModel.updateDisplayFilterText("protocol:tcp port:443")
        #expect(viewModel.snapshot.visiblePacketCount == 1)
        #expect(viewModel.snapshot.displayFilterChips.map(\.label) == ["Protocol: TCP", "Port: 443"])

        viewModel.updateDisplayFilterText("protocol:udp")
        #expect(viewModel.snapshot.visiblePacketCount == 0)
    }

    @Test func restartingLiveCaptureClearsPreviousPacketsAndInspection() async {
        let packet = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let liveSession = InspectorFakeLiveSession()
        liveSession.inspections[packet.id] = makeInspection(for: packet)
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([packet], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }
        viewModel.selectPacket(packet.id)
        await waitUntil {
            viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id
        }

        viewModel.stopLiveCapture()
        liveSession.send(.liveStateChanged(phase: .stopped, message: "Live capture stopped."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .stopped
        }

        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .running &&
                liveSession.startCount == 2
        }

        #expect(liveSession.stopCount == 1)
        #expect(viewModel.snapshot.totalPacketCount == 0)
        #expect(viewModel.snapshot.packetRows.isEmpty)
        #expect(viewModel.snapshot.selectedPacket == nil)
        #expect(viewModel.snapshot.selectedPacketRowIndex == nil)
        #expect(viewModel.snapshot.base.selectedPacketID == nil)
        #expect(viewModel.snapshot.base.inspectionState.inspection == nil)
    }

    @Test func restartingLiveCaptureIgnoresPacketsFromStoppedSession() async {
        let oldPacket = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let stalePacket = makePacket(packetNumber: 2, source: .live, transportHint: .udp)
        let freshPacket = makePacket(packetNumber: 3, source: .live, transportHint: .dns)
        let firstSession = InspectorFakeLiveSession()
        let secondSession = InspectorFakeLiveSession()
        let core = InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
            liveSessions: [firstSession, secondSession]
        )
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: core),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        firstSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        firstSession.send(.packetBatch([oldPacket], disposition: .append))
        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [oldPacket.id]
        }

        viewModel.stopLiveCapture()
        firstSession.send(.liveStateChanged(phase: .stopped, message: "Live capture stopped."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .stopped
        }

        await viewModel.toggleLiveCapture()
        secondSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .running &&
                core.makeLiveCaptureSessionCallCount == 2
        }
        firstSession.send(.packetBatch([stalePacket], disposition: .append))
        #expect(viewModel.snapshot.packetRows.isEmpty)

        secondSession.send(.packetBatch([freshPacket], disposition: .append))
        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [freshPacket.id]
        }

        #expect(viewModel.snapshot.packetRows.map(\.id).contains(stalePacket.id) == false)
    }

    @Test func statusMetricsMonitoringRunsOnlyWhileLiveCaptureIsRunning() async {
        let liveSession = InspectorFakeLiveSession()
        let metricsService = TCPViewerStatusMetricsService(
            timerInterval: 60,
            memorySampler: { 323 * 1_024 * 1_024 },
            callbackQueue: .main
        )
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults(),
            statusMetricsService: metricsService
        )

        #expect(metricsService.isSampling)
        #expect(!metricsService.isMonitoring)
        await viewModel.performInitialLoadIfNeeded()
        #expect(metricsService.isSampling)
        #expect(!metricsService.isMonitoring)

        await viewModel.toggleLiveCapture()
        #expect(metricsService.isSampling)
        #expect(!metricsService.isMonitoring)

        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .running &&
                metricsService.isMonitoring
        }

        liveSession.send(.liveStateChanged(phase: .paused, message: "Capture paused."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .paused &&
                metricsService.isSampling &&
                !metricsService.isMonitoring
        }

        liveSession.send(.liveStateChanged(phase: .running, message: "Capture resumed."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .running &&
                metricsService.isMonitoring
        }

        viewModel.stopLiveCapture()
        liveSession.send(.liveStateChanged(phase: .stopped, message: "Live capture stopped."))
        await waitUntil {
            viewModel.snapshot.base.sessionState.phase == .stopped &&
                metricsService.isSampling &&
                !metricsService.isMonitoring
        }
    }

    @Test func offlineOpenSaveAndSaveAsFlowThroughCoreDocument() async {
        let openURL = URL(fileURLWithPath: "/tmp/inspector-fixture.pcapng")
        let saveURL = URL(fileURLWithPath: "/tmp/inspector-export.pcap")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .dns),
        ]
        let document = InspectorFakeDocument(url: openURL, packets: packets)
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: document
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.base.documentState.phase == .loaded &&
                viewModel.snapshot.packetRows.count == 2
        }

        #expect(viewModel.snapshot.totalPacketCount == 2)
        #expect(viewModel.snapshot.packetRows.map(\.protocolText) == ["UDP", "DNS"])

        await viewModel.saveDocument()
        #expect(document.saveCount == 1)

        await viewModel.saveDocument(to: saveURL, format: .pcap)
        #expect(document.saveAsRequests.count == 1)
        #expect(document.saveAsRequests.first?.0 == saveURL)
        #expect(document.saveAsRequests.first?.1 == .pcap)
        #expect(viewModel.snapshot.base.documentState.fileURL == saveURL)
    }

    @Test func missingNetworkHelperShowsOnboardingButOfflineOpenStillWorks() async {
        let openURL = URL(fileURLWithPath: "/tmp/offline-while-helper-missing.pcapng")
        let packets = [makePacket(packetNumber: 1, source: .offline, transportHint: .udp)]
        let document = InspectorFakeDocument(url: openURL, packets: packets)
        let helper = InspectorFakeNetworkHelperTool(
            snapshot: TCPViewerNetworkHelperToolSnapshot(
                status: .notInstalled,
                authorizationStatus: .notRegistered,
                lastCheckedAt: nil,
                message: "TCP Viewer Network Helper Tool is not installed.",
                installedHelperToolVersion: nil
            )
        )
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    document: document
                ),
                networkHelperTool: helper
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()

        #expect(viewModel.shouldPresentNetworkHelperOnboarding)
        #expect(viewModel.snapshot.base.accessState == .blocked(.helperMissing))
        #expect(viewModel.snapshot.base.sessionState.interfaceInventory.isEmpty)
        #expect(!viewModel.snapshot.base.sessionState.canStart)

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.base.documentState.phase == .loaded &&
                viewModel.snapshot.packetRows.count == 1
        }

        #expect(viewModel.snapshot.totalPacketCount == 1)
    }

    @Test func importingCaptureSelectsImportedFileSourceListItem() async throws {
        let importURL = TCPViewerCaptureFileImportPolicy.standardizedFileURL(URL(fileURLWithPath: "/tmp/import-selection.pcapng"))
        let packets = [makePacket(packetNumber: 1, source: .offline, transportHint: .udp)]
        let document = InspectorFakeDocument(url: importURL, packets: packets)
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: document
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.importDocuments(at: [importURL])
        await waitUntil {
            viewModel.snapshot.base.documentState.phase == .loaded &&
                viewModel.snapshot.base.packetIngestState.importedFiles.count == 1
        }

        let importedFile = try #require(viewModel.snapshot.base.packetIngestState.importedFiles.first)
        #expect(viewModel.snapshot.selectedSourceListSelection == .file(importedFile.id))
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .files) == nil)
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .file(importedFile.id))?.title == "import-selection.pcapng")
    }

    @Test func packetFormattingFilteringAndTableUpdatePlansAreStable() {
        let client = makeClient()
        let healthy = makePacket(
            packetNumber: 1,
            source: .offline,
            transportHint: .http1,
            destinationPort: 80,
            sniDomainName: "api.example.com",
            client: client,
            direction: .outbound,
            tcpFlags: "SYN, ACK",
            tcpPayloadLength: 42,
            interfaceName: "en0"
        )
        let malformed = makePacket(
            packetNumber: 2,
            source: .offline,
            transportHint: .udp,
            decodeStatus: PacketDecodeStatus(kind: .malformed, reason: "Bad length")
        )
        let tls = makePacket(
            packetNumber: 3,
            source: .offline,
            transportHint: .tls,
            destinationPort: 443,
            transportLayerName: "TLSv1.2"
        )
        let tlsFallback = makePacket(
            packetNumber: 4,
            source: .offline,
            transportHint: .tls,
            destinationPort: 443
        )
        let wiresharkProtocol = makePacket(
            packetNumber: 5,
            source: .offline,
            transportHint: .tcp,
            destinationPort: 443,
            protocolSummary: "TLSv1.3"
        )

        let healthyRow = PacketTableRow(packet: healthy)
        let malformedRow = PacketTableRow(packet: malformed)

        #expect(healthyRow.protocolText == "HTTP1")
        #expect(healthyRow.lengthText == "128 B")
        #expect(healthyRow.domainText == "api.example.com")
        #expect(healthyRow.clientText == "Example")
        #expect(healthyRow.text(for: .sourcePort) == "1234")
        #expect(healthyRow.text(for: .destinationPort) == "80")
        #expect(healthyRow.text(for: .streamID) == "7")
        #expect(healthyRow.text(for: .direction) == "Outbound")
        #expect(healthyRow.text(for: .tcpFlags) == "SYN, ACK")
        #expect(healthyRow.text(for: .tcpPayloadBytes) == "42 B")
        #expect(healthyRow.text(for: .pid) == "123")
        #expect(healthyRow.text(for: .bundleIdentifier) == "com.example.app")
        #expect(healthyRow.text(for: .decodeStatus) == "Complete")
        #expect(healthyRow.text(for: .interface) == "en0")
        #expect(malformedRow.severity == .malformed)
        #expect(malformedRow.tags.map(\.label) == ["Malformed"])
        #expect(PacketTableRow(packet: tls).protocolText == "TLSv1.2")
        #expect(PacketTableRow(packet: tlsFallback).protocolText == "TLS")
        #expect(PacketTableRow(packet: wiresharkProtocol).protocolText == "TLSv1.3")

        #expect(PacketDisplayFilter("protocol:http port:80").matches(healthy))
        #expect(PacketDisplayFilter("protocol:TLSv1.2").matches(tls))
        #expect(PacketDisplayFilter("api.example.com").matches(healthy))
        #expect(PacketDisplayFilter("com.example.app").matches(healthy))
        #expect(PacketDisplayFilter("error:malformed").matches(malformed))
        #expect(!PacketDisplayFilter("protocol:tcp").matches(malformed))

        #expect(PacketTableUpdatePlanner.plan(previousGeneration: 0, currentGeneration: 1, proposedPlan: .append(0..<2)) == .append(0..<2))
        #expect(PacketTableUpdatePlanner.plan(previousGeneration: 1, currentGeneration: 2, proposedPlan: .reload) == .reload)
        #expect(PacketTableUpdatePlanner.plan(previousGeneration: 1, currentGeneration: 1, proposedPlan: .reload) == .none)
    }

    @Test func packetTableRowsFormatGlobalAndStreamDeltas() {
        var timingState = PacketTableRowTimingState()
        let first = timingState.row(for: makePacket(packetNumber: 1, source: .live, transportHint: .tcp, streamID: 10))
        let second = timingState.row(for: makePacket(packetNumber: 2, source: .live, transportHint: .tcp, streamID: 10))
        let third = timingState.row(for: makePacket(packetNumber: 3, source: .live, transportHint: .tcp, streamID: 11))

        #expect(first.text(for: .deltaTime) == "-")
        #expect(first.text(for: .streamDeltaTime) == "-")
        #expect(second.text(for: .deltaTime) == "1.000 s")
        #expect(second.text(for: .streamDeltaTime) == "1.000 s")
        #expect(third.text(for: .deltaTime) == "1.000 s")
        #expect(third.text(for: .streamDeltaTime) == "-")
    }

    @Test func packetTableSelectionSyncOnlyTouchesStaleVisualSelection() {
        let packets = [
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
            makePacket(packetNumber: 3, source: .live, transportHint: .dns),
        ]

        #expect(PacketTableSelectionSyncPlanner.action(
            visualSelectedID: packets[1].id,
            selectedPacketID: packets[1].id,
            selectedRowIndex: 1,
            rowCount: packets.count
        ) == .none)

        #expect(PacketTableSelectionSyncPlanner.action(
            visualSelectedID: nil,
            selectedPacketID: packets[1].id,
            selectedRowIndex: 1,
            rowCount: packets.count
        ) == .select(1))

        #expect(PacketTableSelectionSyncPlanner.action(
            visualSelectedID: packets[0].id,
            selectedPacketID: packets[1].id,
            selectedRowIndex: 1,
            rowCount: packets.count
        ) == .select(1))

        #expect(PacketTableSelectionSyncPlanner.action(
            visualSelectedID: packets[1].id,
            selectedPacketID: nil,
            selectedRowIndex: nil,
            rowCount: packets.count
        ) == .deselect)

        #expect(PacketTableSelectionSyncPlanner.action(
            visualSelectedID: nil,
            selectedPacketID: packets[1].id,
            selectedRowIndex: nil,
            rowCount: packets.count
        ) == .none)

        #expect(PacketTableSelectionSyncPlanner.action(
            visualSelectedID: packets[1].id,
            selectedPacketID: packets[1].id,
            selectedRowIndex: packets.count,
            rowCount: packets.count
        ) == .deselect)
    }

    @Test func packetTableViewModelReleasesReplacedRowsOnRenderPath() {
        let second = makePacket(packetNumber: 2, source: .live, transportHint: .udp)
        let secondStore = PacketTableRowStore(
            rows: [PacketTableRow(packet: second)],
            visiblePacketRowIndexByID: [second.id: 0]
        )
        weak var releasedStore: PacketTableRowStore?

        do {
            let viewModel = PacketTableViewModel()
            do {
                let first = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
                let firstStore = PacketTableRowStore(
                    rows: [PacketTableRow(packet: first)],
                    visiblePacketRowIndexByID: [first.id: 0]
                )
                releasedStore = firstStore
                let firstSnapshot = makeInspectorSnapshot(
                    packets: [first],
                    selectedPacketID: first.id,
                    packetTableContent: PacketTableContent(
                        displayFilter: PacketDisplayFilter(""),
                        displayFilterChips: [],
                        store: firstStore,
                        generation: 1,
                        updatePlan: .reload,
                        malformedPacketCount: 0
                    )
                )
                _ = viewModel.render(snapshot: firstSnapshot)
            }
            #expect(releasedStore != nil)

            let secondSnapshot = makeInspectorSnapshot(
                packets: [second],
                selectedPacketID: second.id,
                packetTableContent: PacketTableContent(
                    displayFilter: PacketDisplayFilter(""),
                    displayFilterChips: [],
                    store: secondStore,
                    generation: 2,
                    updatePlan: .reload,
                    malformedPacketCount: 0
                )
            )
            _ = viewModel.render(snapshot: secondSnapshot)
        }

        #expect(releasedStore == nil)
    }

    @Test func packetTableViewModelReadsRowIDsWithoutCopyingRowArray() {
        let packets = [
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
        ]
        let store = PacketTableRowStore(
            rows: packets.map(PacketTableRow.init(packet:)),
            visiblePacketRowIndexByID: [packets[0].id: 0, packets[1].id: 1]
        )
        let snapshot = makeInspectorSnapshot(
            packets: packets,
            selectedPacketID: packets[1].id,
            packetTableContent: PacketTableContent(
                displayFilter: PacketDisplayFilter(""),
                displayFilterChips: [],
                store: store,
                generation: 1,
                updatePlan: .reload,
                malformedPacketCount: 0
            )
        )
        let viewModel = PacketTableViewModel()
        _ = viewModel.render(snapshot: snapshot)

        #expect(viewModel.rowCount == 2)
        #expect(viewModel.rowID(at: 0) == packets[0].id)
        #expect(viewModel.rowID(at: 1) == packets[1].id)
        #expect(viewModel.rowID(at: -1) == nil)
        #expect(viewModel.rowID(at: 2) == nil)
    }

    @Test func inspectorTreeIgnoresUnchangedInspectionDuringAppend() {
        let selectedPacket = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, streamID: nil)
        let appendedPacket = makePacket(packetNumber: 2, source: .live, transportHint: .udp, streamID: nil)
        let treeViewModel = PacketInspectorTreeViewModel()
        let firstSnapshot = makeInspectorSnapshot(
            packets: [selectedPacket],
            selectedPacketID: selectedPacket.id,
            inspection: makeInspection(for: selectedPacket),
            generation: 1,
            updatePlan: .reload
        )
        let appendSnapshot = makeInspectorSnapshot(
            packets: [selectedPacket, appendedPacket],
            selectedPacketID: selectedPacket.id,
            inspection: makeInspection(for: selectedPacket),
            generation: 2,
            updatePlan: .append(1..<2)
        )

        #expect(treeViewModel.render(snapshot: firstSnapshot) == .reload)
        #expect(treeViewModel.rootItems.first?.displayText == "Frame: Packet 1")
        #expect(treeViewModel.render(snapshot: appendSnapshot) == .none)
    }

    @Test func statusStripKeepsCancelAvailableDuringZeroPacketLoad() {
        var base = TCPViewerWindowSnapshot.foundation
        base.loadState = PacketLoadState(progress: PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "Loading capture..."
        ))
        let snapshot = NetworkInspectorSnapshot.make(
            base: base,
            selectedSidebar: .liveCapture,
            selectedSourceListSelection: .allPackets,
            sourceListSnapshot: .empty,
            sourceListFilterText: "",
            workspaceMode: .packets,
            inspectorTab: .summary,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: .empty
        )
        let viewModel = StatusStripViewModel()

        viewModel.render(snapshot: snapshot)

        #expect(viewModel.canCancelLoad)
        #expect(!viewModel.canClear)
    }

    @Test func statusStripClearUsesVisibleTableRows() {
        var base = TCPViewerWindowSnapshot.foundation
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        base.packetIngestState.replace(with: [packet], source: .offline)
        let snapshot = NetworkInspectorSnapshot.make(
            base: base,
            selectedSidebar: .liveCapture,
            selectedSourceListSelection: .allPackets,
            sourceListSnapshot: .empty,
            sourceListFilterText: "",
            workspaceMode: .packets,
            inspectorTab: .summary,
            isInspectorVisible: true,
            displayFilterText: "protocol:udp",
            packetTableContent: .empty
        )
        let viewModel = StatusStripViewModel()

        viewModel.render(snapshot: snapshot)

        #expect(viewModel.totalText == "1 packet")
        #expect(!viewModel.canClear)
    }

    @Test func statusStripHidesCapturePhaseStatusText() {
        var base = TCPViewerWindowSnapshot.foundation
        base.sessionState.phase = .stopped
        let snapshot = NetworkInspectorSnapshot.make(
            base: base,
            selectedSidebar: .liveCapture,
            selectedSourceListSelection: .allPackets,
            sourceListSnapshot: .empty,
            sourceListFilterText: "",
            workspaceMode: .packets,
            inspectorTab: .summary,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: .empty
        )
        let controller = StatusStripViewController()

        controller.loadViewIfNeeded()
        controller.render(snapshot: snapshot)

        let labels = allSubviews(ofType: NSTextField.self, in: controller.view).map(\.stringValue)
        #expect(labels.contains("0 packets"))
        #expect(!labels.contains("Stopped"))
    }

    @Test func statusStripRendersProcessAndCapturedTrafficMetrics() {
        let viewModel = StatusStripViewModel()
        let metrics = TCPViewerStatusMetricsSnapshot(
            memoryBytes: 323 * 1_024 * 1_024 + 1,
            uploadBytesPerSecond: 1_025,
            downloadBytesPerSecond: 0
        )

        viewModel.render(metrics: metrics)

        #expect(viewModel.metricsText == "• 324 MB ↑ 2 KB/s ↓ 0 KB/s")
    }

    @Test func packetRowsAreCachedAcrossNonPacketUpdates() async {
        let packet = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([packet], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        let generationAfterPackets = viewModel.snapshot.packetTableGeneration

        viewModel.selectInspectorTab(.hex)
        #expect(viewModel.snapshot.packetTableGeneration == generationAfterPackets)

        liveSession.send(.healthChanged(CaptureHealthSnapshot(
            packetsReceived: 1,
            packetsDropped: 1,
            packetsDroppedByInterface: 0,
            packetsObserved: 1,
            lastUpdated: Date(timeIntervalSince1970: 2),
            statusMessage: "1 packet dropped."
        )))

        await waitUntil {
            viewModel.snapshot.droppedPacketCount == 1
        }

        #expect(viewModel.snapshot.packetTableGeneration == generationAfterPackets)
    }

    @Test func inspectorTogglePersistsVisibility() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(viewModel.snapshot.isInspectorVisible)

        viewModel.toggleInspector()
        #expect(viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(!viewModel.snapshot.isInspectorVisible)

        let hiddenReloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )
        #expect(hiddenReloadedViewModel.snapshot.inspectorPlacement == .trailing)
        #expect(!hiddenReloadedViewModel.snapshot.isInspectorVisible)

        hiddenReloadedViewModel.toggleInspector()
        #expect(hiddenReloadedViewModel.snapshot.inspectorPlacement == .trailing)
        #expect(hiddenReloadedViewModel.snapshot.isInspectorVisible)
    }

    @Test func inspectorPlacementTogglesCloseActivePlacementAndSwitchVisiblePlacement() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(viewModel.snapshot.isInspectorVisible)

        viewModel.toggleInspector(placement: .trailing)
        #expect(viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(!viewModel.snapshot.isInspectorVisible)

        viewModel.toggleInspector(placement: .bottom)
        #expect(viewModel.snapshot.inspectorPlacement == .bottom)
        #expect(viewModel.snapshot.isInspectorVisible)

        viewModel.toggleInspector(placement: .trailing)
        #expect(viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(viewModel.snapshot.isInspectorVisible)

        viewModel.toggleInspector(placement: .trailing)
        #expect(viewModel.snapshot.inspectorPlacement == .trailing)
        #expect(!viewModel.snapshot.isInspectorVisible)
    }

    @Test func bottomInspectorPlacementPersistsAcrossReloads() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        viewModel.toggleInspector(placement: .bottom)

        let reloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(reloadedViewModel.snapshot.inspectorPlacement == .bottom)
        #expect(reloadedViewModel.snapshot.isInspectorVisible)

        reloadedViewModel.toggleInspector(placement: .bottom)

        let hiddenReloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(hiddenReloadedViewModel.snapshot.inspectorPlacement == .bottom)
        #expect(!hiddenReloadedViewModel.snapshot.isInspectorVisible)
    }

    @Test func bottomInspectorPlacementLaysOutInspectorBelowWorkspace() async throws {
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        let document = InspectorFakeDocument(
            url: URL(fileURLWithPath: "/tmp/root-bottom-inspector.pcapng"),
            packets: [packet]
        )
        let defaults = isolatedDefaults()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: document
            )),
            userDefaults: defaults
        )
        let controller = TCPViewerRootViewController(
            viewModel: viewModel,
            configuration: AppConfiguration(defaults: defaults)
        )

        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        await viewModel.openDocument(at: document.currentURL())
        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [packet.id]
        }

        viewModel.selectPacket(packet.id)
        await waitUntil {
            viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id
        }

        viewModel.toggleInspector(placement: .bottom)
        controller.view.layoutSubtreeIfNeeded()
        await waitUntil {
            guard let workspaceView = controller.workspaceViewForTesting,
                  let inspectorView = controller.inspectorViewForTesting else {
                return false
            }

            let splitView = controller.inspectorSplitViewForTesting
            let inspectorFrame = inspectorView.convert(inspectorView.bounds, to: splitView)
            let workspaceFrame = workspaceView.convert(workspaceView.bounds, to: splitView)
            return !splitView.isVertical &&
                inspectorFrame.height > 0 &&
                workspaceFrame.height > 0 &&
                frame(inspectorFrame, isVisuallyBelow: workspaceFrame, in: splitView)
        }

        let splitView = controller.inspectorSplitViewForTesting
        let workspaceView = try #require(controller.workspaceViewForTesting)
        let inspectorView = try #require(controller.inspectorViewForTesting)
        let inspectorFrame = inspectorView.convert(inspectorView.bounds, to: splitView)
        let workspaceFrame = workspaceView.convert(workspaceView.bounds, to: splitView)

        #expect(!splitView.isVertical)
        #expect(frame(inspectorFrame, isVisuallyBelow: workspaceFrame, in: splitView))
    }

    @Test func sidebarVisibilityPersistsAcrossReloads() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(viewModel.prefersSidebarVisibleOnLaunch())

        viewModel.setSidebarVisible(false)

        let hiddenReloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(!hiddenReloadedViewModel.prefersSidebarVisibleOnLaunch())

        hiddenReloadedViewModel.setSidebarVisible(true)

        let visibleReloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(visibleReloadedViewModel.prefersSidebarVisibleOnLaunch())
    }

    @Test func structuredFilterVisibilityDefaultsHiddenAndPersistsAcrossReloads() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(!viewModel.snapshot.isStructuredFilterVisible)

        viewModel.setStructuredFilterVisible(true)
        #expect(viewModel.snapshot.isStructuredFilterVisible)

        let visibleReloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )
        #expect(visibleReloadedViewModel.snapshot.isStructuredFilterVisible)

        visibleReloadedViewModel.setStructuredFilterVisible(false)

        let hiddenReloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )
        #expect(!hiddenReloadedViewModel.snapshot.isStructuredFilterVisible)
    }

    @Test func customFiltersLoadIntoInitialSnapshot() throws {
        let customFilterService = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))
        let group = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp")],
            operator: .and
        )
        let savedFilter = try customFilterService.save(name: "TCP Preset", group: group)
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))

        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: isolatedDefaults(),
            pinService: PacketPinService(storageURL: temporaryDirectory().appendingPathComponent("Pins.json")),
            savedPacketService: SavedPacketService(storageURL: temporaryDirectory().appendingPathComponent("Saved.json")),
            customFilterService: customFilterService
        )

        #expect(viewModel.snapshot.customFilterItems == [
            PacketCustomFilterItem(id: savedFilter.id, title: "TCP Preset", isSelected: false),
        ])
    }

    @Test func applyingCustomFilterTogglesStructuredFilterVisibilityAndRows() async throws {
        let tcpPacket = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, layerNames: ["Ethernet", "TCP"])
        let udpPacket = makePacket(packetNumber: 2, source: .offline, transportHint: .udp, layerNames: ["Ethernet", "UDP"])
        let customFilterService = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))
        let group = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp")],
            operator: .and
        )
        let savedFilter = try customFilterService.save(name: "TCP Only", group: group)
        let viewModel = makeOfflineViewModel(packets: [tcpPacket, udpPacket], customFilterService: customFilterService)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/custom-filter-apply.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 2
        }

        viewModel.applyCustomFilter(id: savedFilter.id)

        #expect(viewModel.snapshot.isStructuredFilterVisible)
        #expect(viewModel.snapshot.structuredFilterGroup == group)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [tcpPacket.id])
        #expect(viewModel.snapshot.customFilterItems.first?.isSelected == true)

        viewModel.applyCustomFilter(id: savedFilter.id)

        #expect(!viewModel.snapshot.isStructuredFilterVisible)
        #expect(viewModel.snapshot.structuredFilterGroup == group)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [tcpPacket.id, udpPacket.id])
        #expect(viewModel.snapshot.customFilterItems.first?.isSelected == false)
    }

    @Test func savingCurrentStructuredFilterAddsSelectedCustomFilter() throws {
        let customFilterService = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))
        let viewModel = makeOfflineViewModel(packets: [], customFilterService: customFilterService)
        let group = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .summary, condition: .matchesRegex, text: "GET|POST", isEnabled: true),
                PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "443", isEnabled: false),
            ],
            operator: .or
        )

        viewModel.updateStructuredFilterGroup(group)
        viewModel.setStructuredFilterVisible(true)
        let savedFilter = try viewModel.saveCustomFilter(name: "  HTTP Methods  ", group: viewModel.snapshot.structuredFilterGroup)

        #expect(customFilterService.filters().map(\.id) == [savedFilter.id])
        #expect(viewModel.snapshot.customFilterItems == [
            PacketCustomFilterItem(id: savedFilter.id, title: "HTTP Methods", isSelected: true),
        ])
    }

    @Test func renamingAndDeletingCustomFilterRefreshesItemsWithoutChangingStructuredGroup() throws {
        let customFilterService = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))
        let group = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .client, condition: .contains, text: "Safari")],
            operator: .and
        )
        let savedFilter = try customFilterService.save(name: "Client", group: group)
        let viewModel = makeOfflineViewModel(packets: [], customFilterService: customFilterService)

        viewModel.applyCustomFilter(id: savedFilter.id)
        try viewModel.renameCustomFilter(id: savedFilter.id, name: "  Browser  ")

        #expect(viewModel.snapshot.structuredFilterGroup == group)
        #expect(viewModel.snapshot.customFilterItems == [
            PacketCustomFilterItem(id: savedFilter.id, title: "Browser", isSelected: true),
        ])

        try viewModel.deleteCustomFilter(id: savedFilter.id)

        #expect(viewModel.snapshot.structuredFilterGroup == group)
        #expect(viewModel.snapshot.customFilterItems.isEmpty)
        #expect(viewModel.snapshot.isStructuredFilterVisible)
    }

    @Test func overridingCustomFilterKeepsNameAndSelectsUpdatedGroup() throws {
        let customFilterService = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))
        let originalGroup = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .client, condition: .contains, text: "Safari")],
            operator: .and
        )
        let replacementGroup = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .summary, condition: .contains, text: "DNS")],
            operator: .or
        )
        let savedFilter = try customFilterService.save(name: "Traffic", group: originalGroup)
        let viewModel = makeOfflineViewModel(packets: [], customFilterService: customFilterService)

        viewModel.setStructuredFilterVisible(true)
        try viewModel.overrideCustomFilter(id: savedFilter.id, group: replacementGroup)

        let updatedFilter = try #require(customFilterService.filter(id: savedFilter.id))
        #expect(updatedFilter.name == "Traffic")
        #expect(updatedFilter.group == replacementGroup)
        #expect(viewModel.snapshot.structuredFilterGroup == replacementGroup)
        #expect(viewModel.snapshot.customFilterItems == [
            PacketCustomFilterItem(id: savedFilter.id, title: "Traffic", isSelected: true),
        ])
    }

    @Test func duplicatingCustomFilterAddsCopyWithoutChangingStructuredGroup() throws {
        let customFilterService = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))
        let firstGroup = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .client, condition: .contains, text: "Safari")],
            operator: .and
        )
        let secondGroup = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .summary, condition: .contains, text: "DNS")],
            operator: .or
        )
        let first = try customFilterService.save(name: "Client", group: firstGroup)
        let second = try customFilterService.save(name: "Summary", group: secondGroup)
        let viewModel = makeOfflineViewModel(packets: [], customFilterService: customFilterService)

        viewModel.applyCustomFilter(id: second.id)
        try viewModel.duplicateCustomFilter(id: first.id)

        #expect(viewModel.snapshot.structuredFilterGroup == secondGroup)
        #expect(viewModel.snapshot.customFilterItems.map(\.title) == ["Client", "Client", "Summary"])
        #expect(viewModel.snapshot.customFilterItems.map(\.isSelected) == [false, false, true])
    }

    @Test func sidebarThicknessPersistsAndFallsBackWhenInvalid() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(viewModel.preferredSidebarThickness(for: 800) == 280)

        viewModel.rememberSidebarThickness(340)

        let reloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(reloadedViewModel.preferredSidebarThickness(for: 800) == 340)

        reloadedViewModel.rememberSidebarThickness(10_000)

        #expect(reloadedViewModel.preferredSidebarThickness(for: 800) == 280)
    }

    @Test func inspectorThicknessPersistsAndFallsBackWhenInvalid() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        viewModel.rememberInspectorThickness(360)

        let reloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900) == 360)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 900) == 360)

        reloadedViewModel.rememberInspectorThickness(10_000)

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900) == nil)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 900) == 360)

        reloadedViewModel.rememberInspectorThickness(99)

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900) == nil)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 900) == 360)

        reloadedViewModel.rememberInspectorThickness(100)

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900) == nil)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 900) == 360)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 100) == nil)

        reloadedViewModel.rememberInspectorThickness(101)

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900) == 101)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 900) == 101)
    }

    @Test func bottomInspectorThicknessPersistsAndFallsBackWhenInvalid() {
        let defaults = isolatedDefaults()
        let services = TCPViewerServiceRegistry(core: InspectorFakeCore(
            interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
        ))
        let viewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        viewModel.rememberInspectorThickness(420, placement: .trailing)
        viewModel.rememberInspectorThickness(260, placement: .bottom)

        let reloadedViewModel = NetworkInspectorViewModel(
            services: services,
            userDefaults: defaults
        )

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900, placement: .trailing) == 420)
        #expect(reloadedViewModel.preferredInspectorThickness(for: 900, placement: .bottom) == 260)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 900, placement: .bottom) == 260)

        reloadedViewModel.rememberInspectorThickness(10_000, placement: .bottom)

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900, placement: .bottom) == nil)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 900, placement: .bottom) == 360)

        reloadedViewModel.rememberInspectorThickness(100, placement: .bottom)

        #expect(reloadedViewModel.preferredInspectorThickness(for: 900, placement: .bottom) == nil)
        #expect(reloadedViewModel.restoredInspectorThickness(for: 100, placement: .bottom) == nil)
    }

    @Test func packetRowsAppendIncrementallyForMatchingLiveBatches() async {
        let packets = [
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
            makePacket(packetNumber: 3, source: .live, transportHint: .dns),
        ]
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([packets[0]], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        liveSession.send(.packetBatch(Array(packets[1...]), disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 3
        }

        #expect(viewModel.snapshot.packetRows.map(\.id) == packets.map(\.id))
        #expect(viewModel.snapshot.packetTableRowStore.rowIDs == packets.map(\.id))
        #expect(viewModel.snapshot.packetTableUpdatePlan == .append(1..<3))
    }

    @Test func liveModelKeepsLargePacketNavigationAndSourceListShapeCompact() async {
        let liveSession = InspectorFakeLiveSession()
        let clientResolver = InspectorFakePacketClientResolver(defaultClient: nil)
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                ),
                packetMetadataEnricher: PacketMetadataEnrichmentService(clientResolver: clientResolver)
            ),
            userDefaults: isolatedDefaults()
        )
        var lastCheckpoint: UInt64 = 0

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))

        for checkpoint in [UInt64(10_000), 50_000, 100_000] {
            let batch = makeLivePacketBatch(from: lastCheckpoint + 1, through: checkpoint)
            liveSession.send(.packetBatch(batch, disposition: .append))

            await waitUntil(timeoutNanoseconds: 15_000_000_000) {
                viewModel.snapshot.totalPacketCount == Int(checkpoint) &&
                    viewModel.snapshot.visiblePacketCount == Int(checkpoint) &&
                    viewModel.snapshot.base.navigationState.visiblePacketIDs.count == Int(checkpoint)
            }

            #expect(viewModel.snapshot.packetRows.first?.id == 1)
            #expect(viewModel.snapshot.packetRows.last?.id == checkpoint)
            #expect(viewModel.snapshot.base.navigationState.visiblePacketIDs.first == 1)
            #expect(viewModel.snapshot.base.navigationState.visiblePacketIDs.last == checkpoint)
            #expect(viewModel.snapshot.sourceListSnapshot.item(for: .domains)?.count == Int(checkpoint))
            #expect(viewModel.snapshot.sourceListSnapshot.item(for: .domain(.ipAddresses))?.count == Int(checkpoint))
            #expect(viewModel.snapshot.sourceListSnapshot.item(for: .apps)?.count == 0)
            lastCheckpoint = checkpoint
        }

        let navigationLabels = Set(Mirror(reflecting: viewModel.snapshot.base.navigationState).children.compactMap(\.label))
        #expect(navigationLabels.contains("visiblePacketIDs"))
        #expect(!navigationLabels.contains("visiblePackets"))

        let selectedPacket = makePacket(packetNumber: 50_000, source: .live, transportHint: .tcp, streamID: nil)
        liveSession.inspections[selectedPacket.id] = makeInspection(for: selectedPacket)
        viewModel.selectPacket(selectedPacket.id)

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.snapshot.base.inspectionState.inspection?.packetID == selectedPacket.id
        }

        #expect(viewModel.snapshot.selectedPacket?.id == selectedPacket.id)
        #expect(viewModel.snapshot.selectedPacketRowIndex == 49_999)

        viewModel.updateDisplayFilterText("protocol:tcp")
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.snapshot.visiblePacketCount == 50_000
        }

        #expect(viewModel.snapshot.packetRows.count == 50_000)
        #expect(viewModel.snapshot.packetRows.first?.id == 2)
        #expect(viewModel.snapshot.packetRows.last?.id == 100_000)
        #expect(viewModel.snapshot.base.navigationState.visiblePacketIDs.count == 100_000)
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .domain(.ipAddresses))?.count == 100_000)

        viewModel.stopLiveCapture()
        liveSession.send(.liveStateChanged(phase: .stopped, message: "Live capture stopped."))
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.snapshot.base.sessionState.phase == .stopped
        }

        #if DEBUG
        let beforeClear = viewModel.debugMemorySnapshot()
        #expect(beforeClear.ingestPacketCount == 100_000)
        #expect(beforeClear.tableRowCount == 50_000)
        #expect(beforeClear.navigationVisibleIDCount == 100_000)
        #expect(beforeClear.sourceListDomainBucketCount == 1)
        #expect(beforeClear.metadata.flowCount > 0)

        viewModel.clearPackets()
        let afterClear = viewModel.debugMemorySnapshot()
        #expect(afterClear.ingestPacketCount == 0)
        #expect(afterClear.packetIndexCount == 0)
        #expect(afterClear.tableRowCount == 0)
        #expect(afterClear.tableVisiblePacketIndexCount == 0)
        #expect(afterClear.navigationVisibleIDCount == 0)
        #expect(afterClear.sourceListAppBucketCount == 0)
        #expect(afterClear.sourceListDomainBucketCount == 0)
        #expect(afterClear.metadata == .empty)
        #expect(afterClear.liveSession == nil)
        #endif
    }

    @Test func metadataEnrichmentBackfillsSNIAndCachesLiveClient() async {
        let client = makeClient()
        let clientResolver = InspectorFakePacketClientResolver(defaultClient: client)
        let liveSession = InspectorFakeLiveSession()
        let firstPacket = makePacket(
            packetNumber: 1,
            source: .live,
            transportHint: .tcp,
            destinationPort: 80,
            streamID: 99
        )
        let secondPacket = makePacket(
            packetNumber: 2,
            source: .live,
            transportHint: .tcp,
            destinationPort: 443,
            streamID: 99,
            sniDomainName: "api.example.com"
        )
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                ),
                packetMetadataEnricher: PacketMetadataEnrichmentService(clientResolver: clientResolver)
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        #expect(viewModel.snapshot.packetRows.first?.domainText == "-")
        #expect(viewModel.snapshot.packetRows.first?.clientText == "Example")

        liveSession.send(.packetBatch([secondPacket], disposition: .append))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 2 &&
                viewModel.snapshot.packetRows.first?.domainText == "api.example.com"
        }

        #expect(viewModel.snapshot.packetRows.map(\.domainText) == ["api.example.com", "api.example.com"])
        #expect(viewModel.snapshot.packetRows.map(\.clientText) == ["Example", "Example"])
        #expect(clientResolver.clientLookupCount == 1)
    }

    @Test func metadataUpdateAppliesInPlaceWhenVisibleRowCountDoesNotChange() async {
        let clientResolver = InspectorFakePacketClientResolver(defaultClient: makeClient())
        let liveSession = InspectorFakeLiveSession()
        let firstPacket = makePacket(
            packetNumber: 1,
            source: .live,
            transportHint: .tcp,
            destinationPort: 80,
            streamID: 42
        )
        let filteredPacket = makePacket(
            packetNumber: 2,
            source: .live,
            transportHint: .tcp,
            destinationPort: 443,
            streamID: 42,
            sniDomainName: "api.example.com"
        )
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                ),
                packetMetadataEnricher: PacketMetadataEnrichmentService(clientResolver: clientResolver)
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        viewModel.updateDisplayFilterText("port:80")
        let generationAfterFilter = viewModel.snapshot.packetTableGeneration
        liveSession.send(.packetBatch([filteredPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.visiblePacketCount == 1 &&
                viewModel.snapshot.packetRows.first?.domainText == "api.example.com"
        }

        #expect(viewModel.snapshot.totalPacketCount == 2)
        #expect(viewModel.snapshot.packetTableGeneration > generationAfterFilter)
        // Back-fill targets the first packet (still visible under the port:80 filter); the
        // newly-appended packet is filtered out, so the plan reduces to a row-targeted reload
        // instead of a full table rebuild.
        #expect(viewModel.snapshot.packetTableUpdatePlan == .reloadRows(IndexSet(integer: 0)))
    }

    @Test func metadataUpdateThatFlipsVisibilityFallsBackToFullReload() async {
        let chromeClient = makeClient(displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let clientResolver = InspectorFakePacketClientResolver(defaultClient: chromeClient)
        let liveSession = InspectorFakeLiveSession()
        let firstPacket = makePacket(
            packetNumber: 1,
            source: .live,
            transportHint: .tcp,
            destinationPort: 80,
            streamID: 99
        )
        // resolvingPacket carries the SNI for the same flow, which causes the enricher to back-fill
        // firstPacket's SNI. The free-text filter "matchme" matches via packet.sniDomainName, so
        // firstPacket flips from not-visible to visible after back-fill.
        let resolvingPacket = makePacket(
            packetNumber: 2,
            source: .live,
            transportHint: .tcp,
            destinationPort: 80,
            streamID: 99,
            sniDomainName: "matchme.example.com"
        )
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                ),
                packetMetadataEnricher: PacketMetadataEnrichmentService(clientResolver: clientResolver)
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        viewModel.updateDisplayFilterText("matchme")
        await waitUntil {
            viewModel.snapshot.visiblePacketCount == 0
        }
        let generationAfterFilter = viewModel.snapshot.packetTableGeneration
        liveSession.send(.packetBatch([resolvingPacket], disposition: .append))

        // Both packets become visible: resolvingPacket directly, firstPacket via SNI back-fill.
        await waitUntil {
            viewModel.snapshot.visiblePacketCount == 2
        }

        #expect(viewModel.snapshot.packetTableGeneration > generationAfterFilter)
        #expect(viewModel.snapshot.packetTableUpdatePlan == .reload)
    }

    @Test func appendMutationsReuseTheSameRowStoreInstance() async {
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                )
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        ], disposition: .append))
        await waitUntil { viewModel.snapshot.packetRows.count == 1 }

        let storeAfterFirstAppend = viewModel.snapshot.packetTableRowStore

        liveSession.send(.packetBatch([
            makePacket(packetNumber: 2, source: .live, transportHint: .tcp)
        ], disposition: .append))
        await waitUntil { viewModel.snapshot.packetRows.count == 2 }

        // Append-only batches keep the same store instance, so the rows array stays uniquely
        // owned by the class and Swift's CoW doesn't fire on the next mutation.
        #expect(viewModel.snapshot.packetTableRowStore === storeAfterFirstAppend)
        #expect(viewModel.snapshot.packetRows.count == 2)
        #expect(viewModel.snapshot.packetTableRowStore.rowIDs == viewModel.snapshot.packetRows.map(\.id))
    }

    @Test func rebuildAllocatesAFreshRowStoreInstance() async {
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                )
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp, destinationPort: 80),
            makePacket(packetNumber: 2, source: .live, transportHint: .tcp, destinationPort: 443),
        ], disposition: .append))
        await waitUntil { viewModel.snapshot.packetRows.count == 2 }

        let storeBeforeFilterChange = viewModel.snapshot.packetTableRowStore

        // A filter change forces a full rebuild → a fresh store, leaving the old store untouched
        // for any code still holding the previous snapshot.
        viewModel.updateDisplayFilterText("port:80")

        #expect(viewModel.snapshot.packetTableRowStore !== storeBeforeFilterChange)
        #expect(storeBeforeFilterChange.rows.count == 2)
        #expect(viewModel.snapshot.packetRows.count == 1)
    }

    @Test func liveIngestEventsCoalesceIntoTrailingEdgeRebuild() async {
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                )
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))

        // Three back-to-back batches should leave exactly one pending coalesced rebuild work item.
        let first = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let second = makePacket(packetNumber: 2, source: .live, transportHint: .tcp)
        let third = makePacket(packetNumber: 3, source: .live, transportHint: .tcp)
        liveSession.send(.packetBatch([first], disposition: .append))
        liveSession.send(.packetBatch([second], disposition: .append))
        liveSession.send(.packetBatch([third], disposition: .append))

        await waitUntil {
            viewModel.hasPendingCoalescedRebuildForTesting
        }
        #expect(viewModel.snapshot.packetRows.count < 3)

        viewModel.flushPendingCoalescedRebuildForTesting()
        #expect(viewModel.snapshot.packetRows.count == 3)
        #expect(viewModel.hasPendingCoalescedRebuildForTesting == false)
    }

    @Test func userDrivenFilterChangeFlushesPendingCoalescedRebuild() async {
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                )
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        ], disposition: .append))

        await waitUntil {
            viewModel.hasPendingCoalescedRebuildForTesting
        }

        // A user-driven filter change must cancel the pending tick and rebuild synchronously, so
        // the user sees the result immediately rather than 80 ms later.
        viewModel.updateDisplayFilterText("port:9999")

        #expect(viewModel.hasPendingCoalescedRebuildForTesting == false)
        #expect(viewModel.snapshot.displayFilterText == "port:9999")
        #expect(viewModel.snapshot.visiblePacketCount == 0)
    }

    @Test func metadataEnrichmentDoesNotResolveClientsForOfflinePackets() {
        let clientResolver = InspectorFakePacketClientResolver(defaultClient: makeClient())
        let service = PacketMetadataEnrichmentService(clientResolver: clientResolver)
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)

        let result = service.enrich([packet], source: .offline)

        #expect(result.packets.first?.client == nil)
        #expect(clientResolver.clientLookupCount == 0)
    }

    @Test func macOSPacketClientResolverCachesProcessAndBundleIdentityForRepeatedPIDPath() {
        var processNameLookupCount = 0
        var processPathLookupCount = 0
        var bundleIdentityLookupCount = 0
        let executablePath = "/Applications/Example.app/Contents/MacOS/Example"
        let environment = MacOSProcessClientResolverEnvironment(
            processName: { pid in
                processNameLookupCount += 1
                return "Process \(pid)"
            },
            processPath: { _ in
                processPathLookupCount += 1
                return executablePath
            },
            bundleIdentity: { _ in
                bundleIdentityLookupCount += 1
                return MacOSBundleIdentity(
                    displayName: "Example",
                    bundleIdentifier: "com.example.app"
                )
            }
        )
        let resolver = MacOSPacketClientResolver(
            snapshotTTL: 0,
            maxProcessIdentityCacheEntries: 4,
            maxBundleIdentityCacheEntries: 4,
            environment: environment
        )

        let first = resolver.client(for: 123)
        let second = resolver.client(for: 123)

        #expect(first?.displayName == "Example")
        #expect(second?.bundleIdentifier == "com.example.app")
        #expect(processNameLookupCount == 1)
        #expect(processPathLookupCount == 2)
        #expect(bundleIdentityLookupCount == 1)
        #if DEBUG
        #expect(resolver.debugMemorySnapshot().processIdentityCacheCount == 1)
        #expect(resolver.debugMemorySnapshot().bundleIdentityCacheCount == 1)
        resolver.reset()
        #expect(resolver.debugMemorySnapshot() == .empty)
        #endif
    }

    @Test func metadataEnrichmentExpiresIdleFlowBeforeReusingStreamID() {
        let service = PacketMetadataEnrichmentService(
            flowIdleTimeout: 1,
            clientResolver: InspectorFakePacketClientResolver(defaultClient: nil)
        )
        let originalPacket = makePacket(
            packetNumber: 1,
            source: .offline,
            transportHint: .tcp,
            streamID: 77,
            sniDomainName: "old.example.com"
        )
        let reusedStreamPacket = makePacket(
            packetNumber: 3,
            source: .offline,
            transportHint: .tcp,
            streamID: 77
        )

        _ = service.enrich([originalPacket], source: .offline)
        let result = service.enrich([reusedStreamPacket], source: .offline)

        #expect(result.packets.first?.sniDomainName == nil)
        #expect(result.updates.isEmpty)
    }

    @Test func metadataEnrichmentClearsFlowAfterTCPTeardown() {
        let service = PacketMetadataEnrichmentService(clientResolver: InspectorFakePacketClientResolver(defaultClient: nil))
        let originalPacket = makePacket(
            packetNumber: 1,
            source: .offline,
            transportHint: .tcp,
            streamID: 88,
            sniDomainName: "closed.example.com"
        )
        let finishPacket = makePacket(
            packetNumber: 2,
            source: .offline,
            transportHint: .tcp,
            streamID: 88,
            transportDetailSummary: "TCP flags: FIN"
        )
        let reusedStreamPacket = makePacket(
            packetNumber: 3,
            source: .offline,
            transportHint: .tcp,
            streamID: 88
        )

        _ = service.enrich([originalPacket], source: .offline)
        _ = service.enrich([finishPacket], source: .offline)
        let result = service.enrich([reusedStreamPacket], source: .offline)

        #expect(result.packets.first?.sniDomainName == nil)
        #expect(result.updates.isEmpty)
    }

    @Test func metadataEnrichmentCapsPendingBackfillPacketIDs() {
        let service = PacketMetadataEnrichmentService(
            maxPendingPacketIDsPerFlow: 2,
            clientResolver: InspectorFakePacketClientResolver(defaultClient: nil)
        )
        let firstPacket = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: 55)
        let secondPacket = makePacket(packetNumber: 2, source: .offline, transportHint: .tcp, streamID: 55)
        let thirdPacket = makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, streamID: 55)
        let sniPacket = makePacket(
            packetNumber: 4,
            source: .offline,
            transportHint: .tcp,
            streamID: 55,
            sniDomainName: "late.example.com"
        )

        _ = service.enrich([firstPacket, secondPacket, thirdPacket], source: .offline)
        let result = service.enrich([sniPacket], source: .offline)

        #expect(result.packets.first?.sniDomainName == "late.example.com")
        #expect(result.updates.map(\.packetIDs) == [[secondPacket.id, thirdPacket.id]])
    }

    @Test func packetRowsSkipTableUpdateWhenLiveAppendDoesNotMatchFilter() async {
        let firstPacket = makePacket(packetNumber: 1, source: .live, transportHint: .udp)
        let filteredPacket = makePacket(packetNumber: 2, source: .live, transportHint: .tcp)
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: InspectorFakeCore(
                    interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                    liveSession: liveSession
                ),
                packetMetadataEnricher: PacketMetadataEnrichmentService(
                    clientResolver: InspectorFakePacketClientResolver(defaultClient: nil)
                )
            ),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        let generationBeforeFilter = viewModel.snapshot.packetTableGeneration
        viewModel.updateDisplayFilterText("protocol:udp")
        await waitUntil {
            viewModel.snapshot.displayFilterText == "protocol:udp" &&
                viewModel.snapshot.packetTableGeneration > generationBeforeFilter
        }
        liveSession.send(.packetBatch([filteredPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.totalPacketCount == 2
        }

        #expect(viewModel.snapshot.visiblePacketCount == 1)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [firstPacket.id])
        #expect(viewModel.snapshot.packetTableUpdatePlan == .none)
    }

    @Test func packetRowsRefreshWhenOfflinePacketsReuseIDs() async {
        let openURL = URL(fileURLWithPath: "/tmp/reused-ids.pcapng")
        let firstPacket = makePacket(
            packetNumber: 1,
            source: .offline,
            transportHint: .udp,
            destinationPort: 500
        )
        let replacementPacket = makePacket(
            packetNumber: 1,
            source: .offline,
            transportHint: .tcp,
            destinationPort: 443
        )
        let document = InspectorFakeDocument(url: openURL, packets: [firstPacket])
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: document
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.packetRows.first?.protocolText == "UDP"
        }

        let firstGeneration = viewModel.snapshot.packetTableGeneration
        document.replacePackets([replacementPacket])

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.packetRows.first?.protocolText == "TCP"
        }

        #expect(viewModel.snapshot.packetRows.map(\.id) == [firstPacket.id])
        #expect(viewModel.snapshot.packetRows.first?.destinationText == "10.0.0.2:443")
        #expect(viewModel.snapshot.packetTableGeneration > firstGeneration)
        #expect(viewModel.snapshot.packetTableUpdatePlan == .reload)
    }

    @Test func sourceListAppAndDomainSelectionsFilterPacketRows() async {
        let chrome = makeClient(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")
        let tcpviewer = makeClient(displayName: "TCP Viewer", bundleIdentifier: "com.proxyman.tcpviewer")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "openai.com", client: chrome),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: nil, client: tcpviewer),
            makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.github.com", client: nil),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/source-list-selection.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 3
        }

        viewModel.selectSourceList(selection(titled: "Chrome", under: .apps, in: viewModel.snapshot))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])

        viewModel.selectSourceList(selection(titled: "IP Addresses", under: .domains, in: viewModel.snapshot))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id])

        viewModel.selectSourceList(selection(titled: "api.github.com", under: .domains, in: viewModel.snapshot))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[2].id])
    }

    @Test func sourceListAppChildSelectionsFilterPacketRowsByParentAndChild() async throws {
        let chrome = makeClient(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")
        let tcpviewer = makeClient(displayName: "TCP Viewer", bundleIdentifier: "com.proxyman.tcpviewer")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com", client: chrome),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "openai.com", client: chrome),
            makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com", client: tcpviewer),
            makePacket(packetNumber: 4, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: nil, client: chrome, sourceAddress: "10.0.0.3", destinationAddress: "10.0.0.4"),
            makePacket(packetNumber: 5, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: nil, client: tcpviewer, sourceAddress: "10.0.0.5", destinationAddress: "10.0.0.4"),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/source-list-app-child-selection.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        let chromeKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.google.Chrome")
        let apiKey = domainKey("api.example.com")
        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.4")
        _ = try #require(viewModel.snapshot.sourceListSnapshot.item(for: .appDomain(chromeKey, apiKey)))
        _ = try #require(viewModel.snapshot.sourceListSnapshot.item(for: .appIPAddress(chromeKey, ipKey)))

        viewModel.selectSourceList(.appDomain(chromeKey, apiKey))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])

        viewModel.selectSourceList(.appIPAddress(chromeKey, ipKey))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[3].id])
    }

    @Test func sourceListParentAndFavoriteSelectionsUseExpectedPacketSets() async {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "example.com", client: client),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "api.example.com", client: nil),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/source-list-parent-selection.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 2
        }

        viewModel.selectSourceList(.apps)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])

        viewModel.selectSourceList(.domains)
        #expect(viewModel.snapshot.packetRows.map(\.id) == packets.map(\.id))

        viewModel.selectSourceList(.pinned)
        #expect(viewModel.snapshot.packetRows.isEmpty)

        viewModel.selectSourceList(.saved)
        #expect(viewModel.snapshot.packetRows.isEmpty)
    }

    @Test func sourceListFilterOnlyNarrowsSidebarAndDisplayFilterStillCombinesWithSelection() async {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "example.com", client: client),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "example.com", client: client),
            makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com", client: nil),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/source-list-filter.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 3
        }

        viewModel.updateSourceListFilterText("does-not-match-packets")
        #expect(viewModel.snapshot.packetRows.map(\.id) == packets.map(\.id))

        viewModel.selectSourceList(.apps)
        viewModel.updateDisplayFilterText("protocol:udp")
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id])
    }

    @Test func sessionExportUsesAllActivePacketsIgnoringSelectionAndFilter() async {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "example.com", client: client),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "example.com", client: client),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns, streamID: nil, sniDomainName: "api.example.com", client: nil),
        ]
        let document = InspectorFakeDocument(url: URL(fileURLWithPath: "/tmp/export-source.pcapng"), packets: packets)
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: document
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.openDocument(at: document.currentURL())
        await waitUntil {
            viewModel.snapshot.packetRows.count == 3
        }

        viewModel.selectSourceList(.apps)
        viewModel.updateDisplayFilterText("protocol:udp")
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id])

        let result = await viewModel.exportSession(to: URL(fileURLWithPath: "/tmp/session-export.pcapng"), format: .pcapng)

        guard case .success = result else {
            Issue.record("Expected session export to succeed.")
            return
        }
        #expect(document.exportRequests.count == 1)
        #expect(document.exportRequests.first?.0 == packets.map(\.id))
        #expect(document.exportRequests.first?.2 == .pcapng)
    }

    @Test func clearTablePacketsRemovesOnlyVisibleRows() async {
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/clear-table-filter.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.updateDisplayFilterText("protocol:udp")
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id])

        viewModel.clearTablePackets()

        #expect(viewModel.snapshot.totalPacketCount == 2)
        #expect(viewModel.snapshot.base.packetIngestState.packets.map(\.id) == [packets[0].id, packets[2].id])
        #expect(viewModel.snapshot.packetRows.isEmpty)

        viewModel.clearDisplayFilter()
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[2].id])
    }

    @Test func savedExportRequiresCurrentRawBacking() async throws {
        let directory = temporaryDirectory()
        let savedURL = directory.appendingPathComponent("Saved.json")
        let savedService = SavedPacketService(storageURL: savedURL)
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil)
        let document = InspectorFakeDocument(url: URL(fileURLWithPath: "/tmp/current-backed.pcapng"), packets: [packet])
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: document
            )),
            userDefaults: isolatedDefaults(),
            savedPacketService: savedService
        )

        await viewModel.openDocument(at: document.currentURL())
        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        viewModel.savePackets([packet.id])
        let savedBackingIdentity = savedService.records().first?.backingIdentity
        #expect(savedBackingIdentity != nil)

        let success = await viewModel.exportSourceList(.saved, to: URL(fileURLWithPath: "/tmp/saved-current.pcap"), format: .pcap)
        guard case .success = success else {
            Issue.record("Expected current-backed saved export to succeed.")
            return
        }
        #expect(document.exportRequests.first?.0 == [packet.id])
        #expect(document.exportRequests.first?.2 == .pcap)

        let staleSavedURL = directory.appendingPathComponent("StaleSaved.json")
        let staleSavedService = SavedPacketService(storageURL: staleSavedURL)
        try staleSavedService.save([packet], backingIdentity: "old-backing")
        let staleDocument = InspectorFakeDocument(url: URL(fileURLWithPath: "/tmp/stale-backing.pcapng"), packets: [packet])
        let reloaded = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: staleDocument
            )),
            userDefaults: isolatedDefaults(),
            savedPacketService: staleSavedService
        )

        await reloaded.openDocument(at: staleDocument.currentURL())
        await waitUntil {
            reloaded.snapshot.packetRows.count == 1
        }

        let failure = await reloaded.exportSourceList(.saved, to: URL(fileURLWithPath: "/tmp/saved-old.pcapng"), format: .pcapng)
        guard case .failure(let error as TCPViewerCoreError) = failure else {
            Issue.record("Expected saved export without current backing to fail.")
            return
        }
        #expect(error.code == .offlineFileSaveFailed)
        #expect(staleDocument.exportRequests.isEmpty)
    }

    @Test func pinnedAndSavedSelectionsFilterRowsAndReloadFromDisk() async throws {
        let directory = temporaryDirectory()
        let pinURL = directory.appendingPathComponent("Pins.json")
        let savedURL = directory.appendingPathComponent("Saved.json")
        let pinService = PacketPinService(storageURL: pinURL)
        let savedService = SavedPacketService(storageURL: savedURL)
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com"),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "openai.com"),
        ]
        let openURL = URL(fileURLWithPath: "/tmp/pinned-saved-fixture.pcapng")
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: InspectorFakeDocument(url: openURL, packets: packets)
            )),
            userDefaults: isolatedDefaults(),
            pinService: pinService,
            savedPacketService: savedService
        )

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.packetRows.count == 2
        }

        viewModel.pinPacket(packets[0].id, kind: .domain, clickedColumn: .domain)
        let pinID = try #require(pinService.pins().first?.id)
        #expect(viewModel.snapshot.selectedSourceListSelection == .pinnedItem(pinID))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .pinned)?.count == 1)

        viewModel.savePackets([packets[1].id])
        viewModel.selectSourceList(.saved)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id])
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .saved)?.count == 1)

        let reloadedPinService = PacketPinService(storageURL: pinURL)
        let reloadedSavedService = SavedPacketService(storageURL: savedURL)
        let reloaded = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")]
            )),
            userDefaults: isolatedDefaults(),
            pinService: reloadedPinService,
            savedPacketService: reloadedSavedService
        )

        #expect(reloaded.snapshot.sourceListSnapshot.item(for: .pinnedItem(pinID))?.count == 0)
        reloaded.selectSourceList(.saved)
        #expect(reloaded.snapshot.packetRows.map(\.id) == [packets[1].id])

        reloaded.deletePackets([packets[1].id])
        #expect(reloaded.snapshot.packetRows.isEmpty)
        #expect(reloadedSavedService.records().isEmpty)
    }

    @Test func bulkAppPinningPinsUniqueAppsAndSelectsPinnedFolder() async throws {
        let pinService = PacketPinService(storageURL: temporaryDirectory().appendingPathComponent("Pins.json"))
        let chrome = makeClient(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")
        let tcpviewer = makeClient(displayName: "TCP Viewer", bundleIdentifier: "com.proxyman.tcpviewer")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, client: chrome),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, client: tcpviewer),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns, streamID: nil),
            makePacket(packetNumber: 4, source: .offline, transportHint: .tcp, streamID: nil, client: chrome),
        ]
        let openURL = URL(fileURLWithPath: "/tmp/bulk-app-pin-fixture.pcapng")
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: InspectorFakeDocument(url: openURL, packets: packets)
            )),
            userDefaults: isolatedDefaults(),
            pinService: pinService
        )

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.pinAppPackets(packets.map(\.id))

        #expect(pinService.pins().map(\.id.rawValue) == [
            "client:bundleIdentifier:com.google.Chrome",
            "client:bundleIdentifier:com.proxyman.tcpviewer",
        ])
        #expect(viewModel.snapshot.selectedSourceListSelection == .pinned)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[1].id, packets[3].id])
    }

    @Test func sourceListPinTargetsCreateAppAndDomainPins() async throws {
        let pinService = PacketPinService(storageURL: temporaryDirectory().appendingPathComponent("Pins.json"))
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, client: client),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "api.example.com"),
        ]
        let openURL = URL(fileURLWithPath: "/tmp/source-list-pin-fixture.pcapng")
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: InspectorFakeDocument(url: openURL, packets: packets)
            )),
            userDefaults: isolatedDefaults(),
            pinService: pinService
        )

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        let appItem = try #require(viewModel.snapshot.sourceListSnapshot.item(for: .app(PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.app"))))
        let domainItem = try #require(viewModel.snapshot.sourceListSnapshot.item(for: .domain(PacketSourceDomainKey(rawValue: "api.example.com", isMissingDomain: false))))
        let targets = PacketSourceListPinPolicy.targets(for: [appItem, domainItem])
        viewModel.pinSourceListItems(targets)

        #expect(pinService.pins().map(\.id.rawValue) == [
            "client:bundleIdentifier:com.example.app",
            "domain:api.example.com",
        ])
        #expect(viewModel.snapshot.selectedSourceListSelection == .pinned)
        #expect(viewModel.snapshot.packetRows.map(\.id) == packets.map(\.id))
    }

    @Test func pinnedAppSelectionAppendsFutureMatchingPackets() async throws {
        let pinService = PacketPinService(storageURL: temporaryDirectory().appendingPathComponent("Pins.json"))
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let first = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, streamID: nil, client: client)
        let matchingFuture = makePacket(packetNumber: 2, source: .live, transportHint: .udp, streamID: nil, client: client)
        let unrelatedFuture = makePacket(packetNumber: 3, source: .live, transportHint: .dns, streamID: nil)
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            ), packetMetadataEnricher: PacketMetadataEnrichmentService(
                clientResolver: InspectorFakePacketClientResolver(defaultClient: nil)
            )),
            userDefaults: isolatedDefaults(),
            pinService: pinService
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([first], disposition: .append))
        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [first.id]
        }

        viewModel.pinAppPackets([first.id])
        let pinID = try #require(pinService.pins().first?.id)
        #expect(viewModel.snapshot.selectedSourceListSelection == .pinnedItem(pinID))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [first.id])

        liveSession.send(.packetBatch([matchingFuture, unrelatedFuture], disposition: .append))
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.hasPendingCoalescedRebuildForTesting || viewModel.snapshot.totalPacketCount == 3
        }
        viewModel.flushPendingCoalescedRebuildForTesting()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.snapshot.packetRows.map(\.id) == [first.id, matchingFuture.id]
        }

        #expect(viewModel.snapshot.packetRows.map(\.id) == [first.id, matchingFuture.id])
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .pinnedItem(pinID))?.count == 2)
    }

    @Test func pinnedClientChildSelectionsFilterPacketRowsByPinnedClientAndChild() async throws {
        let pinService = PacketPinService(storageURL: temporaryDirectory().appendingPathComponent("Pins.json"))
        let chrome = makeClient(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")
        let tcpviewer = makeClient(displayName: "TCP Viewer", bundleIdentifier: "com.proxyman.tcpviewer")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com", client: chrome),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "openai.com", client: chrome),
            makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com", client: tcpviewer),
            makePacket(packetNumber: 4, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: nil, client: chrome, sourceAddress: "10.0.0.3", destinationAddress: "10.0.0.4"),
        ]
        let openURL = URL(fileURLWithPath: "/tmp/pinned-client-child-filter.pcapng")
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: InspectorFakeDocument(url: openURL, packets: packets)
            )),
            userDefaults: isolatedDefaults(),
            pinService: pinService
        )

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.pinAppPackets([packets[0].id])
        let pinID = try #require(pinService.pins().first?.id)
        let apiKey = domainKey("api.example.com")
        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.4")
        _ = try #require(viewModel.snapshot.sourceListSnapshot.item(for: .pinnedItemDomain(pinID, apiKey)))
        _ = try #require(viewModel.snapshot.sourceListSnapshot.item(for: .pinnedItemIPAddress(pinID, ipKey)))

        viewModel.selectSourceList(.pinnedItemDomain(pinID, apiKey))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])

        viewModel.selectSourceList(.pinnedItemIPAddress(pinID, ipKey))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[3].id])
    }

    @Test func appChildSelectionAppendsFutureMatchingPackets() async {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let first = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com", client: client)
        let matchingFuture = makePacket(packetNumber: 2, source: .live, transportHint: .udp, streamID: nil, sniDomainName: "api.example.com", client: client)
        let differentDomainFuture = makePacket(packetNumber: 3, source: .live, transportHint: .tcp, streamID: nil, sniDomainName: "openai.com", client: client)
        let unrelatedClientFuture = makePacket(
            packetNumber: 4,
            source: .live,
            transportHint: .tcp,
            streamID: nil,
            sniDomainName: "api.example.com",
            client: makeClient(displayName: "Other", bundleIdentifier: "com.example.other")
        )
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            ), packetMetadataEnricher: PacketMetadataEnrichmentService(
                clientResolver: InspectorFakePacketClientResolver(defaultClient: nil)
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([first], disposition: .append))
        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [first.id]
        }

        let appKey = PacketSourceClientKey(rawValue: "bundleIdentifier:com.example.app")
        let apiKey = domainKey("api.example.com")
        viewModel.selectSourceList(.appDomain(appKey, apiKey))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [first.id])

        liveSession.send(.packetBatch([matchingFuture, differentDomainFuture, unrelatedClientFuture], disposition: .append))
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.hasPendingCoalescedRebuildForTesting || viewModel.snapshot.totalPacketCount == 4
        }
        viewModel.flushPendingCoalescedRebuildForTesting()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            viewModel.snapshot.packetRows.map(\.id) == [first.id, matchingFuture.id]
        }

        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .appDomain(appKey, apiKey))?.count == 2)
    }

    @Test func sourceListDeleteActionRemovesPinsAndMatchingPackets() async throws {
        let pinURL = temporaryDirectory().appendingPathComponent("Pins.json")
        let pinService = PacketPinService(storageURL: pinURL)
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, sniDomainName: "api.example.com", client: client),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tcp, sniDomainName: "api.example.com"),
            makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, sniDomainName: nil),
        ]
        let openURL = URL(fileURLWithPath: "/tmp/source-list-delete-fixture.pcapng")
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: InspectorFakeDocument(url: openURL, packets: packets)
            )),
            userDefaults: isolatedDefaults(),
            pinService: pinService
        )

        await viewModel.openDocument(at: openURL)
        await waitUntil {
            viewModel.snapshot.packetRows.count == 3
        }

        viewModel.pinPacket(packets[0].id, kind: .domain, clickedColumn: .domain)
        let pinID = try #require(pinService.pins().first?.id)
        viewModel.deleteSourceListItem(.deletePin(pinID))

        #expect(pinService.pins().isEmpty)
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .pinnedItem(pinID)) == nil)
        #expect(viewModel.snapshot.selectedSourceListSelection == .pinned)

        let appKey = try #require(PacketSourceListClassifier.clientIdentity(for: packets[0])?.key)
        viewModel.selectSourceList(.app(appKey))
        viewModel.deleteSourceListItem(.deletePackets(.app(appKey)))

        #expect(viewModel.snapshot.selectedSourceListSelection == .allPackets)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id, packets[2].id])
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .app(appKey)) == nil)

        let ipKey = PacketSourceIPAddressKey(rawValue: "10.0.0.2")
        viewModel.selectSourceList(.ipAddress(ipKey))
        viewModel.deleteSourceListItem(.deletePackets(.ipAddress(ipKey)))

        #expect(viewModel.snapshot.selectedSourceListSelection == .allPackets)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id])
        #expect(viewModel.snapshot.sourceListSnapshot.item(for: .ipAddress(ipKey)) == nil)
    }

    @Test func deletingRowsSelectsRowAfterLastDeletedVisibleIndex() async {
        let packets = (1...5).map {
            makePacket(packetNumber: UInt64($0), source: .offline, transportHint: .tcp)
        }
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/delete-next-selection.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.selectPacket(packets[1].id)
        viewModel.deletePackets([packets[1].id, packets[2].id])

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[3].id, packets[4].id])
        #expect(viewModel.snapshot.selectedPacket?.id == packets[3].id)
        #expect(viewModel.snapshot.selectedPacketRowIndex == 1)
    }

    @Test func deletingLastRowsSelectsPreviousRemainingRow() async {
        let packets = (1...5).map {
            makePacket(packetNumber: UInt64($0), source: .offline, transportHint: .tcp)
        }
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/delete-end-selection.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.selectPacket(packets[3].id)
        viewModel.deletePackets([packets[3].id, packets[4].id])

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[1].id, packets[2].id])
        #expect(viewModel.snapshot.selectedPacket?.id == packets[2].id)
        #expect(viewModel.snapshot.selectedPacketRowIndex == 2)
    }

    @Test func quickFiltersCombineWithDisplayFilterAndSourceListSelection() async {
        let client = makeClient(displayName: "Example", bundleIdentifier: "com.example.app")
        let packets = [
            makePacket(
                packetNumber: 1,
                source: .offline,
                transportHint: .http1,
                destinationPort: 80,
                streamID: nil,
                client: client,
                layerNames: ["Ethernet", "TCP", "HTTP Request"]
            ),
            makePacket(
                packetNumber: 2,
                source: .offline,
                transportHint: .udp,
                destinationPort: 53,
                streamID: nil,
                client: client,
                layerNames: ["Ethernet", "UDP", "DNS"]
            ),
            makePacket(
                packetNumber: 3,
                source: .offline,
                transportHint: .tcp,
                destinationPort: 443,
                streamID: nil,
                layerNames: ["Ethernet", "TCP"]
            ),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/quick-filter-combined.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 3
        }

        viewModel.selectSourceList(.apps)
        viewModel.toggleQuickFilter(.tcp)
        viewModel.updateDisplayFilterText("port:80")

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])

        viewModel.toggleQuickFilter(.udp)
        viewModel.clearDisplayFilter()

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[1].id])
        #expect(viewModel.snapshot.quickFilterSelection.selectedIDs == [.tcp, .udp])

        viewModel.resetQuickFilters()

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[1].id])
        #expect(viewModel.snapshot.quickFilterSelection.selectedIDs == [.all])
    }

    @Test func quickFilterResetRestoresAllRowsWhenOnlyQuickFiltersAreActive() async {
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, layerNames: ["Ethernet", "TCP"]),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, layerNames: ["Ethernet", "UDP"]),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns, streamID: nil, layerNames: ["Ethernet", "UDP", "DNS"]),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/quick-filter-reset.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 3
        }

        viewModel.toggleQuickFilter(.tcp)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])
        #expect(viewModel.snapshot.selectedPacket?.id == packets[0].id)
        #expect(viewModel.snapshot.selectedPacketRowIndex == 0)

        viewModel.resetQuickFilters()
        #expect(viewModel.snapshot.packetRows.map(\.id) == packets.map(\.id))
        #expect(viewModel.snapshot.selectedPacketID == nil)
        #expect(viewModel.snapshot.selectedPacket == nil)
        #expect(viewModel.snapshot.selectedPacketRowIndex == nil)
        #expect(viewModel.snapshot.base.inspectionState == .empty)
    }

    @Test func quickFilterSelectsFirstVisiblePacketAndLoadsInspector() async {
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp, streamID: nil, layerNames: ["Ethernet", "UDP"]),
            makePacket(packetNumber: 2, source: .offline, transportHint: .tcp, streamID: nil, layerNames: ["Ethernet", "TCP"]),
            makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, streamID: nil, layerNames: ["Ethernet", "TCP"]),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/quick-filter-select-first.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.toggleQuickFilter(.tcp)

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id, packets[2].id])
        #expect(viewModel.snapshot.selectedPacket?.id == packets[1].id)
        #expect(viewModel.snapshot.selectedPacketRowIndex == 0)
        #expect(viewModel.snapshot.base.inspectionState.selectedPacketID == packets[1].id)

        await waitUntil {
            viewModel.snapshot.base.inspectionState.inspection?.packetID == packets[1].id
        }
    }

    @Test func quickFilterLiveAppendOnlyShowsMatchingPackets() async {
        let tcpPacket = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, streamID: nil, layerNames: ["Ethernet", "TCP"])
        let udpPacket = makePacket(packetNumber: 2, source: .live, transportHint: .udp, streamID: nil, layerNames: ["Ethernet", "UDP"])
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        viewModel.toggleQuickFilter(.udp)
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([tcpPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.totalPacketCount == 1
        }
        #expect(viewModel.snapshot.packetRows.isEmpty)

        liveSession.send(.packetBatch([udpPacket], disposition: .append))
        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [udpPacket.id]
        }

        #expect(viewModel.snapshot.visiblePacketCount == 1)
    }

    @Test func quickFilterMetadataUpdateCanRevealClientHelloPacket() async {
        let packet = makePacket(
            packetNumber: 1,
            source: .live,
            transportHint: .tls,
            streamID: nil,
            infoSummary: "Application Data",
            layerNames: ["Ethernet", "TCP", "TLSv1.2"]
        )
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        viewModel.toggleQuickFilter(.clientHello)
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([packet], disposition: .append))

        await waitUntil {
            viewModel.snapshot.totalPacketCount == 1
        }
        #expect(viewModel.snapshot.packetRows.isEmpty)

        liveSession.send(.packetSummaryUpdates([
            PacketSummaryUpdate(packetID: packet.id, protocolSummary: "TLSv1.3", infoSummary: "Client Hello")
        ]))

        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [packet.id]
        }
    }

    @Test func quickFilterSnapshotExposesInspectorEmptyStateResetData() async {
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, layerNames: ["Ethernet", "TCP"])
        let viewModel = makeOfflineViewModel(packets: [packet])

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/quick-filter-empty-state.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        viewModel.toggleQuickFilter(.udp)

        #expect(viewModel.snapshot.packetRows.isEmpty)
        #expect(viewModel.snapshot.selectedPacketRowIndex == nil)
        #expect(viewModel.snapshot.quickFilterAppliedDescription == "Filtered by UDP")
        #expect(viewModel.snapshot.isQuickFilterResetVisible)

        viewModel.resetQuickFilters()
        #expect(viewModel.snapshot.quickFilterAppliedDescription == nil)
        #expect(!viewModel.snapshot.isQuickFilterResetVisible)
    }

    @Test func workspaceEmptyStateIncludesSelectedCustomFilterLabels() async throws {
        let packet = makePacket(
            packetNumber: 1,
            source: .offline,
            transportHint: .tls,
            streamID: nil,
            infoSummary: "TLS Client Hello",
            layerNames: ["Ethernet", "TCP", "TLSv1.3"]
        )
        let customFilterService = PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json"))
        let group = PacketStructuredFilterGroup(
            filters: [PacketStructuredFilter(query: .summary, condition: .contains, text: "abc")],
            operator: .and
        )
        let savedFilter = try customFilterService.save(name: "abc", group: group)
        let viewModel = makeOfflineViewModel(packets: [packet], customFilterService: customFilterService)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/custom-filter-empty-state.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        viewModel.applyCustomFilter(id: savedFilter.id)
        viewModel.toggleQuickFilter(.clientHello)

        let workspaceViewModel = PacketWorkspaceViewModel()
        workspaceViewModel.render(snapshot: viewModel.snapshot)

        #expect(viewModel.snapshot.packetRows.isEmpty)
        #expect(viewModel.snapshot.activeFilterBarLabels == ["Client Hello", "abc"])
        #expect(workspaceViewModel.emptyTitle == "No Matching Packets")
        #expect(workspaceViewModel.activeFilterLabels == ["Client Hello", "abc"])
        #expect(workspaceViewModel.showsResetFiltersButton)
    }

    @Test func structuredFiltersPersistAndRestoreThroughViewModel() {
        let defaults = isolatedDefaults()
        let group = PacketStructuredFilterGroup(
            filters: [
                PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp"),
                PacketStructuredFilter(query: .length, condition: .greaterThanOrEqual, text: "128"),
            ],
            operator: .and
        )
        let firstViewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(interfaces: [])),
            userDefaults: defaults
        )

        firstViewModel.updateStructuredFilterGroup(group)

        let restoredViewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(interfaces: [])),
            userDefaults: defaults
        )
        #expect(restoredViewModel.snapshot.structuredFilterGroup == group)
    }

    @Test func structuredFiltersComposeWithPacketRowsUsingAndOr() async {
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: "api.example.com"),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, sniDomainName: "openai.com"),
            makePacket(packetNumber: 3, source: .offline, transportHint: .tcp, streamID: nil, sniDomainName: nil),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/structured-filter-and-or.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.setStructuredFilterVisible(true)
        let filters = [
            PacketStructuredFilter(query: .urlDomain, condition: .contains, text: "example.com"),
            PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp"),
        ]
        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: filters, operator: .and))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])

        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: filters, operator: .or))
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[2].id])
    }

    @Test func asyncStructuredFilteringShowsLoaderKeepsRowsAndAppliesLatestFilter() async {
        let packets = (1...600).map { index in
            let isTCP = index.isMultiple(of: 2)
            return makePacket(
                packetNumber: UInt64(index),
                source: .offline,
                transportHint: isTCP ? .tcp : .udp,
                destinationPort: isTCP ? 443 : 53,
                streamID: nil
            )
        }
        let udpIDs = packets.filter { $0.transportHint == .udp }.map(\.id)
        let viewModel = makeOfflineViewModel(packets: packets, packetTableAsyncRebuildThreshold: 1)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/async-structured-filter.pcapng"))
        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !viewModel.snapshot.isPacketTableFiltering &&
                viewModel.snapshot.packetRows.count == packets.count
        }

        let unfilteredIDs = viewModel.snapshot.packetRows.map(\.id)
        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp")
        ]))
        viewModel.setStructuredFilterVisible(true)

        #expect(viewModel.snapshot.isPacketTableFiltering)
        #expect(viewModel.snapshot.packetRows.map(\.id) == unfilteredIDs)

        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .protocol, condition: .contains, text: "udp")
        ]))

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !viewModel.snapshot.isPacketTableFiltering &&
                viewModel.snapshot.packetRows.map(\.id) == udpIDs
        }

        #expect(viewModel.snapshot.packetRows.map(\.id) == udpIDs)
    }

    @Test func asyncFilteringAppliesAppendTailBeforePublishingFinalRows() async {
        let liveSession = InspectorFakeLiveSession()
        let filterGate = PacketFilterBuildGate()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults(),
            packetTableAsyncRebuildThreshold: 1,
            packetTableFilterBuildHook: {
                filterGate.markStartedAndWaitUntilReleased()
            }
        )
        let initialPackets = (1...1_200).map { index in
            makePacket(
                packetNumber: UInt64(index),
                source: .live,
                transportHint: .tcp,
                destinationPort: index.isMultiple(of: 2) ? 443 : 80
            )
        }
        let appendedPacket = makePacket(
            packetNumber: 1_201,
            source: .live,
            transportHint: .tcp,
            destinationPort: 8443
        )
        let expectedIDs = initialPackets
            .filter { ($0.endpoints.destination.port ?? 0) >= 400 }
            .map(\.id) + [appendedPacket.id]

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch(initialPackets, disposition: .append))

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !viewModel.snapshot.isPacketTableFiltering &&
                viewModel.snapshot.packetRows.count == initialPackets.count
        }

        let unfilteredIDs = viewModel.snapshot.packetRows.map(\.id)
        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "400")
        ]))
        viewModel.setStructuredFilterVisible(true)

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            filterGate.hasStarted && viewModel.snapshot.isPacketTableFiltering
        }
        #expect(viewModel.snapshot.isPacketTableFiltering)
        #expect(viewModel.snapshot.packetRows.map(\.id) == unfilteredIDs)
        liveSession.send(.packetBatch([appendedPacket], disposition: .append))
        filterGate.release()

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !viewModel.snapshot.isPacketTableFiltering &&
                viewModel.snapshot.totalPacketCount == initialPackets.count + 1 &&
                viewModel.snapshot.packetRows.map(\.id) == expectedIDs
        }

        #expect(viewModel.snapshot.packetRows.map(\.id) == expectedIDs)
    }

    @Test func asyncFilteringReloadsBaselineWhenAppendTailIsNotVisible() async {
        let liveSession = InspectorFakeLiveSession()
        let filterGate = PacketFilterBuildGate()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults(),
            packetTableAsyncRebuildThreshold: 1,
            packetTableFilterBuildHook: {
                filterGate.markStartedAndWaitUntilReleased()
            }
        )
        let initialPackets = (1...30_000).map { index in
            makePacket(
                packetNumber: UInt64(index),
                source: .live,
                transportHint: .tcp,
                infoSummary: index.isMultiple(of: 2) ? "visible-marker-\(index)" : "plain-\(index)"
            )
        }
        let appendedPacket = makePacket(
            packetNumber: 30_001,
            source: .live,
            transportHint: .tcp,
            infoSummary: "plain-tail"
        )
        let expectedIDs = initialPackets
            .filter { $0.infoSummary.hasPrefix("visible-marker-") }
            .map(\.id)

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch(initialPackets, disposition: .append))

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !viewModel.snapshot.isPacketTableFiltering &&
                viewModel.snapshot.packetRows.count == initialPackets.count
        }

        let unfilteredIDs = viewModel.snapshot.packetRows.map(\.id)
        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .anyText, condition: .matchesRegex, text: "visible-marker-[0-9]+")
        ]))
        viewModel.setStructuredFilterVisible(true)

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            filterGate.hasStarted && viewModel.snapshot.isPacketTableFiltering
        }
        #expect(viewModel.snapshot.isPacketTableFiltering)
        #expect(viewModel.snapshot.packetRows.map(\.id) == unfilteredIDs)

        liveSession.send(.packetBatch([appendedPacket], disposition: .append))
        filterGate.release()

        await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            !viewModel.snapshot.isPacketTableFiltering &&
                viewModel.snapshot.totalPacketCount == initialPackets.count + 1 &&
                viewModel.snapshot.packetRows.map(\.id) == expectedIDs
        }

        #expect(viewModel.snapshot.packetRows.map(\.id) == expectedIDs)
        #expect(viewModel.snapshot.packetTableUpdatePlan == .reload)
    }

    @Test func hiddenStructuredFiltersDoNotFilterRowsAndQuickFiltersStillApply() async {
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp, streamID: nil, layerNames: ["Ethernet", "TCP"]),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp, streamID: nil, layerNames: ["Ethernet", "UDP"]),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)

        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/hidden-structured-filter.pcapng"))
        await waitUntil {
            viewModel.snapshot.packetRows.count == packets.count
        }

        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .protocol, condition: .contains, text: "tcp")
        ]))
        #expect(!viewModel.snapshot.isStructuredFilterVisible)
        #expect(viewModel.snapshot.packetRows.map(\.id) == packets.map(\.id))

        viewModel.toggleQuickFilter(.udp)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[1].id])

        viewModel.setStructuredFilterVisible(true)
        #expect(viewModel.snapshot.packetRows.isEmpty)
    }

    @Test func structuredFilterAppliesToLiveAppends() async {
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )
        let lowPortPacket = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, destinationPort: 80)
        let httpsPacket = makePacket(packetNumber: 2, source: .live, transportHint: .tcp, destinationPort: 443)

        viewModel.setStructuredFilterVisible(true)
        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "400")
        ]))
        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([lowPortPacket, httpsPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.totalPacketCount == 2
        }

        #expect(viewModel.snapshot.packetRows.map(\.id) == [httpsPacket.id])
    }

    @Test func hiddenStructuredFilterDoesNotFilterLiveAppends() async {
        let tcpPacket = makePacket(packetNumber: 1, source: .live, transportHint: .tcp, destinationPort: 80, layerNames: ["Ethernet", "TCP"])
        let udpPacket = makePacket(packetNumber: 2, source: .live, transportHint: .udp, destinationPort: 443, layerNames: ["Ethernet", "UDP"])
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        viewModel.updateStructuredFilterGroup(PacketStructuredFilterGroup(filters: [
            PacketStructuredFilter(query: .destinationPort, condition: .greaterThanOrEqual, text: "400")
        ]))
        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([tcpPacket, udpPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.totalPacketCount == 2
        }

        #expect(!viewModel.snapshot.isStructuredFilterVisible)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [tcpPacket.id, udpPacket.id])

        viewModel.toggleQuickFilter(.udp)
        #expect(viewModel.snapshot.packetRows.map(\.id) == [udpPacket.id])
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.NetworkInspectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeOfflineViewModel(
        packets: [PacketSummary],
        packetTableAsyncRebuildThreshold: Int = 5_000,
        customFilterService: PacketCustomFilterService? = nil
    ) -> NetworkInspectorViewModel {
        let openURL = URL(fileURLWithPath: "/tmp/source-list-fixture.pcapng")
        return NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                document: InspectorFakeDocument(url: openURL, packets: packets)
            )),
            userDefaults: isolatedDefaults(),
            pinService: PacketPinService(storageURL: temporaryDirectory().appendingPathComponent("Pins.json")),
            savedPacketService: SavedPacketService(storageURL: temporaryDirectory().appendingPathComponent("Saved.json")),
            customFilterService: customFilterService ?? PacketCustomFilterService(storageURL: temporaryDirectory().appendingPathComponent("CustomFilters.json")),
            packetTableAsyncRebuildThreshold: packetTableAsyncRebuildThreshold
        )
    }

    private func makeClient() -> PacketClient {
        PacketClient(
            pid: 123,
            name: "Example",
            displayName: "Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            bundleIdentifier: "com.example.app",
            bundlePath: "/Applications/Example.app"
        )
    }

    private func makeClient(displayName: String, bundleIdentifier: String) -> PacketClient {
        PacketClient(
            pid: 123,
            name: displayName,
            displayName: displayName,
            executablePath: "/Applications/\(displayName).app/Contents/MacOS/\(displayName)",
            bundleIdentifier: bundleIdentifier,
            bundlePath: "/Applications/\(displayName).app"
        )
    }

    private func selection(
        titled title: String,
        under parentSelection: PacketSourceListSelection,
        in snapshot: NetworkInspectorSnapshot
    ) -> PacketSourceListSelection? {
        snapshot.sourceListSnapshot
            .item(for: parentSelection)?
            .children
            .first { $0.title == title }?
            .selection
    }

    private func domainKey(_ name: String) -> PacketSourceDomainKey {
        PacketSourceDomainKey(rawValue: name.lowercased(), isMissingDomain: false)
    }

    private func makeInterface(id: String, displayName: String) -> CaptureInterfaceSummary {
        CaptureInterfaceSummary(
            id: id,
            technicalName: id,
            displayName: displayName,
            friendlyName: nil,
            interfaceDescription: nil,
            isLoopback: false,
            addresses: [],
            linkType: .ethernet,
            availability: .available,
            capabilities: CaptureInterfaceCapabilities(
                canCapture: true,
                supportsPromiscuousMode: true,
                requiresBPFPermissionSetup: true,
                providesMacOSMetadata: true
            )
        )
    }

    private func makeInspectorSnapshot(
        packets: [PacketSummary],
        selectedPacketID: PacketSummary.ID?,
        inspection: PacketInspection? = nil,
        generation: UInt64 = 1,
        updatePlan: PacketTableUpdatePlan = .reload,
        isLoading: Bool = false,
        packetTableContent: PacketTableContent? = nil
    ) -> NetworkInspectorSnapshot {
        var base = TCPViewerWindowSnapshot.foundation
        base.packetIngestState.replace(with: packets, source: .live)
        base.inspectionState = PacketInspectionState(
            selectedPacketID: selectedPacketID,
            inspection: inspection,
            selectedDetailNodeID: nil,
            highlightedByteRange: nil,
            isLoading: isLoading,
            statusMessage: "Packet loaded."
        )
        let tableContent: PacketTableContent
        if let packetTableContent {
            tableContent = packetTableContent
        } else {
            let rows = packets.map(PacketTableRow.init(packet:))
            let visibleIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
                (row.id, index)
            })
            let store = PacketTableRowStore(rows: rows, visiblePacketRowIndexByID: visibleIndex)
            tableContent = PacketTableContent(
                displayFilter: PacketDisplayFilter(""),
                displayFilterChips: [],
                store: store,
                generation: generation,
                updatePlan: updatePlan,
                malformedPacketCount: 0
            )
        }
        return NetworkInspectorSnapshot.make(
            base: base,
            selectedSidebar: .liveCapture,
            selectedSourceListSelection: .allPackets,
            sourceListSnapshot: .empty,
            sourceListFilterText: "",
            workspaceMode: .packets,
            inspectorTab: .summary,
            isInspectorVisible: true,
            displayFilterText: "",
            packetTableContent: tableContent
        )
    }

    private func makePacket(
        packetNumber: UInt64,
        source: CaptureSource,
        transportHint: TransportProtocolHint,
        sourcePort: UInt16 = 1234,
        destinationPort: UInt16 = 80,
        streamID: UInt32? = 7,
        decodeStatus: PacketDecodeStatus = PacketDecodeStatus(kind: .complete),
        sniDomainName: String? = nil,
        client: PacketClient? = nil,
        direction: PacketDirection? = nil,
        tcpFlags: String? = nil,
        tcpPayloadLength: Int? = nil,
        interfaceName: String? = nil,
        transportDetailSummary: String? = nil,
        transportLayerName: String? = nil,
        protocolSummary: String? = nil,
        infoSummary: String? = nil,
        layerNames: [String]? = nil,
        sourceAddress: String = "10.0.0.1",
        destinationAddress: String = "10.0.0.2"
    ) -> PacketSummary {
        let packetLayers = layerNames?.map { PacketLayer(name: $0) } ?? [
            PacketLayer(name: "Ethernet"),
            PacketLayer(name: transportLayerName ?? transportHint.rawValue.uppercased(), detailSummary: transportDetailSummary),
        ]
        return PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: source,
            interfaceID: source == .live ? "en0" : nil,
            transportHint: transportHint,
            protocolSummary: protocolSummary,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: sourcePort),
                destination: PacketEndpoint(address: destinationAddress, port: destinationPort)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: streamID,
            direction: direction,
            tcpFlags: tcpFlags,
            tcpPayloadLength: tcpPayloadLength,
            infoSummary: infoSummary ?? "Packet \(packetNumber)",
            layers: packetLayers,
            decodeStatus: decodeStatus,
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false, interfaceName: interfaceName),
            sniDomainName: sniDomainName,
            client: client
        )
    }

    private func makeLivePacketBatch(from start: UInt64, through end: UInt64) -> [PacketSummary] {
        (start...end).map { packetNumber in
            makePacket(
                packetNumber: packetNumber,
                source: .live,
                transportHint: packetNumber.isMultiple(of: 2) ? .tcp : .udp,
                streamID: UInt32((packetNumber % 4_096) + 1)
            )
        }
    }

    private func makeInspection(for packet: PacketSummary) -> PacketInspection {
        PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: UInt8(packet.packetNumber % 256), count: 16),
            detailNodes: [
                PacketDetailNode(id: "frame", name: "Frame", value: "Packet \(packet.packetNumber)", kind: .layer)
            ],
            decodeStatus: packet.decodeStatus
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if condition() {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private func allSubviews<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
    let current = (view as? T).map { [$0] } ?? []
    return view.subviews.reduce(current) { result, subview in
        result + allSubviews(ofType: type, in: subview)
    }
}

private func frame(_ lowerFrame: NSRect, isVisuallyBelow upperFrame: NSRect, in view: NSView) -> Bool {
    let tolerance: CGFloat = 1
    if view.isFlipped {
        return lowerFrame.minY >= upperFrame.maxY - tolerance
    }

    return lowerFrame.maxY <= upperFrame.minY + tolerance
}

private final class PacketFilterBuildGate: @unchecked Sendable {
    private struct State {
        var didStart = false
        var isReleased = false
    }

    private let state = Protected(State())

    func markStartedAndWaitUntilReleased() {
        state.write { state in
            state.didStart = true
        }

        while true {
            if state.read(\.isReleased) {
                return
            }

            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func release() {
        state.write { state in
            state.isReleased = true
        }
    }

    var hasStarted: Bool {
        state.read(\.didStart)
    }
}

private final class InspectorFakeCore: TCPViewerCoreProviding, @unchecked Sendable {
    private let interfaces: [CaptureInterfaceSummary]
    private let liveSessions: [InspectorFakeLiveSession]
    private let document: InspectorFakeDocument
    private(set) var makeLiveCaptureSessionCallCount = 0

    init(
        interfaces: [CaptureInterfaceSummary],
        liveSession: InspectorFakeLiveSession = InspectorFakeLiveSession(),
        document: InspectorFakeDocument = InspectorFakeDocument(url: URL(fileURLWithPath: "/tmp/empty.pcapng"), packets: [])
    ) {
        self.interfaces = interfaces
        self.liveSessions = [liveSession]
        self.document = document
    }

    init(
        interfaces: [CaptureInterfaceSummary],
        liveSessions: [InspectorFakeLiveSession],
        document: InspectorFakeDocument = InspectorFakeDocument(url: URL(fileURLWithPath: "/tmp/empty.pcapng"), packets: [])
    ) {
        self.interfaces = interfaces
        self.liveSessions = liveSessions.isEmpty ? [InspectorFakeLiveSession()] : liveSessions
        self.document = document
    }

    func listInterfaces(completion: @escaping TCPViewerCompletion<[CaptureInterfaceSummary]>) {
        completion(.success(interfaces))
    }

    func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void) {
        completion(CaptureFilterValidation(
            disposition: expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .invalid : .valid,
            normalizedExpression: expression.trimmingCharacters(in: .whitespacesAndNewlines),
            message: nil
        ))
    }

    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        try options.validated(for: interface)
    }

    func makeLiveCaptureSession(
        interfaceID: String,
        options: CaptureOptions,
        completion: @escaping TCPViewerCompletion<any LiveCaptureSessionProviding>
    ) {
        let index = min(makeLiveCaptureSessionCallCount, liveSessions.count - 1)
        makeLiveCaptureSessionCallCount += 1
        completion(.success(liveSessions[index]))
    }

    func supportedOfflineFormats() -> [CaptureFileFormat] {
        [.pcap, .pcapng]
    }

    func openOfflineCaptureDocument(
        at fileURL: URL,
        completion: @escaping TCPViewerCompletion<any OfflineCaptureDocumentProviding>
    ) {
        completion(.success(document))
    }

    func loadPacketSummaries(from fileURL: URL, completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        document.open(completion: completion)
    }
}

private final class InspectorFakeNetworkHelperTool: TCPViewerNetworkHelperToolManaging {
    private(set) var snapshot: TCPViewerNetworkHelperToolSnapshot

    init(snapshot: TCPViewerNetworkHelperToolSnapshot) {
        self.snapshot = snapshot
    }

    func refreshStatus(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func install(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func repair(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func uninstall(completion: @escaping (TCPViewerNetworkHelperToolSnapshot) -> Void) -> TCPViewerNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func openSystemSettings() {}
}

private final class InspectorFakePacketClientResolver: PacketClientResolving {
    private let defaultClient: PacketClient?
    private(set) var clientLookupCount = 0
    private(set) var resetCount = 0

    init(defaultClient: PacketClient?) {
        self.defaultClient = defaultClient
    }

    func reset() {
        resetCount += 1
    }

    func client(for packet: PacketSummary) -> PacketClient? {
        clientLookupCount += 1
        return defaultClient
    }
}

private final class InspectorFakeLiveSession: LiveCaptureSessionProviding, @unchecked Sendable {
    var eventHandler: PacketIngestEventHandler?
    var inspections: [PacketSummary.ID: PacketInspection] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var exportRequests: [([PacketSummary.ID], URL, CaptureFileFormat)] = []

    func start(completion: @escaping TCPViewerVoidCompletion) {
        startCount += 1
        completion(.success(()))
    }

    func pause(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func resume(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func stop(completion: @escaping TCPViewerVoidCompletion) {
        stopCount += 1
        completion(.success(()))
    }

    func clearCapturedPackets(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        guard let inspection = inspections[id] else {
            completion(.failure(TCPViewerCoreError(code: .liveSessionControlFailed, message: "Missing inspection.")))
            return
        }

        completion(.success(inspection))
    }

    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        completion(.empty)
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        if shouldCancel?() == true {
            completion(.failure(TCPViewerCoreError(code: .operationCancelled, message: "Packet export was cancelled.")))
            return
        }

        progress?(PacketExportProgress(exportedPacketCount: identifiers.count, totalPacketCount: identifiers.count))
        exportRequests.append((identifiers, url, format))
        completion(.success(()))
    }

    func send(_ event: PacketIngestEvent) {
        eventHandler?(.success(event))
    }
}

private final class InspectorFakeDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    var eventHandler: PacketIngestEventHandler?
    private(set) var url: URL
    private(set) var packets: [PacketSummary]
    private(set) var metadata: CaptureDocumentMetadata
    private(set) var saveCount = 0
    private(set) var saveAsRequests: [(URL, CaptureFileFormat)] = []
    private(set) var exportRequests: [([PacketSummary.ID], URL, CaptureFileFormat)] = []
    private var progress: PacketLoadProgress = .idle

    init(url: URL, packets: [PacketSummary]) {
        self.url = url
        self.packets = packets
        self.metadata = CaptureDocumentMetadata(format: .pcapng)
    }

    func replacePackets(_ packets: [PacketSummary]) {
        self.packets = packets
    }

    func open(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        progress = PacketLoadProgress(
            phase: .completed,
            loadedPacketCount: packets.count,
            message: "Loaded \(packets.count) packets."
        )
        send(.documentMetadataChanged(metadata))
        send(.packetBatch(packets, disposition: .append))
        send(.loadProgressChanged(progress))
        send(.documentStateChanged(phase: .loaded, message: progress.message))
        completion(.success(packets))
    }

    func reopen(completion: @escaping TCPViewerCompletion<[PacketSummary]>) {
        open(completion: completion)
    }

    func cancelLoading(completion: (() -> Void)?) {
        completion?()
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        guard let packet = packets.first(where: { $0.id == id }) else {
            completion(.failure(TCPViewerCoreError(code: .offlineFileOpenFailed, message: "Missing packet.")))
            return
        }

        completion(.success(PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: 0, count: 8),
            detailNodes: [],
            decodeStatus: packet.decodeStatus
        )))
    }

    func save(completion: @escaping TCPViewerVoidCompletion) {
        saveCount += 1
        completion(.success(()))
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
        saveAsRequests.append((url, format))
        self.url = url
        metadata = CaptureDocumentMetadata(format: format)
        completion(.success(()))
    }

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        if shouldCancel?() == true {
            completion(.failure(TCPViewerCoreError(code: .operationCancelled, message: "Packet export was cancelled.")))
            return
        }

        let knownIDs = Set(packets.map(\.id))
        guard identifiers.allSatisfy({ knownIDs.contains($0) }) else {
            completion(.failure(TCPViewerCoreError(code: .offlineFileSaveFailed, message: "Missing packet export backing.")))
            return
        }

        progress?(PacketExportProgress(exportedPacketCount: identifiers.count, totalPacketCount: identifiers.count))
        exportRequests.append((identifiers, url, format))
        completion(.success(()))
    }

    func currentURL() -> URL {
        url
    }

    func currentMetadata() -> CaptureDocumentMetadata {
        metadata
    }

    func packetSummaries() -> [PacketSummary] {
        packets
    }

    func loadProgress() -> PacketLoadProgress {
        progress
    }

    func send(_ event: PacketIngestEvent) {
        eventHandler?(.success(event))
    }
}
