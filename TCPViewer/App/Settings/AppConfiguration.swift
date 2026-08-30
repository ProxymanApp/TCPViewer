//
//  AppConfiguration.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import AppKit
import Foundation

enum AppAppearanceTheme: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    fileprivate var appearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            nil
        case .light:
            .aqua
        case .dark:
            .darkAqua
        }
    }
}

final class AppConfiguration: NSObject {
    static let didChangeNotification = Notification.Name("AppConfigurationDidChange")
    static let defaultPacketFontSize: CGFloat = 12
    static let minimumPacketFontSize: CGFloat = 10
    static let maximumPacketFontSize: CGFloat = 24

    private enum Key {
        static let sharesAnalytics = "TCPViewer.settings.privacy.sharesAnalytics"
        static let sharesCrashReports = "TCPViewer.settings.privacy.sharesCrashReports"
        static let packetFontSize = "TCPViewer.settings.appearance.packetFontSize"
        static let usesMonospacedPacketFont = "TCPViewer.settings.appearance.usesMonospacedPacketFont"
        static let appearanceTheme = "TCPViewer.settings.appearance.theme"
        static let confirmsBeforeQuitting = "TCPViewer.settings.quit.confirmsBeforeQuitting"
        static let isMCPServerEnabled = "TCPViewer.settings.mcp.serverEnabled"
        static let mcpRedactsSensitiveData = "TCPViewer.settings.mcp.redactsSensitiveData"
    }

    private let defaults: UserDefaults
    let interfaceSelectionHistory: InterfaceSelectionHistoryStore
    var userDefaults: UserDefaults { defaults }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.interfaceSelectionHistory = InterfaceSelectionHistoryStore(defaults: defaults)
        super.init()
        registerDefaults()
    }

    var sharesAnalytics: Bool {
        get { defaults.bool(forKey: Key.sharesAnalytics) }
        set { persist(newValue, forKey: Key.sharesAnalytics) }
    }

    var sharesCrashReports: Bool {
        get { defaults.bool(forKey: Key.sharesCrashReports) }
        set { persist(newValue, forKey: Key.sharesCrashReports) }
    }

    var packetFontSize: CGFloat {
        get {
            let rawValue = CGFloat(defaults.double(forKey: Key.packetFontSize))
            guard rawValue.isFinite, rawValue > 0 else {
                return Self.defaultPacketFontSize
            }

            return Self.clampedPacketFontSize(rawValue)
        }
        set {
            persist(Double(Self.clampedPacketFontSize(newValue)), forKey: Key.packetFontSize)
        }
    }

    var usesMonospacedPacketFont: Bool {
        get { defaults.bool(forKey: Key.usesMonospacedPacketFont) }
        set { persist(newValue, forKey: Key.usesMonospacedPacketFont) }
    }

    var appearanceTheme: AppAppearanceTheme {
        get {
            guard let rawValue = defaults.string(forKey: Key.appearanceTheme),
                  let theme = AppAppearanceTheme(rawValue: rawValue) else {
                return .system
            }

            return theme
        }
        set { persist(newValue.rawValue, forKey: Key.appearanceTheme) }
    }

    var confirmsBeforeQuitting: Bool {
        get { defaults.bool(forKey: Key.confirmsBeforeQuitting) }
        set { persist(newValue, forKey: Key.confirmsBeforeQuitting) }
    }

    var isMCPServerEnabled: Bool {
        get { defaults.bool(forKey: Key.isMCPServerEnabled) }
        set { persist(newValue, forKey: Key.isMCPServerEnabled) }
    }

    var mcpRedactsSensitiveData: Bool {
        get { defaults.bool(forKey: Key.mcpRedactsSensitiveData) }
        set { persist(newValue, forKey: Key.mcpRedactsSensitiveData) }
    }

    // Apply the selected app appearance while keeping System mode delegated to macOS.
    func applyAppearance(to application: NSApplication = .shared) {
        let name = appearanceTheme.appearanceName
        application.appearance = name.flatMap { NSAppearance(named: $0) }
    }

    var packetRowHeight: CGFloat {
        ceil(max(22, packetFontSize + 12))
    }

    // Return the packet text font requested by Appearance settings.
    func packetFont(sizeDelta: CGFloat = 0, weight: NSFont.Weight = .regular) -> NSFont {
        let fontSize = max(8, packetFontSize + sizeDelta)
        if usesMonospacedPacketFont {
            return .monospacedSystemFont(ofSize: fontSize, weight: weight)
        }

        return .systemFont(ofSize: fontSize, weight: weight)
    }

    // Restore persisted settings back to the app defaults.
    func resetToDefaults() {
        defaults.removeObject(forKey: Key.sharesAnalytics)
        defaults.removeObject(forKey: Key.sharesCrashReports)
        defaults.removeObject(forKey: Key.packetFontSize)
        defaults.removeObject(forKey: Key.usesMonospacedPacketFont)
        defaults.removeObject(forKey: Key.appearanceTheme)
        defaults.removeObject(forKey: Key.confirmsBeforeQuitting)
        defaults.removeObject(forKey: Key.isMCPServerEnabled)
        defaults.removeObject(forKey: Key.mcpRedactsSensitiveData)
        interfaceSelectionHistory.clear()
        registerDefaults()
        notifyChange()
    }

    // Restore only Appearance settings without changing Privacy choices.
    func resetAppearanceToDefaults() {
        defaults.removeObject(forKey: Key.packetFontSize)
        defaults.removeObject(forKey: Key.usesMonospacedPacketFont)
        defaults.removeObject(forKey: Key.appearanceTheme)
        registerDefaults()
        notifyChange()
    }

    // Reset one CLI-exposed preference without affecting unrelated app state.
    func resetCLISetting(named name: String) -> Bool {
        let key: String
        switch name {
        case "theme": key = Key.appearanceTheme
        case "packet_font_size": key = Key.packetFontSize
        case "monospaced_font": key = Key.usesMonospacedPacketFont
        case "analytics": key = Key.sharesAnalytics
        case "crash_reports": key = Key.sharesCrashReports
        case "quit_confirmation": key = Key.confirmsBeforeQuitting
        case "mcp_enabled": key = Key.isMCPServerEnabled
        case "mcp_redaction": key = Key.mcpRedactsSensitiveData
        default: return false
        }
        defaults.removeObject(forKey: key)
        registerDefaults()
        notifyChange()
        return true
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.sharesAnalytics: true,
            Key.sharesCrashReports: true,
            Key.packetFontSize: Double(Self.defaultPacketFontSize),
            Key.usesMonospacedPacketFont: true,
            Key.appearanceTheme: AppAppearanceTheme.system.rawValue,
            Key.confirmsBeforeQuitting: true,
            Key.isMCPServerEnabled: false,
            Key.mcpRedactsSensitiveData: true,
        ])
    }

    private func persist(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChange()
    }

    private func persist(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChange()
    }

    private func persist(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func clampedPacketFontSize(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumPacketFontSize), maximumPacketFontSize)
    }
}
