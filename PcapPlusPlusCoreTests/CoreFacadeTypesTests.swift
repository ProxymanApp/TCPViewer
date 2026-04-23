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

    @Test func unconfiguredCoreDeclaresOfflineFormats() {
        #expect(UnconfiguredPacketryCore().supportedOfflineFormats() == [.pcap, .pcapng])
    }
}
