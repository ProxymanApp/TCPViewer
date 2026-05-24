#!/bin/sh

set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_DIR="$PROJECT_DIR/Vendor/PcapPlusPlus"
BUILD_ROOT="$PROJECT_DIR/Vendor/.build"
INSTALL_ROOT="$PROJECT_DIR/Vendor/.install/pcapplusplus"
PINNED_TAG="v25.05"
PINNED_COMMIT="a49a79e0b67b402ad75ffa96c1795def36df75c8"
CONFIGURATION_NAME="${CONFIGURATION:-Debug}"
ARCHITECTURES="${ARCHS:-${NATIVE_ARCH_ACTUAL:-${CURRENT_ARCH:-arm64}}}"
# Xcode passes ARCHS as space-separated values, while CMake expects a semicolon list.
CMAKE_ARCHITECTURES="$(printf '%s' "$ARCHITECTURES" | tr ' ' ';')"
BUILD_DIR="$BUILD_ROOT/pcapplusplus-${CONFIGURATION_NAME}-$(printf '%s' "$ARCHITECTURES" | tr ' ' '_')"
STAMP_FILE="$INSTALL_ROOT/.tcpviewer-build-stamp"

resolve_sdkroot() {
  if [ -n "${SDKROOT:-}" ] && [ -e "$SDKROOT" ]; then
    printf '%s' "$SDKROOT"
    return
  fi

  if command -v xcrun >/dev/null 2>&1; then
    xcrun --sdk macosx --show-sdk-path 2>/dev/null || true
  fi
}

SDKROOT_PATH="$(resolve_sdkroot)"
CURRENT_STAMP_CONTENT="tag=$PINNED_TAG;commit=$PINNED_COMMIT;config=$CONFIGURATION_NAME;archs=$CMAKE_ARCHITECTURES;sdk=$SDKROOT_PATH"

cache_value() {
  KEY="$1"
  CACHE_FILE="$2"
  awk -F= -v key="$KEY:INTERNAL" '$1 == key { print $2; exit }' "$CACHE_FILE"
}

cache_entry_value() {
  KEY="$1"
  CACHE_FILE="$2"
  awk -F= -v key="$KEY" 'index($1, key ":") == 1 { print $2; exit }' "$CACHE_FILE"
}

reset_mismatched_cmake_cache() {
  CACHE_FILE="$BUILD_DIR/CMakeCache.txt"

  if [ ! -f "$CACHE_FILE" ]; then
    return
  fi

  CACHE_SOURCE_DIR="$(cache_value CMAKE_HOME_DIRECTORY "$CACHE_FILE")"
  CACHE_BUILD_DIR="$(cache_value CMAKE_CACHEFILE_DIR "$CACHE_FILE")"

  # CMake caches are tied to absolute source/build paths, so copied caches must be discarded.
  if [ "$CACHE_SOURCE_DIR" != "$SOURCE_DIR" ] || [ "$CACHE_BUILD_DIR" != "$BUILD_DIR" ]; then
    echo "warning: removing stale PcapPlusPlus CMake cache for a different checkout." >&2
    rm -rf "$BUILD_DIR"
    return
  fi

  CACHE_SDKROOT="$(cache_entry_value CMAKE_OSX_SYSROOT "$CACHE_FILE")"

  # Xcode SDK paths can change after an update, and CMake keeps old .tbd paths in its cache.
  if [ -n "$CACHE_SDKROOT" ] && { [ ! -e "$CACHE_SDKROOT" ] || { [ -n "$SDKROOT_PATH" ] && [ "$CACHE_SDKROOT" != "$SDKROOT_PATH" ]; }; }; then
    echo "warning: removing stale PcapPlusPlus CMake cache for a different macOS SDK." >&2
    rm -rf "$BUILD_DIR"
  fi
}

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required to prepare vendored PcapPlusPlus." >&2
  exit 1
fi

CMAKE_BIN="${CMAKE_BIN:-}"

if [ -z "$CMAKE_BIN" ]; then
  # Xcode build phases may not inherit Homebrew's PATH, so probe common CMake locations.
  for CANDIDATE in cmake /opt/homebrew/bin/cmake /usr/local/bin/cmake /Applications/CMake.app/Contents/bin/cmake; do
    if command -v "$CANDIDATE" >/dev/null 2>&1; then
      CMAKE_BIN="$(command -v "$CANDIDATE")"
      break
    fi
  done
fi

if [ -z "$CMAKE_BIN" ]; then
  echo "error: cmake is required to build vendored PcapPlusPlus." >&2
  echo "       Install it with: brew install cmake" >&2
  exit 1
fi

# Keep the native dependency reproducible by resetting the submodule to the repository-pinned gitlink before CMake runs.
git -C "$PROJECT_DIR" submodule sync -- Vendor/PcapPlusPlus
git -C "$PROJECT_DIR" submodule update --init --recursive --checkout Vendor/PcapPlusPlus

CURRENT_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"

if [ "$CURRENT_COMMIT" != "$PINNED_COMMIT" ]; then
  echo "error: Vendor/PcapPlusPlus is at $CURRENT_COMMIT, expected $PINNED_TAG ($PINNED_COMMIT)." >&2
  echo "       Run: git submodule update --init --recursive --checkout Vendor/PcapPlusPlus" >&2
  exit 1
fi

if git -C "$SOURCE_DIR" rev-parse --verify --quiet "$PINNED_TAG^{commit}" >/dev/null; then
  TAG_COMMIT="$(git -C "$SOURCE_DIR" rev-parse "$PINNED_TAG^{commit}")"

  if [ "$TAG_COMMIT" != "$PINNED_COMMIT" ]; then
    echo "error: Vendor/PcapPlusPlus tag $PINNED_TAG resolves to $TAG_COMMIT, expected $PINNED_COMMIT." >&2
    exit 1
  fi
fi

mkdir -p "$BUILD_DIR" "$INSTALL_ROOT"
reset_mismatched_cmake_cache

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$CURRENT_STAMP_CONTENT" ] \
  && [ -f "$INSTALL_ROOT/lib/libPcap++.a" ] \
  && [ -f "$INSTALL_ROOT/lib/libPacket++.a" ] \
  && [ -f "$INSTALL_ROOT/lib/libCommon++.a" ]; then
  exit 0
fi

"$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCHITECTURES" \
  -DCMAKE_OSX_SYSROOT="$SDKROOT_PATH" \
  -DBUILD_SHARED_LIBS=OFF \
  -DPCAPPP_BUILD_EXAMPLES=OFF \
  -DPCAPPP_BUILD_TESTS=OFF \
  -DPCAPPP_INSTALL=ON

"$CMAKE_BIN" --build "$BUILD_DIR" --config RelWithDebInfo --parallel
"$CMAKE_BIN" --install "$BUILD_DIR" --config RelWithDebInfo

printf '%s' "$CURRENT_STAMP_CONTENT" > "$STAMP_FILE"
