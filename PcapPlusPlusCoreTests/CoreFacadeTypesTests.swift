import Foundation
import Testing
@testable import PcapPlusPlusCore

struct CoreFacadeTypesTests {

    @Test func pinnedIntegrationMetadataMatchesRepositoryDecision() {
        #expect(PcapPlusPlusCoreModule.plannedVendorPath == "Vendor/PcapPlusPlus")
        #expect(PcapPlusPlusCoreModule.pinnedTag == "v25.05")
        #expect(PcapPlusPlusCoreModule.pinnedCommit == "a49a79e0b67b402ad75ffa96c1795def36df75c8")
    }

    @Test func unconfiguredCoreRejectsEmptyCaptureFilter() async {
        let validation = await UnconfiguredPacketryCore().validateCaptureFilter("   ")

        #expect(validation.disposition == .invalid)
        #expect(validation.normalizedExpression == nil)
    }

    @Test func unconfiguredCoreNormalizesNonEmptyCaptureFilter() async {
        let validation = await UnconfiguredPacketryCore().validateCaptureFilter(" tcp port 443 ")

        #expect(validation.disposition == .unavailable)
        #expect(validation.normalizedExpression == "tcp port 443")
    }

    @Test func captureDefaultsDisablePromiscuousModeForLoopback() {
        let loopback = makeInterface(
            id: "lo0",
            technicalName: "lo0",
            displayName: "Loopback",
            isLoopback: true
        )

        let loopbackDefaults = CaptureOptions.defaults(for: loopback)
        let ethernetDefaults = CaptureOptions.defaults(for: makeInterface(id: "en0"))

        #expect(!loopbackDefaults.promiscuousMode)
        #expect(ethernetDefaults.promiscuousMode)
        #expect(loopbackDefaults.snapshotLength == 65_535)
        #expect(loopbackDefaults.kernelBufferSizeBytes == 4 * 1024 * 1024)
        #expect(loopbackDefaults.readTimeoutMilliseconds == 250)
    }

    @Test func loopbackValidationRejectsPromiscuousOverride() throws {
        let loopback = makeInterface(
            id: "lo0",
            technicalName: "lo0",
            displayName: "Loopback",
            isLoopback: true
        )
        let invalidOptions = CaptureOptions(
            promiscuousMode: true,
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            stopCondition: .manual
        )

        #expect(throws: PacketryCoreError.self) {
            try invalidOptions.validated(for: loopback)
        }
    }

    @Test func rotatingAndRingWritersDefaultToPcapngWhenNormalized() {
        let rotating = CaptureOptions(
            promiscuousMode: true,
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            stopCondition: .manual,
            fileWriting: CaptureFileWriting(
                mode: .rotating,
                directoryURL: URL(fileURLWithPath: "/tmp"),
                fileNameStem: "session",
                format: nil,
                maxFileSizeBytes: 1_024_000
            )
        )
        let ring = CaptureOptions(
            promiscuousMode: true,
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            stopCondition: .manual,
            fileWriting: CaptureFileWriting(
                mode: .ring,
                directoryURL: URL(fileURLWithPath: "/tmp"),
                fileNameStem: "session",
                format: nil,
                maxFileSizeBytes: 1_024_000,
                ringFileCount: 4
            )
        )

        #expect(rotating.normalizedForLiveCapture().fileWriting.format == .pcapng)
        #expect(ring.normalizedForLiveCapture().fileWriting.format == .pcapng)
    }

    @Test func interfaceSortingPrefersSelectableEthernetThenLoopbackThenUnavailable() {
        let sorted = NativeBridgeMapper.sortedInterfaces([
            makeInterface(
                id: "utun0",
                technicalName: "utun0",
                displayName: "Tunnel",
                availability: .unavailable,
                reason: "Inactive service."
            ),
            makeInterface(
                id: "lo0",
                technicalName: "lo0",
                displayName: "Loopback",
                isLoopback: true
            ),
            makeInterface(
                id: "en0",
                technicalName: "en0",
                displayName: "Wi-Fi"
            ),
            makeInterface(
                id: "bridge0",
                technicalName: "bridge0",
                displayName: "Bridge",
                availability: .hidden,
                canCapture: false
            ),
            makeInterface(
                id: "awdl0",
                technicalName: "awdl0",
                displayName: "AWDL",
                availability: .unsupported,
                canCapture: false
            ),
        ])

        #expect(sorted.map(\.id) == ["en0", "lo0", "bridge0", "utun0", "awdl0"])
    }

    @Test func unconfiguredCoreDeclaresOfflineFormats() {
        #expect(UnconfiguredPacketryCore().supportedOfflineFormats() == [.pcap, .pcapng])
    }

    private func makeInterface(
        id: String,
        technicalName: String? = nil,
        displayName: String = "Interface",
        isLoopback: Bool = false,
        availability: CaptureInterfaceAvailability = .available,
        reason: String? = nil,
        canCapture: Bool = true
    ) -> CaptureInterfaceSummary {
        CaptureInterfaceSummary(
            id: id,
            technicalName: technicalName ?? id,
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
}
