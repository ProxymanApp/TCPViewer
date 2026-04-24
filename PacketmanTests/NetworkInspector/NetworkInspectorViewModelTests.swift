import Foundation
import Testing
import PcapPlusPlusCore
@testable import Packetman

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
            services: PacketryServiceRegistry(core: InspectorFakeCore(
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

        viewModel.selectPacket(packet.id)
        await waitUntil {
            viewModel.snapshot.base.inspectionState.inspection?.packetID == packet.id
        }

        #expect(viewModel.snapshot.selectedPacket?.id == packet.id)
        #expect(viewModel.snapshot.base.inspectionState.inspection?.rawBytes.count == 16)

        viewModel.updateDisplayFilterText("protocol:tcp port:443")
        #expect(viewModel.snapshot.visiblePacketCount == 1)
        #expect(viewModel.snapshot.displayFilterChips.map(\.label) == ["Protocol: TCP", "Port: 443"])

        viewModel.updateDisplayFilterText("protocol:udp")
        #expect(viewModel.snapshot.visiblePacketCount == 0)
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
            services: PacketryServiceRegistry(core: InspectorFakeCore(
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
            snapshot: PacketryNetworkHelperToolSnapshot(
                status: .notInstalled,
                authorizationStatus: .notRegistered,
                lastCheckedAt: nil,
                message: "Packetry Network Helper Tool is not installed."
            )
        )
        let viewModel = NetworkInspectorViewModel(
            services: PacketryServiceRegistry(
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

    @Test func packetFormattingFilteringAndTableUpdatePlansAreStable() {
        let client = makeClient()
        let healthy = makePacket(
            packetNumber: 1,
            source: .offline,
            transportHint: .http1,
            destinationPort: 80,
            sniDomainName: "api.example.com",
            client: client
        )
        let malformed = makePacket(
            packetNumber: 2,
            source: .offline,
            transportHint: .udp,
            decodeStatus: PacketDecodeStatus(kind: .malformed, reason: "Bad length")
        )

        let healthyRow = PacketTableRow(packet: healthy)
        let malformedRow = PacketTableRow(packet: malformed)

        #expect(healthyRow.protocolText == "HTTP1")
        #expect(healthyRow.lengthText == "128 B")
        #expect(healthyRow.domainText == "api.example.com")
        #expect(healthyRow.clientText == "Example")
        #expect(malformedRow.severity == .malformed)
        #expect(malformedRow.tags.map(\.label) == ["Malformed"])

        #expect(PacketDisplayFilter("protocol:http port:80").matches(healthy))
        #expect(PacketDisplayFilter("api.example.com").matches(healthy))
        #expect(PacketDisplayFilter("com.example.app").matches(healthy))
        #expect(PacketDisplayFilter("error:malformed").matches(malformed))
        #expect(!PacketDisplayFilter("protocol:tcp").matches(malformed))

        #expect(PacketTableUpdatePlanner.plan(previousGeneration: 0, currentGeneration: 1, proposedPlan: .append(0..<2)) == .append(0..<2))
        #expect(PacketTableUpdatePlanner.plan(previousGeneration: 1, currentGeneration: 2, proposedPlan: .reload) == .reload)
        #expect(PacketTableUpdatePlanner.plan(previousGeneration: 1, currentGeneration: 1, proposedPlan: .reload) == .none)
    }

    @Test func packetTableSelectionSyncOnlyTouchesStaleVisualSelection() {
        let packets = [
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
            makePacket(packetNumber: 3, source: .live, transportHint: .dns),
        ]
        let rows = packets.map(PacketTableRow.init)

        #expect(PacketTableSelectionSyncPlanner.action(
            rows: rows,
            selectedPacketID: packets[1].id,
            selectedRowIndex: 1,
            tableSelectedRow: 1
        ) == .none)

        #expect(PacketTableSelectionSyncPlanner.action(
            rows: rows,
            selectedPacketID: packets[1].id,
            selectedRowIndex: 1,
            tableSelectedRow: -1
        ) == .select(1))

        #expect(PacketTableSelectionSyncPlanner.action(
            rows: rows,
            selectedPacketID: packets[1].id,
            selectedRowIndex: 1,
            tableSelectedRow: 0
        ) == .select(1))

        #expect(PacketTableSelectionSyncPlanner.action(
            rows: rows,
            selectedPacketID: nil,
            selectedRowIndex: nil,
            tableSelectedRow: 1
        ) == .deselect)

        #expect(PacketTableSelectionSyncPlanner.action(
            rows: rows,
            selectedPacketID: packets[1].id,
            selectedRowIndex: nil,
            tableSelectedRow: -1
        ) == .none)
    }

    @Test func packetRowsAreCachedAcrossNonPacketUpdates() async {
        let packet = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: PacketryServiceRegistry(core: InspectorFakeCore(
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

    @Test func packetRowsAppendIncrementallyForMatchingLiveBatches() async {
        let packets = [
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .udp),
            makePacket(packetNumber: 3, source: .live, transportHint: .dns),
        ]
        let liveSession = InspectorFakeLiveSession()
        let viewModel = NetworkInspectorViewModel(
            services: PacketryServiceRegistry(core: InspectorFakeCore(
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
        #expect(viewModel.snapshot.packetTableUpdatePlan == .append(1..<3))
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
            services: PacketryServiceRegistry(
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

    @Test func metadataUpdateRebuildsRowsWhenVisibleRowCountDoesNotChange() async {
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
            services: PacketryServiceRegistry(
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
        #expect(viewModel.snapshot.packetTableUpdatePlan == .reload)
    }

    @Test func metadataEnrichmentDoesNotResolveClientsForOfflinePackets() {
        let clientResolver = InspectorFakePacketClientResolver(defaultClient: makeClient())
        let service = PacketMetadataEnrichmentService(clientResolver: clientResolver)
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)

        let result = service.enrich([packet], source: .offline)

        #expect(result.packets.first?.client == nil)
        #expect(clientResolver.clientLookupCount == 0)
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
            services: PacketryServiceRegistry(core: InspectorFakeCore(
                interfaces: [makeInterface(id: "en0", displayName: "Wi-Fi")],
                liveSession: liveSession
            )),
            userDefaults: isolatedDefaults()
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.packetRows.count == 1
        }

        viewModel.updateDisplayFilterText("protocol:udp")
        let generationAfterFilter = viewModel.snapshot.packetTableGeneration
        liveSession.send(.packetBatch([filteredPacket], disposition: .append))

        await waitUntil {
            viewModel.snapshot.totalPacketCount == 2
        }

        #expect(viewModel.snapshot.visiblePacketCount == 1)
        #expect(viewModel.snapshot.packetTableGeneration == generationAfterFilter)
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
            services: PacketryServiceRegistry(core: InspectorFakeCore(
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

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "Packetry.NetworkInspectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
        transportDetailSummary: String? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: source,
            interfaceID: source == .live ? "en0" : nil,
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: sourcePort),
                destination: PacketEndpoint(address: "10.0.0.2", port: destinationPort)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: streamID,
            infoSummary: "Packet \(packetNumber)",
            layers: [
                PacketLayer(name: "Ethernet"),
                PacketLayer(name: transportHint.rawValue.uppercased(), detailSummary: transportDetailSummary),
            ],
            decodeStatus: decodeStatus,
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: sniDomainName,
            client: client
        )
    }

    private func makeInspection(for packet: PacketSummary) -> PacketInspection {
        PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: UInt8(packet.packetNumber), count: 16),
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

private final class InspectorFakeCore: PacketryCoreProviding, @unchecked Sendable {
    private let interfaces: [CaptureInterfaceSummary]
    private let liveSession: InspectorFakeLiveSession
    private let document: InspectorFakeDocument

    init(
        interfaces: [CaptureInterfaceSummary],
        liveSession: InspectorFakeLiveSession = InspectorFakeLiveSession(),
        document: InspectorFakeDocument = InspectorFakeDocument(url: URL(fileURLWithPath: "/tmp/empty.pcapng"), packets: [])
    ) {
        self.interfaces = interfaces
        self.liveSession = liveSession
        self.document = document
    }

    func listInterfaces(completion: @escaping PacketryCompletion<[CaptureInterfaceSummary]>) {
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
        completion: @escaping PacketryCompletion<any LiveCaptureSessionProviding>
    ) {
        completion(.success(liveSession))
    }

    func supportedOfflineFormats() -> [CaptureFileFormat] {
        [.pcap, .pcapng]
    }

    func openOfflineCaptureDocument(
        at fileURL: URL,
        completion: @escaping PacketryCompletion<any OfflineCaptureDocumentProviding>
    ) {
        completion(.success(document))
    }

    func loadPacketSummaries(from fileURL: URL, completion: @escaping PacketryCompletion<[PacketSummary]>) {
        document.open(completion: completion)
    }
}

private final class InspectorFakeNetworkHelperTool: PacketryNetworkHelperToolManaging {
    private(set) var snapshot: PacketryNetworkHelperToolSnapshot

    init(snapshot: PacketryNetworkHelperToolSnapshot) {
        self.snapshot = snapshot
    }

    func refreshStatus(completion: @escaping (PacketryNetworkHelperToolSnapshot) -> Void) -> PacketryNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func install(completion: @escaping (PacketryNetworkHelperToolSnapshot) -> Void) -> PacketryNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func repair(completion: @escaping (PacketryNetworkHelperToolSnapshot) -> Void) -> PacketryNetworkHelperToolSnapshot {
        completion(snapshot)
        return snapshot
    }

    func uninstall(completion: @escaping (PacketryNetworkHelperToolSnapshot) -> Void) -> PacketryNetworkHelperToolSnapshot {
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

    func start(completion: @escaping PacketryVoidCompletion) {
        startCount += 1
        completion(.success(()))
    }

    func pause(completion: @escaping PacketryVoidCompletion) {
        completion(.success(()))
    }

    func resume(completion: @escaping PacketryVoidCompletion) {
        completion(.success(()))
    }

    func stop(completion: @escaping PacketryVoidCompletion) {
        stopCount += 1
        completion(.success(()))
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>) {
        guard let inspection = inspections[id] else {
            completion(.failure(PacketryCoreError(code: .liveSessionControlFailed, message: "Missing inspection.")))
            return
        }

        completion(.success(inspection))
    }

    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        completion(.empty)
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
    private var progress: PacketLoadProgress = .idle

    init(url: URL, packets: [PacketSummary]) {
        self.url = url
        self.packets = packets
        self.metadata = CaptureDocumentMetadata(format: .pcapng)
    }

    func replacePackets(_ packets: [PacketSummary]) {
        self.packets = packets
    }

    func open(completion: @escaping PacketryCompletion<[PacketSummary]>) {
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

    func reopen(completion: @escaping PacketryCompletion<[PacketSummary]>) {
        open(completion: completion)
    }

    func cancelLoading(completion: (() -> Void)?) {
        completion?()
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping PacketryCompletion<PacketInspection>) {
        guard let packet = packets.first(where: { $0.id == id }) else {
            completion(.failure(PacketryCoreError(code: .offlineFileOpenFailed, message: "Missing packet.")))
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

    func save(completion: @escaping PacketryVoidCompletion) {
        saveCount += 1
        completion(.success(()))
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping PacketryVoidCompletion) {
        saveAsRequests.append((url, format))
        self.url = url
        metadata = CaptureDocumentMetadata(format: format)
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
