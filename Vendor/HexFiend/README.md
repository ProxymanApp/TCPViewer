# Hex Fiend Framework

This directory contains a prebuilt macOS `HexFiend.framework` used by Packetry's packet hex inspector.

- Upstream: https://github.com/HexFiend/HexFiend
- Commit: `32cb2ef78d2ff3bc6ecf326a6b19eeebb2945c13`
- License: BSD 2-Clause, reproduced in `License.txt`

## Rebuild

```sh
git clone https://github.com/HexFiend/HexFiend /tmp/HexFiend
git -C /tmp/HexFiend checkout 32cb2ef78d2ff3bc6ecf326a6b19eeebb2945c13
xcodebuild -project /tmp/HexFiend/app/HexFiend_2.xcodeproj \
  -scheme "Framework Only (Release)" \
  -configuration Release \
  -destination 'platform=macOS' \
  -sdk macosx \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Copy the resulting framework from `DerivedData/Build/Products/Release/HexFiend.framework`.
