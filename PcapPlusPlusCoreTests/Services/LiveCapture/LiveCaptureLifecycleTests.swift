//
//  LiveCaptureLifecycleTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 12/7/26.
//

import Darwin
import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct LiveCaptureLifecycleTests {
    @Test func lifecycleTransitionCancelsAndDrainsRegisteredFollowOperations() {
        let coordinator = LiveTCPFollowOperationCoordinator()
        #expect(coordinator.beginFollow())
        #expect(coordinator.beginFollow())

        let transitionRequested = DispatchSemaphore(value: 0)
        let followOperationsDrained = DispatchSemaphore(value: 0)
        let releaseTransition = DispatchSemaphore(value: 0)
        let transitionFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            transitionRequested.signal()
            coordinator.beginLifecycleTransition()
            followOperationsDrained.signal()
            releaseTransition.wait()
            coordinator.finishLifecycleTransition()
            transitionFinished.signal()
        }

        #expect(transitionRequested.wait(timeout: .now() + 2) == .success)
        let cancellationDeadline = Date().addingTimeInterval(2)
        while !coordinator.shouldCancel && Date() < cancellationDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(coordinator.shouldCancel)
        #expect(!coordinator.beginFollow())

        coordinator.finishFollow()
        #expect(followOperationsDrained.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        coordinator.finishFollow()
        #expect(followOperationsDrained.wait(timeout: .now() + 2) == .success)
        #expect(!coordinator.beginFollow())

        releaseTransition.signal()
        #expect(transitionFinished.wait(timeout: .now() + 2) == .success)
        #expect(coordinator.beginFollow())
        coordinator.finishFollow()
    }

    @Test func startFailureRollsBackAndAllowsRetry() throws {
        let backend = TestLiveCaptureBackend(openFailuresRemaining: 1)
        let session = makeSession(backend: backend)

        do {
            try session.start()
            Issue.record("Expected the first capture open to fail.")
        } catch {
            #expect((error as NSError).localizedDescription.contains("synthetic open failure"))
        }

        try session.start()
        try session.stop()

        #expect(backend.openCount == 2)
        #expect(backend.breakCount == 1)
        #expect(backend.closeCount == 1)
    }

    @Test func startFailureDoesNotAcquireLiveDissectionOwnership() {
        let backend = TestLiveCaptureBackend(openFailuresRemaining: 1)
        var dissectionFactoryCallCount = 0
        let session = PCPPNativeLiveSession(
            interfaceIdentifier: "test0",
            options: makeOptions(),
            captureBackend: backend,
            dissectionSessionFactory: {
                dissectionFactoryCallCount += 1
                return nil
            }
        )

        #expect(throws: NSError.self) {
            try session.start()
        }
        #expect(dissectionFactoryCallCount == 0)
    }

    @Test func fatalPacketReadClosesHandleAndReportsFailureOnce() throws {
        let backend = TestLiveCaptureBackend(queuedReads: [.failure("synthetic read failure")])
        let session = makeSession(backend: backend)
        let failureReported = DispatchSemaphore(value: 0)
        session.errorHandler = { _ in failureReported.signal() }

        try session.start()

        #expect(failureReported.wait(timeout: .now() + 2) == .success)
        #expect(backend.closeCount == 1)
        try session.stop()
        #expect(backend.closeCount == 1)
    }

    @Test func unavailableWiresharkFallsBackWithoutStoppingCapture() throws {
        let packet = Data([0, 1, 2, 3])
        let header = pcap_pkthdr(
            ts: timeval(tv_sec: 1, tv_usec: 0),
            caplen: UInt32(packet.count),
            len: UInt32(packet.count)
        )
        let backend = TestLiveCaptureBackend(queuedReads: [.packet(header: header, bytes: packet)])
        let session = PCPPNativeLiveSession(
            interfaceIdentifier: "test0",
            options: makeOptions(),
            captureBackend: backend,
            dissectionSessionFactory: {
                throw NativeNSError(.unavailableFeature, "synthetic Wireshark failure")
            }
        )
        let packetDelivered = DispatchSemaphore(value: 0)
        session.packetHandler = { _ in packetDelivered.signal() }

        try session.start()
        #expect(packetDelivered.wait(timeout: .now() + 2) == .success)

        let inspection = try session.inspectPacket(withIdentifier: 1)
        #expect(inspection.rawBytes == packet)
        #expect(inspection.detailNodes.contains { $0.fieldName == "tcpviewer.wireshark.fallback" })
        try session.stop()
        #expect(backend.closeCount == 1)
    }

    @Test func shutdownFromCaptureCallbackDoesNotJoinItsOwnQueue() throws {
        let packet = Data([0, 1, 2, 3])
        let header = pcap_pkthdr(
            ts: timeval(tv_sec: 1, tv_usec: 0),
            caplen: UInt32(packet.count),
            len: UInt32(packet.count)
        )
        let backend = TestLiveCaptureBackend(queuedReads: [.packet(header: header, bytes: packet)])
        let session = makeSession(backend: backend)
        let shutdownCompleted = DispatchSemaphore(value: 0)
        session.packetHandler = { [weak session] _ in
            session?.shutdown()
            shutdownCompleted.signal()
        }

        try session.start()

        #expect(shutdownCompleted.wait(timeout: .now() + 2) == .success)
        #expect(backend.breakCount == 1)
        #expect(backend.closeCount == 1)
    }

    @Test func stoppedLiveCaptureReleasesEpanForOfflineInspection() throws {
        let backend = TestLiveCaptureBackend()
        let liveSession = PCPPNativeLiveSession(
            interfaceIdentifier: "test0",
            options: makeOptions(),
            captureBackend: backend,
            dissectionSessionFactory: { try WiresharkEpanSession(purpose: .live) }
        )
        let offlineSession = try WiresharkEpanSession()
        let record = makeUDPPacketRecord()

        try liveSession.start()
        #expect(throws: NSError.self) {
            try offlineSession.observe(record)
        }

        try liveSession.stop()

        try offlineSession.observe(record)
        #expect(try offlineSession.summarize(record).infoSummary.isEmpty == false)
    }

    @Test func captureOptionsRejectValuesThatWouldTrapInt32Conversion() {
        let oversizedSnapshot = CaptureOptions(
            promiscuousMode: false,
            snapshotLength: Int(Int32.max) + 1,
            kernelBufferSizeBytes: 0,
            readTimeoutMilliseconds: 250,
            stopCondition: .manual
        )
        let oversizedTimeout = CaptureOptions(
            promiscuousMode: false,
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 0,
            readTimeoutMilliseconds: Int(Int32.max) + 1,
            stopCondition: .manual
        )

        #expect(throws: TCPViewerCoreError.self) {
            try oversizedSnapshot.validated()
        }
        #expect(throws: TCPViewerCoreError.self) {
            try oversizedTimeout.validated()
        }
    }

    private func makeSession(backend: TestLiveCaptureBackend) -> PCPPNativeLiveSession {
        PCPPNativeLiveSession(
            interfaceIdentifier: "test0",
            options: makeOptions(),
            captureBackend: backend
        )
    }

    private func makeOptions() -> PCPPNativeCaptureOptionsDescriptor {
        PCPPNativeCaptureOptionsDescriptor(
            promiscuousMode: false,
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 0,
            readTimeoutMilliseconds: 50,
            captureFilterExpression: nil,
            stopMode: "manual",
            stopValue: 0,
            fileWritingMode: "disabled",
            captureDirectoryURL: nil,
            fileNameStem: nil,
            fileFormat: nil,
            maxFileSizeBytes: 0,
            ringFileCount: 0
        )
    }

    private func makeUDPPacketRecord() -> NativePacketRecord {
        NativePacketRecord(
            identifier: 1,
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            rawBytes: Data([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
                0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
                0x08, 0x00,
                0x45, 0x00, 0x00, 0x1c, 0x00, 0x01, 0x00, 0x00,
                0x40, 0x11, 0x00, 0x00, 192, 168, 0, 1, 192, 168, 0, 2,
                0x14, 0xe9, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00,
            ]),
            originalLength: 42,
            linkLayerType: Libpcap.dltEthernet,
            interfaceIdentifier: "test0",
            interfaceName: "test0",
            packetComment: nil
        )
    }
}

private final class TestLiveCaptureBackend: PCPPNativeLiveCaptureBackend {
    private let condition = NSCondition()
    private var queuedReads: [LibpcapPacketReadResult]
    private var openFailuresRemaining: Int
    private var didBreak = false
    private var mutableOpenCount = 0
    private var mutableBreakCount = 0
    private var mutableCloseCount = 0

    init(openFailuresRemaining: Int = 0, queuedReads: [LibpcapPacketReadResult] = []) {
        self.openFailuresRemaining = openFailuresRemaining
        self.queuedReads = queuedReads
    }

    var openCount: Int { condition.withLock { mutableOpenCount } }
    var breakCount: Int { condition.withLock { mutableBreakCount } }
    var closeCount: Int { condition.withLock { mutableCloseCount } }

    func open(interfaceName: String, options: PCPPNativeCaptureOptionsDescriptor) throws -> OpaquePointer {
        try condition.withLock {
            mutableOpenCount += 1
            if openFailuresRemaining > 0 {
                openFailuresRemaining -= 1
                throw NativeNSError(.captureStartFailed, "synthetic open failure")
            }
            didBreak = false
            return OpaquePointer(bitPattern: mutableOpenCount)!
        }
    }

    func read(from handle: OpaquePointer) -> LibpcapPacketReadResult {
        condition.lock()
        defer { condition.unlock() }
        if !queuedReads.isEmpty {
            return queuedReads.removeFirst()
        }
        while !didBreak {
            condition.wait()
        }
        return .stopped
    }

    func statistics(for handle: OpaquePointer) -> pcap_stat? {
        pcap_stat()
    }

    func dataLink(for handle: OpaquePointer) -> Int32 {
        Libpcap.dltEthernet
    }

    func breakLoop(_ handle: OpaquePointer) {
        condition.withLock {
            mutableBreakCount += 1
            didBreak = true
            condition.broadcast()
        }
    }

    func close(_ handle: OpaquePointer) {
        condition.withLock {
            mutableCloseCount += 1
        }
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
