//
//  TCPViewerTLSDecryptionSettingsView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/11/26.
//

import AppKit
import PcapPlusPlusCore
import SwiftUI
import UniformTypeIdentifiers

private enum TLSDecryptionSettingsLayout {
    static let cardCornerRadius: CGFloat = 10
    static let dropZoneHeight: CGFloat = 132
    static let fileIconSize: CGFloat = 34
}

// Settings › TLS: the one key log file TCP Viewer uses to decrypt TLS, DTLS and QUIC traffic.
struct TCPViewerTLSDecryptionSettingsView: View {
    let store: TLSDecryptionStore

    @State private var isEnabled: Bool
    @State private var keyLogURL: URL?
    @State private var status: TLSKeyLogStatus
    @State private var errorMessage: String?
    @State private var isDropTargeted = false
    @State private var observers: [NSObjectProtocol] = []

    private let onPreferredHeightChange: () -> Void

    init(store: TLSDecryptionStore = .shared, onPreferredHeightChange: @escaping () -> Void = {}) {
        self.store = store
        self.onPreferredHeightChange = onPreferredHeightChange
        self._isEnabled = State(initialValue: store.isEnabled)
        self._keyLogURL = State(initialValue: store.keyLogFileURL)
        self._status = State(initialValue: store.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            decryptionSection
            Divider()
            proxymanSection
        }
        .frame(width: TCPViewerSettingsLayout.paneWidth, alignment: .leading)
        .padding(.vertical, 26)
        .padding(.horizontal, TCPViewerSettingsLayout.horizontalPadding)
        .frame(width: TCPViewerSettingsLayout.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            refreshState()
            store.refreshStatus()
            startObserving()
        }
        .onDisappear {
            stopObserving()
        }
        .onChange(of: isEnabled) { _, newValue in
            store.setEnabled(newValue)
        }
        .onChange(of: keyLogURL) { _, _ in
            requestPreferredHeightUpdate()
        }
        .onChange(of: errorMessage) { _, _ in
            requestPreferredHeightUpdate()
        }
    }

    // MARK: Sections

    private var decryptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TLS Decryption")
                .font(.title3.weight(.semibold))

            Toggle("Decrypt TLS traffic with a key log file", isOn: $isEnabled)
                .font(.body.weight(.medium))

            Text("TCP Viewer reads the session keys in an SSLKEYLOGFILE to show the HTTP requests and responses inside HTTPS, TLS and QUIC connections. Keys stay in your file; TCP Viewer only remembers where it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let keyLogURL {
                    keyLogCard(for: keyLogURL)
                } else {
                    dropZone
                }
            }
            .opacity(isEnabled ? 1 : 0.55)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            use(url)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var proxymanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decrypt Traffic from Proxyman")
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                stepRow(number: 1, text: "In Proxyman, open Tools › TLS Key Logging…, turn it on and choose a folder.")
                stepRow(number: 2, text: "Add the key log file Proxyman writes there, or drop it on this window.")
                stepRow(number: 3, text: "Capture or open traffic. Connections Proxyman handled show up as HTTP, even while the capture runs.")
            }

            Text("Key logs from Chrome, Firefox, curl and other apps that honor SSLKEYLOGFILE work too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                TLSKeyLogFilePicker.openProxymanGuide()
            } label: {
                Label("How to turn on TLS Key Logging in Proxyman", systemImage: "arrow.up.right")
            }
            .buttonStyle(.link)
        }
    }

    // MARK: Key log

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("Drop a TLS key log file here")
                .font(.body.weight(.semibold))
            Button("Choose Key Log File…") {
                chooseFile()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: TLSDecryptionSettingsLayout.dropZoneHeight)
        .background(
            (isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear),
            in: RoundedRectangle(cornerRadius: TLSDecryptionSettingsLayout.cardCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TLSDecryptionSettingsLayout.cardCornerRadius)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: [6, 4])
                )
        }
    }

    private func keyLogCard(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: TLSDecryptionSettingsLayout.fileIconSize, height: TLSDecryptionSettingsLayout.fileIconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }

                Spacer(minLength: 8)

                Button("Change…") {
                    chooseFile()
                }
            }

            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.isProblem ? statusColor : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(status == .missing)

                Button {
                    store.decryptOpenCapturesAgain()
                } label: {
                    Label("Decrypt Open Captures Again", systemImage: "arrow.clockwise")
                }
                .disabled(!isEnabled || status.isProblem)
                .help("Use keys added to the file since your captures were opened.")

                Spacer()

                Button(role: .destructive) {
                    errorMessage = nil
                    store.removeKeyLogFile()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: TLSDecryptionSettingsLayout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TLSDecryptionSettingsLayout.cardCornerRadius)
                .stroke(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isDropTargeted ? 2 : 1)
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Status

    private var statusTitle: String {
        switch status {
        case .notConfigured:
            "No key log file"
        case .reading:
            "Reading key log…"
        case .ready(let summary) where summary.keyCount == 0:
            "No keys yet. They appear as Proxyman or your browser opens HTTPS connections."
        case .ready(let summary):
            isEnabled ? "Ready: \(summary.tcpviewerDescription)" : "Off: \(summary.tcpviewerDescription)"
        case .missing:
            "The file was moved or deleted. Choose it again to keep decrypting."
        case .unreadable(let reason):
            "Can't read the file. \(reason)"
        case .notKeyLog:
            "This file no longer looks like a TLS key log."
        }
    }

    private var statusSymbol: String {
        switch status {
        case .ready(let summary):
            summary.keyCount == 0 ? "clock.fill" : (isEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
        case .reading:
            "clock.fill"
        case .notConfigured:
            "key.horizontal"
        case .missing, .unreadable, .notKeyLog:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .ready(let summary):
            summary.keyCount == 0 || !isEnabled ? .secondary : .green
        case .reading, .notConfigured:
            .secondary
        case .missing:
            .orange
        case .unreadable, .notKeyLog:
            .red
        }
    }

    // MARK: Actions

    private func chooseFile() {
        TLSKeyLogFilePicker.chooseFile(for: NSApp.keyWindow) { url in
            use(url)
        }
    }

    private func use(_ url: URL) {
        errorMessage = nil
        store.useKeyLogFile(at: url) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
            refreshState()
        }
    }

    private func refreshState() {
        isEnabled = store.isEnabled
        keyLogURL = store.keyLogFileURL
        status = store.status
    }

    // Observe the store directly without introducing Combine into the production target.
    private func startObserving() {
        guard observers.isEmpty else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: TLSDecryptionStore.didChangeNotification,
            object: store,
            queue: .main
        ) { _ in
            refreshState()
            requestPreferredHeightUpdate()
        }
        observers = [observer]
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // Wait for SwiftUI to apply the new layout before AppKit reads the fitting size.
    private func requestPreferredHeightUpdate() {
        DispatchQueue.main.async {
            onPreferredHeightChange()
        }
    }
}
