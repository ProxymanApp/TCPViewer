//
//  TCPViewerLicenseService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import CryptoKit
import Foundation
import PcapPlusPlusCore

final class TCPViewerLicenseService {
    static let shared = TCPViewerLicenseService()
    static let statusDidChangeNotification = Notification.Name("TCPViewerLicenseServiceStatusDidChange")

    private let storage: any TCPViewerLicenseStoring
    private let networkClient: any TCPViewerLicenseNetworkClienting
    private let deviceProvider: any TCPViewerLicenseDeviceProviding
    private let defaults: UserDefaults
    private let buildNumberProvider: () -> String
    private let appVersionProvider: () -> String
    private let osVersionProvider: () -> String
    private let workerQueue: DispatchQueue
    private let verifier: TCPViewerLicenseReceiptVerifier
    private let secrets: any TCPViewerLicenseSecretStoring
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let storedStatus: Protected<TCPViewerLicenseStatus>
    private let queueKey = DispatchSpecificKey<Bool>()
    private var clock: TCPViewerLicenseClockState
    private var clockAnchor: Date
    private var uptimeAnchor: TimeInterval
    private var lastClockSave: TimeInterval = 0
    private var generation = 0
    private var verifying = false
    private var mutating = false
    private var callbacks: [(TCPViewerLicenseStatus) -> Void] = []
    private var timer: DispatchSourceTimer?
    private var nextAttempt: TimeInterval = 0
    private var sessionDenial: TCPViewerLicenseDenial?
    private static let clockAccount = "verification-clock"
    private static let denialAccount = "verification-denial"
    private static let legacyProofAccount = "legacy-entitlement-proof"
    private static let denialFallbackKey = "TCPViewer.license.verificationDenial"
    private static let lastVerifyKey = "TCPViewer.license.lastVerifyTime"
    private static let verificationInterval: TimeInterval = 12 * 3600
    private static let retryInterval: TimeInterval = 60

    init(
        storage: any TCPViewerLicenseStoring = TCPViewerLicenseStorage(),
        networkClient: any TCPViewerLicenseNetworkClienting = TCPViewerLicenseNetworkClient(),
        deviceProvider: any TCPViewerLicenseDeviceProviding = TCPViewerLicenseDeviceIdentifier(),
        defaults: UserDefaults = .standard,
        buildNumberProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.buildNumber },
        appVersionProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.appVersion },
        osVersionProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.osVersion },
        workerQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.LicenseService", qos: .utility),
        verifier: TCPViewerLicenseReceiptVerifier = TCPViewerLicenseReceiptVerifier(),
        secrets: any TCPViewerLicenseSecretStoring = TCPViewerLicenseKeychain(),
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        startTimer: Bool = true
    ) {
        self.storage = storage
        self.networkClient = networkClient
        self.deviceProvider = deviceProvider
        self.defaults = defaults
        self.buildNumberProvider = buildNumberProvider
        self.appVersionProvider = appVersionProvider
        self.osVersionProvider = osVersionProvider
        self.workerQueue = workerQueue
        self.verifier = verifier
        self.secrets = secrets
        self.now = now
        self.uptime = uptime
        self.clockAnchor = now()
        self.uptimeAnchor = uptime()
        self.clock = secrets.read(Self.clockAccount).flatMap { try? JSONDecoder().decode(TCPViewerLicenseClockState.self, from: $0) }
            ?? TCPViewerLicenseClockState(maximumTime: now().timeIntervalSince1970, requiresVerification: false)
        self.storedStatus = Protected(.unauthorized(.invalidLicense))
        workerQueue.setSpecific(key: queueKey, value: true)
        workerQueue.sync { refreshLocalAuthorization(storage.readLicense()) }
        if startTimer {
            let timer = DispatchSource.makeTimerSource(queue: workerQueue)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            workerQueue.sync { scheduleNextTimer() }
            timer.resume()
        }
    }

    deinit { timer?.cancel() }

    var status: TCPViewerLicenseStatus { storedStatus.wrappedValue }
    var isLicenseAuthorized: Bool { status.isAuthorized }
    var currentLicense: TCPViewerLicense? { status.license }

    func activate(licenseKey: String, completion: @escaping (TCPViewerLicenseStatus) -> Void) {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard key.hasPrefix("TCPV-"), key.count <= 255, key.count >= 8 else {
            completeOnMain(.unauthorized(.invalidLicense), completion)
            return
        }
        guard let uuid = deviceProvider.currentDeviceUUID() else {
            completeOnMain(.unauthorized(.couldNotGetDeviceUUID), completion)
            return
        }
        workerQueue.async {
            self.invalidateRequests()
            self.mutating = true
            let generation = self.generation
            self.networkClient.registerLicense(licenseKey: key, deviceName: self.deviceProvider.deviceName(), deviceUUID: uuid,
                buildNumber: self.buildNumberProvider(), appVersion: self.appVersionProvider(), osVersion: self.osVersionProvider()) { result in
                self.workerQueue.async {
                    guard generation == self.generation else { self.completeOnMain(self.status, completion); return }
                    self.mutating = false
                    let resultStatus: TCPViewerLicenseStatus
                    switch result {
                    case .success(let license): resultStatus = self.accept(license)
                    case .failure(let error): resultStatus = .unauthorized(error)
                    }
                    self.scheduleNextTimer()
                    self.completeOnMain(resultStatus, completion)
                }
            }
        }
    }

    func verifyAtLaunch(completion: ((TCPViewerLicenseStatus) -> Void)? = nil) { refreshLicense(completion: completion) }

    // Every presentation calls this, including reuse of the existing hosted license window.
    func refreshLicense(completion: ((TCPViewerLicenseStatus) -> Void)? = nil) {
        workerQueue.async { self.verifyStoredLicense(completion: completion) }
    }

    func verifyIfNeeded(completion: ((TCPViewerLicenseStatus) -> Void)? = nil) {
        workerQueue.async {
            guard let license = self.storage.readLicense() else {
                self.refreshLocalAuthorization(nil)
                self.completeOnMain(self.status, completion)
                return
            }
            self.refreshLocalAuthorization(license)
            if self.verificationIsDue(for: license) { self.verifyStoredLicense(completion: completion, storedLicense: license) }
            else { self.completeOnMain(self.status, completion) }
        }
    }

    func revokeCurrentDevice(completion: @escaping (Result<Void, TCPViewerLicenseError>) -> Void) {
        workerQueue.async {
            self.invalidateRequests()
            guard let license = self.storage.readLicense() else {
                self.clearOnQueue()
                self.completeOnMain(.success(()), completion)
                return
            }
            self.mutating = true
            let generation = self.generation
            self.networkClient.revokeLicense(license: license) { result in
                self.workerQueue.async {
                    guard generation == self.generation else { self.completeOnMain(.failure(.temporaryFailure), completion); return }
                    self.mutating = false
                    switch result {
                    case .success, .failure(.invalidLicense), .failure(.deviceRevoked):
                        self.clearOnQueue()
                        self.completeOnMain(.success(()), completion)
                    case .failure(let error):
                        self.scheduleNextTimer()
                        self.completeOnMain(.failure(error), completion)
                    }
                }
            }
        }
    }

    func clearLicense() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { clearOnQueue() }
        else { workerQueue.sync { clearOnQueue() } }
    }

    private func clearOnQueue() {
        invalidateRequests()
        mutating = false
        storage.removeLicense()
        removeDenial()
        secrets.remove(Self.legacyProofAccount)
        defaults.removeObject(forKey: Self.lastVerifyKey)
        setStatus(.unauthorized(.invalidLicense))
        scheduleNextTimer()
    }

    private func invalidateRequests() {
        generation += 1
        verifying = false
        finishCallbacks()
    }

    // Decide whether this license needs an online check at the current wall-clock time.
    private func verificationIsDue(for license: TCPViewerLicense) -> Bool {
        guard license.receipt != nil else {
            let lastVerifyTime = defaults.double(forKey: Self.lastVerifyKey)
            return !status.isAuthorized || lastVerifyTime <= 0
                || now().timeIntervalSince1970 >= lastVerifyTime + Self.verificationInterval
        }
        guard let claims = receiptClaims(for: license) else { return true }
        // The date here only schedules a request; authorization always verifies the signature separately.
        return clock.requiresVerification || !status.isAuthorized
            || now().timeIntervalSince1970 >= claims.issuedAt + Self.verificationInterval
    }

    // Process only the next verification or offline deadline instead of polling stored credentials.
    private func tick() {
        guard let license = storage.readLicense() else {
            if status.isAuthorized { setStatus(.unauthorized(.invalidReceipt)) }
            scheduleNextTimer()
            return
        }
        if verificationIsDue(for: license), uptime() >= nextAttempt {
            verifyStoredLicense(completion: nil, storedLicense: license)
        } else {
            refreshLocalAuthorization(license)
            scheduleNextTimer(for: license)
        }
    }

    // Coalesce simultaneous launch, foreground, and paywall checks; generations reject obsolete callbacks.
    private func verifyStoredLicense(
        completion: ((TCPViewerLicenseStatus) -> Void)?,
        storedLicense: TCPViewerLicense? = nil
    ) {
        let license = storedLicense ?? storage.readLicense()
        refreshLocalAuthorization(license)
        guard !mutating else { completeOnMain(status, completion); return }
        if let completion { callbacks.append(completion) }
        guard !verifying else { return }
        guard let license else { finishCallbacks(); scheduleNextTimer(); return }
        guard deviceProvider.isSameDeviceUUID(license.deviceUUID) else {
            setStatus(.unauthorized(.invalidReceipt)); finishCallbacks(); scheduleNextTimer(for: license); return
        }
        verifying = true
        nextAttempt = uptime() + Self.retryInterval
        let generation = generation
        networkClient.verifyLicense(license: license, deviceUUID: license.deviceUUID,
            buildNumber: buildNumberProvider(), appVersion: appVersionProvider(), osVersion: osVersionProvider()) { result in
            self.workerQueue.async {
                guard generation == self.generation else { return }
                self.verifying = false
                switch result {
                case .success(let updated): self.setStatus(self.accept(updated))
                case .failure(let error):
                    if error.isTemporary {
                        self.refreshLocalAuthorization(license)
                    } else {
                        // Keep renewal credentials, but never restore an explicitly denied receipt offline.
                        let denial = TCPViewerLicenseDenial(licenseIdentity: self.verificationIdentity(for: license),
                            renewalRequired: error == .renewalRequired || error == .expired)
                        self.saveDenial(denial)
                        if error == .deviceRevoked || error == .licenseDisabled || error == .invalidLicense {
                            self.storage.removeLicense()
                            self.secrets.remove(Self.legacyProofAccount)
                        }
                        self.setStatus(.unauthorized(error))
                    }
                }
                self.finishCallbacks()
                self.scheduleNextTimer()
            }
        }
    }

    private func accept(_ license: TCPViewerLicense) -> TCPViewerLicenseStatus {
        do {
            let authenticated: TCPViewerLicense
            let requiresSignedReceipt = license.receipt != nil || license.licenseType == .teamLicense
                || license.signature.hasPrefix("TCPVA-")
            if requiresSignedReceipt {
                (authenticated, _) = try verifier.verify(license, deviceMatches: deviceProvider.isSameDeviceUUID,
                    buildNumber: buildNumberProvider(), now: now())
            } else {
                guard hasValidLegacyLicenseShape(license) else { throw TCPViewerLicenseError.verificationRequired }
                authenticated = license
            }
            try storage.writeLicense(authenticated)
            if requiresSignedReceipt {
                secrets.remove(Self.legacyProofAccount)
            } else {
                do {
                    try saveLegacyProof(for: authenticated)
                } catch {
                    // Older one-year and lifetime licenses remain usable if Keychain is temporarily unavailable.
                    guard canUseOriginalLegacyValidation(authenticated) else { throw error }
                }
            }
            clock = TCPViewerLicenseClockState(maximumTime: now().timeIntervalSince1970, requiresVerification: false)
            try secrets.write(JSONEncoder().encode(clock), account: Self.clockAccount)
            removeDenial()
            clockAnchor = now()
            uptimeAnchor = uptime()
            defaults.set(now().timeIntervalSince1970, forKey: Self.lastVerifyKey)
            let status = TCPViewerLicenseStatus.authorized(authenticated)
            setStatus(status)
            return status
        } catch let error as TCPViewerLicenseError { return .unauthorized(error) }
        catch { return .unauthorized(.error("Could not save the verified license. Please retry.")) }
    }

    private func refreshLocalAuthorization(_ license: TCPViewerLicense?) {
        guard let license else {
            if status.isAuthorized { setStatus(.unauthorized(.invalidReceipt)) }
            return
        }
        if let denial = currentDenial(), denial.licenseIdentity == verificationIdentity(for: license) {
            setStatus(.unauthorized(denial.renewalRequired ? .renewalRequired : .verificationRequired))
            return
        }
        if license.receipt == nil {
            setStatus(locallyValidateLegacyLicense(license) ? .authorized(license) : .unauthorized(.verificationRequired))
            return
        }
        let wallTime = now().timeIntervalSince1970
        let monotonicTime = clockAnchor.timeIntervalSince1970 + max(0, uptime() - uptimeAnchor)
        let previousClockFailure = clock.requiresVerification
        if wallTime + 5 < max(clock.maximumTime, monotonicTime) { clock.requiresVerification = true }
        clock.maximumTime = max(clock.maximumTime, wallTime, monotonicTime)
        if clock.requiresVerification != previousClockFailure || uptime() >= lastClockSave + 60 {
            do {
                try secrets.write(JSONEncoder().encode(clock), account: Self.clockAccount)
                lastClockSave = uptime()
            } catch { clock.requiresVerification = true }
        }
        guard !clock.requiresVerification else { setStatus(.unauthorized(.clockChanged)); return }
        do {
            let (authenticated, _) = try verifier.verify(license, deviceMatches: deviceProvider.isSameDeviceUUID,
                buildNumber: buildNumberProvider(), now: Date(timeIntervalSince1970: clock.maximumTime))
            setStatus(.authorized(authenticated))
        } catch let error as TCPViewerLicenseError { setStatus(.unauthorized(error)) }
        catch { setStatus(.unauthorized(.invalidReceipt)) }
    }

    // Keep old licenses offline, and use a Keychain proof for legitimate multi-year renewals.
    private func locallyValidateLegacyLicense(_ license: TCPViewerLicense) -> Bool {
        guard hasValidLegacyLicenseShape(license) else { return false }
        return canUseOriginalLegacyValidation(license) || storedLegacyProofMatches(license)
    }

    // Reject malformed individual payloads before accepting a trusted legacy server response.
    private func hasValidLegacyLicenseShape(_ license: TCPViewerLicense) -> Bool {
        guard license.receipt == nil,
              license.licenseType != .teamLicense,
              !license.signature.hasPrefix("TCPVA-"),
              deviceProvider.isSameDeviceUUID(license.deviceUUID),
              license.signature.count >= 20,
              let purchaseDate = TCPViewerLicenseDateParser.date(from: license.purchaseAt),
              let expiryDate = TCPViewerLicenseDateParser.date(from: license.expiryDate) else {
            return false
        }
        return expiryDate >= purchaseDate
    }

    // Preserve the validation available to individual licenses stored by older app versions.
    private func canUseOriginalLegacyValidation(_ license: TCPViewerLicense) -> Bool {
        guard license.hasValidLegacyUpdateEntitlement else { return false }
        return license.hasLifetimeUpdates || (license.remainingDays.map { $0 < 3000 } ?? false)
    }

    // Bind a server-verified multi-year entitlement to its exact local license fields.
    private func saveLegacyProof(for license: TCPViewerLicense) throws {
        try secrets.write(JSONEncoder().encode(legacyProof(for: license)), account: Self.legacyProofAccount)
    }

    // Require every locally loaded field to match the proof saved after online verification.
    private func storedLegacyProofMatches(_ license: TCPViewerLicense) -> Bool {
        guard let data = secrets.read(Self.legacyProofAccount),
              let proof = try? JSONDecoder().decode(TCPViewerLegacyLicenseProof.self, from: data) else {
            return false
        }
        return proof == legacyProof(for: license)
    }

    // Hash the credential before putting the legacy entitlement proof in Keychain.
    private func legacyProof(for license: TCPViewerLicense) -> TCPViewerLegacyLicenseProof {
        TCPViewerLegacyLicenseProof(
            credentialHash: sha256(license.signature),
            deviceUUID: license.deviceUUID,
            purchaseAt: license.purchaseAt,
            expiryDate: license.expiryDate,
            licenseType: license.licenseType,
            activationId: license.activationId
        )
    }

    // Use the server identity when available and a credential digest for older receipts.
    private func verificationIdentity(for license: TCPViewerLicense) -> String {
        if let activationId = license.activationId { return activationId }
        return "legacy:" + sha256(license.signature)
    }

    // Return a stable lowercase digest for local identity comparisons.
    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Keep a non-secret fallback so a transient Keychain error cannot undo a server denial.
    private func saveDenial(_ denial: TCPViewerLicenseDenial) {
        sessionDenial = denial
        guard let data = try? JSONEncoder().encode(denial) else { return }
        do {
            try secrets.write(data, account: Self.denialAccount)
            defaults.removeObject(forKey: Self.denialFallbackKey)
        } catch {
            defaults.set(data, forKey: Self.denialFallbackKey)
        }
    }

    // Prefer the fallback written after a failed Keychain update over any stale Keychain value.
    private func currentDenial() -> TCPViewerLicenseDenial? {
        if let sessionDenial { return sessionDenial }
        if let data = defaults.data(forKey: Self.denialFallbackKey),
           let denial = try? JSONDecoder().decode(TCPViewerLicenseDenial.self, from: data) {
            return denial
        }
        guard let data = secrets.read(Self.denialAccount) else { return nil }
        return try? JSONDecoder().decode(TCPViewerLicenseDenial.self, from: data)
    }

    // Clear every persisted form of denial after removal or successful verification.
    private func removeDenial() {
        sessionDenial = nil
        secrets.remove(Self.denialAccount)
        defaults.removeObject(forKey: Self.denialFallbackKey)
    }

    // Arm one timer for the next online check, retry, or signed offline deadline.
    private func scheduleNextTimer(for storedLicense: TCPViewerLicense? = nil) {
        guard let timer else { return }
        guard !verifying, !mutating else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        guard let license = storedLicense ?? storage.readLicense() else {
            timer.schedule(deadline: .distantFuture)
            return
        }

        let delay: TimeInterval
        if verificationIsDue(for: license) {
            let retryDelay = max(1, nextAttempt - uptime())
            if let deadline = signedOfflineDeadline(for: license) {
                delay = max(1, min(retryDelay, deadline.timeIntervalSince(now())))
            } else {
                delay = retryDelay
            }
        } else {
            delay = max(1, nextScheduledDate(for: license).timeIntervalSince(now()))
        }
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(500))
    }

    // Return the next event encoded by the current legacy or signed receipt.
    private func nextScheduledDate(for license: TCPViewerLicense) -> Date {
        guard let claims = receiptClaims(for: license) else {
            let lastVerifyTime = defaults.double(forKey: Self.lastVerifyKey)
            return Date(timeIntervalSince1970: lastVerifyTime + Self.verificationInterval)
        }

        let verificationDate = Date(timeIntervalSince1970: claims.issuedAt + Self.verificationInterval)
        guard let offlineUntil = claims.offlineUntil else { return verificationDate }
        return min(verificationDate, Date(timeIntervalSince1970: offlineUntil))
    }

    // Return the signed cutoff that must preempt a later network retry.
    private func signedOfflineDeadline(for license: TCPViewerLicense) -> Date? {
        guard let offlineUntil = receiptClaims(for: license)?.offlineUntil else { return nil }
        return Date(timeIntervalSince1970: offlineUntil)
    }

    // Decode untrusted claims only for scheduling; authorization verifies their signature separately.
    private func receiptClaims(for license: TCPViewerLicense) -> TCPViewerLicenseReceiptClaims? {
        guard let receipt = license.receipt,
              let data = TCPViewerLicenseReceiptVerifier.decodeBase64URL(receipt.payload) else { return nil }
        return try? JSONDecoder().decode(TCPViewerLicenseReceiptClaims.self, from: data)
    }

    private func finishCallbacks() {
        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { completeOnMain(status, $0) }
    }

    private func setStatus(_ status: TCPViewerLicenseStatus) {
        guard storedStatus.wrappedValue != status else { return }
        storedStatus.wrappedValue = status
        Self.performOnMain {
            NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: status)
        }
    }

    private func completeOnMain<T>(_ value: T, _ completion: ((T) -> Void)?) {
        guard let completion else { return }
        Self.performOnMain { completion(value) }
    }

    private static func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

private struct TCPViewerLicenseDenial: Codable {
    let licenseIdentity: String
    let renewalRequired: Bool
}

private struct TCPViewerLegacyLicenseProof: Codable, Equatable {
    let credentialHash: String
    let deviceUUID: String
    let purchaseAt: String
    let expiryDate: String
    let licenseType: TCPViewerLicenseType
    let activationId: String?
}
