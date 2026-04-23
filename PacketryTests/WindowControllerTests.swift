import Foundation
import Testing
@testable import Packetry

@MainActor
struct WindowControllerTests {

    @Test func foundationControllerStartsBlockedOnFirstLaunch() {
        let controller = PacketryWindowController()

        #expect(controller.snapshot.accessState == .blocked(.firstLaunch))
        #expect(controller.snapshot.documentState.phase == .idle)
        #expect(controller.snapshot.sessionState.phase == .idle)
    }

    @Test func documentOpenTransitionsToLoadedState() {
        let controller = PacketryWindowController()
        let url = URL(fileURLWithPath: "/tmp/example.pcapng")

        controller.finishDocumentOpen(packetCount: 7)
        controller.beginDocumentOpen(at: url)

        #expect(controller.snapshot.documentState.phase == .opening)
        #expect(controller.snapshot.documentState.fileURL == url)
        #expect(controller.snapshot.visiblePacketCount == 0)

        controller.finishDocumentOpen(packetCount: 42)
        #expect(controller.snapshot.documentState.phase == .loaded)
        #expect(controller.snapshot.documentState.packetCount == 42)
        #expect(controller.snapshot.documentState.canReopen)
        #expect(controller.snapshot.visiblePacketCount == 42)
    }

    @Test func readyAccessPromotesIdleSessionToReady() {
        let controller = PacketryWindowController()

        controller.beginLaunchChecks()
        controller.finishLaunchChecks(with: .ready)

        #expect(controller.snapshot.accessState == .ready)
        #expect(controller.snapshot.sessionState.phase == .ready)
    }

    @Test func blockedAccessDemotesPreviouslyReadySession() {
        let controller = PacketryWindowController()

        controller.finishLaunchChecks(with: .ready)
        controller.finishLaunchChecks(with: .blocked(.helperBroken))

        #expect(controller.snapshot.accessState == .blocked(.helperBroken))
        #expect(controller.snapshot.sessionState.phase == .idle)
        #expect(controller.snapshot.sessionState.statusMessage == CaptureAccessState.blocked(.helperBroken).detail)
    }
}
