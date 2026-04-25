import Foundation
import Testing
import PcapPlusPlusCore
@testable import TCPViewer

@Suite(.serialized)
struct TCPViewerUserDataDirectoryTests {

    @Test func createsReusableSettingsDirectoryInsideApplicationSupportFolder() throws {
        let baseURL = temporaryDirectory()
        let directory = TCPViewerUserDataDirectory(applicationSupportBaseURL: baseURL)

        #expect(directory.appDirectoryURL == baseURL.appendingPathComponent("TCPViewer", isDirectory: true))
        #expect(directory.settingsDirectoryURL == directory.appDirectoryURL.appendingPathComponent("settings", isDirectory: true))
        #expect(directory.settingsFileURL(named: "PinnedPackets.json") == directory.settingsDirectoryURL.appendingPathComponent("PinnedPackets.json"))

        try directory.createSettingsDirectoryIfNeeded()

        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: directory.settingsDirectoryURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func packetUserDataServicesUseSettingsDirectoryByDefault() throws {
        let baseURL = temporaryDirectory()
        let directory = TCPViewerUserDataDirectory(applicationSupportBaseURL: baseURL)
        let pinService = PacketPinService(userDataDirectory: directory)
        let savedService = SavedPacketService(userDataDirectory: directory)

        let packet = makePacket()
        try pinService.upsertPin(from: packet, kind: .domain, clickedColumn: .domain)
        try savedService.save([packet])

        #expect(FileManager.default.fileExists(atPath: directory.settingsFileURL(named: "PinnedPackets.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.settingsFileURL(named: "SavedPackets.json").path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePacket() -> PacketSummary {
        PacketSummary(
            packetNumber: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            source: .live,
            interfaceID: "en0",
            transportHint: .tcp,
            endpoints: PacketEndpoints(
                source: PacketEndpoint(address: "10.0.0.1", port: 1234),
                destination: PacketEndpoint(address: "10.0.0.2", port: 443)
            ),
            originalLength: 128,
            capturedLength: 128,
            streamID: nil,
            infoSummary: "Packet 1",
            layers: [PacketLayer(name: "Ethernet"), PacketLayer(name: "TCP")],
            decodeStatus: PacketDecodeStatus(kind: .complete),
            captureMetadata: PacketCaptureMetadata(linkType: .ethernet, isTruncated: false),
            sniDomainName: "api.example.com"
        )
    }
}
