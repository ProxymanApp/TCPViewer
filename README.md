# TCP Viewer

TCP Viewer is a macOS packet viewer for live captures and capture files. It uses AppKit for the main app, system libpcap for capture, and vendored Wireshark libraries for deep packet details.

## Requirements

- macOS 15+
- Xcode 16+
- Git
- CMake, Ninja, and pkg-config
- Wireshark build dependencies

```bash
brew install cmake ninja pkg-config glib libgcrypt gnutls nghttp2 brotli lz4 zstd
```

## Setup

Clone with submodules and bootstrap the pinned Wireshark dependency:

```bash
git clone --recurse-submodules <repo-url>
cd TCPViewer
cp Config/TCPViewer.local.xcconfig.example Config/TCPViewer.local.xcconfig
./scripts/bootstrap-wireshark.sh
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
./scripts/bootstrap-wireshark.sh
```

Keep local signing, appcast, Sparkle, Sentry, and release values out of Git. Use ignored local files such as `Config/TCPViewer.local.xcconfig`, `.env`, shell environment variables, or Keychain-backed tools.

## Run

In Xcode:

1. Open `TCPViewer.xcodeproj`.
2. Select the `TCPViewer` scheme.
3. Choose `My Mac`.
4. Press Run.

Command-line build:

```bash
xcodebuild -project TCPViewer.xcodeproj -scheme TCPViewer build
```

If Xcode asks for signing, select a development team for `TCPViewer` and `PcapPlusPlusCore`.

## Test

```bash
xcodebuild test \
  -project TCPViewer.xcodeproj \
  -scheme TCPViewer \
  -destination 'platform=macOS'
```

## Deploy

TCP Viewer releases are built, notarized, signed for Sparkle, uploaded to Cloudflare R2, and optionally published to the release backend by the release script.

First-time release setup:

```bash
npm install
bundle install
gh auth login
```

Create a local `.env` from `.env.example` and fill in the required release values. Never commit real secrets.

For production releases, add a matching entry to `ReleaseNote.json`, then run:

```bash
npm run release
```

Choose `beta` or `production` when prompted. Production releases also create the Sparkle appcast, push the `v<version>` tag, and publish the GitHub release. Artifacts are written under:

```bash
~/Desktop/tcpviewer-production/
```

## License

TCP Viewer is licensed under GPL-2.0-or-later. This matches the app's Wireshark integration: `libwireshark`, `libwiretap`, and `libwsutil` are GPL-covered Wireshark libraries.

The full GPL text is in `COPYING`, third-party notices are in `THIRD_PARTY_NOTICES.md`, and binary-release source availability terms are in `SOURCE_CODE_OFFER.md`.

## Acknowledgements

TCP Viewer builds on Wireshark for packet dissection and HexFiend for the embedded hex viewer. See `THIRD_PARTY_NOTICES.md` for details.
