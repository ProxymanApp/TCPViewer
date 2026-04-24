import Testing
@testable import Packetry

@MainActor
struct PacketryNetworkHelperToolManagerTests {

    @Test func notRegisteredServiceMapsToNotInstalled() async {
        let service = MockNetworkHelperService(status: .notRegistered)
        let manager = PacketryNetworkHelperToolManager(
            serviceController: service,
            bpfChecker: MockBPFChecker.ready
        )

        let snapshot = await manager.refreshStatus()

        #expect(snapshot.status == .notInstalled)
    }

    @Test func requiresApprovalServiceMapsToWaitingForApproval() async {
        let service = MockNetworkHelperService(status: .requiresApproval)
        let manager = PacketryNetworkHelperToolManager(
            serviceController: service,
            bpfChecker: MockBPFChecker.ready
        )

        let snapshot = await manager.refreshStatus()

        #expect(snapshot.status == .waitingForApproval)
    }

    @Test func enabledServiceWithoutCurrentProcessGroupNeedsRelaunch() async {
        let service = MockNetworkHelperService(status: .enabled)
        let manager = PacketryNetworkHelperToolManager(
            serviceController: service,
            bpfChecker: MockBPFChecker(
                inspection: PacketryNetworkHelperBPFInspection(
                    groupExists: true,
                    deviceCount: 1,
                    expectedPermissionsReady: true,
                    currentProcessHasCaptureGroup: false,
                    currentProcessCanAccessBPF: true,
                    message: "Relaunch required."
                )
            )
        )

        let snapshot = await manager.refreshStatus()

        #expect(snapshot.status == .installedNeedsRelaunch)
    }

    @Test func enabledServiceWithReadyBPFMapsToReady() async {
        let service = MockNetworkHelperService(status: .enabled)
        let manager = PacketryNetworkHelperToolManager(
            serviceController: service,
            bpfChecker: MockBPFChecker.ready
        )

        let snapshot = await manager.refreshStatus()

        #expect(snapshot.status == .ready)
    }

    @Test func enabledServiceWithWrongBPFPermissionsMapsToBroken() async {
        let service = MockNetworkHelperService(status: .enabled)
        let manager = PacketryNetworkHelperToolManager(
            serviceController: service,
            bpfChecker: MockBPFChecker(
                inspection: PacketryNetworkHelperBPFInspection(
                    groupExists: true,
                    deviceCount: 1,
                    expectedPermissionsReady: false,
                    currentProcessHasCaptureGroup: true,
                    currentProcessCanAccessBPF: false,
                    message: "BPF permissions are wrong."
                )
            )
        )

        let snapshot = await manager.refreshStatus()

        #expect(snapshot.status == .broken)
        #expect(snapshot.message == "BPF permissions are wrong.")
    }

    @Test func installRegistersServiceThenRefreshesStatus() async {
        let service = MockNetworkHelperService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let manager = PacketryNetworkHelperToolManager(
            serviceController: service,
            bpfChecker: MockBPFChecker.ready
        )

        let snapshot = await manager.install()

        #expect(service.registerCount == 1)
        #expect(snapshot.status == .waitingForApproval)
    }
}

private final class MockNetworkHelperService: PacketryNetworkHelperServiceControlling {
    var status: PacketryNetworkHelperAuthorizationStatus
    var statusAfterRegister: PacketryNetworkHelperAuthorizationStatus?
    private(set) var registerCount = 0
    private(set) var openSystemSettingsCount = 0

    init(status: PacketryNetworkHelperAuthorizationStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let statusAfterRegister {
            status = statusAfterRegister
        }
    }

    func openSystemSettings() {
        openSystemSettingsCount += 1
    }
}

private struct MockBPFChecker: PacketryNetworkHelperBPFChecking {
    static let ready = MockBPFChecker(
        inspection: PacketryNetworkHelperBPFInspection(
            groupExists: true,
            deviceCount: 1,
            expectedPermissionsReady: true,
            currentProcessHasCaptureGroup: true,
            currentProcessCanAccessBPF: true,
            message: "Ready."
        )
    )

    let inspection: PacketryNetworkHelperBPFInspection

    func inspect() -> PacketryNetworkHelperBPFInspection {
        inspection
    }
}
