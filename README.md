# TCP Viewer

## Requirements

- macOS 14+
- Xcode 16+
- CMake
- Ninja
- pkg-config
- Git

```bash
brew install cmake ninja pkg-config
```

## First-Time Setup

Clone the repository with submodules, then let the bootstrap scripts prepare the pinned native dependencies:

```bash
git clone --recurse-submodules <repo-url>
cd TCPViewer
./scripts/bootstrap-pcapplusplus.sh
./scripts/bootstrap-wireshark.sh
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
./scripts/bootstrap-pcapplusplus.sh
./scripts/bootstrap-wireshark.sh
```

This prepares the native capture and dissection libraries used by the default developer build.

## Wireshark Deep Packet Details

TCP Viewer's Wireshark-style inspector is built from the vendored Wireshark source. Users should not need to install the Wireshark app separately; release builds should bundle the required libraries with TCP Viewer.

For local development, install Wireshark's build dependencies and build the pinned vendored copy:

```bash
brew install glib libgcrypt gnutls nghttp2 brotli lz4 zstd
./scripts/bootstrap-wireshark.sh
```

The Debug build links the staged Wireshark libraries by default after bootstrap:

```bash
xcodebuild -project TCPViewer.xcodeproj -scheme TCPViewer build
```

Release packaging still needs to bundle the required Wireshark dylibs before distribution.

## License

TCP Viewer is licensed under GPL-2.0-or-later. This matches the app's
Wireshark integration: `libwireshark`, `libwiretap`, and `libwsutil` are
GPL-covered Wireshark libraries, not LGPL libraries.

The full GPL text is in `COPYING`, third-party notices are in
`THIRD_PARTY_NOTICES.md`, and binary-release source availability terms are in
`SOURCE_CODE_OFFER.md`. Xcode builds copy these files into
`Contents/Resources/OpenSourceLicenses` so app bundles carry the required
notices.

Before publishing a binary release, follow
`docs/open-source-release-compliance.md` and make the complete corresponding
source code available for the same release.

## Run

In Xcode:

1. Open `TCPViewer.xcodeproj`
2. Select the `TCPViewer` scheme
3. Choose `My Mac`
4. Press `Run`

If Xcode asks for signing, select your development team for `TCPViewer` and `PcapPlusPlusCore`.

## Test

```bash
xcodebuild test \
  -project TCPViewer.xcodeproj \
  -scheme TCPViewer \
  -destination 'platform=macOS'
```

## Troubleshooting

Missing submodule:

```bash
git submodule update --init --recursive
./scripts/bootstrap-pcapplusplus.sh
```

Missing CMake:

```bash
brew install cmake
```

Missing Ninja or pkg-config while building Wireshark:

```bash
brew install ninja pkg-config
```

Wireshark backend is not active:

```bash
./scripts/bootstrap-wireshark.sh
xcodebuild -project TCPViewer.xcodeproj -scheme TCPViewer build
```
