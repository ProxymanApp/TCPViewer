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
    let onOpenSystemSettings: () -> Void
    let onRelaunch: () -> Void
    let onContinueOffline: () -> Void

    private static let helperBenefits = [
        "Capture live traffic without running TCP Viewer as root.",
        "Keep /dev/bpf* capture permissions repaired automatically.",
        "Stay local: the helper never inspects, stores, or uploads traffic."
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .opacity(0.45)

            VStack(alignment: .leading, spacing: 16) {
                Text("Why install it?")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.helperBenefits, id: \.self) { benefit in
                        benefitRow(benefit)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()
                .opacity(0.45)

            HStack(spacing: 12) {
                Button {
                    onContinueOffline()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                primaryAction
            }
            .padding(20)
            .background(.thinMaterial)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
        .shadow(color: .black.opacity(0.12), radius: 28, y: 16)
        .padding(1)
        .frame(width: 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.blue.opacity(0.12))

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 7) {
                Text("Install Helper Tool")
                    .font(.system(size: 26, weight: .semibold))

                Text("TCP Viewer uses a small privileged helper so macOS can grant packet-capture access securely.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
    }

    private func benefitRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch snapshot.status {
        case .notInstalled, .unsupported:
            Button {
                onInstall()
            } label: {
                Label("Install Helper Tool", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .waitingForApproval:
            Button {
                onOpenSystemSettings()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .installedNeedsRelaunch:
            Button {
                onRelaunch()
            } label: {
                Label("Relaunch TCP Viewer", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .broken:
            Button {
                onRepair()
            } label: {
                Label("Repair Helper", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .ready:
            Button {
                onContinueOffline()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
