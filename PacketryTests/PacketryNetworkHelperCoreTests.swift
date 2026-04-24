import Testing
@testable import Packetry

struct PacketryNetworkHelperCoreTests {

    @Test func missingGroupCreatesGroupAddsAdminUserAndRepairsBPFDevices() {
        let system = FakeNetworkHelperSystem(
            groupExists: false,
            consoleUser: "nghia",
            userIsAdmin: true,
            bpfDevicePaths: ["/dev/bpf0", "/dev/bpf1"]
        )
        let result = PacketryNetworkHelperCore(system: system).run()

        #expect(result.exitCode == .success)
        #expect(system.didCreateGroup)
        #expect(system.addedUsers == ["nghia"])
        #expect(system.permissionTargets == ["/dev/bpf0", "/dev/bpf1"])
    }

    @Test func existingGroupRepairsBPFWithoutCreatingGroupAgain() {
        let system = FakeNetworkHelperSystem(
            groupExists: true,
            consoleUser: "nghia",
            userIsAdmin: true,
            bpfDevicePaths: ["/dev/bpf0"]
        )
        let result = PacketryNetworkHelperCore(system: system).run()

        #expect(result.exitCode == .success)
        #expect(!system.didCreateGroup)
        #expect(system.addedUsers == ["nghia"])
        #expect(system.permissionTargets == ["/dev/bpf0"])
    }

    @Test func nonAdminConsoleUserIsDeniedBeforeChangingBPFDevices() {
        let system = FakeNetworkHelperSystem(
            groupExists: true,
            consoleUser: "guest",
            userIsAdmin: false,
            bpfDevicePaths: ["/dev/bpf0"]
        )
        let result = PacketryNetworkHelperCore(system: system).run()

        #expect(result.exitCode == .notAdmin)
        #expect(system.addedUsers.isEmpty)
        #expect(system.permissionTargets.isEmpty)
    }

    @Test func missingConsoleUserFailsWhenNewGroupNeedsEnrollment() {
        let system = FakeNetworkHelperSystem(
            groupExists: false,
            consoleUser: nil,
            userIsAdmin: true,
            bpfDevicePaths: ["/dev/bpf0"]
        )
        let result = PacketryNetworkHelperCore(system: system).run()

        #expect(result.exitCode == .noConsoleUser)
        #expect(system.didCreateGroup)
        #expect(system.permissionTargets.isEmpty)
    }

    @Test func bpfPermissionFailureReturnsExplicitExitCode() {
        let system = FakeNetworkHelperSystem(
            groupExists: true,
            consoleUser: "nghia",
            userIsAdmin: true,
            bpfDevicePaths: ["/dev/bpf0"],
            applyError: PacketryNetworkHelperSystemError(
                exitCode: .bpfPermissionFailure,
                message: "chmod failed"
            )
        )
        let result = PacketryNetworkHelperCore(system: system).run()

        #expect(result.exitCode == .bpfPermissionFailure)
        #expect(result.message == "chmod failed")
    }
}

private final class FakeNetworkHelperSystem: PacketryNetworkHelperSystem {
    private let groupExistsValue: Bool
    private let consoleUserValue: String?
    private let userIsAdminValue: Bool
    private let bpfDevicePathValues: [String]
    private let applyError: PacketryNetworkHelperSystemError?

    private(set) var didCreateGroup = false
    private(set) var addedUsers: [String] = []
    private(set) var permissionTargets: [String] = []

    init(
        groupExists: Bool,
        consoleUser: String?,
        userIsAdmin: Bool,
        bpfDevicePaths: [String],
        applyError: PacketryNetworkHelperSystemError? = nil
    ) {
        self.groupExistsValue = groupExists
        self.consoleUserValue = consoleUser
        self.userIsAdminValue = userIsAdmin
        self.bpfDevicePathValues = bpfDevicePaths
        self.applyError = applyError
    }

    func captureGroupExists() throws -> Bool {
        groupExistsValue
    }

    func createCaptureGroup() throws {
        didCreateGroup = true
    }

    func currentConsoleUser() -> String? {
        consoleUserValue
    }

    func userIsAdmin(_ username: String) throws -> Bool {
        userIsAdminValue
    }

    func addUserToCaptureGroup(_ username: String) throws {
        addedUsers.append(username)
    }

    func bpfDevicePaths() throws -> [String] {
        bpfDevicePathValues
    }

    func applyCapturePermissions(toDeviceAt path: String) throws {
        if let applyError {
            throw applyError
        }

        permissionTargets.append(path)
    }
}
