//
//  TCPViewerSentryConfigurationTests.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/5/26.
//

import Foundation
import Testing
@testable import TCPViewer

struct TCPViewerSentryConfigurationTests {
    @Test func resolvesTrimmedDSN() {
        let dsn = TCPViewerSentryConfiguration.resolvedValue("  https://public@example.ingest.sentry.io/1  ")

        #expect(dsn == "https://public@example.ingest.sentry.io/1")
    }

    @Test func resolvesXcconfigEscapedDSN() {
        let dsn = TCPViewerSentryConfiguration.resolvedValue("https:/$()/public@example.ingest.sentry.io/1")

        #expect(dsn == "https://public@example.ingest.sentry.io/1")
    }

    @Test func rejectsMissingAndPlaceholderDSN() {
        #expect(TCPViewerSentryConfiguration.resolvedValue(nil) == nil)
        #expect(TCPViewerSentryConfiguration.resolvedValue("  ") == nil)
        #expect(TCPViewerSentryConfiguration.resolvedValue("$(TCPVIEWER_SENTRY_DSN)") == nil)
    }

    @Test func rejectsTruncatedDSNFromUnescapedXcconfigURL() {
        #expect(TCPViewerSentryConfiguration.resolvedValue("http:") == nil)
        #expect(TCPViewerSentryConfiguration.resolvedValue("https:") == nil)
    }

    @Test func serviceStartsOnlyWhenCrashReportsAreEnabled() {
        let configuration = AppConfiguration(defaults: Self.makeUserDefaults())
        let controller = StubSentryController()
        let service = TCPViewerSentryService(
            configuration: configuration,
            controller: controller,
            dsnProvider: { "https://public@example.ingest.sentry.io/1" }
        )

        configuration.sharesCrashReports = false
        service.start()
        #expect(controller.startCalls.isEmpty)

        configuration.sharesCrashReports = true
        #expect(controller.startCalls == ["https://public@example.ingest.sentry.io/1"])
        #expect(controller.isCrashReportingAllowed?() == true)
    }

    @Test func serviceClosesWhenCrashReportsAreDisabled() {
        let configuration = AppConfiguration(defaults: Self.makeUserDefaults())
        let controller = StubSentryController()
        let service = TCPViewerSentryService(
            configuration: configuration,
            controller: controller,
            dsnProvider: { "https://public@example.ingest.sentry.io/1" }
        )

        service.start()
        #expect(controller.startCalls.count == 1)

        configuration.sharesCrashReports = false
        #expect(controller.closeCallCount == 1)
        #expect(controller.isCrashReportingAllowed?() == false)
    }

    @Test func serviceDoesNotStartWithoutConfiguredDSN() {
        let configuration = AppConfiguration(defaults: Self.makeUserDefaults())
        let controller = StubSentryController()
        let service = TCPViewerSentryService(
            configuration: configuration,
            controller: controller,
            dsnProvider: { nil }
        )

        service.start()

        #expect(controller.startCalls.isEmpty)
    }

    private static func makeUserDefaults() -> UserDefaults {
        let suiteName = "TCPViewerSentryConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class StubSentryController: TCPViewerSentryControlling {
    private(set) var startCalls: [String] = []
    private(set) var closeCallCount = 0
    private(set) var isCrashReportingAllowed: (() -> Bool)?

    var isStarted: Bool {
        !startCalls.isEmpty && closeCallCount == 0
    }

    func start(dsn: String, isCrashReportingAllowed: @escaping () -> Bool) {
        startCalls.append(dsn)
        self.isCrashReportingAllowed = isCrashReportingAllowed
    }

    func close() {
        guard isStarted else {
            return
        }

        closeCallCount += 1
    }
}
