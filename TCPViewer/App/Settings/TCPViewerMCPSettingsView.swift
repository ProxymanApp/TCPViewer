//
//  TCPViewerMCPSettingsView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 20/7/26.
//

import AppKit
import SwiftUI

private enum TCPViewerMCPSettingsLayout {
    static let paneHeight: CGFloat = 760
    static let commandHeight: CGFloat = 48
    static let manualConfigurationHeight: CGFloat = 170
    static let manualConfigurationFontSize: CGFloat = 11
}

struct TCPViewerMCPSettingsView: View {
    let configuration: AppConfiguration
    let server: TCPViewerMCPHTTPServer

    @State private var isServerEnabled: Bool
    @State private var redactsSensitiveData: Bool
    @State private var isLicenseAuthorized: Bool
    @State private var serverState: TCPViewerMCPHTTPServerState
    @State private var selectedClient = TCPViewerMCPClientConfiguration.codex
    @State private var copiedClient: TCPViewerMCPClientConfiguration?
    @State private var observers: [NSObjectProtocol] = []

    private let installConfiguration: TCPViewerMCPInstallConfiguration

    init(
        configuration: AppConfiguration,
        server: TCPViewerMCPHTTPServer = .shared,
        installConfiguration: TCPViewerMCPInstallConfiguration = TCPViewerMCPInstallConfiguration()
    ) {
        self.configuration = configuration
        self.server = server
        self.installConfiguration = installConfiguration
        self._isServerEnabled = State(initialValue: configuration.isMCPServerEnabled)
        self._redactsSensitiveData = State(initialValue: configuration.mcpRedactsSensitiveData)
        self._isLicenseAuthorized = State(initialValue: TCPViewerLicenseService.shared.isLicenseAuthorized)
        self._serverState = State(initialValue: server.state)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                serverSection
                Divider()
                privacySection
                Divider()
                aboutSection
            }
            .frame(width: TCPViewerSettingsLayout.paneWidth, alignment: .leading)
            .padding(.vertical, 26)
            .padding(.horizontal, TCPViewerSettingsLayout.horizontalPadding)
        }
        .frame(
            width: TCPViewerSettingsLayout.windowWidth,
            height: TCPViewerMCPSettingsLayout.paneHeight
        )
        .onAppear {
            refreshState()
            startObserving()
        }
        .onDisappear {
            stopObserving()
        }
        .onChange(of: isServerEnabled) { _, newValue in
            configuration.isMCPServerEnabled = newValue
        }
        .onChange(of: redactsSensitiveData) { _, newValue in
            configuration.mcpRedactsSensitiveData = newValue
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP Server")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                Toggle("Enable MCP Server", isOn: $isServerEnabled)
                    .font(.body.weight(.medium))
                    .disabled(!isLicenseAuthorized)

                Spacer()

                if !isLicenseAuthorized {
                    Label("PRO", systemImage: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }

            Text("Start a secure local HTTP bridge for Model Context Protocol clients. MCP clients authenticate through a private per-launch key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor)

                if !isLicenseAuthorized {
                    Button("Unlock TCP Viewer PRO") {
                        showPaywall()
                    }
                    .buttonStyle(.link)
                }
            }

            Text("MCP Configuration")
                .font(.callout.weight(.semibold))
                .padding(.top, 4)

            Picker("MCP Client", selection: $selectedClient) {
                ForEach(TCPViewerMCPClientConfiguration.allCases) { client in
                    Text(client.title).tag(client)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 470)

            HStack(alignment: .top, spacing: 10) {
                ScrollView([.horizontal, .vertical]) {
                    Text(installConfiguration.text(for: selectedClient))
                        .font(selectedClient == .manual
                            ? .system(
                                size: TCPViewerMCPSettingsLayout.manualConfigurationFontSize,
                                weight: .regular,
                                design: .monospaced
                            )
                            : .system(.callout, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: selectedClient == .manual
                    ? TCPViewerMCPSettingsLayout.manualConfigurationHeight
                    : TCPViewerMCPSettingsLayout.commandHeight)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator, lineWidth: 1)
                }

                Button {
                    copyConfiguration()
                } label: {
                    Label(copiedClient == selectedClient ? "Copied" : "Copy", systemImage: copiedClient == selectedClient ? "checkmark" : "doc.on.doc")
                }
            }

            Text(installConfiguration.detail(for: selectedClient))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Privacy")
                .font(.title3.weight(.semibold))

            Toggle("Redact Sensitive Data Before Sending to AI", isOn: $redactsSensitiveData)
                .font(.body.weight(.medium))

            Text("Scrubs authorization headers, cookies, credentials, private keys, tokens, and sensitive query or body fields from packet summaries and decoded details.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !redactsSensitiveData {
                Label(
                    "Full captured values can be sent to MCP clients. Raw packet-byte access is also enabled.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About MCP Integration")
                .font(.callout.weight(.semibold))

            Text("AI assistants can query packets with multiple filters, inspect decoded protocol details, summarize traffic, list streams and interfaces, export PCAP or PCAPNG selections, reveal packets, and control live capture. Every scan and response is bounded for large captures.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openMCPDocumentation()
            } label: {
                Label("Learn more about MCP", systemImage: "arrow.up.right")
            }
            .buttonStyle(.link)
        }
    }

    private var statusTitle: String {
        guard isLicenseAuthorized else {
            return "Requires TCP Viewer PRO"
        }
        switch serverState {
        case .stopped:
            return isServerEnabled ? "Stopped" : "Disabled"
        case .starting:
            return "Starting…"
        case .running(let port):
            return "Running on localhost:\(port)"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private var statusSymbol: String {
        switch serverState {
        case .running:
            return "checkmark.circle.fill"
        case .starting:
            return "clock.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return isLicenseAuthorized ? "xmark.circle.fill" : "lock.fill"
        }
    }

    private var statusColor: Color {
        switch serverState {
        case .running:
            return .green
        case .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func copyConfiguration() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(installConfiguration.text(for: selectedClient), forType: .string)
        copiedClient = selectedClient
    }

    private func refreshState() {
        isServerEnabled = configuration.isMCPServerEnabled
        redactsSensitiveData = configuration.mcpRedactsSensitiveData
        isLicenseAuthorized = TCPViewerLicenseService.shared.isLicenseAuthorized
        serverState = server.state
    }

    // Observe app-owned state directly without introducing Combine into the production target.
    private func startObserving() {
        guard observers.isEmpty else {
            return
        }
        let center = NotificationCenter.default
        let serverObserver = center.addObserver(
            forName: TCPViewerMCPHTTPServer.stateDidChangeNotification,
            object: server,
            queue: .main
        ) { _ in
            serverState = server.state
        }
        let licenseObserver = center.addObserver(
            forName: TCPViewerLicenseService.statusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            isLicenseAuthorized = TCPViewerLicenseService.shared.isLicenseAuthorized
        }
        let configurationObserver = center.addObserver(
            forName: AppConfiguration.didChangeNotification,
            object: configuration,
            queue: .main
        ) { _ in
            isServerEnabled = configuration.isMCPServerEnabled
            redactsSensitiveData = configuration.mcpRedactsSensitiveData
        }
        observers = [serverObserver, licenseObserver, configurationObserver]
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = []
    }

    private func showPaywall() {
        NSApp.sendAction(#selector(AppDelegate.showPaywall(_:)), to: NSApp.delegate, from: nil)
    }

    private func openMCPDocumentation() {
        guard let url = URL(string: "https://modelcontextprotocol.io/docs/getting-started/intro") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
