//
//  TCPViewerLicenseService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation

final class TCPViewerLicenseService {
    static let shared = TCPViewerLicenseService()
    static let statusDidChangeNotification = Notification.Name("TCPViewerLicenseServiceStatusDidChange")

    private enum Constants {
        static let licenseVerificationIntervalHours = 12
        static let lastVerifyDefaultsKey = "TCPViewer.license.lastVerifyTime"
    }

    private let storage: any TCPViewerLicenseStoring
    private let networkClient: any TCPViewerLicenseNetworkClienting
    private let deviceProvider: any TCPViewerLicenseDeviceProviding
    private let defaults: UserDefaults
    private let buildNumberProvider: () -> String
    private let workerQueue: DispatchQueue
    private let lock = NSLock()

    private var storedStatus: TCPViewerLicenseStatus

    init(
        storage: any TCPViewerLicenseStoring = TCPViewerLicenseStorage(),
        networkClient: any TCPViewerLicenseNetworkClienting = TCPViewerLicenseNetworkClient(),
        deviceProvider: any TCPViewerLicenseDeviceProviding = TCPViewerLicenseDeviceIdentifier(),
        defaults: UserDefaults = .standard,
        buildNumberProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.buildNumber },
        workerQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.LicenseService", qos: .utility)
    ) {
        self.storage = storage
        self.networkClient = networkClient
        self.deviceProvider = deviceProvider
        self.defaults = defaults
        self.buildNumberProvider = buildNumberProvider
        self.workerQueue = workerQueue
        self.storedStatus = Self.initialStatus(storage: storage, deviceProvider: deviceProvider)
    }

    var status: TCPViewerLicenseStatus {
        lock.withLock { storedStatus }
    }

    var isLicenseAuthorized: Bool {
        status.isAuthorized
    }

    var currentLicense: TCPViewerLicense? {
        status.license
    }

    func activate(licenseKey: String, completion: @escaping (TCPViewerLicenseStatus) -> Void) {
        let normalizedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKey.hasPrefix("TCPV-") else {
            completion(.unauthorized(.invalidLicense))
            return
        }
        guard let deviceUUID = deviceProvider.currentDeviceUUID() else {
            completion(.unauthorized(.couldNotGetDeviceUUID))
            return
        }

        networkClient.registerLicense(
            licenseKey: normalizedKey,
            deviceName: deviceProvider.deviceName(),
            deviceUUID: deviceUUID,
            buildNumber: buildNumberProvider()
        ) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let license):
                do {
                    try storage.writeLicense(license)
                    updateLastVerifyLicenseTime()
                    let status = TCPViewerLicenseStatus.authorized(license)
                    setStatus(status)
                    completion(status)
                } catch {
                    completion(.unauthorized(.error(error.localizedDescription)))
                }
            case .failure(let error):
                completion(.unauthorized(error))
            }
        }
    }

    func verifyAtLaunch(completion: ((TCPViewerLicenseStatus) -> Void)? = nil) {
        verifyStoredLicense(completion: completion)
    }

    func verifyIfNeeded(completion: ((TCPViewerLicenseStatus) -> Void)? = nil) {
        guard let lastVerifyDate = lastVerifyLicenseDate(),
              let nextVerifyDate = Calendar.current.date(
                byAdding: .hour,
                value: Constants.licenseVerificationIntervalHours,
                to: lastVerifyDate
              ) else {
            verifyStoredLicense(completion: completion)
            return
        }

        if Date() > nextVerifyDate {
            verifyStoredLicense(completion: completion)
        } else {
            completion?(status)
        }
    }

    func revokeCurrentDevice(completion: @escaping (Result<Void, TCPViewerLicenseError>) -> Void) {
        guard let license = storage.readLicense() else {
            clearLicense()
            completion(.success(()))
            return
        }

        networkClient.revokeLicense(license: license) { [weak self] _ in
            self?.clearLicense()
            completion(.success(()))
        }
    }

    func clearLicense() {
        storage.removeLicense()
        defaults.removeObject(forKey: Constants.lastVerifyDefaultsKey)
        setStatus(.unauthorized(.invalidLicense))
    }

    private static func initialStatus(
        storage: any TCPViewerLicenseStoring,
        deviceProvider: any TCPViewerLicenseDeviceProviding
    ) -> TCPViewerLicenseStatus {
        guard let license = storage.readLicense(),
              Self.locallyValidateStoredLicense(license, deviceProvider: deviceProvider) else {
            return .unauthorized(.invalidLicense)
        }

        return .authorized(license)
    }

    private func verifyStoredLicense(completion: ((TCPViewerLicenseStatus) -> Void)?) {
        workerQueue.async { [weak self] in
            guard let self else { return }
            guard let license = storage.readLicense() else {
                removeStoredLicenseAndComplete(completion)
                return
            }
            guard locallyValidateStoredLicense(license) else {
                removeStoredLicenseAndComplete(completion)
                return
            }

            // The server checks the submitted UUID against the signed receipt payload.
            networkClient.verifyLicense(
                license: license,
                deviceUUID: license.deviceUUID,
                buildNumber: buildNumberProvider()
            ) { [weak self] result in
                guard let self else { return }

                switch result {
                case .success(let updatedLicense):
                    do {
                        try storage.writeLicense(updatedLicense)
                        updateLastVerifyLicenseTime()
                        let status = TCPViewerLicenseStatus.authorized(updatedLicense)
                        setStatus(status)
                        completion?(status)
                    } catch {
                        completion?(.unauthorized(.error(error.localizedDescription)))
                    }
                case .failure(.noInternetConnection):
                    completion?(status)
                case .failure(let error):
                    removeStoredLicenseAndComplete(completion, error: error)
                }
            }
        }
    }

    private func locallyValidateStoredLicense(_ license: TCPViewerLicense) -> Bool {
        Self.locallyValidateStoredLicense(license, deviceProvider: deviceProvider)
    }

    private static func locallyValidateStoredLicense(
        _ license: TCPViewerLicense,
        deviceProvider: any TCPViewerLicenseDeviceProviding
    ) -> Bool {
        guard deviceProvider.isSameDeviceUUID(license.deviceUUID) else {
            return false
        }
        guard license.signature.count >= 20 else {
            return false
        }
        guard license.hasOneYearUpdateWindow else {
            return false
        }
        guard let remainingDays = license.remainingDays else {
            return false
        }

        // Also reject far-future expiry values that still fit a forged one-year window.
        return remainingDays < 3000
    }

    private func removeStoredLicenseAndComplete(
        _ completion: ((TCPViewerLicenseStatus) -> Void)?,
        error: TCPViewerLicenseError = .invalidLicense
    ) {
        storage.removeLicense()
        defaults.removeObject(forKey: Constants.lastVerifyDefaultsKey)
        let status = TCPViewerLicenseStatus.unauthorized(error)
        setStatus(status)
        completion?(status)
    }

    private func setStatus(_ status: TCPViewerLicenseStatus) {
        lock.withLock {
            storedStatus = status
        }
        TCPViewerLicenseService.postStatusDidChange(status)
    }

    private func lastVerifyLicenseDate() -> Date? {
        let timestamp = defaults.double(forKey: Constants.lastVerifyDefaultsKey)
        guard timestamp > 0 else {
            return nil
        }

        return Date(timeIntervalSince1970: timestamp)
    }

    private func updateLastVerifyLicenseTime() {
        defaults.set(Date().timeIntervalSince1970, forKey: Constants.lastVerifyDefaultsKey)
    }

    private static func postStatusDidChange(_ status: TCPViewerLicenseStatus) {
        let block = {
            NotificationCenter.default.post(
                name: TCPViewerLicenseService.statusDidChangeNotification,
                object: status
            )
        }

        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ closure: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try closure()
    }
}
