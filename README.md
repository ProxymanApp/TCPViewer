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
cd Packetry
./scripts/bootstrap-pcapplusplus.sh
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
./scripts/bootstrap-pcapplusplus.sh
```

This is enough for the default developer build. TCP Viewer will use PcapPlusPlus for capture, packet summaries, export, and fallback packet details.

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
