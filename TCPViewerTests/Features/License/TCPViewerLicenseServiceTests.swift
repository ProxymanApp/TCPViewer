//
//  TCPViewerLicenseServiceTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import CryptoKit
import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerLicenseServiceTests {
    @Test func activationAuthenticatesStoresAndCompletesOnMain() throws {
        let rig = LicenseTestRig()
        let license = try rig.signed()
        rig.network.registerResult = .success(license)
        let service = rig.service()
        var main = false
        let status = waitForLicenseStatus { finish in
            service.activate(licenseKey: " tcpv-key\n") { value in main = Thread.isMainThread; finish(value) }
        }
        #expect(status == .authorized(license))
        #expect(rig.storage.license == license)
        #expect(rig.network.registeredKey == "TCPV-KEY")
        #expect(main)
    }

    @Test func invalidKeyNeverCallsNetwork() {
        let rig = LicenseTestRig(); let service = rig.service()
        let status = waitForLicenseStatus { service.activate(licenseKey: "BAD", completion: $0) }
        #expect(status == .unauthorized(.invalidLicense))
        #expect(rig.network.registeredKey == nil)
    }

    @Test func individualActivationsUseTheExistingUnsignedFlow() {
        for type in [TCPViewerLicenseType.standardLicense, .comboLicense, .lifetimeLicense] {
            let rig = LicenseTestRig(); let license = rig.legacy(type: type); rig.network.registerResult = .success(license)
            let service = rig.service()
            #expect(waitForLicenseStatus { service.activate(licenseKey: "TCPV-KEY", completion: $0) } == .authorized(license))
            #expect(rig.storage.license == license)
        }
    }

    @Test func renewedIndividualActivationsKeepTheirExtendedUpdateWindow() {
        for type in [TCPViewerLicenseType.standardLicense, .comboLicense] {
            let rig = LicenseTestRig()
            rig.storage.license = rig.legacy(type: type)
            let renewed = rig.legacy(type: type, expiry: "2027-01-01T00:00:00.000Z")
            rig.network.verifyResult = .success(renewed)
            let service = rig.service()

            #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .authorized(renewed))
            #expect(rig.service().status == .authorized(renewed))
        }
    }

    @Test func unsignedTeamActivationsCannotAuthorize() {
        let rig = LicenseTestRig(); rig.network.registerResult = .success(rig.legacy(type: .teamLicense))
        let service = rig.service()
        #expect(waitForLicenseStatus { service.activate(licenseKey: "TCPV-KEY", completion: $0) } == .unauthorized(.verificationRequired))
        #expect(rig.storage.license == nil)
    }

    @Test func existingIndividualActivationsStayOnTheUnsignedFlow() {
        for type in [TCPViewerLicenseType.standardLicense, .comboLicense, .lifetimeLicense] {
            let rig = LicenseTestRig(); let legacy = rig.legacy(type: type); rig.storage.license = legacy
            rig.network.verifyResult = .failure(.noInternetConnection)
            let service = rig.service()
            #expect(service.isLicenseAuthorized)
            #expect(waitForLicenseStatus { service.verifyAtLaunch(completion: $0) } == .authorized(legacy))
            #expect(rig.storage.license == legacy)
            rig.network.verifyResult = .success(legacy)
            #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .authorized(legacy))
            #expect(rig.network.verifiedSignature == legacy.signature)
            #expect(rig.storage.license?.receipt == nil)
        }
    }

    @Test func invalidLegacyFileCannotAuthorize() {
        let rig = LicenseTestRig(); var legacy = rig.legacy(); legacy.signature = "short"; rig.storage.license = legacy
        rig.network.verifyResult = .failure(.noInternetConnection)
        let service = rig.service()
        #expect(!service.isLicenseAuthorized)
        #expect(waitForLicenseStatus { service.verifyAtLaunch(completion: $0) } == .unauthorized(.verificationRequired))
        #expect(rig.storage.license == legacy)
    }

    @Test func legacyRenewalDenialPersistsWithoutDeletingCredential() {
        let rig = LicenseTestRig(); let legacy = rig.legacy(); rig.storage.license = legacy
        rig.network.verifyResult = .failure(.renewalRequired)
        let service = rig.service()
        #expect(service.isLicenseAuthorized)
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .unauthorized(.renewalRequired))
        #expect(rig.storage.license == legacy)
        #expect(rig.service().status == .unauthorized(.renewalRequired))
    }

    @Test func renewalsBeyondOneYearRemainAuthorizedAndExpiredCoverageDoesNotExpireCoveredBuild() throws {
        let rig = LicenseTestRig(); let license = try rig.signed(type: .standardLicense, expiry: "2025-12-31T23:59:59.999Z")
        rig.storage.license = license
        let service = rig.service()
        #expect(service.isLicenseAuthorized)
        let renewed = try rig.signed(type: .standardLicense, expiry: "2030-12-31T23:59:59.999Z")
        rig.network.verifyResult = .success(renewed)
        #expect(waitForLicenseStatus { service.verifyAtLaunch(completion: $0) } == .authorized(renewed))
    }

    @Test func forcedPaywallRefreshIgnoresRecentVerificationAndCoalescesRequests() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed(); rig.network.holdVerification = true
        let service = rig.service()
        _ = waitForLicenseStatus { service.verifyIfNeeded(completion: $0) }
        #expect(rig.network.verifyCount == 0)
        let finished = DispatchSemaphore(value: 0)
        service.refreshLicense { _ in finished.signal() }
        service.refreshLicense { _ in finished.signal() }
        rig.drain()
        #expect(rig.network.verifyCount == 1)
        rig.network.pendingVerification?(.success(try rig.signed()))
        #expect(waitForLicenseSignal(finished)); #expect(waitForLicenseSignal(finished))
        rig.network.holdVerification = false
        rig.network.verifyResult = .success(try rig.signed())
        _ = waitForLicenseStatus { service.refreshLicense(completion: $0) }
        #expect(rig.network.verifyCount == 2)
    }

    @Test func foregroundVerifiesAtTwelveHoursAndLaunchAlwaysVerifies() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed(type: .standardLicense)
        rig.network.verifyResult = .success(try rig.signed(type: .standardLicense))
        let service = rig.service()
        _ = waitForLicenseStatus { service.verifyAtLaunch(completion: $0) }
        rig.advance(12 * 3600 - 1)
        _ = waitForLicenseStatus { service.verifyIfNeeded(completion: $0) }
        #expect(rig.network.verifyCount == 1)
        rig.advance(1)
        rig.network.verifyResult = .success(try rig.signed(type: .standardLicense))
        _ = waitForLicenseStatus { service.verifyIfNeeded(completion: $0) }
        #expect(rig.network.verifyCount == 2)
    }

    @Test func temporaryFailuresPreserveTeamUntilExactSevenDayBoundaryThenRecover() throws {
        let rig = LicenseTestRig(); let original = try rig.signed(); rig.storage.license = original
        let service = rig.service()
        for error in [TCPViewerLicenseError.noInternetConnection, .temporaryFailure, .error("bad gateway")] {
            rig.network.verifyResult = .failure(error)
            #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) }.isAuthorized)
        }
        rig.advance(7 * 86400 - 1)
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) }.isAuthorized)
        rig.advance(1)
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .unauthorized(.offlineVerificationRequired))
        #expect(rig.storage.license == original)
        let refreshed = try rig.signed(); rig.network.verifyResult = .success(refreshed)
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .authorized(refreshed))
    }

    @Test func timerEnforcesDeadlineWhileAppRemainsOpen() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed(); rig.network.verifyResult = .failure(.noInternetConnection)
        rig.advance(7 * 86400 - 1)
        let service = rig.service(timer: true)
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) }.isAuthorized)
        rig.advance(1)
        let deadline = Date().addingTimeInterval(3)
        while service.isLicenseAuthorized && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(service.status == .unauthorized(.offlineVerificationRequired))
    }

    @Test func timerDoesNotPollStoredLicenseBeforeNextDeadline() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed()
        let service = rig.service(timer: true)
        let readCount = rig.storage.readCount

        Thread.sleep(forTimeInterval: 1.2)

        #expect(service.isLicenseAuthorized)
        #expect(rig.storage.readCount == readCount)
    }

    @Test func individualPlansKeepOfflineAccessAfterSevenDays() throws {
        for type in [TCPViewerLicenseType.standardLicense, .comboLicense, .lifetimeLicense] {
            let rig = LicenseTestRig(); rig.storage.license = try rig.signed(type: type)
            rig.network.verifyResult = .failure(.temporaryFailure)
            let service = rig.service(); rig.advance(30 * 86400)
            #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) }.isAuthorized)
        }
    }

    @Test func uncoveredBuildRetainsCredentialAndRefreshAfterRenewalRestoresAccess() throws {
        let rig = LicenseTestRig(); let license = try rig.signed(build: "998"); rig.storage.license = license
        rig.network.verifyResult = .failure(.renewalRequired)
        let service = rig.service()
        #expect(!service.isLicenseAuthorized)
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .unauthorized(.renewalRequired))
        #expect(rig.storage.license == license)
        #expect(rig.service().status == .unauthorized(.renewalRequired))
        rig.network.verifyResult = .failure(.temporaryFailure)
        #expect(!waitForLicenseStatus { service.refreshLicense(completion: $0) }.isAuthorized)
        let renewed = try rig.signed(expiry: "2030-01-01T23:59:59.999Z")
        rig.network.verifyResult = .success(renewed)
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .authorized(renewed))
    }

    @Test func remoteRevocationAndDisablingRemoveAuthorizationAndCredential() throws {
        for error in [TCPViewerLicenseError.deviceRevoked, .licenseDisabled, .invalidLicense] {
            let rig = LicenseTestRig(); rig.storage.license = try rig.signed()
            rig.network.verifyResult = .failure(error); let service = rig.service()
            #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .unauthorized(error))
            #expect(rig.storage.license == nil)
            let reactivated = try rig.signed(token: "reactivated", activationId: UUID().uuidString)
            rig.network.registerResult = .success(reactivated)
            #expect(waitForLicenseStatus { service.activate(licenseKey: "TCPV-KEY", completion: $0) } == .authorized(reactivated))
        }
    }

    @Test func staleVerificationCannotRemoveNewActivation() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed(); rig.network.holdVerification = true
        let service = rig.service(); service.refreshLicense(); rig.drain()
        let oldCallback = rig.network.pendingVerification
        let newer = try rig.signed(token: "new", activationId: UUID().uuidString)
        rig.network.registerResult = .success(newer)
        _ = waitForLicenseStatus { service.activate(licenseKey: "TCPV-NEW", completion: $0) }
        oldCallback?(.failure(.deviceRevoked)); rig.drain()
        #expect(service.currentLicense == newer)
        #expect(rig.storage.license == newer)
    }

    @Test func staleActivationCannotRestoreRemovedLicense() throws {
        let rig = LicenseTestRig(); rig.network.holdRegistration = true
        let service = rig.service(); let done = DispatchSemaphore(value: 0)
        service.activate(licenseKey: "TCPV-KEY") { _ in done.signal() }; rig.drain()
        service.clearLicense()
        rig.network.pendingRegistration?(.success(try rig.signed()))
        #expect(waitForLicenseSignal(done)); rig.drain()
        #expect(!service.isLicenseAuthorized); #expect(rig.storage.license == nil)
    }

    @Test func clockRollbackPersistsUntilSuccessfulOnlineVerification() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed(); rig.network.verifyResult = .failure(.noInternetConnection)
        let service = rig.service(); rig.advance(3600)
        _ = waitForLicenseStatus { service.verifyIfNeeded(completion: $0) }
        rig.queue.sync { rig.date = rig.date.addingTimeInterval(-600) }
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .unauthorized(.clockChanged))
        rig.queue.sync { rig.date = rig.date.addingTimeInterval(600) }
        #expect(waitForLicenseStatus { service.refreshLicense(completion: $0) } == .unauthorized(.clockChanged))
        let restarted = rig.service()
        #expect(restarted.status == .unauthorized(.clockChanged))
        rig.network.verifyResult = .success(try rig.signed())
        #expect(waitForLicenseStatus { restarted.refreshLicense(completion: $0) }.isAuthorized)
    }

    @Test func missingReceiptCannotBypassTheOfflineDeadline() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed()
        let service = rig.service()
        rig.queue.sync { rig.storage.license = nil }
        #expect(!waitForLicenseStatus { service.verifyIfNeeded(completion: $0) }.isAuthorized)
    }

    @Test func localRemovalWaitsForServerAndRetainsAccessOnNetworkFailure() throws {
        let rig = LicenseTestRig(); rig.storage.license = try rig.signed(); let service = rig.service()
        rig.network.revokeResult = .failure(.noInternetConnection)
        let done = DispatchSemaphore(value: 0)
        service.revokeCurrentDevice { result in
            if case .success = result { Issue.record("Network failure must not remove the seat locally") }
            done.signal()
        }
        #expect(waitForLicenseSignal(done)); #expect(service.isLicenseAuthorized)
        rig.network.revokeResult = .success(())
        service.revokeCurrentDevice { _ in done.signal() }
        #expect(waitForLicenseSignal(done)); #expect(!service.isLicenseAuthorized)
        #expect(rig.storage.license == nil)
    }
}

final class LicenseTestStorage: TCPViewerLicenseStoring {
    var license: TCPViewerLicense?
    private(set) var readCount = 0
    func readLicense() -> TCPViewerLicense? { readCount += 1; return license }
    func writeLicense(_ license: TCPViewerLicense) throws { self.license = license }
    func removeLicense() { license = nil }
}

final class LicenseTestRig {
    let key = Curve25519.Signing.PrivateKey()
    let storage = LicenseTestStorage()
    let network = LicenseTestNetwork()
    let queue = DispatchQueue(label: "LicenseTestRig.\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "LicenseTests.\(UUID().uuidString)")!
    var date = Date(timeIntervalSince1970: 1788775200)
    var elapsed: TimeInterval = 100

    func service(timer: Bool = false) -> TCPViewerLicenseService {
        TCPViewerLicenseService(storage: storage, networkClient: network, deviceProvider: LicenseTestDevice(),
            defaults: defaults, buildNumberProvider: { "999" },
            appVersionProvider: { "1.0" }, osVersionProvider: { "26.0" }, workerQueue: queue,
            verifier: TCPViewerLicenseReceiptVerifier(publicKeys: ["test": key.publicKey.rawRepresentation]),
            now: { self.date }, uptime: { self.elapsed }, startTimer: timer)
    }
    func advance(_ seconds: TimeInterval) { queue.sync { date = date.addingTimeInterval(seconds); elapsed += seconds } }
    func drain() { queue.sync {} }
    func legacy(
        type: TCPViewerLicenseType = .standardLicense,
        expiry: String = "2025-01-01T00:00:00.000Z"
    ) -> TCPViewerLicense {
        TCPViewerLicense(signature: "legacy-activation-credential", deviceUUID: "device-1", email: "owner@example.com",
            purchaseAt: "2024-01-01T00:00:00.000Z", expiryDate: expiry, licenseType: type)
    }
    func signed(type: TCPViewerLicenseType = .teamLicense, token: String = "credential", build: String = "999",
                device: String = "device-1", activationId: String = "activation", expiry: String = "2028-01-01T23:59:59.999Z") throws -> TCPViewerLicense {
        let claims = TCPViewerLicenseReceiptClaims(activationId: activationId,
            activationTokenHash: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(),
            productID: "com.proxyman.TCPViewer", device_uuid: device, licenseType: type, email: "owner@example.com",
            purchaseAt: "2024-01-01T00:00:00.000Z", expiryAt: expiry, numberOfSeats: 5, usedSeats: 1,
            buildNumber: build, issuedAt: date.timeIntervalSince1970,
            offlineUntil: type == .teamLicense ? date.timeIntervalSince1970 + 7 * 86400 : nil)
        let payload = try JSONEncoder().encode(claims).licenseBase64URL
        let signature = try key.signature(for: Data("1.test.\(payload)".utf8)).licenseBase64URL
        return TCPViewerLicense(signature: token, deviceUUID: device, email: claims.email, purchaseAt: claims.purchaseAt,
            expiryDate: expiry, licenseType: type,
            receipt: TCPViewerLicenseReceipt(version: 1, keyId: "test", payload: payload, signature: signature),
            activationId: activationId, numberOfSeats: 5, usedSeats: 1)
    }
}

private struct LicenseTestDevice: TCPViewerLicenseDeviceProviding {
    func deviceName() -> String { "Test Mac" }
    func hashedDeviceIDs() -> [String] { ["device-1", "device-2"] }
}

final class LicenseTestNetwork: TCPViewerLicenseNetworkClienting {
    var registerResult: Result<TCPViewerLicense, TCPViewerLicenseError> = .failure(.invalidLicense)
    var verifyResult: Result<TCPViewerLicense, TCPViewerLicenseError> = .failure(.noInternetConnection)
    var revokeResult: Result<Void, TCPViewerLicenseError> = .success(())
    var holdVerification = false
    var holdRegistration = false
    var pendingVerification: ((Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void)?
    var pendingRegistration: ((Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void)?
    var verifyCount = 0
    var registeredKey: String?
    var verifiedSignature: String?
    func registerLicense(licenseKey: String, deviceName: String, deviceUUID: String, buildNumber: String, appVersion: String, osVersion: String, completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void) {
        registeredKey = licenseKey
        if holdRegistration { pendingRegistration = completion } else { completion(registerResult) }
    }
    func verifyLicense(license: TCPViewerLicense, deviceUUID: String, buildNumber: String, appVersion: String, osVersion: String, completion: @escaping (Result<TCPViewerLicense, TCPViewerLicenseError>) -> Void) {
        verifiedSignature = license.signature; verifyCount += 1
        if holdVerification { pendingVerification = completion } else { completion(verifyResult) }
    }
    func revokeLicense(license: TCPViewerLicense, completion: @escaping (Result<Void, TCPViewerLicenseError>) -> Void) { completion(revokeResult) }
}

extension Data {
    var licenseBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

func waitForLicenseStatus(_ start: (@escaping (TCPViewerLicenseStatus) -> Void) -> Void) -> TCPViewerLicenseStatus {
    var status: TCPViewerLicenseStatus?
    let semaphore = DispatchSemaphore(value: 0)
    start { status = $0; semaphore.signal() }
    #expect(waitForLicenseSignal(semaphore))
    return status ?? .unauthorized(.error("Missing callback"))
}

func waitForLicenseSignal(_ semaphore: DispatchSemaphore) -> Bool {
    if Thread.isMainThread {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if semaphore.wait(timeout: .now()) == .success { return true }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return false
    }
    return semaphore.wait(timeout: .now() + 3) == .success
}
