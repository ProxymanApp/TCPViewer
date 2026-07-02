//
//  TCPViewerLicenseService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import Foundation
import PcapPlusPlusCore

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
    private let appVersionProvider: () -> String
    private let osVersionProvider: () -> String
    private let workerQueue: DispatchQueue
    private let storedStatus: Protected<TCPViewerLicenseStatus>

    init(
        storage: any TCPViewerLicenseStoring = TCPViewerLicenseStorage(),
        networkClient: any TCPViewerLicenseNetworkClienting = TCPViewerLicenseNetworkClient(),
        deviceProvider: any TCPViewerLicenseDeviceProviding = TCPViewerLicenseDeviceIdentifier(),
        defaults: UserDefaults = .standard,
        buildNumberProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.buildNumber },
        appVersionProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.appVersion },
        osVersionProvider: @escaping () -> String = { TCPViewerLicenseAppVersion.current.osVersion },
        workerQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.LicenseService", qos: .utility)
    ) {
        self.storage = storage
        self.networkClient = networkClient
        self.deviceProvider = deviceProvider
        self.defaults = defaults
        self.buildNumberProvider = buildNumberProvider
        self.appVersionProvider = appVersionProvider
        self.osVersionProvider = osVersionProvider
        self.workerQueue = workerQueue
        self.storedStatus = Protected(Self.initialStatus(storage: storage, deviceProvider: deviceProvider))
    }

    var status: TCPViewerLicenseStatus {
        storedStatus.wrappedValue
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
            completeOnMain(.unauthorized(.invalidLicense), completion)
            return
        }
        guard let deviceUUID = deviceProvider.currentDeviceUUID() else {
            completeOnMain(.unauthorized(.couldNotGetDeviceUUID), completion)
            return
        }

        networkClient.registerLicense(
            licenseKey: normalizedKey,
            deviceName: deviceProvider.deviceName(),
            deviceUUID: deviceUUID,
            buildNumber: buildNumberProvider(),
            appVersion: appVersionProvider(),
            osVersion: osVersionProvider()
        ) { result in
            self.workerQueue.async {
                switch result {
                case .success(let license):
                    do {
                        try self.storage.writeLicense(license)
                        self.updateLastVerifyLicenseTime()
                        let status = TCPViewerLicenseStatus.authorized(license)
                        self.setStatus(status)
                        self.completeOnMain(status, completion)
                    } catch {
                        self.completeOnMain(.unauthorized(.error(error.localizedDescription)), completion)
                    }
                case .failure(let error):
                    self.completeOnMain(.unauthorized(error), completion)
                }
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
            completeOnMain(status, completion)
        }
    }

    func revokeCurrentDevice(completion: @escaping (Result<Void, TCPViewerLicenseError>) -> Void) {
        workerQueue.async {
            guard let license = self.storage.readLicense() else {
                self.clearLicense()
                self.completeOnMain(.success(()), completion)
                return
            }

            self.networkClient.revokeLicense(license: license) { result in
                self.workerQueue.async {
                    // Clear locally only after License Manager accepted or already lost this device.
                    switch result {
                    case .success, .failure(.invalidLicense):
                        self.clearLicense()
                        self.completeOnMain(.success(()), completion)
                    case .failure(let error):
                        self.completeOnMain(.failure(error), completion)
                    }
                }
            }
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
                buildNumber: buildNumberProvider(),
                appVersion: appVersionProvider(),
                osVersion: osVersionProvider()
            ) { result in
                self.workerQueue.async {
                    switch result {
                    case .success(let updatedLicense):
                        do {
                            try self.storage.writeLicense(updatedLicense)
                            self.updateLastVerifyLicenseTime()
                            let status = TCPViewerLicenseStatus.authorized(updatedLicense)
                            self.setStatus(status)
                            self.completeOnMain(status, completion)
                        } catch {
                            self.completeOnMain(.unauthorized(.error(error.localizedDescription)), completion)
                        }
                    case .failure(.noInternetConnection):
                        // Offline Macs keep their current receipt until the server can be reached.
                        self.completeOnMain(self.status, completion)
                    case .failure(let error):
                        self.removeStoredLicenseAndComplete(completion, error: error)
                    }
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
        // Bind the encrypted receipt to this Mac so copied Application Support files cannot unlock PRO.
        guard deviceProvider.isSameDeviceUUID(license.deviceUUID) else {
            return false
        }
        guard license.signature.count >= 20 else {
            return false
        }
        guard license.hasValidUpdateEntitlement else {
            return false
        }
        if license.hasLifetimeUpdates {
            return true
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
        completeOnMain(status, completion)
    }

    private func setStatus(_ status: TCPViewerLicenseStatus) {
        storedStatus.wrappedValue = status
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

    private func completeOnMain<T>(_ value: T, _ completion: ((T) -> Void)?) {
        guard let completion else {
            return
        }

        Self.performOnMain {
            completion(value)
        }
    }

    private static func postStatusDidChange(_ status: TCPViewerLicenseStatus) {
        performOnMain {
            NotificationCenter.default.post(
                name: TCPViewerLicenseService.statusDidChangeNotification,
                object: status
            )
        }
    }

    private static func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
