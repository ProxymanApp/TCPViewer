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

    init(manager: any TCPViewerNetworkHelperToolManaging) {
        self.manager = manager
        self._snapshot = State(initialValue: manager.snapshot)
    }

    var body: some View {
        CenteredSettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                header

                Divider()
                    .opacity(0.5)

                VStack(alignment: .leading, spacing: 10) {
                    benefitRow("Capture live traffic without running TCP Viewer as root.")
                    benefitRow("Keep /dev/bpf* capture permissions repaired automatically.")
                }

                actionRow
            }
            .padding(20)
            .frame(width: 430, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            }
        }
        .onAppear {
            refreshStatus()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(statusTint.opacity(0.12))

                Image(systemName: statusImageName)
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusTint)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Helper Tool")
                        .font(.system(size: 18, weight: .semibold))

                    statusBadge
                }

                Text(statusDetail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusBadge: some View {
        Label(statusBadgeTitle, systemImage: statusBadgeImageName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(statusTint.opacity(0.12), in: Capsule())
    }

    private func benefitRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
        }
        .labelStyle(.titleAndIcon)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            primaryAction

            Button {
                openHelperToolPath()
            } label: {
                Label("Open Helper Path", systemImage: "folder")
            }

            if canUninstallHelper {
                Button(role: .destructive) {
                    uninstallHelper()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .disabled(snapshot.status == .installing)
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch snapshot.status {
        case .notInstalled, .unsupported:
            Button {
                installHelper()
            } label: {
                Label("Install Helper Tool", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .waitingForApproval:
            Button {
                manager.openSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .installedNeedsRelaunch:
            Button {
                relaunchTCPViewer()
            } label: {
                Label("Relaunch TCP Viewer", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .broken:
            Button {
                snapshot = manager.repair { snapshot = $0 }
            } label: {
                Label("Repair", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .ready:
            EmptyView()
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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

    private var statusBadgeTitle: String {
        switch snapshot.status {
        case .notInstalled:
            "Not Installed"
        case .waitingForApproval:
            "Needs Approval"
        case .installedNeedsRelaunch:
            "Needs Relaunch"
        case .ready:
            "Ready"
        case .broken:
            "Unavailable"
        case .unsupported:
            "Unsupported"
        case .installing:
            "Installing"
        }
    }

    private var statusDetail: String {
        switch snapshot.status {
        case .notInstalled:
            "Install the helper to let macOS grant TCP Viewer secure packet-capture access."
        case .waitingForApproval:
            "Approve TCP Viewer in System Settings to finish enabling live capture."
        case .installedNeedsRelaunch:
            "Relaunch TCP Viewer so macOS refreshes the helper permissions."
        case .ready:
            "The helper is installed and ready for live capture."
        case .broken:
            "Repair the helper so TCP Viewer can restore capture access."
        case .unsupported:
            "TCP Viewer cannot use the current helper state on this Mac."
        case .installing:
            "Registering the privileged helper with macOS."
        }
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

    private var statusBadgeImageName: String {
        switch snapshot.status {
        case .ready:
            "checkmark.circle.fill"
        case .installedNeedsRelaunch:
            "arrow.triangle.2.circlepath"
        case .waitingForApproval, .installing:
            "clock.fill"
        case .notInstalled:
            "exclamationmark.circle.fill"
        case .broken, .unsupported:
            "xmark.circle.fill"
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
}

struct TCPViewerMoreAppsSettingsView: View {
    var body: some View {
        CenteredSettingsPane {
            ProductRow(
                iconAssetName: "ProxymanAppIcon",
                title: "Proxyman for macOS, Windows, Linux",
                detail: "Inspect, filter, and modify HTTP traffic across desktop platforms.",
                ctaTitle: "Download",
                destinationURL: URL(string: "https://proxyman.com/download")
            )
            ProductRow(
                iconAssetName: "ProxymanAppIcon",
                title: "Proxyman iOS, Android",
                detail: "Capture and inspect mobile HTTP traffic from devices and emulators.",
                ctaTitle: "Get App",
                destinationURL: URL(string: "https://proxyman.com/download")
            )
            ProductRow(
                iconAssetName: "TinyShieldAppIcon",
                title: "TinyShield",
                detail: "See every connection. Block every threat.",
                ctaTitle: "Visit",
                destinationURL: URL(string: "https://tinyshield.proxyman.com")
            )
        }
    }
}

private struct ProductRow: View {
    @Environment(\.openURL) private var openURL

    let iconAssetName: String
    let title: String
    let detail: String
    let ctaTitle: String
    let destinationURL: URL?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(iconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(ctaTitle) {
                guard let destinationURL else {
                    return
                }

                openURL(destinationURL)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(destinationURL == nil)
        }
        .frame(width: 430, alignment: .leading)
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
