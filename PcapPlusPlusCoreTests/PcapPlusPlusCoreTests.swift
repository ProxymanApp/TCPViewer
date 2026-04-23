import Foundation
import Testing
@testable import PcapPlusPlusCore

struct PcapPlusPlusCoreTests {

    @Test func nativeCoreLoadsTcpFixtureAndMatchesGolden() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("tcp").appendingPathComponent("tcp-reassembly.pcap")
        let golden = try loadSummaryGolden(named: "tcp-reassembly.summary.json")

        let packets = try await NativePacketryCore().loadPacketSummaries(from: fixtureURL)

        #expect(packets.count == golden.expectedPacketCount)
        #expect(Set(packets.map(\.source)) == [.offline])
        #expect(packets.contains { golden.expectedTransportHints.contains($0.transportHint.rawValue) })
        #expect(packets.allSatisfy { !$0.infoSummary.isEmpty })
        #expect(packets.allSatisfy { !$0.layers.isEmpty })
    }

    @Test func nativeCoreLoadsUdpPcapngFixtureAndMatchesGolden() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("udp").appendingPathComponent("someip-sd.pcapng")
        let golden = try loadSummaryGolden(named: "someip-sd.summary.json")

        let document = try await NativePacketryCore().openOfflineCaptureDocument(at: fixtureURL)
        let packets = try await document.open()
        let metadata = await document.currentMetadata()

        #expect(packets.count == golden.expectedPacketCount)
        #expect(metadata.format == .pcapng)
        #expect(packets.contains { golden.expectedTransportHints.contains($0.transportHint.rawValue) })
        #expect(packets.contains { $0.endpoints.source.port != nil })
    }

    @Test func malformedFixtureSurfacesDecodeIssuesExplicitly() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("malformed").appendingPathComponent("partial-http-request.pcap")
        let golden = try loadMalformedGolden(named: "ipv4-malformed.summary.json")

        let packets = try await NativePacketryCore().loadPacketSummaries(from: fixtureURL)

        #expect(packets.count == golden.expectedPacketCount)
        #expect(packets.filter { $0.decodeStatus.kind != .complete }.count == golden.expectedIssueCount)
        #expect(packets.allSatisfy { golden.expectedDecodeKinds.contains($0.decodeStatus.kind.rawValue) })
        #expect(packets.contains { $0.captureMetadata.isTruncated || $0.decodeStatus.kind == .partial })
    }

    @Test func offlineDocumentsRoundTripPcapngMetadataAndDropUnsupportedMetadataInPcap() async throws {
        let metadataFixtureURL = CoreFixtureCatalog.captureCategoryURL("macos-metadata").appendingPathComponent("many-interfaces-1.pcapng")
        let metadataGolden = try loadMetadataGolden(named: "many-interfaces-1.metadata.json")
        let pcapFixtureURL = CoreFixtureCatalog.captureCategoryURL("macos-metadata").appendingPathComponent("ipsec.pcapng")
        let pcapGolden = try loadMetadataGolden(named: "ipsec.metadata.json")
        let core = NativePacketryCore()
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let sourceDocument = try await core.openOfflineCaptureDocument(at: metadataFixtureURL)
        let originalPackets = try await sourceDocument.open()
        let originalMetadata = await sourceDocument.currentMetadata()

        #expect(originalPackets.count == metadataGolden.expectedPacketCount)
        #expect(originalMetadata.format == .pcapng)
        #expect(originalMetadata.operatingSystem?.contains(metadataGolden.expectedOperatingSystemContains) == true)
        #expect(originalMetadata.captureApplication?.contains(metadataGolden.expectedCaptureApplicationContains) == true)

        let savedPcapngURL = tempDirectory.appendingPathComponent("roundtrip.pcapng")
        try await sourceDocument.save(to: savedPcapngURL, format: .pcapng)

        let reopenedPcapng = try await core.openOfflineCaptureDocument(at: savedPcapngURL)
        let pcapngPackets = try await reopenedPcapng.open()
        let pcapngMetadata = await reopenedPcapng.currentMetadata()

        #expect(pcapngPackets.count == originalPackets.count)
        #expect(pcapngPackets.map(\.timestamp) == originalPackets.map(\.timestamp))
        #expect(pcapngMetadata.format == .pcapng)
        #expect(pcapngMetadata.operatingSystem == originalMetadata.operatingSystem)
        #expect(pcapngMetadata.captureApplication == originalMetadata.captureApplication)

        let editableCopyURL = tempDirectory.appendingPathComponent("editable-copy.pcapng")
        try fileManager.copyItem(at: metadataFixtureURL, to: editableCopyURL)
        let editableDocument = try await core.openOfflineCaptureDocument(at: editableCopyURL)
        _ = try await editableDocument.open()
        try await editableDocument.save()

        let reopenedEditable = try await core.openOfflineCaptureDocument(at: editableCopyURL)
        let editablePackets = try await reopenedEditable.open()
        #expect(editablePackets.count == originalPackets.count)

        let savedPcapURL = tempDirectory.appendingPathComponent("roundtrip.pcap")
        let pcapSourceDocument = try await core.openOfflineCaptureDocument(at: pcapFixtureURL)
        let pcapSourcePackets = try await pcapSourceDocument.open()
        let pcapSourceMetadata = await pcapSourceDocument.currentMetadata()
        #expect(pcapSourcePackets.count == pcapGolden.expectedPacketCount)
        #expect(pcapSourceMetadata.operatingSystem?.contains(pcapGolden.expectedOperatingSystemContains) == true)
        #expect(pcapSourceMetadata.captureApplication?.contains(pcapGolden.expectedCaptureApplicationContains) == true)
        try await pcapSourceDocument.save(to: savedPcapURL, format: .pcap)

        let reopenedPcap = try await core.openOfflineCaptureDocument(at: savedPcapURL)
        let pcapPackets = try await reopenedPcap.open()
        let pcapMetadata = await reopenedPcap.currentMetadata()

        #expect(pcapPackets.count == pcapSourcePackets.count)
        #expect(pcapPackets.map(\.timestamp) == pcapSourcePackets.map(\.timestamp))
        #expect(pcapMetadata.format == .pcap)
        #expect(isBlank(pcapMetadata.operatingSystem))
        #expect(isBlank(pcapMetadata.captureApplication))
        #expect(isBlank(pcapMetadata.hardware))
        #expect(isBlank(pcapMetadata.fileComment))
    }

    private func loadSummaryGolden(named fileName: String) throws -> SummaryGolden {
        let url = CoreFixtureCatalog.fixturesRoot
            .appendingPathComponent("goldens", isDirectory: true)
            .appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SummaryGolden.self, from: data)
    }

    private func loadMalformedGolden(named fileName: String) throws -> MalformedGolden {
        let url = CoreFixtureCatalog.fixturesRoot
            .appendingPathComponent("goldens", isDirectory: true)
            .appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MalformedGolden.self, from: data)
    }

    private func loadMetadataGolden(named fileName: String) throws -> MetadataGolden {
        let url = CoreFixtureCatalog.fixturesRoot
            .appendingPathComponent("goldens", isDirectory: true)
            .appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MetadataGolden.self, from: data)
    }

    private func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

private struct SummaryGolden: Decodable {
    let fixture: String
    let expectedPacketCount: Int
    let expectedTransportHints: [String]
}

private struct MalformedGolden: Decodable {
    let fixture: String
    let expectedPacketCount: Int
    let expectedIssueCount: Int
    let expectedDecodeKinds: [String]
}

private struct MetadataGolden: Decodable {
    let fixture: String
    let expectedPacketCount: Int
    let expectedOperatingSystemContains: String
    let expectedCaptureApplicationContains: String
}
