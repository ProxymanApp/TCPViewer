//
//  TCPViewerLicenseServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerLicenseServiceTests {
    @Test func activationSuccessStoresLicenseAndUpdatesStatus() throws {
        let storage = try makeStorage()
        let network = StubLicenseNetworkClient()
        let license = makeLicense(email: "ada@example.com")
        network.registerResult = .success(license)
        let service = makeService(storage: storage, network: network)

        let status = waitForStatus {
            service.activate(licenseKey: " TCPV-KEY \n", completion: $0)
        }

        #expect(status == .authorized(license))
        #expect(service.currentLicense == license)
        #expect(storage.readLicense() == license)
        #expect(network.registeredLicenseKey == "TCPV-KEY")
        #expect(network.registeredDeviceUUID == "device-1")
        #expect(network.registeredBuildNumber == "999")
    }

    @Test func activationRejectsInvalidPrefixBeforeNetworkCall() throws {
        let storage = try makeStorage()
        let network = StubLicenseNetworkClient()
        let service = makeService(storage: storage, network: network)

        let status = waitForStatus {
            service.activate(licenseKey: "BAD-KEY", completion: $0)
        }

        #expect(status == .unauthorized(.invalidLicense))
        #expect(network.registeredLicenseKey == nil)
        #expect(storage.readLicense() == nil)
    }

    @Test func launchVerificationSuccessRefreshesStoredLicense() throws {
        let storage = try makeStorage()
        let oldLicense = makeLicense(email: "old@example.com")
        let updatedLicense = makeLicense(email: "new@example.com")
        try storage.writeLicense(oldLicense)

        let network = StubLicenseNetworkClient()
        network.verifyResult = .success(updatedLicense)
        let service = makeService(storage: storage, network: network)

        let status = waitForStatus {
            service.verifyAtLaunch(completion: $0)
        }

        #expect(status == .authorized(updatedLicense))
        #expect(storage.readLicense() == updatedLicense)
        #expect(network.verifiedSignature == oldLicense.signature)
        #expect(network.verifiedDeviceUUID == "device-1")
    }

    @Test func launchVerificationUsesStoredFallbackDeviceUUID() throws {
        let storage = try makeStorage()
        let license = makeLicense(deviceUUID: "device-2")
        try storage.writeLicense(license)

        let network = StubLicenseNetworkClient()
        network.verifyResult = .success(license)
        let deviceProvider = StubDeviceProvider(deviceIDs: ["device-1", "device-2"])
        let service = makeService(storage: storage, network: network, deviceProvider: deviceProvider)

        let status = waitForStatus {
            service.verifyAtLaunch(completion: $0)
        }

        #expect(status == .authorized(license))
        #expect(network.verifiedDeviceUUID == "device-2")
    }

    @Test func launchVerificationKeepsStoredLicenseWhenOffline() throws {
        let storage = try makeStorage()
        let license = makeLicense()
        try storage.writeLicense(license)

        let network = StubLicenseNetworkClient()
        network.verifyResult = .failure(.noInternetConnection)
        let service = makeService(storage: storage, network: network)

        let status = waitForStatus {
            service.verifyAtLaunch(completion: $0)
        }

        #expect(status == .authorized(license))
        #expect(storage.readLicense() == license)
    }

    @Test func verifyIfNeededWithoutPreviousTimestampVerifiesStoredLicense() throws {
        let storage = try makeStorage()
        let oldLicense = makeLicense(email: "old@example.com")
        let updatedLicense = makeLicense(email: "new@example.com")
        try storage.writeLicense(oldLicense)

        let network = StubLicenseNetworkClient()
        network.verifyResult = .success(updatedLicense)
        let service = makeService(storage: storage, network: network)

        let status = waitForStatus {
            service.verifyIfNeeded(completion: $0)
        }

        #expect(status == .authorized(updatedLicense))
        #expect(network.verifiedSignature == oldLicense.signature)
    }

    @Test func verifyIfNeededSkipsFreshVerification() throws {
        let storage = try makeStorage()
        let license = makeLicense()
        try storage.writeLicense(license)
        let defaults = makeDefaults()
        defaults.set(Date().timeIntervalSince1970, forKey: "TCPViewer.license.lastVerifyTime")

        let network = StubLicenseNetworkClient()
        let service = makeService(storage: storage, network: network, defaults: defaults)

        let status = waitForStatus {
            service.verifyIfNeeded(completion: $0)
        }

        #expect(status == .authorized(license))
        #expect(network.verifiedSignature == nil)
    }

    @Test func onlineRevocationRemovesStoredLicenseOnNextVerification() throws {
        let storage = try makeStorage()
        let license = makeLicense()
        try storage.writeLicense(license)

        let network = StubLicenseNetworkClient()
        network.verifyResult = .failure(.invalidLicense)
        let service = makeService(storage: storage, network: network)

        let status = waitForStatus {
            service.verifyAtLaunch(completion: $0)
        }

        #expect(status == .unauthorized(.invalidLicense))
        #expect(storage.readLicense() == nil)
    }

    @Test func localRevokeAlwaysClearsStoredLicense() throws {
        let storage = try makeStorage()
        let license = makeLicense()
        try storage.writeLicense(license)

        let network = StubLicenseNetworkClient()
        network.revokeResult = .failure(.noInternetConnection)
        let service = makeService(storage: storage, network: network)

        let result = waitForVoid {
            service.revokeCurrentDevice(completion: $0)
        }

        try result.get()
        #expect(storage.readLicense() == nil)
        #expect(service.status == .unauthorized(.invalidLicense))
        #expect(network.revokedSignature == license.signature)
    }

    private func makeService(
        storage: TCPViewerLicenseStorage,
        network: StubLicenseNetworkClient,
        deviceProvider: any TCPViewerLicenseDeviceProviding = StubDeviceProvider(),
        defaults: UserDefaults? = nil
    ) -> TCPViewerLicenseService {
        TCPViewerLicenseService(
            storage: storage,
            networkClient: network,
            deviceProvider: deviceProvider,
            defaults: defaults ?? makeDefaults(),
            buildNumberProvider: { "999" },
            workerQueue: DispatchQueue(label: "TCPViewerLicenseServiceTests-\(UUID().uuidString)")
        )
    }

    private func makeStorage() throws -> TCPViewerLicenseStorage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TCPViewerLicenseServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return TCPViewerLicenseStorage(
            fileURL: directory.appendingPathComponent("receipt.bin"),
            cipher: TCPViewerLicenseCipher(secret: "service-tests-secret")
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TCPViewerLicenseServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeLicense(email: String = "ada@example.com", deviceUUID: String = "device-1") -> TCPViewerLicense {
        TCPViewerLicense(
            signature: "abcdefghijklmnopqrstuvwxyz",
            deviceUUID: deviceUUID,
            email: email,
            purchaseAt: "2026-05-01T10:20:30.123Z",
            expiryDate: "2028-05-01T10:20:30.123Z"
        )
    }

    private func waitForStatus(
        _ start: (@escaping (TCPViewerLicenseStatus) -> Void) -> Void
    ) -> TCPViewerLicenseStatus {
        var status: TCPViewerLicenseStatus?
        let semaphore = DispatchSemaphore(value: 0)
        start {
            status = $0
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + 2) == .success)
        return status ?? .unauthorized(.error("Missing callback"))
    }

    private func waitForVoid(
        _ start: (@escaping (Result<Void, TCPViewerLicenseError>) -> Void) -> Void
    ) -> Result<Void, TCPViewerLicenseError> {
        var result: Result<Void, TCPViewerLicenseError>?
        let semaphore = DispatchSemaphore(value: 0)
        start {
            result = $0
            semaphore.signal()
        }
        #expect(semaphore.wait(timeout: .now() + 2) == .success)
        return result ?? .failure(.error("Missing callback"))
    }
}

private struct StubDeviceProvider: TCPViewerLicenseDeviceProviding {
    let deviceIDs: [String]

    init(deviceIDs: [String] = ["device-1"]) {
        self.deviceIDs = deviceIDs
    }

    func deviceName() -> String {
        "Ada's Mac"
    }

    func hashedDeviceIDs() -> [String] {
        deviceIDs
    }
}

private final class StubLicenseNetworkClient: TCPViewerLicenseNetworkClienting {
    var registerResult: Result<TCPViewerLicense, TCPViewerLicenseError> = .failure(.invalidLicense)
    var verifyResult: Result<TCPViewerLicense, TCPViewerLicenseError> = .failure(.invalidLicense)
    var revokeResult: Result<Void, TCPViewerLicenseError> = .success(())

    var registeredLicenseKey: String?
    var registeredDeviceUUID: String?
    var registeredBuildNumber: String?
    var verifiedSignature: String?
    var verifiedDeviceUUID: String?
    var revokedSignature: String?

    func registerLicense(
        licenseKey: String,
        deviceName: String,
        deviceUUID: String,
        buildNumber: String,
        completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void
    ) {
        registeredLicenseKey = licenseKey
        registeredDeviceUUID = deviceUUID
        registeredBuildNumber = buildNumber
        completion(registerResult)
    }

    func verifyLicense(
        license: TCPViewerLicense,
        deviceUUID: String,
        buildNumber: String,
        completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void
    ) {
        verifiedSignature = license.signature
        verifiedDeviceUUID = deviceUUID
        completion(verifyResult)
    }

    func revokeLicense(
        license: TCPViewerLicense,
        completion: @escaping (Result<Void, TCPViewerLicenseError>) -> Void
    ) {
        revokedSignature = license.signature
        completion(revokeResult)
    }
}
