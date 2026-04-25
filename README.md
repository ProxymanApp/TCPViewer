# TCP Viewer

## Requirements

- macOS 14+
- Xcode 16+
- CMake
- Git

```bash
brew install cmake
```

## First-Time Setup

```bash
git clone --recurse-submodules <repo-url>
cd TCPViewer
open TCPViewer.xcodeproj
```

If you already cloned the repo:

```bash
./scripts/bootstrap-pcapplusplus.sh
```

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
./scripts/bootstrap-pcapplusplus.sh
```

Missing CMake:

```bash
brew install cmake
```
