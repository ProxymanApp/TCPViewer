import Testing
@testable import Packetry

struct CaptureAccessModelTests {

    @Test func readyStateIsCaptureReady() {
        #expect(CaptureAccessState.ready.isCaptureReady)
        #expect(!CaptureAccessState.ready.requiresGuidance)
    }

    @Test func blockedStateProvidesRecoverySteps() {
        let state = CaptureAccessState.blocked(.helperBroken)

        #expect(state.requiresGuidance)
        #expect(state.title == "Repair Capture Access Helper")
        #expect(state.recommendedSteps.count == 2)
        #expect(state.recommendedSteps.first?.actionLabel == "Repair")
    }

    @Test func recoveringStateSuggestsRetry() {
        let state = CaptureAccessState.recovering

        #expect(state.requiresGuidance)
        #expect(state.recommendedSteps.count == 1)
        #expect(state.recommendedSteps.first?.actionLabel == "Retry")
    }

    @Test func helperNeedsRelaunchExplainsRestartStep() {
        let state = CaptureAccessState.blocked(.helperNeedsRelaunch)

        #expect(state.requiresGuidance)
        #expect(state.title == "Relaunch Packetry")
        #expect(state.recommendedSteps.first?.actionLabel == "Relaunch")
    }
}
