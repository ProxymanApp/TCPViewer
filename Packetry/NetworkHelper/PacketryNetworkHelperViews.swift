import AppKit
import SwiftUI

struct PacketrySettingsView: View {
    @ObservedObject var networkHelperToolManager: PacketryNetworkHelperToolManager

    var body: some View {
        TabView {
            PacketryNetworkHelperSettingsView(manager: networkHelperToolManager)
                .tabItem {
                    Label("Helper", systemImage: "lock.shield")
                }
        }
        .frame(width: 640, height: 460)
    }
}

struct PacketryNetworkHelperSettingsView: View {
    @ObservedObject var manager: PacketryNetworkHelperToolManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Allows Packetry to capture packets without running the app as root.", systemImage: "checkmark.shield")
                Label("Adjusts local /dev/bpf* device permissions for Packetry capture access.", systemImage: "slider.horizontal.3")
                Label("Does not inspect, store, or transmit your network traffic.", systemImage: "eye.slash")
            }
            .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Text(manager.snapshot.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Spacer()
            }
            .padding(12)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button {
                    Task {
                        await manager.refreshStatus()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }

                if manager.snapshot.status == .waitingForApproval {
                    Button {
                        manager.openSystemSettings()
                    } label: {
                        Label("System Settings", systemImage: "gear")
                    }
                }

                if canUninstallHelper {
                    Button(role: .destructive) {
                        Task {
                            await manager.uninstall()
                        }
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                }

                Spacer()

                primaryAction
            }
        }
        .padding(24)
        .task {
            await manager.refreshStatus()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusImage)
                .font(.system(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusTint)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(PacketryNetworkHelperConstants.displayName)
                    .font(.title3.weight(.semibold))

                Text(manager.snapshot.title)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var canUninstallHelper: Bool {
        switch manager.snapshot.status {
        case .waitingForApproval, .installedNeedsRelaunch, .ready, .broken, .unsupported:
            true
        case .notInstalled, .installing:
            false
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch manager.snapshot.status {
        case .notInstalled, .unsupported:
            Button {
                Task {
                    await manager.install()
                }
            } label: {
                Label("Install", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        case .waitingForApproval:
            Button {
                manager.openSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
        case .installedNeedsRelaunch:
            Button {
                relaunchPacketry()
            } label: {
                Label("Relaunch Packetry", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
        case .broken:
            Button {
                Task {
                    await manager.repair()
                }
            } label: {
                Label("Repair", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var statusImage: String {
        switch manager.snapshot.status {
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
        switch manager.snapshot.status {
        case .ready:
            .green
        case .installedNeedsRelaunch, .waitingForApproval, .installing:
            .orange
        case .notInstalled:
            .blue
        case .broken, .unsupported:
            .red
        }
    }

    private func relaunchPacketry() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
    }
}

struct PacketryNetworkHelperOnboardingSheet: View {
    let snapshot: PacketryNetworkHelperToolSnapshot
    let onInstall: () -> Void
    let onRepair: () -> Void
    let onRetry: () -> Void
    let onOpenSystemSettings: () -> Void
    let onRelaunch: () -> Void
    let onContinueOffline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(PacketryNetworkHelperConstants.displayName)
                        .font(.title3.weight(.semibold))
                    Text(snapshot.title)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Packetry needs a small background helper so macOS allows non-root packet capture. The helper only adjusts local capture-device permissions for /dev/bpf* and does not inspect, store, or transmit network traffic.")
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    onContinueOffline()
                } label: {
                    Label("Continue Offline", systemImage: "doc")
                }

                Button {
                    onRetry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }

                Spacer()

                primaryAction
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch snapshot.status {
        case .notInstalled, .unsupported:
            Button {
                onInstall()
            } label: {
                Label("Install Helper", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        case .waitingForApproval:
            Button {
                onOpenSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
        case .installedNeedsRelaunch:
            Button {
                onRelaunch()
            } label: {
                Label("Relaunch Packetry", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
        case .broken:
            Button {
                onRepair()
            } label: {
                Label("Repair Helper", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)
        case .ready:
            Button {
                onContinueOffline()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        case .installing:
            ProgressView()
                .controlSize(.small)
        }
    }
}
