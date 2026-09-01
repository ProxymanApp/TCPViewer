//
//  EndpointStatisticsDrillDownTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 1/9/26.
//

import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
@MainActor
struct EndpointStatisticsDrillDownTests {

    @Test func filtersExactAppDomainIPAndTransportEndpointIdentities() async {
        let alphaClient = makeClient(name: "Alpha", bundleIdentifier: "com.example.alpha")
        let betaClient = makeClient(name: "Beta", bundleIdentifier: "com.example.beta")
        let packets = [
            makePacket(number: 1, transport: .tcp, client: alphaClient),
            makePacket(number: 2, transport: .udp, client: alphaClient),
            makePacket(number: 3, transport: .tcp, client: betaClient),
            makePacket(number: 4, transport: .tls, domain: "api.example.com", layers: ["Ethernet", "TCP", "TLS"]),
            makePacket(number: 5, transport: .tcp, domain: " API.EXAMPLE.COM. "),
            makePacket(number: 6, transport: .tcp, domain: "cdn.api.example.com"),
            makePacket(number: 7, transport: .tcp, sourceAddress: "198.51.100.8", destinationAddress: "192.0.2.1"),
            makePacket(number: 8, transport: .udp, sourceAddress: "192.0.2.1", destinationAddress: "198.51.100.8"),
            makePacket(number: 9, transport: .tcp, sourceAddress: "198.51.100.80", destinationAddress: "192.0.2.1"),
            makePacket(number: 10, transport: .tcp, sourceAddress: "2001:0db8:0:0:0:0:0:8", destinationAddress: "2001:db8::1"),
            makePacket(number: 11, transport: .udp, sourceAddress: "2001:db8::1", destinationAddress: "2001:db8::8"),
            makePacket(number: 12, transport: .tcp, sourceAddress: "2001:db8::80", destinationAddress: "2001:db8::1"),
            makePacket(
                number: 13,
                transport: .tls,
                destinationPort: 443,
                sourceAddress: "10.0.0.1",
                destinationAddress: "192.0.2.20",
                layers: ["Ethernet", "TCP", "TLS"]
            ),
            makePacket(
                number: 14,
                transport: .udp,
                destinationPort: 443,
                sourceAddress: "10.0.0.1",
                destinationAddress: "192.0.2.20"
            ),
            makePacket(
                number: 15,
                transport: .tcp,
                destinationPort: 444,
                sourceAddress: "10.0.0.1",
                destinationAddress: "192.0.2.20"
            ),
            makePacket(
                number: 16,
                transport: .dns,
                destinationPort: 53,
                sourceAddress: "10.0.0.1",
                destinationAddress: "192.0.2.30",
                layers: ["Ethernet", "UDP", "DNS"]
            ),
            makePacket(
                number: 17,
                transport: .tcp,
                destinationPort: 53,
                sourceAddress: "10.0.0.1",
                destinationAddress: "192.0.2.30"
            ),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)
        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/endpoint-drilldown-identities.pcapng"))
        await waitUntil { viewModel.snapshot.packetRows.count == packets.count }

        let cases: [(String, EndpointStatisticsRow.ID, [PacketSummary.ID])] = [
            (
                "app",
                EndpointStatisticsRow.ID(group: .apps, key: "bundleIdentifier:com.example.alpha"),
                [packets[0].id, packets[1].id]
            ),
            (
                "domain",
                EndpointStatisticsRow.ID(group: .domains, key: "api.example.com"),
                [packets[3].id, packets[4].id]
            ),
            (
                "IPv4",
                EndpointStatisticsRow.ID(group: .ipv4, key: "198.51.100.8"),
                [packets[6].id, packets[7].id]
            ),
            (
                "IPv6",
                EndpointStatisticsRow.ID(group: .ipv6, key: "2001:db8::8"),
                [packets[9].id, packets[10].id]
            ),
            (
                "TCP",
                EndpointStatisticsRow.ID(group: .tcp, key: "192.0.2.20:443"),
                [packets[12].id]
            ),
            (
                "UDP",
                EndpointStatisticsRow.ID(group: .udp, key: "192.0.2.30:53"),
                [packets[15].id]
            ),
        ]

        for (name, rowID, expectedPacketIDs) in cases {
            viewModel.showRelatedPackets(forEndpoint: rowID)

            #expect(viewModel.snapshot.packetRows.map(\.id) == expectedPacketIDs, "Wrong exact match for \(name)")
            #expect(viewModel.snapshot.selectedPacket?.id == expectedPacketIDs.first, "Wrong first selection for \(name)")

            viewModel.clearEndpointStatisticsFilter()
            #expect(viewModel.snapshot.packetRows.map(\.id) == packets.map(\.id), "Clear did not restore rows after \(name)")
        }
    }

    @Test func composesWithExistingFiltersAndClearRestoresTheirScope() async {
        let alphaClient = makeClient(name: "Alpha", bundleIdentifier: "com.example.alpha")
        let betaClient = makeClient(name: "Beta", bundleIdentifier: "com.example.beta")
        let packets = [
            makePacket(number: 1, transport: .tcp, destinationPort: 443, client: alphaClient),
            makePacket(number: 2, transport: .udp, destinationPort: 443, client: alphaClient),
            makePacket(number: 3, transport: .tcp, destinationPort: 443, client: betaClient),
            makePacket(number: 4, transport: .tcp, destinationPort: 80, client: alphaClient),
        ]
        let viewModel = makeOfflineViewModel(packets: packets)
        await viewModel.openDocument(at: URL(fileURLWithPath: "/tmp/endpoint-drilldown-filter-composition.pcapng"))
        await waitUntil { viewModel.snapshot.packetRows.count == packets.count }

        viewModel.toggleQuickFilter(.tcp)
        viewModel.updateDisplayFilterText("port:443")
        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[2].id])

        viewModel.showRelatedPackets(forEndpoint: EndpointStatisticsRow.ID(
            group: .apps,
            key: "bundleIdentifier:com.example.alpha"
        ))

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id])
        #expect(viewModel.snapshot.selectedPacket?.id == packets[0].id)
        #expect(viewModel.snapshot.endpointStatisticsFilterLabel == "Apps: com.example.alpha")
        #expect(viewModel.snapshot.quickFilterSelection.activeIDs == [.tcp])
        #expect(viewModel.snapshot.displayFilterText == "port:443")

        viewModel.clearEndpointStatisticsFilter()

        #expect(viewModel.snapshot.packetRows.map(\.id) == [packets[0].id, packets[2].id])
        #expect(viewModel.snapshot.endpointStatisticsFilterLabel == nil)
        #expect(viewModel.snapshot.quickFilterSelection.activeIDs == [.tcp])
        #expect(viewModel.snapshot.displayFilterText == "port:443")
    }

    @Test func liveMetadataBackfillRevealsDomainMatchesWithoutAnotherUserAction() async {
        let liveSession = EndpointDrilldownFakeLiveSession()
        let viewModel = makeLiveViewModel(liveSession: liveSession)
        let firstPacket = makePacket(number: 1, source: .live, transport: .tcp, streamID: 77)
        let resolvingPacket = makePacket(
            number: 2,
            source: .live,
            transport: .tls,
            streamID: 77,
            domain: "late.example.com",
            layers: ["Ethernet", "TCP", "TLS"]
        )

        await viewModel.performInitialLoadIfNeeded()
        await viewModel.toggleLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))
        await waitUntil { viewModel.snapshot.totalPacketCount == 1 }

        viewModel.showRelatedPackets(forEndpoint: EndpointStatisticsRow.ID(
            group: .domains,
            key: "late.example.com"
        ))
        #expect(viewModel.snapshot.packetRows.isEmpty)

        liveSession.send(.packetBatch([resolvingPacket], disposition: .append))
        await waitUntil {
            viewModel.snapshot.packetRows.map(\.id) == [firstPacket.id, resolvingPacket.id]
        }

        #expect(viewModel.snapshot.packetRows.map(\.domainText) == ["late.example.com", "late.example.com"])
        #expect(viewModel.snapshot.endpointStatisticsFilterLabel == "Domains: late.example.com")
    }

    private func makeOfflineViewModel(packets: [PacketSummary]) -> NetworkInspectorViewModel {
        let document = EndpointDrilldownFakeDocument(
            url: URL(fileURLWithPath: "/tmp/endpoint-drilldown-fixture.pcapng"),
            packets: packets
        )
        return makeViewModel(core: EndpointDrilldownFakeCore(document: document))
    }

    private func makeLiveViewModel(liveSession: EndpointDrilldownFakeLiveSession) -> NetworkInspectorViewModel {
        makeViewModel(core: EndpointDrilldownFakeCore(liveSession: liveSession))
    }

    private func makeViewModel(core: EndpointDrilldownFakeCore) -> NetworkInspectorViewModel {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        return NetworkInspectorViewModel(
            services: TCPViewerServiceRegistry(
                core: core,
                packetMetadataEnricher: PacketMetadataEnrichmentService(
                    clientResolver: EndpointDrilldownNilClientResolver()
                )
            ),
            userDefaults: isolatedDefaults(),
            pinService: PacketPinService(storageURL: storageDirectory.appendingPathComponent("Pins.json")),
            savedPacketService: SavedPacketService(storageURL: storageDirectory.appendingPathComponent("Saved.json")),
            customFilterService: PacketCustomFilterService(storageURL: storageDirectory.appendingPathComponent("Filters.json"))
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "TCPViewer.EndpointStatisticsDrillDownTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeClient(name: String, bundleIdentifier: String) -> PacketClient {
        PacketClient(
            pid: 123,
            name: name,
            displayName: name,
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            bundleIdentifier: bundleIdentifier,
            bundlePath: "/Applications/\(name).app"
        )
    }

    private func makePacket(
        number: UInt64,
        source: CaptureSource = .offline,
        transport: TransportProtocolHint,
        sourcePort: UInt16 = 50_000,
        destinationPort: UInt16 = 80,
        streamID: UInt32? = nil,
        domain: String? = nil,
        client: PacketClient? = nil,
        sourceAddress: String = "10.0.0.1",
        destinationAddress: String = "10.0.0.2",
        layers: [String]? = nil
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: number,
            timestamp: Date(timeIntervalSince1970: TimeInterval(number)),
            source: source,
            interfaceID: source == .live ? "en0" : nil,
            transportHint: transport,
            protocolSummary: nil,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: sourceAddress, port: sourcePort),
                destination: PacketEndpoint(address: destinationAddress, port: destinationPort)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: streamID,
            direction: nil,
            infoSummary: "Packet \(number)",
            layers: (layers ?? defaultLayers(for: transport)).map { PacketLayer(name: $0) },
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: domain,
            client: client
        )
    }

    private func defaultLayers(for transport: TransportProtocolHint) -> [String] {
        switch transport {
        case .udp, .dns:
            return ["Ethernet", "UDP"]
        default:
            return ["Ethernet", "TCP"]
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
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

private final class EndpointDrilldownFakeCore: TCPViewerCoreProviding, @unchecked Sendable {
    private let document: EndpointDrilldownFakeDocument
    private let liveSession: EndpointDrilldownFakeLiveSession

    init(
        document: EndpointDrilldownFakeDocument = EndpointDrilldownFakeDocument(
            url: URL(fileURLWithPath: "/tmp/empty-endpoint-drilldown.pcapng"),
            packets: []
        ),
        liveSession: EndpointDrilldownFakeLiveSession = EndpointDrilldownFakeLiveSession()
    ) {
        self.document = document
        self.liveSession = liveSession
    }

    func listInterfaces(completion: @escaping TCPViewerCompletion<[CaptureInterfaceSummary]>) {
        completion(.success([CaptureInterfaceSummary(
            id: "en0",
            technicalName: "en0",
            displayName: "Wi-Fi",
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
        )]))
    }

    func validateCaptureFilter(_ expression: String, completion: @escaping (CaptureFilterValidation) -> Void) {
        completion(CaptureFilterValidation(
            disposition: expression.isEmpty ? .invalid : .valid,
            normalizedExpression: expression,
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
        completion(.success(liveSession))
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

    func loadPacketSummaries(
        from fileURL: URL,
        completion: @escaping TCPViewerCompletion<[PacketSummary]>
    ) {
        completion(.success(document.packetSummaries()))
    }
}

private final class EndpointDrilldownFakeDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    var eventHandler: PacketIngestEventHandler?
    private let url: URL
    private let packets: [PacketSummary]
    private let metadata = CaptureDocumentMetadata(format: .pcapng)
    private var progress = PacketLoadProgress.idle

    init(url: URL, packets: [PacketSummary]) {
        self.url = url
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
        completion(.success(()))
    }

    func save(to url: URL, format: CaptureFileFormat, completion: @escaping TCPViewerVoidCompletion) {
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
        progress?(PacketExportProgress(exportedPacketCount: identifiers.count, totalPacketCount: identifiers.count))
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

    private func send(_ event: PacketIngestEvent) {
        eventHandler?(.success(event))
    }
}

private final class EndpointDrilldownFakeLiveSession: LiveCaptureSessionProviding, @unchecked Sendable {
    var eventHandler: PacketIngestEventHandler?
    private var packetsByID: [PacketSummary.ID: PacketSummary] = [:]

    func start(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func pause(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func resume(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func stop(completion: @escaping TCPViewerVoidCompletion) {
        completion(.success(()))
    }

    func clearCapturedPackets(completion: @escaping TCPViewerVoidCompletion) {
        packetsByID.removeAll()
        completion(.success(()))
    }

    func inspectPacket(id: PacketSummary.ID, completion: @escaping TCPViewerCompletion<PacketInspection>) {
        guard let packet = packetsByID[id] else {
            completion(.failure(TCPViewerCoreError(code: .liveSessionControlFailed, message: "Missing packet.")))
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

    func exportPackets(
        withIDs identifiers: [PacketSummary.ID],
        to url: URL,
        format: CaptureFileFormat,
        progress: PacketExportProgressHandler?,
        shouldCancel: PacketExportCancellationCheck?,
        completion: @escaping TCPViewerVoidCompletion
    ) {
        progress?(PacketExportProgress(exportedPacketCount: identifiers.count, totalPacketCount: identifiers.count))
        completion(.success(()))
    }

    func healthSnapshot(completion: @escaping (CaptureHealthSnapshot) -> Void) {
        completion(.empty)
    }

    func send(_ event: PacketIngestEvent) {
        if case .packetBatch(let packets, let disposition) = event {
            if disposition == .replace {
                packetsByID.removeAll()
            }
            for packet in packets {
                packetsByID[packet.id] = packet
            }
        }
        eventHandler?(.success(event))
    }
}

private final class EndpointDrilldownNilClientResolver: PacketClientResolving {
    func reset() {}

    func client(for packet: PacketSummary) -> PacketClient? {
        nil
    }
}
