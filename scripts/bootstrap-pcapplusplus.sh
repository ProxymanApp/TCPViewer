#!/bin/sh

set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_DIR="$PROJECT_DIR/Vendor/PcapPlusPlus"
BUILD_ROOT="$PROJECT_DIR/Vendor/.build"
INSTALL_ROOT="$PROJECT_DIR/Vendor/.install/pcapplusplus"
CONFIGURATION_NAME="${CONFIGURATION:-Debug}"
ARCHITECTURES="${ARCHS:-${NATIVE_ARCH_ACTUAL:-${CURRENT_ARCH:-arm64}}}"
BUILD_DIR="$BUILD_ROOT/pcapplusplus-${CONFIGURATION_NAME}-$(printf '%s' "$ARCHITECTURES" | tr ' ' '_')"
STAMP_FILE="$INSTALL_ROOT/.packetry-build-stamp"
CURRENT_STAMP_CONTENT="tag=v25.05;config=$CONFIGURATION_NAME;archs=$ARCHITECTURES"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: Vendor/PcapPlusPlus is missing. Run: git submodule update --init --recursive Vendor/PcapPlusPlus" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake is required to build vendored PcapPlusPlus." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$INSTALL_ROOT"

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$CURRENT_STAMP_CONTENT" ] \
  && [ -f "$INSTALL_ROOT/lib/libPcap++.a" ] \
  && [ -f "$INSTALL_ROOT/lib/libPacket++.a" ] \
  && [ -f "$INSTALL_ROOT/lib/libCommon++.a" ]; then
  exit 0
fi

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURES" \
  -DBUILD_SHARED_LIBS=OFF \
  -DPCAPPP_BUILD_EXAMPLES=OFF \
  -DPCAPPP_BUILD_TESTS=OFF \
  -DPCAPPP_INSTALL=ON

cmake --build "$BUILD_DIR" --config RelWithDebInfo --parallel
cmake --install "$BUILD_DIR" --config RelWithDebInfo

printf '%s' "$CURRENT_STAMP_CONTENT" > "$STAMP_FILE"
