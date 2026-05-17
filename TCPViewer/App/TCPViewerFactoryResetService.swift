//
//  TCPViewerFactoryResetService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 17/5/26.
//

import Foundation

struct TCPViewerFactoryResetResult: Equatable {
    let helperToolSnapshot: TCPViewerNetworkHelperToolSnapshot?
}

final class TCPViewerFactoryResetService {
    typealias Completion = (Result<TCPViewerFactoryResetResult, Error>) -> Void

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let defaultsDomainName: String
    private let userDataDirectory: TCPViewerUserDataDirectory
    private let cacheDirectoryURL: URL?
    private let savedApplicationStateURL: URL?
    private let helperToolManager: (any TCPViewerNetworkHelperToolManaging)?
    private let workerQueue: DispatchQueue

    convenience init(helperToolManager: (any TCPViewerNetworkHelperToolManaging)? = nil) {
        let fileManager = FileManager.default
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.proxyman.tcpviewer"
        let cacheDirectoryURL = Self.defaultCacheDirectoryURL(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier
        )
        let savedApplicationStateURL = Self.defaultSavedApplicationStateURL(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier
        )

        self.init(
            fileManager: fileManager,
            defaults: .standard,
            defaultsDomainName: bundleIdentifier,
            userDataDirectory: .shared,
            cacheDirectoryURL: cacheDirectoryURL,
            savedApplicationStateURL: savedApplicationStateURL,
            helperToolManager: helperToolManager
        )
    }

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults,
        defaultsDomainName: String,
        userDataDirectory: TCPViewerUserDataDirectory,
        cacheDirectoryURL: URL?,
        savedApplicationStateURL: URL?,
        helperToolManager: (any TCPViewerNetworkHelperToolManaging)?,
        workerQueue: DispatchQueue = DispatchQueue(label: "com.proxyman.tcpviewer.FactoryReset", qos: .userInitiated)
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.defaultsDomainName = defaultsDomainName
        self.userDataDirectory = userDataDirectory
        self.cacheDirectoryURL = cacheDirectoryURL
        self.savedApplicationStateURL = savedApplicationStateURL
        self.helperToolManager = helperToolManager
        self.workerQueue = workerQueue
    }

    func reset(uninstallHelperTool: Bool, completion: @escaping Completion) {
        // Uninstall first so the helper manager can still read its current state before defaults disappear.
        guard uninstallHelperTool, let helperToolManager else {
            resetLocalState(helperToolSnapshot: nil, completion: completion)
            return
        }

        helperToolManager.uninstall { [self] snapshot in
            resetLocalState(helperToolSnapshot: snapshot, completion: completion)
        }
    }

    private func resetLocalState(
        helperToolSnapshot: TCPViewerNetworkHelperToolSnapshot?,
        completion: @escaping Completion
    ) {
        workerQueue.async {
            let result = Result {
                try self.removeLocalFiles()
                self.removePreferences()
                return TCPViewerFactoryResetResult(helperToolSnapshot: helperToolSnapshot)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func removeLocalFiles() throws {
        try removeItemIfPresent(at: userDataDirectory.appDirectoryURL)
        try removeItemIfPresent(at: cacheDirectoryURL)
        try removeItemIfPresent(at: savedApplicationStateURL)
    }

    private func removePreferences() {
        defaults.removePersistentDomain(forName: defaultsDomainName)
        defaults.synchronize()
    }

    private func removeItemIfPresent(at url: URL?) throws {
        guard let url, fileManager.fileExists(atPath: url.path) else {
            return
        }

        try fileManager.removeItem(at: url)
    }

    private static func defaultCacheDirectoryURL(fileManager: FileManager, bundleIdentifier: String) -> URL? {
        guard let cacheBaseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        return cacheBaseURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    private static func defaultSavedApplicationStateURL(fileManager: FileManager, bundleIdentifier: String) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
    }
}
