//
//  TCPViewerLicenseView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 4/5/26.
//

import AppKit
import SwiftUI

struct TCPViewerLicenseView: View {
    fileprivate struct Feature: Identifiable {
        let id = UUID()
        let systemImage: String
        let title: String
        let detail: String
    }

    private let licenseService: TCPViewerLicenseService
    private let features: [Feature] = [
        Feature(systemImage: "antenna.radiowaves.left.and.right", title: "Live Packet Capture", detail: "Capture TCP and UDP traffic from supported local interfaces."),
        Feature(systemImage: "doc.on.doc", title: "pcap and pcapng Workflows", detail: "Open, save, and export packet captures for repeatable analysis."),
        Feature(systemImage: "list.bullet.rectangle.portrait", title: "Packet Inspection", detail: "Browse Wireshark-style packet details, bytes, and decoded protocol fields."),
        Feature(systemImage: "line.3.horizontal.decrease.circle", title: "Focused Filtering", detail: "Use capture and packet workflows built for TCP/UDP investigation."),
    ]

    @State private var status: TCPViewerLicenseStatus
    @State private var statusObserver: NSObjectProtocol?
    @State private var isActivating = false
    @State private var isRevoking = false

    init(licenseService: TCPViewerLicenseService) {
        self.licenseService = licenseService
        self._status = State(initialValue: licenseService.status)
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    licenseState
                    actionArea
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 280, maxWidth: 330, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Included with TCP Viewer")
                        .font(.system(size: 24, weight: .semibold))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(features) { feature in
                            FeatureTile(feature: feature)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Simple perpetual license with 2 years of updates", systemImage: "checkmark.circle.fill")
                        Label("Transfer seats through License Manager", systemImage: "checkmark.circle.fill")
                        Label("Native macOS packet analyzer by Proxyman LLC", systemImage: "checkmark.circle.fill")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(30)
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(.regularMaterial)
        .onAppear(perform: startObservingStatus)
        .onDisappear(perform: stopObservingStatus)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("TCP Viewer")
                    .font(.system(size: 38, weight: .bold))
                Text("PRO")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.black)
                    .background(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text("Native packet capture and inspection for focused TCP/UDP workflows.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var licenseState: some View {
        switch status {
        case .authorized(let license):
            LicenseInfoPanel(license: license)
        case .unauthorized:
            VStack(alignment: .leading, spacing: 5) {
                Text("You're using the free version.")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Activate TCP Viewer PRO to register this Mac with your license.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var actionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    TCPViewerLicenseWebsiteService.open(.buyLicense)
                } label: {
                    Label("Buy License", systemImage: "cart")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showActivationAlert()
                } label: {
                    Label("Activate", systemImage: "key")
                }
                .disabled(isActivating)
            }

            HStack(spacing: 8) {
                Button {
                    revokeLicense()
                } label: {
                    Label("Remove License", systemImage: "trash")
                }
                .disabled(!status.isAuthorized || isRevoking)

                Button {
                    TCPViewerLicenseWebsiteService.open(.licenseManager)
                } label: {
                    Label("License Manager", systemImage: "person.2.badge.key")
                }
            }

            if isActivating || isRevoking {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isActivating ? "Activating license..." : "Removing license...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            Text("Find, transfer, or revoke devices from License Manager.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func showActivationAlert() {
        let alert = NSAlert()
        alert.messageText = "Activate License"
        alert.informativeText = "Enter your TCP Viewer license key to activate this Mac."
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.placeholderString = "TCPV-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
        alert.accessoryView = input
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let licenseKey = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !licenseKey.isEmpty else {
            showErrorAlert(message: "Please enter a license key.")
            return
        }

        activateLicense(licenseKey)
    }

    private func activateLicense(_ licenseKey: String) {
        isActivating = true
        licenseService.activate(licenseKey: licenseKey) { result in
            DispatchQueue.main.async {
                isActivating = false
                status = licenseService.status

                switch result {
                case .authorized:
                    showSuccessAlert()
                case .unauthorized(let error):
                    handleActivationError(error)
                }
            }
        }
    }

    private func revokeLicense() {
        isRevoking = true
        licenseService.revokeCurrentDevice { _ in
            DispatchQueue.main.async {
                isRevoking = false
                status = licenseService.status
            }
        }
    }

    private func handleActivationError(_ error: TCPViewerLicenseError) {
        switch error {
        case .outOfSeats:
            let alert = NSAlert()
            alert.messageText = "No seats available"
            alert.informativeText = "Your license is already used on the maximum number of devices. Open License Manager to revoke an old device, then try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "License Manager")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                TCPViewerLicenseWebsiteService.open(.licenseManager)
            }
        case .expired, .renewalRequired:
            let alert = NSAlert()
            alert.messageText = "License renewal required"
            alert.informativeText = error.errorDescription ?? "Please renew your TCP Viewer license."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Renew License")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                TCPViewerLicenseWebsiteService.open(.renewLicense)
            }
        default:
            showErrorAlert(message: error.errorDescription ?? error.localizedDescription)
        }
    }

    private func showSuccessAlert() {
        let alert = NSAlert()
        alert.messageText = "License Activated"
        alert.informativeText = "TCP Viewer PRO is active on this Mac."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "License Activation Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startObservingStatus() {
        status = licenseService.status
        guard statusObserver == nil else {
            return
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: TCPViewerLicenseService.statusDidChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let updatedStatus = notification.object as? TCPViewerLicenseStatus {
                status = updatedStatus
            } else {
                status = licenseService.status
            }
        }
    }

    private func stopObservingStatus() {
        guard let statusObserver else {
            return
        }

        NotificationCenter.default.removeObserver(statusObserver)
        self.statusObserver = nil
    }
}

private struct LicenseInfoPanel: View {
    let license: TCPViewerLicense

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Registered to \(license.email)")
                    .font(.headline)
            }

            Text(expiryText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var expiryText: String {
        guard let remainingDays = license.remainingDays else {
            return "Updates available until \(license.formattedExpiryDate)"
        }

        if remainingDays < 0 {
            return "License expired \(abs(remainingDays)) days ago"
        }
        if remainingDays == 0 {
            return "Updates available until today"
        }
        if remainingDays < 30 {
            return "Updates available until \(license.formattedExpiryDate) (\(remainingDays) days from now)"
        }

        let months = remainingDays / 30
        return "Updates available until \(license.formattedExpiryDate) (\(months + 1) months from now)"
    }
}

private struct FeatureTile: View {
    let feature: TCPViewerLicenseView.Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 27, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34, alignment: .leading)

            Text(feature.title)
                .font(.system(size: 15, weight: .semibold))

            Text(feature.detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
