import Foundation
import Testing
import PcapPlusPlusCore
@testable import Packetry

@MainActor
struct WindowControllerTests {

    @Test func controllerInitialLoadSelectsFirstEligibleInterface() async {
        let fakeCore = FakePacketryCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "lo0", displayName: "Loopback", isLoopback: true),
                makeInterface(id: "bridge0", displayName: "Bridge", availability: .hidden, canCapture: false),
            ]]
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.performInitialLoadIfNeeded()

        #expect(controller.snapshot.accessState == .ready)
        #expect(controller.snapshot.sessionState.phase == .ready)
        #expect(controller.snapshot.sessionState.interfaceInventory.map(\.id) == ["en0", "lo0", "bridge0"])
        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")
        #expect(controller.snapshot.sessionState.options.promiscuousMode)
    }

    @Test func refreshClearsStaleInterfaceSelectionWhenInventoryChanges() async {
        let fakeCore = FakePacketryCore(
            interfaceInventories: [
                [makeInterface(id: "en0", displayName: "Wi-Fi")],
                [makeInterface(id: "utun0", displayName: "Tunnel", availability: .unavailable, reason: "Inactive service.")],
            ]
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")

        await controller.refreshInterfaces()

        #expect(controller.snapshot.accessState == .blocked(.noEligibleInterfaces))
        #expect(controller.snapshot.sessionState.selectedInterfaceID == nil)
        #expect(controller.snapshot.sessionState.statusMessage.contains("no longer available"))
    }

    @Test func liveCaptureLifecycleAppliesEventsAndHealth() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakePacketryCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            liveSession: liveSession
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        await settleEventLoop()

        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([
            makePacket(packetNumber: 1, source: .live, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .live, transportHint: .http1),
        ]))
        liveSession.send(.healthChanged(CaptureHealthSnapshot(
            packetsReceived: 2,
            packetsDropped: 1,
            packetsDroppedByInterface: 0,
            packetsObserved: 3,
            lastUpdated: Date(),
            statusMessage: "Healthy"
        )))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running &&
            controller.snapshot.sessionState.capturedPacketCount == 2 &&
            controller.snapshot.packetIngestState.totalPacketCount == 2 &&
            controller.snapshot.sessionState.health.packetsDropped == 1
        }

        #expect(liveSession.startCount == 1)
        #expect(controller.snapshot.sessionState.phase == .running)
        #expect(controller.snapshot.sessionState.capturedPacketCount == 2)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 2)
        #expect(controller.snapshot.sessionState.health.packetsDropped == 1)

        await controller.pauseLiveCapture()
        liveSession.send(.liveStateChanged(phase: .paused, message: "Capture paused."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .paused
        }
        #expect(liveSession.pauseCount == 1)
        #expect(controller.snapshot.sessionState.phase == .paused)

        await controller.resumeLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture resumed."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }
        #expect(liveSession.resumeCount == 1)
        #expect(controller.snapshot.sessionState.phase == .running)

        await controller.stopLiveCapture()
        liveSession.send(.liveStateChanged(phase: .stopped, message: "Capture stopped."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .stopped
        }
        #expect(liveSession.stopCount == 1)
        #expect(controller.snapshot.sessionState.phase == .stopped)
    }

    @Test func documentOpenReopenSaveAndSaveAsUpdateSnapshot() async {
        let openURL = URL(fileURLWithPath: "/tmp/session.pcapng")
        let saveAsURL = URL(fileURLWithPath: "/tmp/exported.pcap")
        let document = FakeOfflineDocument(
            url: openURL,
            metadata: CaptureDocumentMetadata(
                format: .pcapng,
                operatingSystem: "macOS",
                hardware: "Apple",
                captureApplication: "PacketryTests",
                fileComment: "fixture"
            ),
            openPackets: [
                makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
                makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
            ],
            reopenPackets: [
                makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
                makePacket(packetNumber: 2, source: .offline, transportHint: .dns),
                makePacket(packetNumber: 3, source: .offline, transportHint: .dns),
            ]
        )
        let fakeCore = FakePacketryCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            documentFactory: { _ in document }
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.openDocument(at: openURL)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
            controller.snapshot.documentState.packetCount == 2
        }

        #expect(controller.snapshot.documentState.phase == .loaded)
        #expect(controller.snapshot.documentState.fileURL == openURL)
        #expect(controller.snapshot.documentState.packetCount == 2)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 2)
        #expect(controller.snapshot.documentState.metadata?.captureApplication == "PacketryTests")

        await controller.reopenDocument()
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
            controller.snapshot.documentState.packetCount == 3
        }

        #expect(controller.snapshot.documentState.phase == .loaded)
        #expect(controller.snapshot.documentState.packetCount == 3)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 3)

        await controller.saveDocument()
        await waitUntil {
            controller.snapshot.documentState.phase == .saved
        }
        #expect(document.saveCount == 1)
        #expect(controller.snapshot.documentState.phase == .saved)

        await controller.saveDocument(to: saveAsURL, format: .pcap)
        await waitUntil {
            controller.snapshot.documentState.phase == .saved &&
            controller.snapshot.documentState.fileURL == saveAsURL
        }
        #expect(document.saveAsRequests.count == 1)
        #expect(controller.snapshot.documentState.fileURL == saveAsURL)
        #expect(controller.snapshot.documentState.format == .pcap)
    }

    private func makeInterface(
        id: String,
        displayName: String,
        isLoopback: Bool = false,
        availability: CaptureInterfaceAvailability = .available,
        reason: String? = nil,
        canCapture: Bool = true
    ) -> CaptureInterfaceSummary {
        CaptureInterfaceSummary(
            id: id,
            technicalName: id,
            displayName: displayName,
            friendlyName: nil,
            interfaceDescription: nil,
            isLoopback: isLoopback,
            addresses: [],
            linkType: isLoopback ? .loopback : .ethernet,
            availability: availability,
            availabilityReason: reason,
            activityPreview: CaptureInterfaceActivityPreview(),
            capabilities: CaptureInterfaceCapabilities(
                canCapture: canCapture,
                supportsPromiscuousMode: !isLoopback,
                requiresBPFPermissionSetup: true,
                providesMacOSMetadata: true
            )
        )
    }

    private func makePacket(
        packetNumber: UInt64,
        source: CaptureSource,
        transportHint: TransportProtocolHint
    ) -> PacketSummary {
        PacketSummary(
            packetNumber: packetNumber,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packetNumber)),
            source: source,
            interfaceID: source == .live ? "en0" : nil,
            transportHint: transportHint,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 80)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: 42,
            infoSummary: "Packet \(packetNumber)",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "IPv4")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }

    private func settleEventLoop() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if condition() {
                return
            }

            await settleEventLoop()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class FakePacketryCore: PacketryCoreProviding, @unchecked Sendable {
    private let interfaceInventories: [[CaptureInterfaceSummary]]
    private let liveSession: FakeLiveSession
    private let documentFactory: (URL) -> FakeOfflineDocument
    private var interfaceCallCount = 0

    init(
        interfaceInventories: [[CaptureInterfaceSummary]],
        liveSession: FakeLiveSession = FakeLiveSession(),
        documentFactory: @escaping (URL) -> FakeOfflineDocument = { url in
            FakeOfflineDocument(
                url: url,
                metadata: CaptureDocumentMetadata(format: .pcapng),
                openPackets: []
            )
        }
    ) {
        self.interfaceInventories = interfaceInventories
        self.liveSession = liveSession
        self.documentFactory = documentFactory
    }

    func listInterfaces() async throws -> [CaptureInterfaceSummary] {
        let index = min(interfaceCallCount, interfaceInventories.count - 1)
        interfaceCallCount += 1
        return interfaceInventories[index]
    }

    func validateCaptureFilter(_ expression: String) async -> CaptureFilterValidation {
        CaptureFilterValidation(disposition: .valid, normalizedExpression: expression.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        try options.validated(for: interface)
    }

    func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions) async throws -> any LiveCaptureSessionProviding {
        _ = interfaceID
        _ = options
        return liveSession
    }

    func supportedOfflineFormats() -> [CaptureFileFormat] {
        [.pcap, .pcapng]
    }

    func openOfflineCaptureDocument(at fileURL: URL) async throws -> any OfflineCaptureDocumentProviding {
        documentFactory(fileURL)
    }

    func loadPacketSummaries(from fileURL: URL) async throws -> [PacketSummary] {
        let document = try await openOfflineCaptureDocument(at: fileURL)
        return try await document.open()
    }
}

private final class FakeLiveSession: LiveCaptureSessionProviding, @unchecked Sendable {
    private let pipe = EventPipe<PacketIngestEvent>()

    private(set) var startCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0

    func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        pipe.stream
    }

    func start() async throws {
        startCount += 1
    }

    func pause() async throws {
        pauseCount += 1
    }

    func resume() async throws {
        resumeCount += 1
    }

    func stop() async throws {
        stopCount += 1
    }

    func healthSnapshot() async -> CaptureHealthSnapshot {
        .empty
    }

    func send(_ event: PacketIngestEvent) {
        pipe.yield(event)
    }
}

private final class FakeOfflineDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    private let pipe = EventPipe<PacketIngestEvent>()

    private(set) var url: URL
    private(set) var metadata: CaptureDocumentMetadata
    private(set) var packets: [PacketSummary]
    private let reopenPackets: [PacketSummary]

    private(set) var saveCount = 0
    private(set) var saveAsRequests: [(URL, CaptureFileFormat)] = []

    init(
        url: URL,
        metadata: CaptureDocumentMetadata,
        openPackets: [PacketSummary],
        reopenPackets: [PacketSummary]? = nil
    ) {
        self.url = url
        self.metadata = metadata
        self.packets = openPackets
        self.reopenPackets = reopenPackets ?? openPackets
    }

    func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        pipe.stream
    }

    func open() async throws -> [PacketSummary] {
        pipe.yield(.documentMetadataChanged(metadata))
        pipe.yield(.packetBatch(packets))
        pipe.yield(.documentStateChanged(phase: .loaded, message: "Loaded \(packets.count) packets from \(url.lastPathComponent)."))
        return packets
    }

    func reopen() async throws -> [PacketSummary] {
        packets = reopenPackets
        pipe.yield(.documentMetadataChanged(metadata))
        pipe.yield(.packetBatch(packets))
        pipe.yield(.documentStateChanged(phase: .loaded, message: "Reloaded \(packets.count) packets from \(url.lastPathComponent)."))
        return packets
    }

    func save() async throws {
        saveCount += 1
        pipe.yield(.documentMetadataChanged(metadata))
        pipe.yield(.documentStateChanged(phase: .saved, message: "Saved \(url.lastPathComponent)."))
    }

    func save(to url: URL, format: CaptureFileFormat) async throws {
        saveAsRequests.append((url, format))
        self.url = url

        if format == .pcap {
            metadata = CaptureDocumentMetadata(format: .pcap)
        } else {
            metadata = CaptureDocumentMetadata(
                format: .pcapng,
                operatingSystem: metadata.operatingSystem,
                hardware: metadata.hardware,
                captureApplication: metadata.captureApplication,
                fileComment: metadata.fileComment
            )
        }

        pipe.yield(.documentMetadataChanged(metadata))
        pipe.yield(.documentStateChanged(phase: .saved, message: "Saved as \(url.lastPathComponent)."))
    }

    func currentURL() async -> URL {
        url
    }

    func currentMetadata() async -> CaptureDocumentMetadata {
        metadata
    }

    func packetSummaries() async -> [PacketSummary] {
        packets
    }
}

private final class EventPipe<Element> {
    let stream: AsyncThrowingStream<Element, Error>
    private let continuation: AsyncThrowingStream<Element, Error>.Continuation

    init() {
        var capturedContinuation: AsyncThrowingStream<Element, Error>.Continuation?
        stream = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func yield(_ element: Element) {
        continuation.yield(element)
    }
}
