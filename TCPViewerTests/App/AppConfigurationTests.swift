import Foundation
import Testing
@testable import TCPViewer

struct AppConfigurationTests {
    @Test func defaultsMatchInitialSettingsDesign() {
        let configuration = AppConfiguration(defaults: Self.makeUserDefaults())

        #expect(configuration.sharesAnalytics)
        #expect(configuration.sharesCrashReports)
        #expect(configuration.usesMonospacedPacketFont)
        #expect(configuration.packetFontSize == AppConfiguration.defaultPacketFontSize)
        #expect(configuration.appearanceTheme == .system)
    }

    @Test func persistsPrivacyAndAppearanceSettings() {
        let defaults = Self.makeUserDefaults()
        let configuration = AppConfiguration(defaults: defaults)

        configuration.sharesAnalytics = false
        configuration.sharesCrashReports = false
        configuration.usesMonospacedPacketFont = false
        configuration.packetFontSize = 16
        configuration.appearanceTheme = .dark

        let reloadedConfiguration = AppConfiguration(defaults: defaults)
        #expect(!reloadedConfiguration.sharesAnalytics)
        #expect(!reloadedConfiguration.sharesCrashReports)
        #expect(!reloadedConfiguration.usesMonospacedPacketFont)
        #expect(reloadedConfiguration.packetFontSize == 16)
        #expect(reloadedConfiguration.appearanceTheme == .dark)
    }

    @Test func clampsInvalidFontSizes() {
        let configuration = AppConfiguration(defaults: Self.makeUserDefaults())

        configuration.packetFontSize = 1
        #expect(configuration.packetFontSize == AppConfiguration.minimumPacketFontSize)

        configuration.packetFontSize = 200
        #expect(configuration.packetFontSize == AppConfiguration.maximumPacketFontSize)
    }

    @Test func packetRowHeightScalesWithFontSize() {
        let configuration = AppConfiguration(defaults: Self.makeUserDefaults())

        configuration.packetFontSize = 10
        #expect(configuration.packetRowHeight == 22)

        configuration.packetFontSize = 12
        #expect(configuration.packetRowHeight == 24)

        configuration.packetFontSize = 18
        #expect(configuration.packetRowHeight == 30)
    }

    @Test func resetAppearanceKeepsPrivacySettings() {
        let configuration = AppConfiguration(defaults: Self.makeUserDefaults())
        configuration.sharesAnalytics = false
        configuration.sharesCrashReports = false
        configuration.packetFontSize = 18
        configuration.usesMonospacedPacketFont = false
        configuration.appearanceTheme = .dark

        configuration.resetAppearanceToDefaults()

        #expect(!configuration.sharesAnalytics)
        #expect(!configuration.sharesCrashReports)
        #expect(configuration.packetFontSize == AppConfiguration.defaultPacketFontSize)
        #expect(configuration.usesMonospacedPacketFont)
        #expect(configuration.appearanceTheme == .system)
    }

    @Test func invalidThemeFallsBackToSystem() {
        let defaults = Self.makeUserDefaults()
        defaults.set("neon", forKey: "TCPViewer.settings.appearance.theme")

        let configuration = AppConfiguration(defaults: defaults)

        #expect(configuration.appearanceTheme == .system)
    }

    private static func makeUserDefaults() -> UserDefaults {
        let suiteName = "AppConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
