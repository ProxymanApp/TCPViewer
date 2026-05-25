//
//  TCPViewerSentryService.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/5/26.
//

import Foundation
import Sentry

enum TCPViewerSentryConfiguration {
    static let dsnInfoKey = "TCPViewerSentryDSN"

    // Return a configured DSN only when local build settings resolved it.
    static func dsn(from bundle: Bundle = .main) -> String? {
        resolvedValue(bundle.object(forInfoDictionaryKey: dsnInfoKey) as? String)
    }

    // Reject empty values and unresolved Xcode placeholders.
    static func resolvedValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("$(") else {
            return nil
        }

        return value
    }
}

final class TCPViewerSentryService {
    private let configuration: AppConfiguration
    private let bundle: Bundle
    private let notificationCenter: NotificationCenter
    private let controller: TCPViewerSentryControlling
    private let dsnProvider: () -> String?
    private var settingsObserver: NSObjectProtocol?

    init(
        configuration: AppConfiguration,
        bundle: Bundle = .main,
        notificationCenter: NotificationCenter = .default,
        controller: TCPViewerSentryControlling = TCPViewerSentrySDKController(),
        dsnProvider: (() -> String?)? = nil
    ) {
        self.configuration = configuration
        self.bundle = bundle
        self.notificationCenter = notificationCenter
        self.controller = controller
        self.dsnProvider = dsnProvider ?? {
            TCPViewerSentryConfiguration.dsn(from: bundle)
        }
    }

    deinit {
        if let settingsObserver {
            notificationCenter.removeObserver(settingsObserver)
        }
    }

    // Observe Privacy settings and apply the current crash-report preference.
    func start() {
        observeSettingsIfNeeded()
        applyCrashReportPreference()
    }

    private func observeSettingsIfNeeded() {
        guard settingsObserver == nil else {
            return
        }

        settingsObserver = notificationCenter.addObserver(
            forName: AppConfiguration.didChangeNotification,
            object: configuration,
            queue: nil
        ) { [weak self] _ in
            self?.applyCrashReportPreference()
        }
    }

    private func applyCrashReportPreference() {
        guard configuration.sharesCrashReports else {
            controller.close()
            return
        }

        guard let dsn = dsnProvider() else {
            return
        }

        controller.start(dsn: dsn) { [weak configuration] in
            configuration?.sharesCrashReports == true
        }
    }
}

protocol TCPViewerSentryControlling: AnyObject {
    var isStarted: Bool { get }

    func start(dsn: String, isCrashReportingAllowed: @escaping () -> Bool)
    func close()
}

final class TCPViewerSentrySDKController: TCPViewerSentryControlling {
    var isStarted: Bool {
        SentrySDK.isEnabled
    }

    // Configure Sentry as crash-report-only telemetry for the Privacy crash report toggle.
    func start(dsn: String, isCrashReportingAllowed: @escaping () -> Bool) {
        guard !isStarted else {
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = false
            options.enabled = true
            options.enableSwizzling = false
            options.enableAutoSessionTracking = false
            options.enableAutoPerformanceTracing = false
            options.enableWatchdogTerminationTracking = false
            options.enableAppHangTracking = false
            options.shutdownTimeInterval = 0
            options.sendDefaultPii = false
            options.beforeSend = { event in
                isCrashReportingAllowed() ? event : nil
            }
        }
    }

    func close() {
        guard isStarted else {
            return
        }

        SentrySDK.close()
    }
}
