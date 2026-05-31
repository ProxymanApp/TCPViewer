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

Clone the repository with submodules, then let the bootstrap script prepare the pinned Wireshark dependency:

```bash
git clone --recurse-submodules <repo-url>
cd TCPViewer
./scripts/bootstrap-wireshark.sh
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
./scripts/bootstrap-wireshark.sh
```

This prepares the native Wireshark libraries staged by the default developer build. TCP Viewer capture, capture-file I/O, and fallback packet dissection are implemented in Swift with the system libpcap runtime.

## Local Xcode Build Settings

TCP Viewer keeps app build settings in Xcode configuration files. Create an
ignored local config from the template before building in Xcode:

```bash
cp Config/TCPViewer.local.xcconfig.example Config/TCPViewer.local.xcconfig
```

Set `TCPVIEWER_DEVELOPMENT_TEAM`, `TCPVIEWER_BUILD_KEY`,
`TCPVIEWER_APPCAST_URL`, `TCPVIEWER_SPARKLE_PUBLIC_ED_KEY`, and optionally
`TCPVIEWER_SENTRY_DSN` in `Config/TCPViewer.local.xcconfig`. Set
`TCPVIEWER_USES_LOCAL_LICENSE_SERVER` to `true` only when local license API
traffic should use the debug server. Because
`.xcconfig` files treat `//` as comments, URL values that contain `://` must
use Xcode's escaped form, for example
`https:/$()/updates.example.com/appcast.xml`.

The root `.env` file is still supported for release scripts, but it is not
included by Xcode app builds.

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
Keychain-backed tools. The release `.env` file is read by the Node.js and
fastlane tooling only; local Xcode app builds read
`Config/TCPViewer.local.xcconfig` instead.

First-time release setup:

```bash
npm install
bundle install
gh auth login
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
  "title": "TCP Viewer 1.1 Release",
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
Choose `production` to release the app version and build number currently set in
the Xcode project. The script preflights `ReleaseNote.json`, shows the parsed app
version and build number in the confirmation summary, verifies the GitHub CLI
session, checks that the working tree is clean and synced with the default
branch, and fails if the `v<version>` Git tag or GitHub release already exists.
It then runs `bundle exec fastlane mac build_production`, performs the same
final DMG verification before uploading to R2, writes the Sparkle appcast XML
from `ReleaseNote.json` into the production artifact folder, creates and pushes
the annotated `v<version>` tag, and publishes the GitHub release with the DMG
attached.

To also create the production release record through the TCP Viewer backend,
enable the optional backend publisher in local `.env`:

```bash
TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND=1
TCPVIEWER_RELEASE_BACKEND_URL=http:/$()/localhost:3000
TCPVIEWER_RELEASE_BACKEND_SCRIPT_SECRET=<same value as backend SCRIPT_SECRET>
```

When enabled, production releases publish to the backend URL you configure. Use
`http:/$()/localhost:3000` to verify the production release script against your
local backend, or set the production API URL when you want to publish there.
The script preflights the backend with
`/api/releases/check-can-script-release-new-build` and, after the DMG upload and
appcast generation succeed, calls `/api/releases/create-new-release`. Leave the
flag disabled to skip backend publishing.

Production artifacts are exported under:

```bash
~/Desktop/tcpviewer-production/production/<version>-<build>/
```

## Troubleshooting

Missing submodule:

```bash
git submodule update --init --recursive
./scripts/bootstrap-wireshark.sh
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
