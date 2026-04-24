# Packetry

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
cd Packetry
open Packetry.xcodeproj
```

If you already cloned the repo:

```bash
./scripts/bootstrap-pcapplusplus.sh
```

## Run

In Xcode:

1. Open `Packetry.xcodeproj`
2. Select the `Packetry` scheme
3. Choose `My Mac`
4. Press `Run`

If Xcode asks for signing, select your development team for `Packetry` and `PcapPlusPlusCore`.

## Test

```bash
xcodebuild test \
  -project Packetry.xcodeproj \
  -scheme Packetry \
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
