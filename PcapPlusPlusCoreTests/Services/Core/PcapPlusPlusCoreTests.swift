import Foundation
import Testing
@testable import PcapPlusPlusCore

@Suite(.serialized)
struct PcapPlusPlusCoreTests {

    @Test func nativeCoreLoadsTcpFixtureAndMatchesGolden() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("tcp").appendingPathComponent("tcp-reassembly.pcap")
        let golden = try loadSummaryGolden(named: "tcp-reassembly.summary.json")

        let packets = try await fallbackCore().loadPacketSummaries(from: fixtureURL)

        #expect(packets.count == golden.expectedPacketCount)
        #expect(Set(packets.map(\.source)) == [.offline])
        #expect(packets.contains { golden.expectedTransportHints.contains($0.transportHint.rawValue) })
        #expect(packets.allSatisfy { !$0.infoSummary.isEmpty })
        #expect(packets.allSatisfy { !$0.layers.isEmpty })
    }

    @Test func nativeCoreLoadsUdpPcapngFixtureAndMatchesGolden() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("udp").appendingPathComponent("someip-sd.pcapng")
        let golden = try loadSummaryGolden(named: "someip-sd.summary.json")

        let document = try await fallbackCore().openOfflineCaptureDocument(at: fixtureURL)
        let packets = try await document.open()
        let metadata = await document.currentMetadata()

        #expect(packets.count == golden.expectedPacketCount)
        #expect(metadata.format == .pcapng)
        #expect(packets.contains { golden.expectedTransportHints.contains($0.transportHint.rawValue) })
        #expect(packets.contains { $0.endpoints.source.port != nil })
    }

    @Test func nativeCoreMapsTlsClientHelloSNIOnlyWhenPresent() async throws {
        let tlsFixtureURL = CoreFixtureCatalog.captureCategoryURL("tls").appendingPathComponent("SSL-ClientHello1.pcap")
        let splitTLSFixtureURL = CoreFixtureCatalog.captureCategoryURL("tls").appendingPathComponent("SSL-ClientHello1-split.pcap")
        let udpFixtureURL = CoreFixtureCatalog.captureCategoryURL("udp").appendingPathComponent("someip-sd.pcapng")

        let core = fallbackCore()
        let tlsPackets = try await core.loadPacketSummaries(from: tlsFixtureURL)
        let splitTLSPackets = try await core.loadPacketSummaries(from: splitTLSFixtureURL)
        let udpPackets = try await core.loadPacketSummaries(from: udpFixtureURL)

        #expect(tlsPackets.contains { $0.sniDomainName == "www.google.com" })
        #expect(splitTLSPackets.contains { $0.sniDomainName == "www.google.com" })
        #expect(udpPackets.allSatisfy { $0.sniDomainName == nil })
    }

    @Test func malformedFixtureSurfacesDecodeIssuesExplicitly() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("malformed").appendingPathComponent("partial-http-request.pcap")
        let golden = try loadMalformedGolden(named: "ipv4-malformed.summary.json")

        let packets = try await fallbackCore().loadPacketSummaries(from: fixtureURL)

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
        let core = fallbackCore()
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

    @Test func failedSaveAsPcapPreservesExistingDestinationFile() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("macos-metadata").appendingPathComponent("many-interfaces-1.pcapng")
        let core = fallbackCore()
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let document = try await core.openOfflineCaptureDocument(at: fixtureURL)
        _ = try await document.open()

        let destinationURL = tempDirectory.appendingPathComponent("existing-output.pcap")
        let originalContents = Data("existing destination".utf8)
        try originalContents.write(to: destinationURL)

        var didThrow = false
        do {
            try await document.save(to: destinationURL, format: .pcap)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: destinationURL) == originalContents)
    }

    @Test func offlineDocumentExportsSelectedPacketsAsPcapAndPcapng() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("tls").appendingPathComponent("SSL-ClientHello1.pcap")
        let core = fallbackCore()
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let document = try await core.openOfflineCaptureDocument(at: fixtureURL)
        let packets = try await document.open()
        let selectedPackets = Array(packets.prefix(2))
        let selectedIDs = selectedPackets.map(\.id)
        let originalInspections = try await selectedIDs.asyncMap { try await document.inspectPacket(id: $0) }

        let pcapngURL = tempDirectory.appendingPathComponent("selected.pcapng")
        try await document.exportPackets(withIDs: selectedIDs, to: pcapngURL, format: .pcapng)
        let reopenedPcapng = try await core.openOfflineCaptureDocument(at: pcapngURL)
        let pcapngPackets = try await reopenedPcapng.open()
        let pcapngInspections = try await pcapngPackets.map(\.id).asyncMap { try await reopenedPcapng.inspectPacket(id: $0) }

        #expect(pcapngPackets.count == selectedPackets.count)
        #expect(pcapngPackets.map(\.timestamp) == selectedPackets.map(\.timestamp))
        #expect(pcapngInspections.map(\.rawBytes) == originalInspections.map(\.rawBytes))

        let pcapURL = tempDirectory.appendingPathComponent("selected.pcap")
        try await document.exportPackets(withIDs: selectedIDs, to: pcapURL, format: .pcap)
        let pcapHeader = try Data(contentsOf: pcapURL).prefix(4)
        #expect([
            Data([0xd4, 0xc3, 0xb2, 0xa1]),
            Data([0xa1, 0xb2, 0xc3, 0xd4]),
            Data([0x4d, 0x3c, 0xb2, 0xa1]),
            Data([0xa1, 0xb2, 0x3c, 0x4d]),
        ].contains(Data(pcapHeader)))

        let reopenedPcap = try await core.openOfflineCaptureDocument(at: pcapURL)
        let pcapPackets = try await reopenedPcap.open()
        let pcapInspections = try await pcapPackets.map(\.id).asyncMap { try await reopenedPcap.inspectPacket(id: $0) }
        #expect(pcapPackets.count == selectedPackets.count)
        #expect(pcapPackets.map(\.timestamp) == selectedPackets.map(\.timestamp))
        #expect(pcapInspections.map(\.rawBytes) == originalInspections.map(\.rawBytes))
    }

    @Test func exportFailuresDoNotReplaceExistingDestination() async throws {
        let fixtureURL = CoreFixtureCatalog.captureCategoryURL("tls").appendingPathComponent("SSL-ClientHello1.pcap")
        let core = fallbackCore()
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let document = try await core.openOfflineCaptureDocument(at: fixtureURL)
        _ = try await document.open()
        let destinationURL = tempDirectory.appendingPathComponent("existing.pcapng")
        let originalContents = Data("existing export".utf8)
        try originalContents.write(to: destinationURL)

        do {
            try await document.exportPackets(withIDs: [UInt64.max], to: destinationURL, format: .pcapng)
            Issue.record("Expected export to fail for a missing packet identifier.")
        } catch {
            #expect(try Data(contentsOf: destinationURL) == originalContents)
        }

        do {
            try await document.exportPackets(withIDs: [], to: destinationURL, format: .pcapng)
            Issue.record("Expected export to fail for an empty packet selection.")
        } catch {
            #expect(try Data(contentsOf: destinationURL) == originalContents)
        }
    }

    @Test func nativeLiveSessionCanStopBeforeStart() async throws {
        let core = fallbackCore()
        guard let captureInterface = try await core.listInterfaces().first(where: \.isSelectable) else {
            return
        }

        let session = try await core.makeLiveCaptureSession(
            interfaceID: captureInterface.id,
            options: CaptureOptions.defaults(for: captureInterface)
        )

        try await session.stop()
    }

    private func loadSummaryGolden(named fileName: String) throws -> SummaryGolden {
        let url = CoreFixtureCatalog.fixturesRoot
            .appendingPathComponent("goldens", isDirectory: true)
            .appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SummaryGolden.self, from: data)
    }

    private func fallbackCore() -> NativeTCPViewerCore {
        NativeTCPViewerCore(disablesWiresharkForOfflineDocuments: true, disablesWiresharkForLiveSessions: true)
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension Array {
    func asyncMap<Transformed>(_ transform: (Element) async throws -> Transformed) async throws -> [Transformed] {
        var values: [Transformed] = []
        values.reserveCapacity(count)
        for element in self {
            let value = try await transform(element)
            values.append(value)
        }
        return values
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
