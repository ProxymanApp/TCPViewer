import AppKit
import SwiftUI

enum TCPViewerSettingsLayout {
    static let windowWidth: CGFloat = 760
    static let paneWidth: CGFloat = 620
    static let verticalPadding: CGFloat = 30
    static let horizontalPadding: CGFloat = 28
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
            SettingsHeading(
                title: "Privacy",
                message: "Control diagnostics that help improve TCP Viewer."
            )

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
                    .frame(width: 148)
                Text("Powered by Sentry")
                    .fontWeight(.medium)
                Image(systemName: "arrow.up.right.circle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                    .frame(width: 148)
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
            SettingsHeading(
                title: "Appearance",
                message: "Tune packet text and choose how TCP Viewer follows macOS appearance."
            )

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
                    .frame(width: 260)

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
                .frame(width: 260)
            }

            SettingsRow(title: "Preview:") {
                Text("GET /packets tcp port 443")
                    .font(.system(size: packetFontSize, design: usesMonospacedPacketFont ? .monospaced : .default))
                    .foregroundStyle(.secondary)
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
}

struct TCPViewerHelperToolSettingsView: View {
    let manager: any TCPViewerNetworkHelperToolManaging

    @State private var snapshot: TCPViewerNetworkHelperToolSnapshot

    init(manager: any TCPViewerNetworkHelperToolManaging) {
        self.manager = manager
        self._snapshot = State(initialValue: manager.snapshot)
    }

    var body: some View {
        SettingsPane {
            SettingsHeading(
                title: "Helper Tool",
                message: "TCP Viewer uses a small background helper so macOS can allow packet capture without running the app as root."
            )

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: statusImageName)
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusTint)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(snapshot.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(lastCheckedText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 520, alignment: .leading)
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

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("More Apps from Proxyman")
                    .font(.system(size: 15, weight: .semibold))

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
        .onAppear {
            refreshStatus()
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch snapshot.status {
        case .notInstalled, .unsupported:
            Button {
                snapshot = manager.install { snapshot = $0 }
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

    private func uninstallHelper() {
        snapshot = manager.uninstall { snapshot = $0 }
    }

    private func openHelperToolPath() {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TCPViewerHelperTool")
        if FileManager.default.fileExists(atPath: helperURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([helperURL])
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
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
            .frame(width: 520, alignment: .leading)
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

private struct SettingsHeading: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
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
                .frame(width: 136, alignment: .trailing)

            VStack(alignment: .leading, spacing: 7) {
                content
                if let detail {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 440, alignment: .leading)
        }
    }
}
