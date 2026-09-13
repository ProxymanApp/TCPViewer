//
//  TCPViewerCLICommandRouter.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import AppKit
import Foundation
import PcapPlusPlusCore

protocol TCPViewerCLICommandRouting: AnyObject {
    func route(_ request: TCPViewerCLIRequest, completion: @escaping (TCPViewerCLIResponse) -> Void)
}

final class TCPViewerCLICommandRouter: TCPViewerCLICommandRouting {
    private weak var appDelegate: AppDelegate?
    private let dataSourceOverride: (() -> (any TCPViewerMCPDataSource)?)?
    private let licenseService: TCPViewerLicenseService
    private lazy var mcpRouter = TCPViewerMCPCommandRouter(
        dataSourceProvider: { [weak self] in self?.dataSourceOverride?() ?? TCPViewerMCPServiceProvider.shared.activeSource() },
        isLicenseAuthorized: { [licenseService] in licenseService.isLicenseAuthorized },
        requiresAuthorizedLicense: false,
        redactionEnabled: { false }
    )

    init(
        appDelegate: AppDelegate,
        licenseService: TCPViewerLicenseService = .shared,
        dataSourceProvider: (() -> (any TCPViewerMCPDataSource)?)? = nil
    ) {
        self.appDelegate = appDelegate
        self.dataSourceOverride = dataSourceProvider
        self.licenseService = licenseService
    }

    // Route one validated request while keeping AppKit and workspace access on the main thread.
    func route(_ request: TCPViewerCLIRequest, completion: @escaping (TCPViewerCLIResponse) -> Void) {
        precondition(Thread.isMainThread)
        switch request.command {
        case .licenseStatus:
            completion(success(request, data: licenseStatusData()))
        case .licenseActivate:
            activateLicense(request, completion: completion)
        case .licenseRevoke:
            revokeLicense(request, completion: completion)
        case .settingsList, .settingsGet, .settingsSet, .settingsReset:
            routeSettings(request, completion: completion)
        default:
            routeThroughMCP(request, completion: completion)
        }
    }

    private func routeThroughMCP(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard let appDelegate else {
            completion(failure(request, code: "app_unavailable", message: "TCP Viewer is unavailable."))
            return
        }
        if request.command != .appStatus && dataSourceOverride == nil &&
            !["workspace_id", "tab_id", "pane_id"].contains(where: { request.value($0) != nil }) {
            appDelegate.cliPrepareWorkspace(creatingTab: request.command == .fileImport || request.command == .tabsCreate)
        }
        guard let command = mcpCommand(for: request.command) else {
            completion(failure(request, code: "unsupported_command", message: "The command is not supported."))
            return
        }

        var parameters = request.params.mapValues(mcpValue)
        if request.command == .captureStart, request.string("capture_filter") != nil {
            parameters["confirm_bpf_filter"] = .bool(true)
        }
        if request.command == .fileExport {
            parameters["apply_result_pagination"] = .bool(true)
        }
        mcpRouter.route(TCPViewerMCPRequest(command: command.rawValue, params: parameters)) { response in
            guard response.success, let data = response.data else {
                completion(self.failure(
                    request,
                    code: request.command == .fileImport ? "import_failed" : request.command == .fileExportSession ? "export_failed" : request.command == .streamFollow ? "follow_failed" : "app_command_failed",
                    message: response.error ?? "TCP Viewer could not complete the command.",
                    data: response.data?.mapValuesWithKeys { key, value in self.cliValue(value, key: key) }
                ))
                return
            }
            if request.command == .packetsReveal {
                appDelegate.cliRevealActiveWindow()
            }
            var cliData = data.mapValuesWithKeys { key, value in self.cliValue(value, key: key) }
            if request.command == .appStatus {
                let snapshot = TCPViewerMCPServiceProvider.shared.activeSource()?.mcpWorkspaceSnapshot()
                cliData["running"] = .bool(true)
                cliData["cli_version"] = .string(TCPViewerLicenseAppVersion.current.appVersion)
                cliData["cli_build"] = .string(TCPViewerLicenseAppVersion.current.buildNumber)
                cliData["license_state"] = .string(self.licenseService.isLicenseAuthorized ? "authorized" : "not_activated")
                cliData["active_document"] = snapshot?.documentURL.map { .string($0.path) } ?? .null
            }
            completion(self.success(request, data: cliData))
        }
    }

    private func mcpCommand(for command: TCPViewerCLICommand) -> TCPViewerMCPCommand? {
        switch command {
        case .workspaceList: .listWorkspaces
        case .tabsList: .listTabs
        case .tabsCreate: .createTab
        case .tabsSelect: .selectTab
        case .tabsMove: .moveTab
        case .tabsClose: .closeTab
        case .paneGet: .getPane
        case .paneUpdate: .updatePane
        case .splitSet: .setSplitView
        case .paneFocus: .focusPane
        case .sourcesList: .listSources
        case .overviewGet: .getOverviewStatistics
        case .statisticsEndpoints: .getEndpointStatistics
        case .appStatus: .getAppStatus
        case .interfacesList: .listInterfaces
        case .captureStatus: .getCaptureOverview
        case .captureStart: .startCapture
        case .capturePause: .pauseCapture
        case .captureResume: .resumeCapture
        case .captureStop: .stopCapture
        case .packetsList: .queryPackets
        case .packetsSummary: .summarizeCapture
        case .packetsDetails: .getPacketDetails
        case .packetsBytes: .getPacketBytes
        case .packetsClear: .clearPackets
        case .packetsReveal: .revealPacket
        case .streamPackets: .listStreamPackets
        case .fileExport: .exportPackets
        case .fileImport: .importCapture
        case .fileExportSession: .exportSession
        case .streamFollow: .followStream
        default: nil
        }
    }

    static func followData(_ stream: FollowStream, direction: String, encoding: String,
                           maximumBytes: Int, maximumRecords: Int) -> [String: TCPViewerCLIValue] {
        let values = TCPViewerAutomationStreamSerializer.data(stream, direction: direction, encoding: encoding,
                                                              maximumBytes: maximumBytes, maximumRecords: maximumRecords)
        guard let data = try? JSONEncoder().encode(values),
              let result = try? JSONDecoder().decode([String: TCPViewerCLIValue].self, from: data) else { return [:] }
        return result
    }

    private func activateLicense(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard let key = request.string("license_key"), key.hasPrefix("TCPV-"), key.utf8.count <= 4_096 else {
            completion(failure(request, code: "invalid_parameter", message: "A valid TCP Viewer license key is required."))
            return
        }
        licenseService.activate(licenseKey: key) { status in
            guard status.isAuthorized else {
                let message: String
                if case .unauthorized(let error) = status {
                    message = error.localizedDescription.replacingOccurrences(of: key, with: "<redacted>")
                } else {
                    message = "The license could not be activated."
                }
                completion(self.failure(request, code: "license_activation_failed", message: message))
                return
            }
            completion(self.success(request, data: self.licenseStatusData()))
        }
    }

    private func revokeLicense(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard request.bool("confirm") == true else {
            completion(failure(request, code: "confirmation_required", message: "License revocation requires confirmation."))
            return
        }
        licenseService.revokeCurrentDevice { result in
            switch result {
            case .success:
                completion(self.success(request, data: ["authorized": .bool(false), "revoked": .bool(true)]))
            case .failure(let error):
                completion(self.failure(request, code: "license_revoke_failed", error: error))
            }
        }
    }

    private func licenseStatusData() -> [String: TCPViewerCLIValue] {
        guard let license = licenseService.currentLicense, licenseService.isLicenseAuthorized else {
            return ["authorized": .bool(false)]
        }
        return [
            "authorized": .bool(true),
            "email": .string(license.email),
            "license_type": .string(license.licenseType.rawValue),
            "update_expiry": .string(license.expiryDate),
            "lifetime_updates": .bool(license.hasLifetimeUpdates),
        ]
    }

    private func routeSettings(
        _ request: TCPViewerCLIRequest,
        completion: @escaping (TCPViewerCLIResponse) -> Void
    ) {
        guard let appDelegate else {
            completion(failure(request, code: "app_unavailable", message: "TCP Viewer is unavailable."))
            return
        }
        let configuration = appDelegate.appConfiguration
        do {
            switch request.command {
            case .settingsList:
                completion(success(request, data: ["settings": .object(settings(configuration))]))
            case .settingsGet:
                guard let key = request.string("key"), let value = settings(configuration)[key] else {
                    throw CLIError(code: "unknown_setting", message: "The setting key is not supported.")
                }
                completion(success(request, data: ["key": .string(key), "value": value]))
            case .settingsSet:
                guard let key = request.string("key"), let rawValue = request.string("value") else {
                    throw CLIError(code: "invalid_parameter", message: "A setting key and value are required.")
                }
                try setSetting(key, value: rawValue, configuration: configuration)
                appDelegate.cliRefreshSettings()
                completion(success(request, data: ["key": .string(key), "value": settings(configuration)[key] ?? .null]))
            case .settingsReset:
                if request.bool("all") == true {
                    for key in settings(configuration).keys { _ = configuration.resetCLISetting(named: key) }
                    appDelegate.cliRefreshSettings()
                    completion(success(request, data: ["settings": .object(settings(configuration))]))
                } else if let key = request.string("key"), configuration.resetCLISetting(named: key) {
                    appDelegate.cliRefreshSettings()
                    completion(success(request, data: ["key": .string(key), "value": settings(configuration)[key] ?? .null]))
                } else {
                    throw CLIError(code: "unknown_setting", message: "The setting key is not supported.")
                }
            default:
                throw CLIError(code: "unsupported_command", message: "The settings command is not supported.")
            }
        } catch let error as CLIError {
            completion(failure(request, code: error.code, message: error.message))
        } catch {
            completion(failure(request, code: "invalid_parameter", error: error))
        }
    }

    private func settings(_ configuration: AppConfiguration) -> [String: TCPViewerCLIValue] {
        [
            "theme": .string(configuration.appearanceTheme.rawValue),
            "packet_font_size": .double(Double(configuration.packetFontSize)),
            "monospaced_font": .bool(configuration.usesMonospacedPacketFont),
            "analytics": .bool(configuration.sharesAnalytics),
            "crash_reports": .bool(configuration.sharesCrashReports),
            "quit_confirmation": .bool(configuration.confirmsBeforeQuitting),
            "mcp_enabled": .bool(configuration.isMCPServerEnabled),
            "mcp_redaction": .bool(configuration.mcpRedactsSensitiveData),
        ]
    }

    private func setSetting(_ key: String, value: String, configuration: AppConfiguration) throws {
        switch key {
        case "theme":
            guard let theme = AppAppearanceTheme(rawValue: value.lowercased()) else {
                throw CLIError(code: "invalid_setting_value", message: "theme must be system, light, or dark.")
            }
            configuration.appearanceTheme = theme
        case "packet_font_size":
            guard let size = Double(value), size.isFinite,
                  Double(AppConfiguration.minimumPacketFontSize)...Double(AppConfiguration.maximumPacketFontSize) ~= size else {
                throw CLIError(code: "invalid_setting_value", message: "packet_font_size must be between 10 and 24.")
            }
            configuration.packetFontSize = CGFloat(size)
        case "monospaced_font": configuration.usesMonospacedPacketFont = try boolean(value)
        case "analytics": configuration.sharesAnalytics = try boolean(value)
        case "crash_reports": configuration.sharesCrashReports = try boolean(value)
        case "quit_confirmation": configuration.confirmsBeforeQuitting = try boolean(value)
        case "mcp_enabled": configuration.isMCPServerEnabled = try boolean(value)
        case "mcp_redaction": configuration.mcpRedactsSensitiveData = try boolean(value)
        default:
            throw CLIError(code: "unknown_setting", message: "The setting key is not supported.")
        }
    }

    private func boolean(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: throw CLIError(code: "invalid_setting_value", message: "Boolean settings accept true or false.")
        }
    }

    private func mcpValue(_ value: TCPViewerCLIValue) -> TCPViewerMCPValue {
        switch value {
        case .string(let value): .string(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .bool(let value): .bool(value)
        case .array(let value): .array(value.map(mcpValue))
        case .object(let value): .object(value.mapValues(mcpValue))
        case .null: .null
        }
    }

    private func cliValue(_ value: TCPViewerMCPValue, key: String? = nil) -> TCPViewerCLIValue {
        switch value {
        case .string(let value):
            if key == "direction" {
                return .string(value.replacingOccurrences(of: "clientToServer", with: "client_to_server")
                    .replacingOccurrences(of: "serverToClient", with: "server_to_client"))
            }
            return .string(value)
        case .int(let value): return .int(value)
        case .double(let value):
            if ["timestamp", "earliest_timestamp", "latest_timestamp"].contains(key) {
                return .string(Self.iso8601.string(from: Date(timeIntervalSince1970: value)))
            }
            return .double(value)
        case .bool(let value): return .bool(value)
        case .array(let value): return .array(value.map { cliValue($0) })
        case .object(let value): return .object(value.mapValuesWithKeys { key, value in cliValue(value, key: key) })
        case .null: return .null
        }
    }

    private func success(_ request: TCPViewerCLIRequest, data: [String: TCPViewerCLIValue]) -> TCPViewerCLIResponse {
        .success(requestID: request.requestID, command: request.command, data: data)
    }

    private func failure(
        _ request: TCPViewerCLIRequest,
        code: String,
        error: Error,
        data: [String: TCPViewerCLIValue]? = nil
    ) -> TCPViewerCLIResponse {
        failure(request, code: code, message: error.localizedDescription, data: data)
    }

    private func failure(
        _ request: TCPViewerCLIRequest,
        code: String,
        message: String,
        data: [String: TCPViewerCLIValue]? = nil
    ) -> TCPViewerCLIResponse {
        .failure(
            requestID: request.requestID,
            command: request.command,
            code: code,
            message: message,
            data: data
        )
    }

    private struct CLIError: Error {
        let code: String
        let message: String
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension Dictionary {
    func mapValuesWithKeys<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { key, value in (key, transform(key, value)) })
    }
}
