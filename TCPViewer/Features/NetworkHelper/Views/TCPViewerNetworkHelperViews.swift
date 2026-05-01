//
//  TCPViewerNetworkHelperViews.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 24/4/26.
//

import SwiftUI

struct TCPViewerNetworkHelperOnboardingSheet: View {
    let snapshot: TCPViewerNetworkHelperToolSnapshot
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
                    Text(TCPViewerNetworkHelperConstants.displayName)
                        .font(.title3.weight(.semibold))
                    Text(snapshot.title)
                        .foregroundStyle(.secondary)
                }
            }

            Text("TCP Viewer needs a small background helper so macOS allows non-root packet capture. The helper only adjusts local capture-device permissions for /dev/bpf* and does not inspect, store, or transmit network traffic.")
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
                Label("Relaunch TCP Viewer", systemImage: "arrow.triangle.2.circlepath")
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
