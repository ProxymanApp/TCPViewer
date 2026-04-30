import Foundation
import Testing
@testable import PcapPlusPlusCore

struct CoreFacadeTypesTests {

    @Test func pinnedIntegrationMetadataMatchesRepositoryDecision() {
        #expect(PcapPlusPlusCoreModule.plannedVendorPath == "Vendor/PcapPlusPlus")
        #expect(PcapPlusPlusCoreModule.pinnedTag == "v25.05")
        #expect(PcapPlusPlusCoreModule.pinnedCommit == "a49a79e0b67b402ad75ffa96c1795def36df75c8")
        #expect(PcapPlusPlusCoreModule.wiresharkVendorPath == "Vendor/Wireshark")
        #expect(PcapPlusPlusCoreModule.wiresharkPinnedTag == "v4.6.4")
        #expect(PcapPlusPlusCoreModule.wiresharkPinnedCommit == "93282876538d78a2927108dd71ee0ff370aedb0a")
    }

    @Test func unconfiguredCoreRejectsEmptyCaptureFilter() async {
        let validation = await UnconfiguredTCPViewerCore().validateCaptureFilter("   ")

        #expect(validation.disposition == .invalid)
        #expect(validation.normalizedExpression == nil)
    }

    @Test func unconfiguredCoreNormalizesNonEmptyCaptureFilter() async {
        let validation = await UnconfiguredTCPViewerCore().validateCaptureFilter(" tcp port 443 ")

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

    @Test func captureDefaultsDisablePromiscuousModeWhenUnsupported() {
        let interface = makeInterface(
            id: "en0",
            technicalName: "en0",
            displayName: "Wi-Fi",
            supportsPromiscuousMode: false
        )

        let defaults = CaptureOptions.defaults(for: interface)

        #expect(!defaults.promiscuousMode)
    }

    @Test func validationCoercesLoopbackPromiscuousOverride() throws {
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

        let validatedOptions = try invalidOptions.validated(for: loopback)

        #expect(!validatedOptions.promiscuousMode)
    }

    @Test func validationCoercesUnsupportedPromiscuousRequest() throws {
        let interface = makeInterface(
            id: "en0",
            technicalName: "en0",
            displayName: "Wi-Fi",
            supportsPromiscuousMode: false
        )
        let options = CaptureOptions(
            promiscuousMode: true,
            snapshotLength: 65_535,
            kernelBufferSizeBytes: 4 * 1024 * 1024,
            readTimeoutMilliseconds: 250,
            stopCondition: .manual
        )

        let validatedOptions = try options.validated(for: interface)

        #expect(!validatedOptions.promiscuousMode)
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

    @Test func exportFormatNormalizationFallsBackToPcapng() {
        #expect(CaptureFileFormat(exportRawValue: "pcap") == .pcap)
        #expect(CaptureFileFormat(exportRawValue: "PCAPNG") == .pcapng)
        #expect(CaptureFileFormat(exportRawValue: nil) == .pcapng)
        #expect(CaptureFileFormat(exportRawValue: "bad-format") == .pcapng)
    }

    @Test func liveCaptureDurationTimerPreservesRemainingTimeAcrossPause() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = LiveCaptureDurationStopTimer(durationMilliseconds: 10_000)

        #expect(timer.scheduleDelay(now: start) == 10_000)
        #expect(timer.pause(now: start.addingTimeInterval(3)) == 7_000)
        #expect(timer.scheduleDelay(now: start.addingTimeInterval(20)) == 7_000)

        #expect(timer.pause(now: start.addingTimeInterval(24)) == 3_000)
        timer.reset()
        #expect(timer.scheduleDelay(now: start.addingTimeInterval(30)) == 10_000)
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

    @Test func friendlyInterfaceNamePrefersSystemNameAndKeepsBSDName() {
        let name = NativeBridgeMapper.friendlyInterfaceName(
            technicalName: "en0",
            pcapDescription: "en0",
            isLoopback: false,
            linkType: .ethernet,
            systemInterfaceName: "Wi-Fi"
        )

        #expect(name == "Wi-Fi (en0)")
    }

    @Test func friendlyInterfaceNameFallsBackToCaptureDescription() {
        let name = NativeBridgeMapper.friendlyInterfaceName(
            technicalName: "en5",
            pcapDescription: "USB 10/100/1000 LAN",
            isLoopback: false,
            linkType: .ethernet
        )

        #expect(name == "USB 10/100/1000 LAN (en5)")
    }

    @Test func friendlyInterfaceNameNamesCommonGroupedAndVirtualInterfaces() {
        #expect(NativeBridgeMapper.friendlyInterfaceName(
            technicalName: "pktap0",
            pcapDescription: nil,
            isLoopback: false,
            linkType: .ethernet
        ) == "All Interfaces (pktap0)")
        #expect(NativeBridgeMapper.friendlyInterfaceName(
            technicalName: "utun2",
            pcapDescription: nil,
            isLoopback: false,
            linkType: .raw
        ) == "VPN Tunnel (utun2)")
        #expect(NativeBridgeMapper.friendlyInterfaceName(
            technicalName: "lo0",
            pcapDescription: nil,
            isLoopback: true,
            linkType: .loopback
        ) == "Loopback (lo0)")
    }

    @Test func unconfiguredCoreDeclaresOfflineFormats() {
        #expect(UnconfiguredTCPViewerCore().supportedOfflineFormats() == [.pcap, .pcapng])
    }

    private func makeInterface(
        id: String,
        technicalName: String? = nil,
        displayName: String = "Interface",
        isLoopback: Bool = false,
        availability: CaptureInterfaceAvailability = .available,
        reason: String? = nil,
        canCapture: Bool = true,
        supportsPromiscuousMode: Bool? = nil
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
                supportsPromiscuousMode: supportsPromiscuousMode ?? !isLoopback,
                requiresBPFPermissionSetup: true,
                providesMacOSMetadata: true
            )
        )
    }
}
