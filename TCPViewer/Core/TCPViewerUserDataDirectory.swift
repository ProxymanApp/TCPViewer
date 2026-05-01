//
//  TCPViewerUserDataDirectory.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import Foundation

final class TCPViewerUserDataDirectory {
    static let shared = TCPViewerUserDataDirectory()

    private static let appFolderName = "TCPViewer"
    private static let settingsFolderName = "settings"

    private let fileManager: FileManager
    private let applicationSupportBaseURL: URL

    init(fileManager: FileManager = .default, applicationSupportBaseURL: URL? = nil) {
        self.fileManager = fileManager
        self.applicationSupportBaseURL = applicationSupportBaseURL ?? Self.defaultApplicationSupportBaseURL(fileManager: fileManager)
    }

    var appDirectoryURL: URL {
        applicationSupportBaseURL.appendingPathComponent(Self.appFolderName, isDirectory: true)
    }

    var settingsDirectoryURL: URL {
        appDirectoryURL.appendingPathComponent(Self.settingsFolderName, isDirectory: true)
    }

    func settingsFileURL(named fileName: String) -> URL {
        settingsDirectoryURL.appendingPathComponent(fileName)
    }

    @discardableResult
    func createSettingsDirectoryIfNeeded() throws -> URL {
        try fileManager.createDirectory(at: settingsDirectoryURL, withIntermediateDirectories: true)
        return settingsDirectoryURL
    }

    private static func defaultApplicationSupportBaseURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
