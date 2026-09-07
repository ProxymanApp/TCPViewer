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
    private static let clockAccount = "verification-clock"
    private static let denialAccount = "verification-denial"
    private static let lastVerifyKey = "TCPViewer.license.lastVerifyTime"

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
        workerQueue.sync { refreshLocalAuthorization() }
        if startTimer {
            let timer = DispatchSource.makeTimerSource(queue: workerQueue)
            // Check the signed deadline while the app stays open, even if no window gains focus.
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
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
            self.refreshLocalAuthorization()
            if self.verificationIsDue { self.verifyStoredLicense(completion: completion) }
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
                    case .failure(let error): self.completeOnMain(.failure(error), completion)
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
        secrets.remove(Self.denialAccount)
        defaults.removeObject(forKey: Self.lastVerifyKey)
        setStatus(.unauthorized(.invalidLicense))
    }

    private func invalidateRequests() {
        generation += 1
        verifying = false
        finishCallbacks()
    }

    private var verificationIsDue: Bool {
        guard let license = storage.readLicense(), let receipt = license.receipt,
              let data = TCPViewerLicenseReceiptVerifier.decodeBase64URL(receipt.payload),
              let claims = try? JSONDecoder().decode(TCPViewerLicenseReceiptClaims.self, from: data) else { return true }
        // The date here only schedules a request; authorization always verifies the signature separately.
        return clock.requiresVerification || !status.isAuthorized || now().timeIntervalSince1970 >= claims.issuedAt + 12 * 3600
    }

    private func tick() {
        guard storage.readLicense() != nil else {
            if status.isAuthorized { setStatus(.unauthorized(.invalidReceipt)) }
            return
        }
        refreshLocalAuthorization()
        if verificationIsDue, uptime() >= nextAttempt { verifyStoredLicense(completion: nil) }
    }

    // Coalesce simultaneous launch, foreground, and paywall checks; generations reject obsolete callbacks.
    private func verifyStoredLicense(completion: ((TCPViewerLicenseStatus) -> Void)?) {
        refreshLocalAuthorization()
        guard !mutating else { completeOnMain(status, completion); return }
        if let completion { callbacks.append(completion) }
        guard !verifying else { return }
        guard let license = storage.readLicense() else { finishCallbacks(); return }
        guard deviceProvider.isSameDeviceUUID(license.deviceUUID) else {
            setStatus(.unauthorized(.invalidReceipt)); finishCallbacks(); return
        }
        verifying = true
        nextAttempt = uptime() + 60
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
                        self.refreshLocalAuthorization()
                    } else {
                        // Keep renewal credentials, but never restore an explicitly denied receipt offline.
                        if let id = license.activationId {
                            let denial = TCPViewerLicenseDenial(activationId: id, renewalRequired: error == .renewalRequired || error == .expired)
                            if let data = try? JSONEncoder().encode(denial) { try? self.secrets.write(data, account: Self.denialAccount) }
                        }
                        if error == .deviceRevoked || error == .licenseDisabled || error == .invalidLicense { self.storage.removeLicense() }
                        self.setStatus(.unauthorized(error))
                    }
                }
                self.finishCallbacks()
            }
        }
    }

    private func accept(_ license: TCPViewerLicense) -> TCPViewerLicenseStatus {
        do {
            let (authenticated, _) = try verifier.verify(license, deviceMatches: deviceProvider.isSameDeviceUUID,
                buildNumber: buildNumberProvider(), now: now())
            try storage.writeLicense(authenticated)
            clock = TCPViewerLicenseClockState(maximumTime: now().timeIntervalSince1970, requiresVerification: false)
            try secrets.write(JSONEncoder().encode(clock), account: Self.clockAccount)
            secrets.remove(Self.denialAccount)
            clockAnchor = now()
            uptimeAnchor = uptime()
            defaults.set(now().timeIntervalSince1970, forKey: Self.lastVerifyKey)
            let status = TCPViewerLicenseStatus.authorized(authenticated)
            setStatus(status)
            return status
        } catch let error as TCPViewerLicenseError { return .unauthorized(error) }
        catch { return .unauthorized(.error("Could not save the verified license. Please retry.")) }
    }

    private func refreshLocalAuthorization() {
        guard let license = storage.readLicense() else {
            if status.isAuthorized { setStatus(.unauthorized(.invalidReceipt)) }
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
        if let id = license.activationId, let data = secrets.read(Self.denialAccount),
           let denial = try? JSONDecoder().decode(TCPViewerLicenseDenial.self, from: data), denial.activationId == id {
            setStatus(.unauthorized(denial.renewalRequired ? .renewalRequired : .verificationRequired))
            return
        }
        do {
            let (authenticated, _) = try verifier.verify(license, deviceMatches: deviceProvider.isSameDeviceUUID,
                buildNumber: buildNumberProvider(), now: Date(timeIntervalSince1970: clock.maximumTime))
            setStatus(.authorized(authenticated))
        } catch let error as TCPViewerLicenseError { setStatus(.unauthorized(error)) }
        catch { setStatus(.unauthorized(.invalidReceipt)) }
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
    let activationId: String
    let renewalRequired: Bool
}
