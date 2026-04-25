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
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.sharesAnalytics: true,
            Key.sharesCrashReports: true,
            Key.packetFontSize: Double(Self.defaultPacketFontSize),
            Key.usesMonospacedPacketFont: true,
            Key.appearanceTheme: AppAppearanceTheme.system.rawValue,
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
