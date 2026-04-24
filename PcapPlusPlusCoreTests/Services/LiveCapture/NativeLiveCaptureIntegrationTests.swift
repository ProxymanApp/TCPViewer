import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
final class NativeLiveCaptureIntegrationTests {

    @Test func liveCaptureOnConfiguredInterfaceCapturesAndInspectsRandomPacket() async throws {
        guard let requestedInterfaceID = Self.requestedInterfaceID else {
            return
        }

        let core = NativePacketryCore()
        let interfaces = try await core.listInterfaces()
        let captureInterface = try #require(
            interfaces.first { $0.id == requestedInterfaceID },
            "Set PACKETRY_LIVE_CAPTURE_INTERFACE to an available interface, for example en1."
        )
        guard captureInterface.isSelectable else {
            let message = captureInterface.availabilityReason ?? "\(requestedInterfaceID) is not selectable for live capture."
            Issue.record(Comment(rawValue: message))
            return
        }

        let session = try await core.makeLiveCaptureSession(
            interfaceID: captureInterface.id,
            options: CaptureOptions.defaults(for: captureInterface)
        )
        let probe = LiveCaptureProbe()
        let events = session.events()
        let collector = Task {
            do {
                for try await event in events {
                    await probe.record(event)
                }
            } catch is CancellationError {
            } catch {
                await probe.record(error)
            }
        }
        defer {
            collector.cancel()
        }

        try await session.start()
        try await Task.sleep(for: .seconds(2))
        try await session.stop()

        let packetPool = await waitForCapturedPackets(in: probe, timeout: .seconds(1))
        if let streamError = await probe.streamError() {
            throw streamError
        }

        #expect(!packetPool.isEmpty)
        let packet = try #require(packetPool.randomElement())
        #expect(packet.source == .live)
        #expect(packet.interfaceID == captureInterface.id)
        #expect(packet.capturedLength > 0)

        let inspection = try await session.inspectPacket(id: packet.id)
        #expect(inspection.packetID == packet.id)
        #expect(!inspection.rawBytes.isEmpty)
        #expect(inspection.rawBytes.count == packet.capturedLength)
        #expect(!inspection.detailNodes.isEmpty)
    }

    private static var requestedInterfaceID: String? {
        let value = ProcessInfo.processInfo.environment["PACKETRY_LIVE_CAPTURE_INTERFACE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

private actor LiveCaptureProbe {
    private var packets: [PacketSummary] = []
    private var error: Error?

    func record(_ event: PacketIngestEvent) {
        switch event {
        case .packetBatch(let batch, .append):
            packets.append(contentsOf: batch)
        case .packetBatch(let batch, .replace):
            packets = batch
        case .liveStateChanged, .documentStateChanged, .loadProgressChanged, .healthChanged, .documentMetadataChanged:
            break
        @unknown default:
            break
        }
    }

    func record(_ error: Error) {
        self.error = error
    }

    func packetPool() -> [PacketSummary] {
        packets
    }

    func streamError() -> Error? {
        error
    }
}

private func waitForCapturedPackets(
    in probe: LiveCaptureProbe,
    timeout: Duration,
    pollInterval: Duration = .milliseconds(50)
) async -> [PacketSummary] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
        let packets = await probe.packetPool()
        if !packets.isEmpty {
            return packets
        }

        try? await Task.sleep(for: pollInterval)
    }

    return await probe.packetPool()
}
