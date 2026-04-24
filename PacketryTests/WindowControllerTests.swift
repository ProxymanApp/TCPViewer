import Foundation
import Testing
import PcapPlusPlusCore
@testable import Packetry

@Suite(.serialized)
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

        await tearDown(controller)
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

        await tearDown(controller)
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
        ], disposition: .append))
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

        await controller.resumeLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture resumed."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }
        #expect(liveSession.resumeCount == 1)

        await controller.stopLiveCapture()
        liveSession.send(.liveStateChanged(phase: .stopped, message: "Capture stopped."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .stopped
        }
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func terminationPreparationStopsRunningLiveCaptureOnce() async {
        let liveSession = FakeLiveSession()
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        let shouldTerminate = await controller.prepareForApplicationTermination()

        #expect(shouldTerminate)
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func terminationPreparationStopsFailedRetainedLiveCapture() async {
        let liveSession = FakeLiveSession()
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .failed, message: "Capture failed."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .failed
        }

        let shouldTerminate = await controller.prepareForApplicationTermination()

        #expect(shouldTerminate)
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func repeatedTerminationPreparationDoesNotStopReleasedLiveCaptureAgain() async {
        let liveSession = FakeLiveSession()
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        let firstPreparation = await controller.prepareForApplicationTermination()
        let secondPreparation = await controller.prepareForApplicationTermination()

        #expect(firstPreparation)
        #expect(secondPreparation)
        #expect(liveSession.stopCount == 1)

        await tearDown(controller)
    }

    @Test func terminationPreparationCancelsQuitWhenLiveStopFails() async {
        let liveSession = FakeLiveSession()
        liveSession.stopError = PacketryCoreError(code: .liveSessionControlFailed, message: "Stop failed.")
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        let shouldTerminate = await controller.prepareForApplicationTermination()

        #expect(!shouldTerminate)
        #expect(liveSession.stopCount == 1)
        #expect(controller.snapshot.sessionState.phase == .failed)
        #expect(controller.snapshot.sessionState.lastError?.code == .liveSessionControlFailed)

        await tearDown(controller)
    }

    @Test func refreshWhileCaptureIsRunningKeepsActiveSelection() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakePacketryCore(
            interfaceInventories: [
                [makeInterface(id: "en0", displayName: "Wi-Fi")],
                [makeInterface(id: "en0", displayName: "Wi-Fi", availability: .unavailable, reason: "Temporarily unavailable.", canCapture: false)],
            ],
            liveSession: liveSession
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        await waitUntil {
            controller.snapshot.sessionState.phase == .running
        }

        await controller.refreshInterfaces()

        #expect(controller.snapshot.sessionState.selectedInterfaceID == "en0")
        #expect(controller.snapshot.sessionState.phase == .running)
        #expect(controller.snapshot.sessionState.statusMessage.contains("Keeping"))

        await tearDown(controller)
    }

    @Test func selectingAlternateInterfacePropagatesToLiveCapture() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakePacketryCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi"),
                makeInterface(id: "lo0", displayName: "Loopback", isLoopback: true),
            ]],
            liveSession: liveSession
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        controller.selectInterface("lo0")
        await controller.startLiveCapture()

        #expect(fakeCore.liveSessionRequests.last?.interfaceID == "lo0")
        #expect(liveSession.startCount == 1)

        await tearDown(controller)
    }

    @Test func liveCaptureStartsInNormalModeWhenInterfaceDoesNotSupportPromiscuousMode() async {
        let liveSession = FakeLiveSession()
        let fakeCore = FakePacketryCore(
            interfaceInventories: [[
                makeInterface(id: "en0", displayName: "Wi-Fi", supportsPromiscuousMode: false),
            ]],
            liveSession: liveSession
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()

        #expect(controller.snapshot.sessionState.options.promiscuousMode == false)
        #expect(fakeCore.liveSessionRequests.last?.interfaceID == "en0")
        #expect(fakeCore.liveSessionRequests.last?.options.promiscuousMode == false)
        #expect(liveSession.startCount == 1)

        await tearDown(controller)
    }

    @Test func documentOpenReopenSaveAndSaveAsUpdateSnapshot() async {
        let openURL = URL(fileURLWithPath: "/tmp/session.pcapng")
        let saveAsURL = URL(fileURLWithPath: "/tmp/exported.pcap")
        let openPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
        ]
        let reopenPackets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .dns),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns),
        ]
        let document = FakeOfflineDocument(
            url: openURL,
            metadata: CaptureDocumentMetadata(
                format: .pcapng,
                operatingSystem: "macOS",
                hardware: "Apple",
                captureApplication: "PacketryTests",
                fileComment: "fixture"
            ),
            openPlan: .completed(openPackets),
            reopenPlan: .completed(reopenPackets),
            inspections: (openPackets + reopenPackets).reduce(into: [:]) { inspections, packet in
                inspections[packet.id] = makeInspection(for: packet)
            }
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
        #expect(controller.snapshot.loadState.progress.phase == .completed)

        await controller.reopenDocument()
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
            controller.snapshot.documentState.packetCount == 3
        }

        #expect(controller.snapshot.documentState.packetCount == 3)
        #expect(controller.snapshot.packetIngestState.totalPacketCount == 3)

        await controller.saveDocument()
        await waitUntil {
            controller.snapshot.documentState.phase == .saved
        }
        #expect(document.saveCount == 1)

        await controller.saveDocument(to: saveAsURL, format: .pcap)
        await waitUntil {
            controller.snapshot.documentState.phase == .saved &&
            controller.snapshot.documentState.fileURL == saveAsURL
        }
        #expect(document.saveAsRequests.count == 1)
        #expect(controller.snapshot.documentState.fileURL == saveAsURL)
        #expect(controller.snapshot.documentState.format == .pcap)

        await tearDown(controller)
    }

    @Test func openingNewDocumentIgnoresEventsFromPreviousDocumentStream() async {
        let firstURL = URL(fileURLWithPath: "/tmp/first-stream.pcapng")
        let secondURL = URL(fileURLWithPath: "/tmp/second-stream.pcapng")
        let stalePacket = makePacket(packetNumber: 1, source: .offline, transportHint: .udp)
        let secondPacket = makePacket(packetNumber: 1, source: .offline, transportHint: .dns)
        let secondOpenGate = AsyncGate()

        let firstDocument = FakeOfflineDocument(
            url: firstURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed([stalePacket])
        )
        let secondDocument = FakeOfflineDocument(
            url: secondURL,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: FakeOfflineDocument.LoadPlan(
                batches: [[secondPacket]],
                progress: [],
                error: nil,
                gate: secondOpenGate
            ),
            inspections: [secondPacket.id: makeInspection(for: secondPacket)]
        )
        let staleProgress = PacketLoadProgress(
            phase: .cancelled,
            loadedPacketCount: 99,
            isPartialResult: true,
            message: "Stale load was cancelled."
        )
        let fakeCore = FakePacketryCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            documentFactory: { url in
                if url == secondURL {
                    firstDocument.send(.packetBatch([stalePacket], disposition: .append))
                    firstDocument.send(.loadProgressChanged(staleProgress))
                    return secondDocument
                }

                return firstDocument
            }
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore)
        )

        await controller.openDocument(at: firstURL)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }

        let openTask = Task {
            await controller.openDocument(at: secondURL)
        }
        await waitUntil {
            controller.snapshot.documentState.fileURL == secondURL &&
            controller.snapshot.documentState.phase == .opening
        }
        await settleEventLoop()

        #expect(controller.snapshot.packetIngestState.totalPacketCount == 0)
        #expect(controller.snapshot.documentState.isPartialResult == false)

        await secondOpenGate.open()
        await openTask.value

        #expect(controller.snapshot.documentState.phase == .loaded)
        #expect(controller.snapshot.packetIngestState.packets.map(\.transportHint) == [.dns])

        await tearDown(controller)
    }

    @Test func selectingPacketLoadsInspectionAndHighlightsDetailByteRange() async {
        let url = URL(fileURLWithPath: "/tmp/inspection.pcapng")
        let packet = makePacket(packetNumber: 1, source: .offline, transportHint: .tcp)
        let inspection = makeInspection(
            for: packet,
            detailNodes: [
                PacketDetailNode(
                    id: "frame",
                    name: "Frame",
                    value: "Packet 1",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "frame.number", name: "Frame Number", value: "1")
                    ]
                ),
                PacketDetailNode(
                    id: "ipv4",
                    name: "IPv4",
                    value: "10.0.0.1 -> 10.0.0.2",
                    kind: .layer,
                    byteRange: PacketByteRange(offset: 14, length: 20),
                    children: [
                        PacketDetailNode(
                            id: "ipv4.src",
                            name: "Source",
                            value: "10.0.0.1",
                            byteRange: PacketByteRange(offset: 26, length: 4)
                        ),
                        PacketDetailNode(
                            id: "ipv4.dst",
                            name: "Destination",
                            value: "10.0.0.2",
                            byteRange: PacketByteRange(offset: 30, length: 4)
                        ),
                    ]
                ),
            ]
        )
        let document = FakeOfflineDocument(
            url: url,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed([packet]),
            inspections: [packet.id: inspection]
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: url)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }

        controller.selectPacket(packet.id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == packet.id &&
            !controller.snapshot.inspectionState.isLoading
        }

        #expect(controller.snapshot.selectedPacketID == packet.id)
        #expect(controller.snapshot.inspectionState.inspection?.rawBytes.count == 64)
        #expect(controller.snapshot.inspectionState.statusMessage.contains("1"))

        controller.selectDetailNode("ipv4.src")

        #expect(controller.snapshot.inspectionState.selectedDetailNodeID == "ipv4.src")
        #expect(controller.snapshot.inspectionState.highlightedByteRange == PacketByteRange(offset: 26, length: 4))

        await tearDown(controller)
    }

    @Test func navigationMovesAcrossVisiblePacketsAndValidatesJumpInput() async {
        let url = URL(fileURLWithPath: "/tmp/navigation.pcapng")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .tcp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 3, source: .offline, transportHint: .dns),
        ]
        let document = FakeOfflineDocument(
            url: url,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: .completed(packets),
            inspections: Dictionary(uniqueKeysWithValues: packets.map { ($0.id, makeInspection(for: $0)) })
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: url)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded
        }

        controller.selectPacket(packets[0].id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == packets[0].id
        }

        controller.selectNextPacket()
        await waitUntil {
            controller.snapshot.selectedPacketID == packets[1].id &&
            controller.snapshot.inspectionState.inspection?.packetID == packets[1].id
        }
        #expect(controller.snapshot.inspectionState.inspection?.packetID == packets[1].id)

        controller.selectPreviousPacket()
        await waitUntil {
            controller.snapshot.selectedPacketID == packets[0].id
        }

        controller.updateJumpText("abc")
        controller.jumpToPacketNumber()
        #expect(controller.snapshot.navigationState.jumpErrorMessage == "Enter a valid packet number.")

        controller.updateJumpText("99")
        controller.jumpToPacketNumber()
        #expect(controller.snapshot.navigationState.jumpErrorMessage == "Packet 99 is not visible right now.")

        controller.updateJumpText("3")
        controller.jumpToPacketNumber()
        await waitUntil {
            controller.snapshot.selectedPacketID == packets[2].id &&
            controller.snapshot.inspectionState.inspection?.packetID == packets[2].id
        }
        #expect(controller.snapshot.navigationState.jumpErrorMessage == nil)
        #expect(controller.snapshot.inspectionState.inspection?.packetID == packets[2].id)

        await tearDown(controller)
    }

    @Test func livePacketAppendsKeepExistingSelectionAnchored() async {
        let liveSession = FakeLiveSession()
        let firstPacket = makePacket(packetNumber: 1, source: .live, transportHint: .tcp)
        let secondPacket = makePacket(packetNumber: 2, source: .live, transportHint: .udp)
        liveSession.inspections[firstPacket.id] = makeInspection(for: firstPacket)
        liveSession.inspections[secondPacket.id] = makeInspection(for: secondPacket)

        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                liveSession: liveSession
            ))
        )

        await controller.refreshInterfaces()
        await controller.startLiveCapture()
        liveSession.send(.liveStateChanged(phase: .running, message: "Capture running."))
        liveSession.send(.packetBatch([firstPacket], disposition: .append))
        await waitUntil {
            controller.snapshot.packetIngestState.totalPacketCount == 1
        }

        controller.selectPacket(firstPacket.id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == firstPacket.id
        }

        liveSession.send(.packetBatch([secondPacket], disposition: .append))
        await waitUntil {
            controller.snapshot.packetIngestState.totalPacketCount == 2
        }

        #expect(controller.snapshot.selectedPacketID == firstPacket.id)
        #expect(controller.snapshot.inspectionState.inspection?.packetID == firstPacket.id)
        #expect(controller.snapshot.navigationState.visiblePackets.map(\.packetNumber) == [1, 2])

        await tearDown(controller)
    }

    @Test func captureFilterPreferencesLoadPersistAndPropagateToLiveCapture() async {
        let suiteName = "PacketryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(" udp port 53 ", forKey: "Packetry.captureFilterText")
        defaults.set(["port 80", "tcp"], forKey: "Packetry.recentCaptureFilters")

        let liveSession = FakeLiveSession()
        let fakeCore = FakePacketryCore(
            interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
            liveSession: liveSession,
            captureFilterValidator: { expression in
                let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
                return CaptureFilterValidation(disposition: .valid, normalizedExpression: trimmed, message: nil)
            }
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: fakeCore),
            userDefaults: defaults
        )

        #expect(controller.snapshot.filterState.captureFilterText == " udp port 53 ")
        #expect(controller.snapshot.filterState.recentCaptureFilters == ["port 80", "tcp"])

        await controller.refreshInterfaces()
        await controller.startLiveCapture()

        #expect(liveSession.startCount == 1)
        #expect(fakeCore.liveSessionRequests.count == 1)
        #expect(fakeCore.liveSessionRequests.last?.interfaceID == "en0")
        #expect(fakeCore.liveSessionRequests.last?.options.captureFilterExpression == "udp port 53")
        #expect(controller.snapshot.filterState.captureFilterText == "udp port 53")
        #expect(defaults.string(forKey: "Packetry.captureFilterText") == "udp port 53")
        #expect(defaults.stringArray(forKey: "Packetry.recentCaptureFilters")?.first == "udp port 53")

        await tearDown(controller)
    }

    @Test func partialDocumentLoadKeepsLoadedPacketsAndDisablesSave() async {
        let url = URL(fileURLWithPath: "/tmp/partial-load.pcapng")
        let packets = [
            makePacket(packetNumber: 1, source: .offline, transportHint: .udp),
            makePacket(packetNumber: 2, source: .offline, transportHint: .udp),
        ]
        let cancelledProgress = PacketLoadProgress(
            phase: .cancelled,
            loadedPacketCount: packets.count,
            processedBytes: 128,
            totalBytes: 256,
            isPartialResult: true,
            message: "Loading cancelled after 2 packets from partial-load.pcapng."
        )
        let document = FakeOfflineDocument(
            url: url,
            metadata: CaptureDocumentMetadata(format: .pcapng),
            openPlan: FakeOfflineDocument.LoadPlan(
                batches: [[packets[0]], [packets[1]]],
                progress: [
                    PacketLoadProgress(
                        phase: .loading,
                        loadedPacketCount: 1,
                        processedBytes: 64,
                        totalBytes: 256,
                        isPartialResult: false,
                        message: "Loaded 1 packets from partial-load.pcapng…"
                    ),
                    cancelledProgress,
                ],
                error: PacketryCoreError(
                    code: .operationCancelled,
                    message: "Loading partial-load.pcapng was cancelled after 2 packets."
                )
            ),
            inspections: Dictionary(uniqueKeysWithValues: packets.map { ($0.id, makeInspection(for: $0)) })
        )
        let controller = PacketryWindowController(
            services: PacketryServiceRegistry(core: FakePacketryCore(
                interfaceInventories: [[makeInterface(id: "en0", displayName: "Wi-Fi")]],
                documentFactory: { _ in document }
            ))
        )

        await controller.openDocument(at: url)
        await waitUntil {
            controller.snapshot.documentState.phase == .loaded &&
            controller.snapshot.documentState.isPartialResult
        }

        #expect(controller.snapshot.packetIngestState.totalPacketCount == 2)
        #expect(controller.snapshot.documentState.packetCount == 2)
        #expect(controller.snapshot.documentState.isPartialResult)
        #expect(controller.snapshot.documentState.canSave == false)
        #expect(controller.snapshot.documentState.canSaveAs == false)
        #expect(controller.snapshot.loadState.progress.phase == .cancelled)
        #expect(controller.snapshot.loadState.progress.isPartialResult)

        controller.selectPacket(packets[0].id)
        await waitUntil {
            controller.snapshot.inspectionState.inspection?.packetID == packets[0].id
        }
        #expect(controller.snapshot.inspectionState.inspection?.packetID == packets[0].id)

        await tearDown(controller)
    }

    private func makeInterface(
        id: String,
        displayName: String,
        isLoopback: Bool = false,
        availability: CaptureInterfaceAvailability = .available,
        reason: String? = nil,
        canCapture: Bool = true,
        supportsPromiscuousMode: Bool? = nil
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
                supportsPromiscuousMode: supportsPromiscuousMode ?? !isLoopback,
                requiresBPFPermissionSetup: true,
                providesMacOSMetadata: true
            )
        )
    }

    private func makePacket(
        packetNumber: UInt64,
        source: CaptureSource,
        transportHint: TransportProtocolHint,
        layers: [PacketLayer]? = nil
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
            layers: layers ?? [PacketLayer(name: "Ethernet"), PacketLayer(name: source == .live ? "IPv4" : "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false)
        )
    }

    private func makeInspection(
        for packet: PacketSummary,
        detailNodes: [PacketDetailNode]? = nil
    ) -> PacketInspection {
        PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: UInt8(packet.packetNumber), count: 64),
            detailNodes: detailNodes ?? [
                PacketDetailNode(
                    id: "frame",
                    name: "Frame",
                    value: "Packet \(packet.packetNumber)",
                    kind: .layer,
                    children: [
                        PacketDetailNode(id: "frame.number", name: "Frame Number", value: "\(packet.packetNumber)")
                    ]
                )
            ],
            decodeStatus: packet.decodeStatus
        )
    }

    private func settleEventLoop() async {
        for _ in 0..<5 {
            await Task.yield()
        }
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

            await settleEventLoop()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func tearDown(_ controller: PacketryWindowController) async {
        controller.cancelBackgroundWork()
        await settleEventLoop()
        await settleEventLoop()
    }
}

private final class FakePacketryCore: PacketryCoreProviding, @unchecked Sendable {
    private let interfaceInventories: [[CaptureInterfaceSummary]]
    private let liveSession: FakeLiveSession
    private let documentFactory: (URL) -> FakeOfflineDocument
    private let captureFilterValidator: (String) -> CaptureFilterValidation
    private var interfaceCallCount = 0

    private(set) var liveSessionRequests: [(interfaceID: String, options: CaptureOptions)] = []

    init(
        interfaceInventories: [[CaptureInterfaceSummary]],
        liveSession: FakeLiveSession = FakeLiveSession(),
        documentFactory: @escaping (URL) -> FakeOfflineDocument = { url in
            FakeOfflineDocument(
                url: url,
                metadata: CaptureDocumentMetadata(format: .pcapng),
                openPlan: .completed([])
            )
        },
        captureFilterValidator: @escaping (String) -> CaptureFilterValidation = { expression in
            let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureFilterValidation(
                disposition: trimmed.isEmpty ? .invalid : .valid,
                normalizedExpression: trimmed.isEmpty ? nil : trimmed,
                message: trimmed.isEmpty ? "Capture filters cannot be empty." : nil
            )
        }
    ) {
        self.interfaceInventories = interfaceInventories
        self.liveSession = liveSession
        self.documentFactory = documentFactory
        self.captureFilterValidator = captureFilterValidator
    }

    func listInterfaces() async throws -> [CaptureInterfaceSummary] {
        guard !interfaceInventories.isEmpty else {
            return []
        }

        let index = min(interfaceCallCount, interfaceInventories.count - 1)
        interfaceCallCount += 1
        return interfaceInventories[index]
    }

    func validateCaptureFilter(_ expression: String) async -> CaptureFilterValidation {
        captureFilterValidator(expression)
    }

    func validateCaptureOptions(_ options: CaptureOptions, for interface: CaptureInterfaceSummary?) throws -> CaptureOptions {
        try options.validated(for: interface)
    }

    func makeLiveCaptureSession(interfaceID: String, options: CaptureOptions) async throws -> any LiveCaptureSessionProviding {
        liveSessionRequests.append((interfaceID: interfaceID, options: options))
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

    var inspections: [PacketSummary.ID: PacketInspection] = [:]
    var stopError: Error?
    private(set) var startCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var latestHealthSnapshot = CaptureHealthSnapshot.empty

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
        if let stopError {
            throw stopError
        }
    }

    func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        guard let inspection = inspections[id] else {
            throw PacketryCoreError(code: .liveSessionControlFailed, message: "Missing inspection for packet \(id).")
        }
        return inspection
    }

    func healthSnapshot() async -> CaptureHealthSnapshot {
        latestHealthSnapshot
    }

    func send(_ event: PacketIngestEvent) {
        if case .healthChanged(let health) = event {
            latestHealthSnapshot = health
        }
        pipe.yield(event)
    }
}

private final class FakeOfflineDocument: OfflineCaptureDocumentProviding, @unchecked Sendable {
    struct LoadPlan {
        var batches: [[PacketSummary]]
        var progress: [PacketLoadProgress]
        var error: PacketryCoreError?
        var gate: AsyncGate? = nil

        static func completed(_ packets: [PacketSummary]) -> LoadPlan {
            LoadPlan(
                batches: packets.isEmpty ? [] : [packets],
                progress: [],
                error: nil,
                gate: nil
            )
        }
    }

    private let pipe = EventPipe<PacketIngestEvent>()

    private(set) var url: URL
    private(set) var metadata: CaptureDocumentMetadata
    private(set) var packets: [PacketSummary] = []
    private let openPlan: LoadPlan
    private let reopenPlan: LoadPlan
    private let inspections: [PacketSummary.ID: PacketInspection]

    private(set) var saveCount = 0
    private(set) var saveAsRequests: [(URL, CaptureFileFormat)] = []
    private(set) var cancelLoadingCount = 0
    private(set) var currentProgress: PacketLoadProgress = .idle

    init(
        url: URL,
        metadata: CaptureDocumentMetadata,
        openPlan: LoadPlan,
        reopenPlan: LoadPlan? = nil,
        inspections: [PacketSummary.ID: PacketInspection] = [:]
    ) {
        self.url = url
        self.metadata = metadata
        self.openPlan = openPlan
        self.reopenPlan = reopenPlan ?? openPlan
        self.inspections = inspections
    }

    func events() -> AsyncThrowingStream<PacketIngestEvent, Error> {
        pipe.stream
    }

    func open() async throws -> [PacketSummary] {
        try await run(openPlan, verb: "Loaded")
    }

    func reopen() async throws -> [PacketSummary] {
        try await run(reopenPlan, verb: "Reloaded")
    }

    func cancelLoading() async {
        cancelLoadingCount += 1
    }

    func inspectPacket(id: PacketSummary.ID) async throws -> PacketInspection {
        if let inspection = inspections[id] {
            return inspection
        }

        guard let packet = packets.first(where: { $0.id == id }) else {
            throw PacketryCoreError(code: .offlineFileOpenFailed, message: "Missing packet \(id).")
        }

        return PacketInspection(
            packetID: packet.id,
            packetNumber: packet.packetNumber,
            rawBytes: Data(repeating: 0xAB, count: 32),
            detailNodes: [
                PacketDetailNode(id: "frame", name: "Frame", value: "Packet \(packet.packetNumber)", kind: .layer)
            ],
            decodeStatus: packet.decodeStatus
        )
    }

    func save() async throws {
        if currentProgress.isPartialResult {
            throw PacketryCoreError(
                code: .offlineFileSaveFailed,
                message: "Packetry cannot save a partially loaded capture. Reload the file to finish loading first."
            )
        }

        saveCount += 1
        pipe.yield(.documentMetadataChanged(metadata))
        pipe.yield(.documentStateChanged(phase: .saved, message: "Saved \(url.lastPathComponent)."))
    }

    func save(to url: URL, format: CaptureFileFormat) async throws {
        if currentProgress.isPartialResult {
            throw PacketryCoreError(
                code: .offlineFileSaveFailed,
                message: "Packetry cannot save a partially loaded capture. Reload the file to finish loading first."
            )
        }

        saveAsRequests.append((url, format))
        self.url = url
        metadata = CaptureDocumentMetadata(
            format: format,
            operatingSystem: format == .pcapng ? metadata.operatingSystem : nil,
            hardware: format == .pcapng ? metadata.hardware : nil,
            captureApplication: format == .pcapng ? metadata.captureApplication : nil,
            fileComment: format == .pcapng ? metadata.fileComment : nil
        )

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

    func loadProgress() async -> PacketLoadProgress {
        currentProgress
    }

    private func run(_ plan: LoadPlan, verb: String) async throws -> [PacketSummary] {
        packets = []
        currentProgress = PacketLoadProgress(
            phase: .loading,
            loadedPacketCount: 0,
            message: "\(verb == "Loaded" ? "Opening" : "Reopening") \(url.lastPathComponent)..."
        )

        pipe.yield(.documentMetadataChanged(metadata))
        pipe.yield(.packetBatch([], disposition: .replace))
        if let gate = plan.gate {
            await gate.wait()
        }

        for (index, batch) in plan.batches.enumerated() {
            packets.append(contentsOf: batch)
            pipe.yield(.packetBatch(batch, disposition: .append))

            if index < plan.progress.count {
                currentProgress = plan.progress[index]
                pipe.yield(.loadProgressChanged(currentProgress))
            }
        }

        if let error = plan.error {
            if plan.progress.isEmpty {
                currentProgress = PacketLoadProgress(
                    phase: error.code == .operationCancelled ? .cancelled : .failed,
                    loadedPacketCount: packets.count,
                    isPartialResult: !packets.isEmpty,
                    message: error.message
                )
                pipe.yield(.loadProgressChanged(currentProgress))
            }
            throw error
        }

        if currentProgress.phase != .completed {
            currentProgress = PacketLoadProgress(
                phase: .completed,
                loadedPacketCount: packets.count,
                isPartialResult: false,
                message: "\(verb) \(packets.count) packets from \(url.lastPathComponent)."
            )
            pipe.yield(.loadProgressChanged(currentProgress))
        }

        pipe.yield(.documentStateChanged(phase: .loaded, message: currentProgress.message))
        return packets
    }

    func send(_ event: PacketIngestEvent) {
        pipe.yield(event)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waitingContinuations = continuations
        continuations.removeAll()
        waitingContinuations.forEach { $0.resume() }
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

    deinit {
        continuation.finish()
    }

    func yield(_ element: Element) {
        continuation.yield(element)
    }
}
