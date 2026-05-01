#!/bin/sh

set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_DIR="$PROJECT_DIR/Vendor/Wireshark"
BUILD_ROOT="$PROJECT_DIR/Vendor/.build"
INSTALL_ROOT="$PROJECT_DIR/Vendor/.install/wireshark"
PINNED_TAG="v4.6.4"
PINNED_COMMIT="93282876538d78a2927108dd71ee0ff370aedb0a"
REMOTE_URL="https://gitlab.com/wireshark/wireshark.git"
CONFIGURATION_NAME="${CONFIGURATION:-Debug}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
ARCHITECTURES="${ARCHS:-${NATIVE_ARCH_ACTUAL:-${CURRENT_ARCH:-arm64}}}"
# Xcode passes ARCHS as space-separated values, while CMake expects a semicolon list.
CMAKE_ARCHITECTURES="$(printf '%s' "$ARCHITECTURES" | tr ' ' ';')"
BUILD_DIR="$BUILD_ROOT/wireshark-${CONFIGURATION_NAME}-$(printf '%s' "$ARCHITECTURES" | tr ' ' '_')"
STAMP_FILE="$INSTALL_ROOT/.tcpviewer-build-stamp"
CURRENT_STAMP_CONTENT="tag=$PINNED_TAG;commit=$PINNED_COMMIT;config=$CONFIGURATION_NAME;archs=$CMAKE_ARCHITECTURES;deployment=$DEPLOYMENT_TARGET"

cache_value() {
  KEY="$1"
  CACHE_FILE="$2"
  awk -F= -v key="$KEY:INTERNAL" '$1 == key { print $2; exit }' "$CACHE_FILE"
}

reset_mismatched_cmake_cache() {
  CACHE_FILE="$BUILD_DIR/CMakeCache.txt"

  if [ ! -f "$CACHE_FILE" ]; then
    return
  fi

  CACHE_SOURCE_DIR="$(cache_value CMAKE_HOME_DIRECTORY "$CACHE_FILE")"
  CACHE_BUILD_DIR="$(cache_value CMAKE_CACHEFILE_DIR "$CACHE_FILE")"

  # CMake caches are tied to absolute paths, so copied build folders must be recreated.
  if [ "$CACHE_SOURCE_DIR" != "$SOURCE_DIR" ] || [ "$CACHE_BUILD_DIR" != "$BUILD_DIR" ]; then
    echo "warning: removing stale Wireshark CMake cache for a different checkout." >&2
    rm -rf "$BUILD_DIR"
  fi
}

find_tool() {
  VARIABLE_VALUE="$1"
  shift

  if [ -n "$VARIABLE_VALUE" ]; then
    if command -v "$VARIABLE_VALUE" >/dev/null 2>&1; then
      command -v "$VARIABLE_VALUE"
      return
    fi
    echo "$VARIABLE_VALUE"
    return
  fi

  for CANDIDATE in "$@"; do
    if command -v "$CANDIDATE" >/dev/null 2>&1; then
      command -v "$CANDIDATE"
      return
    fi
  done
}

has_installed_library() {
  NAME="$1"
  find "$INSTALL_ROOT/lib" -name "lib$NAME.*" -print -quit 2>/dev/null | grep -q .
}

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required to prepare vendored Wireshark." >&2
  exit 1
fi

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$CURRENT_STAMP_CONTENT" ] \
  && has_installed_library wireshark \
  && has_installed_library wiretap \
  && has_installed_library wsutil; then
  exit 0
fi

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "error: pkg-config is required for Wireshark dependency discovery." >&2
  echo "       Install Wireshark's macOS build dependencies, for example: brew install pkg-config cmake ninja glib libgcrypt gnutls nghttp2 brotli lz4 zstd" >&2
  exit 1
fi

CMAKE_BIN="$(find_tool "${CMAKE_BIN:-}" cmake /opt/homebrew/bin/cmake /usr/local/bin/cmake /Applications/CMake.app/Contents/bin/cmake)"
if [ -z "$CMAKE_BIN" ]; then
  echo "error: cmake is required to build vendored Wireshark." >&2
  echo "       Install it with: brew install cmake" >&2
  exit 1
fi

NINJA_BIN="$(find_tool "${NINJA_BIN:-}" ninja /opt/homebrew/bin/ninja /usr/local/bin/ninja)"
if [ -z "$NINJA_BIN" ]; then
  echo "error: ninja is required to build vendored Wireshark." >&2
  echo "       Install it with: brew install ninja" >&2
  exit 1
fi

if [ ! -e "$SOURCE_DIR/.git" ]; then
  if [ -d "$SOURCE_DIR" ] && [ -n "$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "error: $SOURCE_DIR exists but is not a git checkout." >&2
    echo "       Remove it or move it aside before running this script again." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$SOURCE_DIR")"
  git clone --branch "$PINNED_TAG" --depth 1 "$REMOTE_URL" "$SOURCE_DIR"
elif ! git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $SOURCE_DIR has a .git entry but is not a valid git checkout." >&2
  exit 1
fi

git -C "$SOURCE_DIR" fetch --depth 1 origin "refs/tags/$PINNED_TAG:refs/tags/$PINNED_TAG"
git -C "$SOURCE_DIR" checkout --detach "$PINNED_COMMIT"
git -C "$SOURCE_DIR" submodule update --init --recursive

CURRENT_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ "$CURRENT_COMMIT" != "$PINNED_COMMIT" ]; then
  echo "error: Vendor/Wireshark is at $CURRENT_COMMIT, expected $PINNED_TAG ($PINNED_COMMIT)." >&2
  exit 1
fi

TAG_COMMIT="$(git -C "$SOURCE_DIR" rev-parse "$PINNED_TAG^{commit}")"
if [ "$TAG_COMMIT" != "$PINNED_COMMIT" ]; then
  echo "error: Vendor/Wireshark tag $PINNED_TAG resolves to $TAG_COMMIT, expected $PINNED_COMMIT." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$INSTALL_ROOT"
reset_mismatched_cmake_cache

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$CURRENT_STAMP_CONTENT" ] \
  && has_installed_library wireshark \
  && has_installed_library wiretap \
  && has_installed_library wsutil; then
  exit 0
fi

# Clear partial installs so CMake's macOS install-name rewrites stay repeatable.
rm -rf "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"

"$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCHITECTURES" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DENABLE_APPLICATION_BUNDLE=OFF \
  -DENABLE_QT6=OFF \
  -DENABLE_QT5=OFF \
  -DENABLE_DOCS=OFF \
  -DENABLE_DOXYGEN=OFF \
  -DENABLE_MAN_PAGES=OFF \
  -DENABLE_PLUGINS=OFF \
  -DBUILD_androiddump=OFF \
  -DBUILD_ciscodump=OFF \
  -DBUILD_capinfos=OFF \
  -DBUILD_captype=OFF \
  -DBUILD_dcerpcidl2wrs=OFF \
  -DBUILD_dftest=OFF \
  -DBUILD_dpauxmon=OFF \
  -DBUILD_dumpcap=OFF \
  -DBUILD_editcap=OFF \
  -DBUILD_etwdump=OFF \
  -DBUILD_falcodump=OFF \
  -DBUILD_mergecap=OFF \
  -DBUILD_mmdbresolve=OFF \
  -DBUILD_randpktdump=OFF \
  -DBUILD_randpkt=OFF \
  -DBUILD_rawshark=OFF \
  -DBUILD_reordercap=OFF \
  -DBUILD_sharkd=OFF \
  -DBUILD_sdjournal=OFF \
  -DBUILD_sshdig=OFF \
  -DBUILD_sshdump=OFF \
  -DBUILD_text2pcap=OFF \
  -DBUILD_tshark=OFF \
  -DBUILD_udpdump=OFF \
  -DBUILD_wifidump=OFF \
  -DBUILD_wireshark=OFF

"$CMAKE_BIN" --build "$BUILD_DIR" --config RelWithDebInfo --target epan wiretap wsutil --parallel
"$CMAKE_BIN" --install "$BUILD_DIR" --config RelWithDebInfo

if ! has_installed_library wireshark || ! has_installed_library wiretap || ! has_installed_library wsutil; then
  echo "error: Wireshark install did not produce libwireshark, libwiretap, and libwsutil in $INSTALL_ROOT/lib." >&2
  exit 1
fi

printf '%s' "$CURRENT_STAMP_CONTENT" > "$STAMP_FILE"

cat <<EOF
Wireshark installed in $INSTALL_ROOT.
Enable TCP Viewer's Wireshark backend with:

TCPVIEWER_HAS_WIRESHARK=1 \\
TCPVIEWER_WIRESHARK_LDFLAGS="-L$INSTALL_ROOT/lib -Wl,-rpath,$INSTALL_ROOT/lib -lwireshark -lwiretap -lwsutil"
EOF
