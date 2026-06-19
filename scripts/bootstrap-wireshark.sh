#!/bin/sh

set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_DIR="$PROJECT_DIR/Vendor/Wireshark"
BUILD_ROOT="$PROJECT_DIR/Vendor/.build"
INSTALL_ROOT="$PROJECT_DIR/Vendor/.install/wireshark"
DEPS_INSTALL_ROOT="$PROJECT_DIR/Vendor/.install/wireshark-deps"
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
DEPS_STAMP_FILE="$DEPS_INSTALL_ROOT/.tcpviewer-build-stamp"

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
BASE_STAMP_CONTENT="tag=$PINNED_TAG;commit=$PINNED_COMMIT;config=$CONFIGURATION_NAME;archs=$CMAKE_ARCHITECTURES;deployment=$DEPLOYMENT_TARGET;sdk=$SDKROOT_PATH"

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

is_allowed_runtime_cache_path() {
  PATH_VALUE="$1"

  case "$PATH_VALUE" in
    -I/*|-L/*)
      PATH_VALUE="${PATH_VALUE#-?}"
      ;;
    -Wl,-rpath,/*)
      PATH_VALUE="${PATH_VALUE#-Wl,-rpath,}"
      ;;
  esac

  case "$PATH_VALUE" in
    ""|*-NOTFOUND|*NOTFOUND)
      return 0
      ;;
    "$DEPS_INSTALL_ROOT"|"$DEPS_INSTALL_ROOT"/*|/usr/lib/*|/System/Library/*)
      return 0
      ;;
  esac

  if [ -n "$SDKROOT_PATH" ]; then
    case "$PATH_VALUE" in
      "$SDKROOT_PATH"|"$SDKROOT_PATH"/*)
        return 0
        ;;
    esac
  fi

  case "$PATH_VALUE" in
    /*)
      return 1
      ;;
  esac

  return 0
}

is_forbidden_runtime_cache_entry() {
  KEY="$1"
  VALUE="$2"

  case "$KEY" in
    *LIBRARY*|*LIBRARIES*|*INCLUDE*|*LIBDIR*|*LIBRARY_DIRS*|*LDFLAGS*|*LDFLAG*|*LINK_FLAGS*)
      ;;
    *)
      return 1
      ;;
  esac

  OLD_IFS="$IFS"
  IFS=';'
  for PATH_VALUE in $VALUE; do
    IFS="$OLD_IFS"
    if ! is_allowed_runtime_cache_path "$PATH_VALUE"; then
      return 0
    fi
    IFS=';'
  done
  IFS="$OLD_IFS"

  return 1
}

cache_has_forbidden_runtime_path() {
  CACHE_FILE="$1"

  while IFS= read -r LINE; do
    case "$LINE" in
      *"="*)
        KEY="${LINE%%:*}"
        VALUE="${LINE#*=}"
        if is_forbidden_runtime_cache_entry "$KEY" "$VALUE"; then
          return 0
        fi
        ;;
    esac
  done < "$CACHE_FILE"

  return 1
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
    return
  fi

  CACHE_SDKROOT="$(cache_entry_value CMAKE_OSX_SYSROOT "$CACHE_FILE")"

  # Xcode SDK paths can change after an update, and CMake keeps old .tbd paths in its cache.
  if [ -n "$CACHE_SDKROOT" ] && { [ ! -e "$CACHE_SDKROOT" ] || { [ -n "$SDKROOT_PATH" ] && [ "$CACHE_SDKROOT" != "$SDKROOT_PATH" ]; }; }; then
    echo "warning: removing stale Wireshark CMake cache for a different macOS SDK." >&2
    rm -rf "$BUILD_DIR"
    return
  fi

  # Existing checkouts may still cache old Homebrew runtime paths from bottle-based builds.
  if cache_has_forbidden_runtime_path "$CACHE_FILE"; then
    echo "warning: removing stale Wireshark CMake cache with machine-local runtime paths." >&2
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

validate_wireshark_cache_paths() {
  CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
  FAILURE_FILE="$BUILD_DIR/tcpviewer-forbidden-runtime-paths.txt"

  [ -f "$CACHE_FILE" ] || return
  : > "$FAILURE_FILE"

  while IFS= read -r LINE; do
    case "$LINE" in
      *"="*)
        KEY="${LINE%%:*}"
        VALUE="${LINE#*=}"
        if is_forbidden_runtime_cache_entry "$KEY" "$VALUE"; then
          printf '%s\n' "$LINE" >> "$FAILURE_FILE"
        fi
        ;;
    esac
  done < "$CACHE_FILE"

  if [ -s "$FAILURE_FILE" ]; then
    echo "error: Wireshark CMake resolved runtime headers or libraries from a machine-local prefix." >&2
    echo "       Rebuild with scripts/bootstrap-wireshark-deps.sh so runtime deps come from $DEPS_INSTALL_ROOT." >&2
    sed 's/^/       /' "$FAILURE_FILE" >&2
    exit 1
  fi
}

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required to prepare vendored Wireshark." >&2
  exit 1
fi

"$PROJECT_DIR/scripts/bootstrap-wireshark-deps.sh"

if [ ! -f "$DEPS_STAMP_FILE" ]; then
  echo "error: Wireshark dependency stamp was not created at $DEPS_STAMP_FILE." >&2
  exit 1
fi
CURRENT_STAMP_CONTENT="$BASE_STAMP_CONTENT;deps=$(cat "$DEPS_STAMP_FILE")"

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$CURRENT_STAMP_CONTENT" ] \
  && has_installed_library wireshark \
  && has_installed_library wiretap \
  && has_installed_library wsutil; then
  exit 0
fi

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "error: pkg-config is required for Wireshark dependency discovery." >&2
  echo "       Install build tools with: brew install pkg-config cmake ninja meson autoconf automake libtool" >&2
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

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export PKG_CONFIG_PATH="$DEPS_INSTALL_ROOT/lib/pkgconfig:$DEPS_INSTALL_ROOT/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export CMAKE_PREFIX_PATH="$DEPS_INSTALL_ROOT"
export PATH="$DEPS_INSTALL_ROOT/bin:$PATH"
export CC="${CC:-/usr/bin/clang}"
export CXX="${CXX:-/usr/bin/clang++}"
unset CPATH
unset LIBRARY_PATH
unset DYLD_LIBRARY_PATH
unset DYLD_FALLBACK_LIBRARY_PATH

COMMON_FLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET -Werror=unguarded-availability-new"
if [ -n "$SDKROOT_PATH" ]; then
  COMMON_FLAGS="-isysroot $SDKROOT_PATH $COMMON_FLAGS"
fi

export CPPFLAGS="-I$DEPS_INSTALL_ROOT/include ${TCPVIEWER_WIRESHARK_CPPFLAGS:-}"
export CFLAGS="$COMMON_FLAGS -O2 ${TCPVIEWER_WIRESHARK_CFLAGS:-}"
export CXXFLAGS="$COMMON_FLAGS -O2 ${TCPVIEWER_WIRESHARK_CXXFLAGS:-}"
export LDFLAGS="-L$DEPS_INSTALL_ROOT/lib -mmacosx-version-min=$DEPLOYMENT_TARGET ${TCPVIEWER_WIRESHARK_LDFLAGS:-}"

"$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCHITECTURES" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_SYSROOT="$SDKROOT_PATH" \
  -DCMAKE_PREFIX_PATH="$DEPS_INSTALL_ROOT" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DCMAKE_SYSTEM_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE \
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE \
  -DCMAKE_INSTALL_NAME_DIR="@rpath" \
  -DENABLE_APPLICATION_BUNDLE=OFF \
  -DENABLE_QT6=OFF \
  -DENABLE_QT5=OFF \
  -DENABLE_DOCS=OFF \
  -DENABLE_DOXYGEN=OFF \
  -DENABLE_MAN_PAGES=OFF \
  -DENABLE_PLUGINS=OFF \
  -DENABLE_AMRNB=OFF \
  -DENABLE_OPUS=OFF \
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

validate_wireshark_cache_paths
"$CMAKE_BIN" --build "$BUILD_DIR" --config RelWithDebInfo --target epan wiretap wsutil --parallel
"$CMAKE_BIN" --install "$BUILD_DIR" --config RelWithDebInfo

if ! has_installed_library wireshark || ! has_installed_library wiretap || ! has_installed_library wsutil; then
  echo "error: Wireshark install did not produce libwireshark, libwiretap, and libwsutil in $INSTALL_ROOT/lib." >&2
  exit 1
fi

printf '%s' "$CURRENT_STAMP_CONTENT" > "$STAMP_FILE"

cat <<EOF
Wireshark installed in $INSTALL_ROOT.
TCP Viewer links and bundles the Wireshark backend by default.
EOF
