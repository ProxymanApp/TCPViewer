//
//  TCPViewerAboutView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 10/5/26.
//

import AppKit
import SwiftUI

struct TCPViewerAboutView: View {
    static let preferredWindowContentSize = NSSize(width: 512, height: 286)

    let info: TCPViewerAboutInfo
    let appIcon: NSImage

    @Environment(\.openURL) private var openURL
    @State private var copiedTarget: CopiedTarget?

    private enum CopiedTarget {
        case version
        case debugInfo
    }

    private var didCopyVersion: Bool {
        copiedTarget == .version
    }

    private var didCopyDebugInfo: Bool {
        copiedTarget == .debugInfo
    }

    init(
        info: TCPViewerAboutInfo = .current,
        appIcon: NSImage = NSApp.applicationIconImage
    ) {
        self.info = info
        self.appIcon = appIcon
    }

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            appIconView

            VStack(alignment: .leading, spacing: 0) {
                Text(info.appName)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                versionRow
                    .padding(.top, 5)

                iconActions
                    .padding(.top, 16)

                linkActions
                    .padding(.top, 26)

                copyrightText
                    .padding(.top, 15)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 10)
        .padding(.leading, 34)
        .padding(.trailing, 26)
        .padding(.bottom, 24)
        .frame(
            width: Self.preferredWindowContentSize.width,
            height: Self.preferredWindowContentSize.height,
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appIconView: some View {
        Image(nsImage: appIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 120, height: 120)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 6)
    }

    private var versionRow: some View {
        HStack(spacing: 11) {
            Text("Version \(info.appVersion) (\(info.buildVersion))")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Self.secondaryTextColor)
                .lineLimit(1)

            Button {
                copyToPasteboard(info.appVersionCopyText, target: .version)
            } label: {
                Image(systemName: didCopyVersion ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(didCopyVersion ? Color.green.opacity(0.92) : Self.secondaryTextColor)
            .help(didCopyVersion ? "Version copied" : "Copy version")

            UpToDateBadge()
        }
    }

    private var iconActions: some View {
        HStack(spacing: 17) {
            IconButton(systemImage: "chevron.left.forwardslash.chevron.right", help: "GitHub") {
                open(Self.githubURL)
            }
            IconButton(systemImage: "xmark.square.fill", help: "X") {
                open(Self.xURL)
            }
            IconButton(systemImage: "info.circle.fill", help: "Website") {
                open(Self.websiteURL)
            }
        }
    }

    private var linkActions: some View {
        VStack(alignment: .leading, spacing: 11) {
            LinkTextButton(title: "About Team") {
                open(Self.teamURL)
            }
            LinkTextButton(title: "Acknowledgement") {
                openAcknowledgement()
            }
            LinkTextButton(
                title: didCopyDebugInfo ? "Copied Debug Info" : "Copy Debug Info",
                isCopied: didCopyDebugInfo
            ) {
                copyToPasteboard(info.debugInformationText, target: .debugInfo)
            }
        }
    }

    private var copyrightText: some View {
        Text("\u{00A9} 2022-2026 Proxyman LLC")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Self.secondaryTextColor)
    }

    private func copyToPasteboard(_ text: String, target: CopiedTarget) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTarget = target
    }

    private func open(_ url: URL) {
        openURL(url)
    }

    private func openAcknowledgement() {
        if let url = Bundle.main.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "md",
            subdirectory: "OpenSourceLicenses"
        ) {
            NSWorkspace.shared.open(url)
            return
        }

        open(Self.githubURL)
    }

    private static let teamURL = URL(string: "https://proxyman.com/support")!
    private static let websiteURL = URL(string: "https://proxyman.com")!
    private static let githubURL = URL(string: "https://github.com/ProxymanApp")!
    private static let xURL = URL(string: "https://x.com/proxyman_app")!
    private static let secondaryTextColor = Color.secondary
}

private struct UpToDateBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.green)

            Text("Up-to-date")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.14))
        .clipShape(Capsule())
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct LinkTextButton: View {
    let title: String
    let isCopied: Bool
    let action: () -> Void

    init(title: String, isCopied: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isCopied = isCopied
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                }

                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .underline(!isCopied)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCopied ? Color.green.opacity(0.92) : Color.secondary)
    }
}
