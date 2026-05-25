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

## Production Release

TCP Viewer uses Sparkle 2 for macOS app updates. Release builds are packaged by
the Node.js release script, built by fastlane, packaged with `create-dmg`,
notarized as a DMG, signed with Sparkle's EdDSA update key, uploaded to
Cloudflare R2, and exported with a Sparkle appcast.

Release secrets must stay out of Git. Keep them in local `.env`, shell env, or
Keychain-backed tools. Because `.env` is also included by Xcode as an
`.xcconfig`, URL values that contain `://` should use Xcode's escaped form,
for example `https:/$()/updates.example.com/appcast.xml`.

First-time release setup:

```bash
npm install
bundle install
```

Notarization and Sentry values are read from environment variables only. Set
`TCPVIEWER_NOTARIZATION_USERNAME`, `TCPVIEWER_NOTARIZATION_ASC_PROVIDER`,
`FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`, `SENTRY_AUTH_TOKEN`,
`SENTRY_ORG_SLUG`, and `SENTRY_PROJECT_SLUG` in local
`.env` or the shell.

Generate or transfer the Sparkle EdDSA key with Sparkle's `generate_keys` tool.
Store the private key in `TCPVIEWER_SPARKLE_PRIVATE_ED_KEY` and the public key
in `TCPVIEWER_SPARKLE_PUBLIC_ED_KEY`. The public key is embedded into the app's
`SUPublicEDKey`; the private key is only used by the local release script.

Before production, add a matching entry to `ReleaseNote.json`:

```json
{
  "version": "1.1.0",
  "features": [],
  "improvements": [],
  "bugs": []
}
```

Run the release flow:

```bash
npm run release
```

Choose `beta` to enter a custom DMG name suffix. After preflight checks, the
script confirms a DMG named `tcpviewer_<version>_<custom_name>.dmg`, runs
`bundle exec fastlane mac build_beta`, creates the DMG with `create-dmg`, signs
and notarizes the DMG, verifies the final code-signing and notarization status,
uploads dSYMs to Sentry, signs the DMG for Sparkle, uploads it to R2, and prints
the beta DMG URL.
Choose `production` to enter the next version; the script increments the build
number, preflights `ReleaseNote.json`, asks for confirmation, runs
`bundle exec fastlane mac build_production`, performs the same final DMG
verification before uploading to R2, and writes the Sparkle appcast XML from
`ReleaseNote.json` into the production artifact folder. Any private website or
service publishing step should live outside this open-source repository.

Production artifacts are exported under:

```bash
~/Desktop/tcpviewer-production/production/<version>-<build>/
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
