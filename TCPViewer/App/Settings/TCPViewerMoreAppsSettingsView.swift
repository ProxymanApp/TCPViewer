//
//  TCPViewerMoreAppsSettingsView.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 14/11/26.
//

import AppKit
import SwiftUI

/// Settings › More Apps: every Proxyman platform, then the apps from the Proxyman team.
struct TCPViewerMoreAppsSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                MoreAppsSectionHeader(
                    title: "Proxyman on Every Platform",
                    detail: "The HTTP debugging proxy from the team behind TCP Viewer, on desktop and mobile."
                )

                // Five equal-width tiles, one per platform.
                HStack(spacing: 10) {
                    ForEach(ProxymanPlatform.all) { platform in
                        PlatformTileButton(platform: platform)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                MoreAppsSectionHeader(
                    title: "Apps from Proxyman",
                    detail: "Standalone tools from the Proxyman team for device testing, network monitoring, and security."
                )

                // Grid (not LazyVGrid) stretches the three cards to the tallest one.
                Grid(horizontalSpacing: 12) {
                    GridRow {
                        ForEach(ProxymanApp.all) { app in
                            ProxymanAppCardButton(app: app)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: TCPViewerSettingsLayout.paneWidth, alignment: .leading)
        .padding(.vertical, TCPViewerSettingsLayout.verticalPadding)
        .padding(.horizontal, TCPViewerSettingsLayout.horizontalPadding)
        .frame(width: TCPViewerSettingsLayout.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private enum MoreAppsLayout {
    static let cornerRadius: CGFloat = 10
}

/// Section title with a one-line explanation below it.
private struct MoreAppsSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Card chrome shared by platform tiles and app cards: filled surface, hairline border, accent border on hover.
private struct MoreAppsCardBackground: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MoreAppsLayout.cornerRadius, style: .continuous)
        return content
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.stroke(isHovering ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.18), lineWidth: 1))
            .contentShape(shape)
    }
}

// MARK: - Platform Tiles

/// A clickable tile for one Proxyman platform, opening its store or download page.
private struct PlatformTileButton: View {
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    let platform: ProxymanPlatform

    var body: some View {
        Button {
            openURL(platform.url)
        } label: {
            VStack(spacing: 0) {
                PlatformGlyphView(glyph: platform.glyph)
                    .frame(width: 30, height: 30)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )

                Text(platform.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.top, 10)

                HStack(spacing: 3) {
                    Text(platform.storeName)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 3)
            }
            .padding(.top, 16)
            .padding(.bottom, 14)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if platform.isNew {
                    NewBadge()
                        .padding(7)
                }
            }
            .modifier(MoreAppsCardBackground(isHovering: isHovering))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(platform.title)
        .accessibilityLabel(platform.title)
    }
}

/// Platform logo: the Apple symbol, a drawn Windows mark, or a bundled image.
private struct PlatformGlyphView: View {
    let glyph: PlatformGlyph

    var body: some View {
        switch glyph {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.primary)
        case .windows:
            WindowsLogoMark()
                .padding(2)
        case .asset(let name):
            Image(name)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }
}

/// The four-square Windows mark, drawn so no Microsoft image ships in the repo.
private struct WindowsLogoMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let gap = size * 0.07
            let tile = (size - gap) / 2
            let blue = Color(red: 0.0, green: 0.47, blue: 0.83)

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Rectangle().fill(blue).frame(width: tile, height: tile)
                    Rectangle().fill(blue).frame(width: tile, height: tile)
                }
                HStack(spacing: gap) {
                    Rectangle().fill(blue).frame(width: tile, height: tile)
                    Rectangle().fill(blue).frame(width: tile, height: tile)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - App Cards

/// A card for one Proxyman app; the running app shows Installed instead of a link.
private struct ProxymanAppCardButton: View {
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    let app: ProxymanApp

    var body: some View {
        Button {
            openURL(app.url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(app.iconAssetName)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)

                    Spacer(minLength: 8)

                    if app.isNew {
                        NewBadge()
                    }
                }

                Text(app.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .padding(.top, 12)

                Text(app.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                Spacer(minLength: 14)

                if app.isCurrentApp {
                    InstalledLabel()
                        .padding(.vertical, 4)
                } else {
                    HStack(spacing: 5) {
                        Text("Open Website")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(isHovering ? 0.16 : 0.10)))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(MoreAppsCardBackground(isHovering: isHovering))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(app.url.absoluteString)
    }
}

/// Green check with "Installed", marking the app that is running.
private struct InstalledLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text("Installed")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

/// Small red NEW pill for recently released products.
private struct NewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .fixedSize()
    }
}

// MARK: - Model

private enum PlatformGlyph {
    case apple
    case windows
    case asset(String)
}

/// One Proxyman app per platform.
private struct ProxymanPlatform: Identifiable {
    let name: String
    let title: String
    let storeName: String
    let glyph: PlatformGlyph
    let isNew: Bool
    let url: URL

    var id: String { name }

    static let all: [ProxymanPlatform] = [
        ProxymanPlatform(name: "macOS", title: "Proxyman for macOS", storeName: "Download", glyph: .apple, isNew: false,
                         url: URL(string: "https://proxyman.com/")!),
        ProxymanPlatform(name: "iOS", title: "Proxyman for iOS", storeName: "App Store", glyph: .apple, isNew: false,
                         url: URL(string: "https://apps.apple.com/us/app/proxyman/id1551292695")!),
        ProxymanPlatform(name: "Android", title: "Proxyman for Android", storeName: "Google Play", glyph: .asset("AndroidPlatformIcon"), isNew: true,
                         url: URL(string: "https://play.google.com/store/apps/details?id=com.proxyman.proxymanandroid")!),
        ProxymanPlatform(name: "Windows", title: "Proxyman for Windows", storeName: "Download", glyph: .windows, isNew: false,
                         url: URL(string: "https://proxyman.com/windows")!),
        ProxymanPlatform(name: "Linux", title: "Proxyman for Linux", storeName: "Download", glyph: .asset("LinuxPlatformIcon"), isNew: false,
                         url: URL(string: "https://proxyman.com/linux")!)
    ]
}

/// A standalone app from the Proxyman team.
private struct ProxymanApp: Identifiable {
    let name: String
    let detail: String
    let iconAssetName: String
    let isNew: Bool
    let isCurrentApp: Bool
    let url: URL

    var id: String { name }

    static let all: [ProxymanApp] = [
        ProxymanApp(name: "Device MCP",
                    detail: "Mirror and control iPhone, Android, and simulators on your Mac, and let AI agents test your app.",
                    iconAssetName: "DeviceMCPAppIcon", isNew: true, isCurrentApp: false,
                    url: URL(string: "https://devicemcp.ai/")!),
        ProxymanApp(name: "TCP Viewer",
                    detail: "The best-in-class alternative to Wireshark. Capture, filter, and inspect TCP, UDP, and DNS traffic on your Mac.",
                    iconAssetName: "TCPViewerAppIcon", isNew: false, isCurrentApp: true,
                    url: URL(string: "https://tcpviewer.proxyman.com")!),
        ProxymanApp(name: "TinyShield",
                    detail: "A lightweight firewall that helps monitor and block outbound network connections.",
                    iconAssetName: "TinyShieldAppIcon", isNew: false, isCurrentApp: false,
                    url: URL(string: "https://tinyshield.proxyman.com")!)
    ]
}
