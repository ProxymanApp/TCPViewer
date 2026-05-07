//
//  TCPViewerSettingsView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 25/4/26.
//

import AppKit
import SwiftUI

enum TCPViewerSettingsLayout {
    static let windowWidth: CGFloat = 600
    static let paneWidth: CGFloat = 460
    static let verticalPadding: CGFloat = 30
    static let horizontalPadding: CGFloat = 28
    static let rowTitleWidth: CGFloat = 116
    static let rowSpacing: CGFloat = 12
    static let rowContentWidth: CGFloat = paneWidth - rowTitleWidth - rowSpacing
    static let rowContentLeadingInset: CGFloat = rowTitleWidth + rowSpacing
}

struct TCPViewerPrivacySettingsView: View {
    let configuration: AppConfiguration

    @State private var sharesAnalytics: Bool
    @State private var sharesCrashReports: Bool

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self._sharesAnalytics = State(initialValue: configuration.sharesAnalytics)
        self._sharesCrashReports = State(initialValue: configuration.sharesCrashReports)
    }

    var body: some View {
        SettingsPane {
            SettingsRow(
                title: "Analytics:",
                detail: "Help improve TCP Viewer by automatically sending anonymous diagnostics and usage data."
            ) {
                Toggle("Share analytics with Proxyman", isOn: $sharesAnalytics)
            }

            SettingsRow(
                title: "Crash Report:",
                detail: "Help improve stability by sending an anonymous crash report if TCP Viewer exits unexpectedly. Reports do not contain personal information."
            ) {
                Toggle("Share crash report with Proxyman", isOn: $sharesCrashReports)
            }

            HStack(spacing: 6) {
                Spacer()
                    .frame(width: TCPViewerSettingsLayout.rowContentLeadingInset)
                Text("Powered by Sentry")
                    .fontWeight(.medium)
                Image(systemName: "arrow.up.right.circle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                    .frame(width: TCPViewerSettingsLayout.rowContentLeadingInset)
                Button {
                    openPrivacyPolicy()
                } label: {
                    Label("Privacy Policy", systemImage: "arrow.up.right")
                }
            }
        }
        .onChange(of: sharesAnalytics) { _, newValue in
            configuration.sharesAnalytics = newValue
        }
        .onChange(of: sharesCrashReports) { _, newValue in
            configuration.sharesCrashReports = newValue
        }
    }

    private func openPrivacyPolicy() {
        guard let url = URL(string: "https://proxyman.io/privacy") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

struct TCPViewerAppearanceSettingsView: View {
    let configuration: AppConfiguration

    @State private var packetFontSize: Double
    @State private var usesMonospacedPacketFont: Bool
    @State private var appearanceTheme: AppAppearanceTheme

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self._packetFontSize = State(initialValue: Double(configuration.packetFontSize))
        self._usesMonospacedPacketFont = State(initialValue: configuration.usesMonospacedPacketFont)
        self._appearanceTheme = State(initialValue: configuration.appearanceTheme)
    }

    var body: some View {
        SettingsPane {
            SettingsRow(
                title: "Font Size:",
                detail: "Used by packet-oriented text such as tables and payload views."
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: $packetFontSize,
                        in: Double(AppConfiguration.minimumPacketFontSize)...Double(AppConfiguration.maximumPacketFontSize),
                        step: 1
                    )
                    .frame(width: 190)

                    TextField("", value: $packetFontSize, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)

                    Stepper("", value: $packetFontSize, in: Double(AppConfiguration.minimumPacketFontSize)...Double(AppConfiguration.maximumPacketFontSize), step: 1)
                        .labelsHidden()
                }
            }

            SettingsRow(title: "Font:") {
                Toggle("Use monospaced font for packet text", isOn: $usesMonospacedPacketFont)
            }

            SettingsRow(
                title: "Theme:",
                detail: "System follows the current macOS Light or Dark appearance."
            ) {
                Picker("", selection: $appearanceTheme) {
                    ForEach(AppAppearanceTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            SettingsRow(title: "Preview:") {
                Text("GET /packets tcp port 443")
                    .font(.system(size: packetFontSize, design: usesMonospacedPacketFont ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack {
                Spacer()
                    .frame(width: TCPViewerSettingsLayout.rowContentLeadingInset)
                Button {
                    restoreAppearanceDefaults()
                } label: {
                    Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .onChange(of: packetFontSize) { _, newValue in
            configuration.packetFontSize = CGFloat(newValue)
            packetFontSize = Double(configuration.packetFontSize)
        }
        .onChange(of: usesMonospacedPacketFont) { _, newValue in
            configuration.usesMonospacedPacketFont = newValue
        }
        .onChange(of: appearanceTheme) { _, newValue in
            configuration.appearanceTheme = newValue
            configuration.applyAppearance()
        }
    }

    private func restoreAppearanceDefaults() {
        configuration.resetAppearanceToDefaults()
        packetFontSize = Double(configuration.packetFontSize)
        usesMonospacedPacketFont = configuration.usesMonospacedPacketFont
        appearanceTheme = configuration.appearanceTheme
        configuration.applyAppearance()
    }
}

struct TCPViewerHelperToolSettingsView: View {
    let manager: any TCPViewerNetworkHelperToolManaging

    @State private var snapshot: TCPViewerNetworkHelperToolSnapshot
    @State private var isShowingHelperError = false

    init(manager: any TCPViewerNetworkHelperToolManaging) {
        self.manager = manager
        self._snapshot = State(initialValue: manager.snapshot)
    }

    var body: some View {
        CenteredSettingsPane {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: statusImageName)
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusTint)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(statusTitle)
                            .font(.system(size: 17, weight: .semibold))

                        if shouldShowHelperErrorButton {
                            helperErrorButton
                        }
                    }

                    Text(statusMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(lastCheckedText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 8) {
                Button {
                    refreshStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(snapshot.status == .installing)

                Button {
                    openHelperToolPath()
                } label: {
                    Label("Open Helper Path", systemImage: "folder")
                }

                if snapshot.status == .waitingForApproval {
                    Button {
                        manager.openSystemSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                }

                if canUninstallHelper {
                    Button {
                        uninstallHelper()
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .disabled(snapshot.status == .installing)
                }

                primaryAction
            }

        }
        .onAppear {
            refreshStatus()
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch snapshot.status {
        case .notInstalled, .unsupported:
            Button {
                installHelper()
            } label: {
                Label("Install", systemImage: "arrow.down.circle")
            }
        case .waitingForApproval:
            Button {
                manager.openSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
        case .installedNeedsRelaunch:
            Button {
                relaunchTCPViewer()
            } label: {
                Label("Relaunch TCP Viewer", systemImage: "arrow.triangle.2.circlepath")
            }
        case .broken:
            Button {
                snapshot = manager.repair { snapshot = $0 }
            } label: {
                Label("Repair", systemImage: "wrench.and.screwdriver")
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var canUninstallHelper: Bool {
        switch snapshot.status {
        case .waitingForApproval, .installedNeedsRelaunch, .ready, .broken, .unsupported:
            true
        case .notInstalled, .installing:
            false
        }
    }

    private var shouldShowHelperErrorButton: Bool {
        snapshot.status == .notInstalled
    }

    private var statusTitle: String {
        switch snapshot.status {
        case .notInstalled:
            TCPViewerNetworkHelperConstants.displayName
        default:
            snapshot.title
        }
    }

    private var statusMessage: String {
        switch snapshot.status {
        case .notInstalled:
            // Keep the header compact; the detailed installation reason lives in the error popover.
            "Not installed"
        default:
            snapshot.message
        }
    }

    private var helperErrorButton: some View {
        Button {
            isShowingHelperError = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Error")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $isShowingHelperError, arrowEdge: .bottom) {
            helperErrorPopover
        }
    }

    private var helperErrorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Helper Tool Not Installed", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)

            Text(snapshot.message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    isShowingHelperError = false
                    installHelper()
                } label: {
                    Label("Install Helper Tool", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut(.defaultAction)

                Button("Dismiss") {
                    isShowingHelperError = false
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var statusImageName: String {
        switch snapshot.status {
        case .ready:
            "checkmark.shield.fill"
        case .installedNeedsRelaunch:
            "arrow.triangle.2.circlepath"
        case .notInstalled, .waitingForApproval, .installing:
            "lock.shield"
        case .broken, .unsupported:
            "exclamationmark.shield"
        }
    }

    private var statusTint: Color {
        switch snapshot.status {
        case .ready:
            .green
        case .installedNeedsRelaunch, .waitingForApproval, .installing:
            .orange
        case .notInstalled:
            .accentColor
        case .broken, .unsupported:
            .red
        }
    }

    private var lastCheckedText: String {
        guard let date = snapshot.lastCheckedAt else {
            return "Status has not been checked yet."
        }

        return "Last checked \(Self.dateFormatter.string(from: date))"
    }

    private func refreshStatus() {
        snapshot = manager.refreshStatus { snapshot = $0 }
    }

    private func installHelper() {
        snapshot = manager.install { snapshot = $0 }
    }

    private func uninstallHelper() {
        snapshot = manager.uninstall { snapshot = $0 }
    }

    private func openHelperToolPath() {
        let helperURL = URL(fileURLWithPath: TCPViewerNetworkHelperConstants.installedHelperToolPath)
        if FileManager.default.fileExists(atPath: helperURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([helperURL])
        } else {
            NSWorkspace.shared.open(helperURL.deletingLastPathComponent())
        }
    }

    private func relaunchTCPViewer() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct TCPViewerMoreAppsSettingsView: View {
    var body: some View {
        CenteredSettingsPane {
            ProductRow(
                systemImage: "desktopcomputer",
                title: "Proxyman for macOS, Windows, Linux",
                detail: "Inspect, debug, and rewrite HTTP traffic on desktop."
            )
            ProductRow(
                systemImage: "iphone.and.arrow.forward",
                title: "Proxyman iOS, Android",
                detail: "Capture and inspect mobile traffic while you build and test."
            )
            ProductRow(
                systemImage: "shield.lefthalf.filled",
                title: "TinyShield",
                detail: "A focused network privacy companion for everyday protection."
            )
        }
    }
}

private struct ProductRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 380, alignment: .leading)
        }
    }
}

private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .frame(width: TCPViewerSettingsLayout.paneWidth, alignment: .leading)
        .padding(.vertical, TCPViewerSettingsLayout.verticalPadding)
        .padding(.horizontal, TCPViewerSettingsLayout.horizontalPadding)
        .frame(width: TCPViewerSettingsLayout.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CenteredSettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            content
        }
        .frame(width: TCPViewerSettingsLayout.paneWidth, alignment: .center)
        .padding(.vertical, TCPViewerSettingsLayout.verticalPadding)
        .padding(.horizontal, TCPViewerSettingsLayout.horizontalPadding)
        .frame(width: TCPViewerSettingsLayout.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: NSFont.systemFontSize, weight: .semibold))
                .frame(width: TCPViewerSettingsLayout.rowTitleWidth, alignment: .trailing)

            VStack(alignment: .leading, spacing: 7) {
                content
                if let detail {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: TCPViewerSettingsLayout.rowContentWidth, alignment: .leading)
        }
        .frame(width: TCPViewerSettingsLayout.paneWidth, alignment: .leading)
    }
}
