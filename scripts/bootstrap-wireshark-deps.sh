#!/bin/sh

set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
BUILD_ROOT="$PROJECT_DIR/Vendor/.build/wireshark-deps"
SOURCE_ROOT="$BUILD_ROOT/sources"
DOWNLOAD_ROOT="$BUILD_ROOT/downloads"
INSTALL_ROOT="$PROJECT_DIR/Vendor/.install/wireshark-deps"
STAMP_FILE="$INSTALL_ROOT/.tcpviewer-build-stamp"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
ARCHITECTURES="${ARCHS:-${NATIVE_ARCH_ACTUAL:-${CURRENT_ARCH:-arm64}}}"
CMAKE_ARCHITECTURES="$(printf '%s' "$ARCHITECTURES" | tr ' ' ';')"

GLIB_VERSION=2.88.1
PCRE2_VERSION=10.47
GETTEXT_VERSION=1.0
LIBGCRYPT_VERSION=1.12.2
LIBGPG_ERROR_VERSION=1.61
GNUTLS_VERSION=3.8.13
GMP_VERSION=6.3.0
NETTLE_VERSION=4.0
LIBTASN1_VERSION=4.21.0
LIBIDN2_VERSION=2.3.8
LIBUNISTRING_VERSION=1.4.2
P11_KIT_VERSION=0.26.2
BROTLI_VERSION=1.2.0
CARES_VERSION=1.34.6
LZ4_VERSION=1.10.0
NGHTTP2_VERSION=1.69.0
NGHTTP3_VERSION=1.16.0
SNAPPY_VERSION=1.2.2
XXHASH_VERSION=0.8.3
ZSTD_VERSION=1.5.7
BUILD_REVISION=3

resolve_sdkroot() {
  if [ -n "${SDKROOT:-}" ] && [ -e "$SDKROOT" ]; then
    printf '%s' "$SDKROOT"
    return
  fi

  if command -v xcrun >/dev/null 2>&1; then
    xcrun --sdk macosx --show-sdk-path 2>/dev/null || true
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

SDKROOT_PATH="$(resolve_sdkroot)"
CURRENT_STAMP_CONTENT="revision=$BUILD_REVISION;glib=$GLIB_VERSION;pcre2=$PCRE2_VERSION;gettext=$GETTEXT_VERSION;libgcrypt=$LIBGCRYPT_VERSION;libgpg-error=$LIBGPG_ERROR_VERSION;gnutls=$GNUTLS_VERSION;gmp=$GMP_VERSION;nettle=$NETTLE_VERSION;libtasn1=$LIBTASN1_VERSION;libidn2=$LIBIDN2_VERSION;libunistring=$LIBUNISTRING_VERSION;p11-kit=$P11_KIT_VERSION;brotli=$BROTLI_VERSION;c-ares=$CARES_VERSION;lz4=$LZ4_VERSION;nghttp2=$NGHTTP2_VERSION;nghttp3=$NGHTTP3_VERSION;snappy=$SNAPPY_VERSION;xxhash=$XXHASH_VERSION;zstd=$ZSTD_VERSION;archs=$CMAKE_ARCHITECTURES;deployment=$DEPLOYMENT_TARGET;sdk=$SDKROOT_PATH"

has_installed_library() {
  NAME="$1"
  find "$INSTALL_ROOT/lib" -name "lib$NAME.*.dylib" -print -quit 2>/dev/null | grep -q .
}

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$CURRENT_STAMP_CONTENT" ] \
  && has_installed_library glib-2.0 \
  && has_installed_library gnutls \
  && has_installed_library gcrypt \
  && has_installed_library zstd; then
  exit 0
fi

CURL_BIN="$(find_tool "${CURL_BIN:-}" curl /usr/bin/curl)"
CMAKE_BIN="$(find_tool "${CMAKE_BIN:-}" cmake /opt/homebrew/bin/cmake /usr/local/bin/cmake /Applications/CMake.app/Contents/bin/cmake)"
NINJA_BIN="$(find_tool "${NINJA_BIN:-}" ninja /opt/homebrew/bin/ninja /usr/local/bin/ninja)"
MESON_BIN="$(find_tool "${MESON_BIN:-}" meson /opt/homebrew/bin/meson /usr/local/bin/meson)"
PKG_CONFIG_BIN="$(find_tool "${PKG_CONFIG:-}" pkg-config /opt/homebrew/bin/pkg-config /usr/local/bin/pkg-config)"

if [ -z "$CURL_BIN" ]; then
  echo "error: curl is required to download Wireshark dependency source archives." >&2
  exit 1
fi

if [ -z "$CMAKE_BIN" ] || [ -z "$NINJA_BIN" ] || [ -z "$MESON_BIN" ] || [ -z "$PKG_CONFIG_BIN" ]; then
  echo "error: cmake, ninja, meson, and pkg-config are required as build tools." >&2
  echo "       Install build tools with: brew install cmake ninja meson pkg-config autoconf automake libtool" >&2
  exit 1
fi

rm -rf "$INSTALL_ROOT"
mkdir -p "$DOWNLOAD_ROOT" "$SOURCE_ROOT" "$INSTALL_ROOT"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export PKG_CONFIG="$PKG_CONFIG_BIN"
export PKG_CONFIG_PATH="$INSTALL_ROOT/lib/pkgconfig:$INSTALL_ROOT/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export CMAKE_PREFIX_PATH="$INSTALL_ROOT"
export PATH="$INSTALL_ROOT/bin:$PATH"
# Meson detects Ninja separately, so pass the absolute path resolved outside Xcode's restricted PATH.
export NINJA="$NINJA_BIN"
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

export CPPFLAGS="-I$INSTALL_ROOT/include ${TCPVIEWER_WIRESHARK_DEPS_CPPFLAGS:-}"
export CFLAGS="$COMMON_FLAGS -O2 ${TCPVIEWER_WIRESHARK_DEPS_CFLAGS:-}"
export CXXFLAGS="$COMMON_FLAGS -O2 ${TCPVIEWER_WIRESHARK_DEPS_CXXFLAGS:-}"
export LDFLAGS="-L$INSTALL_ROOT/lib -mmacosx-version-min=$DEPLOYMENT_TARGET ${TCPVIEWER_WIRESHARK_DEPS_LDFLAGS:-}"

download_archive() {
  NAME="$1"
  URL="$2"
  CHECKSUM="$3"
  ARCHIVE_PATH="$DOWNLOAD_ROOT/$NAME"

  if [ ! -f "$ARCHIVE_PATH" ]; then
    "$CURL_BIN" --fail --location --retry 3 --output "$ARCHIVE_PATH" "$URL"
  fi

  ACTUAL_CHECKSUM="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{ print $1 }')"
  if [ "$ACTUAL_CHECKSUM" != "$CHECKSUM" ]; then
    echo "error: checksum mismatch for $NAME" >&2
    echo "       expected: $CHECKSUM" >&2
    echo "       actual:   $ACTUAL_CHECKSUM" >&2
    exit 1
  fi
}

extract_archive() {
  NAME="$1"
  ARCHIVE_NAME="$2"
  SOURCE_DIR="$SOURCE_ROOT/$NAME"

  if [ -d "$SOURCE_DIR" ]; then
    printf '%s' "$SOURCE_DIR"
    return
  fi

  mkdir -p "$SOURCE_DIR"
  tar -xf "$DOWNLOAD_ROOT/$ARCHIVE_NAME" -C "$SOURCE_DIR" --strip-components 1
  printf '%s' "$SOURCE_DIR"
}

build_autotools() {
  NAME="$1"
  shift
  SOURCE_DIR="$1"
  shift
  BUILD_DIR="$BUILD_ROOT/build/$NAME"

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  (
    cd "$BUILD_DIR"
    "$SOURCE_DIR/configure" --prefix="$INSTALL_ROOT" --disable-static --enable-shared "$@"
    make -j"${PARALLEL_JOBS:-$(sysctl -n hw.ncpu)}"
    make install
  )
}

build_cmake() {
  NAME="$1"
  shift
  SOURCE_DIR="$1"
  shift
  BUILD_DIR="$BUILD_ROOT/build/$NAME"

  rm -rf "$BUILD_DIR"
  "$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCHITECTURES" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT_PATH" \
    -DCMAKE_INSTALL_NAME_DIR="@rpath" \
    -DCMAKE_PREFIX_PATH="$INSTALL_ROOT" \
    "$@"
  "$CMAKE_BIN" --build "$BUILD_DIR" --parallel
  "$CMAKE_BIN" --install "$BUILD_DIR"
}

build_meson() {
  NAME="$1"
  shift
  SOURCE_DIR="$1"
  shift
  BUILD_DIR="$BUILD_ROOT/build/$NAME"

  rm -rf "$BUILD_DIR"
  "$MESON_BIN" setup "$BUILD_DIR" "$SOURCE_DIR" \
    --prefix "$INSTALL_ROOT" \
    --libdir lib \
    --buildtype release \
    --default-library shared \
    "$@"
  "$MESON_BIN" compile -C "$BUILD_DIR"
  "$MESON_BIN" install -C "$BUILD_DIR"
}

validate_pkg_config_files() {
  FAILURE_FILE="$INSTALL_ROOT/.tcpviewer-forbidden-pkg-config-paths.txt"
  : > "$FAILURE_FILE"

  find "$INSTALL_ROOT" -name '*.pc' -print | while IFS= read -r PC_FILE; do
    if grep -E '/opt/homebrew|/usr/local' "$PC_FILE" >/dev/null 2>&1; then
      printf '%s\n' "$PC_FILE" >> "$FAILURE_FILE"
    fi
  done

  if [ -s "$FAILURE_FILE" ]; then
    echo "error: generated pkg-config files reference machine-local runtime prefixes." >&2
    sed 's/^/       /' "$FAILURE_FILE" >&2
    exit 1
  fi
}

normalize_dependency_install_names() {
  find "$INSTALL_ROOT/lib" -type f -name '*.dylib' -print | while IFS= read -r LIBRARY; do
    INSTALL_ID="$(otool -D "$LIBRARY" 2>/dev/null | sed -n '/):$/d; 1!p' | head -n 1)"
    case "$INSTALL_ID" in
      "$INSTALL_ROOT"/lib/*|/usr/local/lib/*|/opt/homebrew/lib/*)
        install_name_tool -id "@rpath/$(basename "$INSTALL_ID")" "$LIBRARY"
        ;;
    esac
  done

  # Normalize upstream Makefile install names before Wireshark records them while linking.
  find "$INSTALL_ROOT/lib" -type f -name '*.dylib' -print | while IFS= read -r LIBRARY; do
    otool -L "$LIBRARY" 2>/dev/null | sed -n '/^[[:space:]]/ { s/^[[:space:]]*//; s/ (compatibility.*$//; p; }' | while IFS= read -r DEPENDENCY; do
      case "$DEPENDENCY" in
        "$INSTALL_ROOT"/lib/*|/usr/local/lib/*|/opt/homebrew/lib/*)
          install_name_tool -change "$DEPENDENCY" "@rpath/$(basename "$DEPENDENCY")" "$LIBRARY"
          ;;
      esac
    done
  done
}

download_archive "libunistring-$LIBUNISTRING_VERSION.tar.gz" "https://ftpmirror.gnu.org/gnu/libunistring/libunistring-$LIBUNISTRING_VERSION.tar.gz" "e82664b170064e62331962126b259d452d53b227bb4a93ab20040d846fec01d8"
build_autotools "libunistring" "$(extract_archive "libunistring-$LIBUNISTRING_VERSION" "libunistring-$LIBUNISTRING_VERSION.tar.gz")"

download_archive "gettext-$GETTEXT_VERSION.tar.gz" "https://ftpmirror.gnu.org/gnu/gettext/gettext-$GETTEXT_VERSION.tar.gz" "85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a"
GETTEXT_SOURCE_DIR="$(extract_archive "gettext-$GETTEXT_VERSION" "gettext-$GETTEXT_VERSION.tar.gz")"
# Wireshark only needs the gettext runtime libintl library; gettext-tools builds extra UI libraries.
build_autotools "gettext-runtime" "$GETTEXT_SOURCE_DIR/gettext-runtime" --disable-java --disable-csharp --with-libunistring-prefix="$INSTALL_ROOT"

download_archive "pcre2-$PCRE2_VERSION.tar.bz2" "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.bz2" "47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7"
build_cmake "pcre2" "$(extract_archive "pcre2-$PCRE2_VERSION" "pcre2-$PCRE2_VERSION.tar.bz2")" \
  -DBUILD_SHARED_LIBS=ON \
  -DPCRE2_BUILD_TESTS=OFF \
  -DPCRE2_BUILD_PCRE2GREP=OFF \
  -DPCRE2_BUILD_PCRE2_8=ON \
  -DPCRE2_BUILD_PCRE2_16=OFF \
  -DPCRE2_BUILD_PCRE2_32=OFF

download_archive "glib-$GLIB_VERSION.tar.xz" "https://download.gnome.org/sources/glib/2.88/glib-$GLIB_VERSION.tar.xz" "51ab804c56f6eab3e5045c774d1290ac5e4c923d4f9a3d8e33123bee45c1840e"
GLIB_SOURCE_DIR="$(extract_archive "glib-$GLIB_VERSION" "glib-$GLIB_VERSION.tar.xz")"
GLIB_PATCH_FILE="$PROJECT_DIR/scripts/patches/glib-2.88.1-macos-pipe2-availability.patch"
# Keep patching idempotent because extracted dependency sources are cached between builds.
if /usr/bin/patch -d "$GLIB_SOURCE_DIR" -p1 --forward --dry-run < "$GLIB_PATCH_FILE" >/dev/null 2>&1; then
  /usr/bin/patch -d "$GLIB_SOURCE_DIR" -p1 --forward < "$GLIB_PATCH_FILE"
elif ! /usr/bin/patch -d "$GLIB_SOURCE_DIR" -p1 --reverse --dry-run < "$GLIB_PATCH_FILE" >/dev/null 2>&1; then
  echo "error: could not apply the GLib macOS availability patch." >&2
  exit 1
fi
build_meson "glib" "$GLIB_SOURCE_DIR" \
  -Dtests=false \
  -Dinstalled_tests=false \
  -Dintrospection=disabled \
  -Dman-pages=disabled \
  -Ddtrace=false \
  -Dsystemtap=false \
  -Dselinux=disabled \
  -Dlibmount=disabled \
  -Dxattr=false

download_archive "libgpg-error-$LIBGPG_ERROR_VERSION.tar.bz2" "https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-$LIBGPG_ERROR_VERSION.tar.bz2" "7a85413f2bc354f4f8aa832b718af122e48965e9e0eb9012ee659c13c6385c93"
build_autotools "libgpg-error" "$(extract_archive "libgpg-error-$LIBGPG_ERROR_VERSION" "libgpg-error-$LIBGPG_ERROR_VERSION.tar.bz2")"

download_archive "libgcrypt-$LIBGCRYPT_VERSION.tar.bz2" "https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-$LIBGCRYPT_VERSION.tar.bz2" "7ce33c2492221a0436f96a8500215e9f3e3dcb5fd26a757cd415e7a843babd5e"
build_autotools "libgcrypt" "$(extract_archive "libgcrypt-$LIBGCRYPT_VERSION" "libgcrypt-$LIBGCRYPT_VERSION.tar.bz2")" --with-libgpg-error-prefix="$INSTALL_ROOT"

download_archive "gmp-$GMP_VERSION.tar.xz" "https://ftpmirror.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz" "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
build_autotools "gmp" "$(extract_archive "gmp-$GMP_VERSION" "gmp-$GMP_VERSION.tar.xz")"

download_archive "nettle-$NETTLE_VERSION.tar.gz" "https://ftpmirror.gnu.org/gnu/nettle/nettle-$NETTLE_VERSION.tar.gz" "3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094"
build_autotools "nettle" "$(extract_archive "nettle-$NETTLE_VERSION" "nettle-$NETTLE_VERSION.tar.gz")" --with-lib-path="$INSTALL_ROOT/lib" --with-include-path="$INSTALL_ROOT/include"

download_archive "libtasn1-$LIBTASN1_VERSION.tar.gz" "https://ftpmirror.gnu.org/gnu/libtasn1/libtasn1-$LIBTASN1_VERSION.tar.gz" "1d8a444a223cc5464240777346e125de51d8e6abf0b8bac742ac84609167dc87"
build_autotools "libtasn1" "$(extract_archive "libtasn1-$LIBTASN1_VERSION" "libtasn1-$LIBTASN1_VERSION.tar.gz")"

download_archive "libidn2-$LIBIDN2_VERSION.tar.gz" "https://ftpmirror.gnu.org/gnu/libidn/libidn2-$LIBIDN2_VERSION.tar.gz" "f557911bf6171621e1f72ff35f5b1825bb35b52ed45325dcdee931e5d3c0787a"
build_autotools "libidn2" "$(extract_archive "libidn2-$LIBIDN2_VERSION" "libidn2-$LIBIDN2_VERSION.tar.gz")" --with-libunistring-prefix="$INSTALL_ROOT" --disable-doc

download_archive "p11-kit-$P11_KIT_VERSION.tar.xz" "https://github.com/p11-glue/p11-kit/releases/download/$P11_KIT_VERSION/p11-kit-$P11_KIT_VERSION.tar.xz" "09fd9f44da4813a3141e73d5e7cf7008e5660d0405f13d56c15e1da9dcecf828"
build_meson "p11-kit" "$(extract_archive "p11-kit-$P11_KIT_VERSION" "p11-kit-$P11_KIT_VERSION.tar.xz")" \
  -Dgtk_doc=false \
  -Dman=false \
  -Dnls=false \
  -Dtrust_module=disabled \
  -Dsystemd=disabled \
  -Dbash_completion=disabled

download_archive "gnutls-$GNUTLS_VERSION.tar.xz" "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-$GNUTLS_VERSION.tar.xz" "ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e"
build_autotools "gnutls" "$(extract_archive "gnutls-$GNUTLS_VERSION" "gnutls-$GNUTLS_VERSION.tar.xz")" --disable-doc --disable-tests --disable-tools --with-included-unistring=no --with-p11-kit

download_archive "brotli-$BROTLI_VERSION.tar.gz" "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" "816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec"
build_cmake "brotli" "$(extract_archive "brotli-$BROTLI_VERSION" "brotli-$BROTLI_VERSION.tar.gz")" -DBUILD_SHARED_LIBS=ON -DBROTLI_DISABLE_TESTS=ON

download_archive "c-ares-$CARES_VERSION.tar.gz" "https://github.com/c-ares/c-ares/releases/download/v$CARES_VERSION/c-ares-$CARES_VERSION.tar.gz" "912dd7cc3b3e8a79c52fd7fb9c0f4ecf0aaa73e45efda880266a2d6e26b84ef5"
# SDK 27 exposes pipe2, but c-ares must retain its portable fallback for the macOS 15 target.
build_cmake "c-ares" "$(extract_archive "c-ares-$CARES_VERSION" "c-ares-$CARES_VERSION.tar.gz")" -DCARES_SHARED=ON -DCARES_STATIC=OFF -DCARES_BUILD_TOOLS=OFF -DCARES_BUILD_TESTS=OFF -DHAVE_PIPE2=0

download_archive "lz4-$LZ4_VERSION.tar.gz" "https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VERSION.tar.gz" "537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"
(
  cd "$(extract_archive "lz4-$LZ4_VERSION" "lz4-$LZ4_VERSION.tar.gz")"
  make -C lib clean
  make -C lib -j"${PARALLEL_JOBS:-$(sysctl -n hw.ncpu)}" PREFIX="$INSTALL_ROOT" BUILD_SHARED=yes BUILD_STATIC=no
  make -C lib install PREFIX="$INSTALL_ROOT" BUILD_SHARED=yes BUILD_STATIC=no
)

download_archive "nghttp2-$NGHTTP2_VERSION.tar.gz" "https://github.com/nghttp2/nghttp2/releases/download/v$NGHTTP2_VERSION/nghttp2-$NGHTTP2_VERSION.tar.gz" "c866b7477cbb7512ab6863a685027adbb1bb8da8fc3bab7429ed43d3281d5aa9"
build_autotools "nghttp2" "$(extract_archive "nghttp2-$NGHTTP2_VERSION" "nghttp2-$NGHTTP2_VERSION.tar.gz")" --enable-lib-only --without-libxml2 --without-jemalloc --without-systemd --without-cunit

download_archive "nghttp3-$NGHTTP3_VERSION.tar.xz" "https://github.com/ngtcp2/nghttp3/releases/download/v$NGHTTP3_VERSION/nghttp3-$NGHTTP3_VERSION.tar.xz" "776f59a99905c9a348846807b2e5ac9bb3485fc0f8c0250ba803018d5238a16e"
build_cmake "nghttp3" "$(extract_archive "nghttp3-$NGHTTP3_VERSION" "nghttp3-$NGHTTP3_VERSION.tar.xz")" -DENABLE_SHARED_LIB=ON -DENABLE_STATIC_LIB=OFF -DENABLE_LIB_ONLY=ON

download_archive "snappy-$SNAPPY_VERSION.tar.gz" "https://github.com/google/snappy/archive/refs/tags/$SNAPPY_VERSION.tar.gz" "90f74bc1fbf78a6c56b3c4a082a05103b3a56bb17bca1a27e052ea11723292dc"
build_cmake "snappy" "$(extract_archive "snappy-$SNAPPY_VERSION" "snappy-$SNAPPY_VERSION.tar.gz")" -DBUILD_SHARED_LIBS=ON -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF

download_archive "xxhash-$XXHASH_VERSION.tar.gz" "https://github.com/Cyan4973/xxHash/archive/refs/tags/v$XXHASH_VERSION.tar.gz" "aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80"
(
  cd "$(extract_archive "xxhash-$XXHASH_VERSION" "xxhash-$XXHASH_VERSION.tar.gz")"
  make clean
  make -j"${PARALLEL_JOBS:-$(sysctl -n hw.ncpu)}" libxxhash
  make install PREFIX="$INSTALL_ROOT" BUILD_SHARED=1 BUILD_STATIC=0
)

download_archive "zstd-$ZSTD_VERSION.tar.gz" "https://github.com/facebook/zstd/archive/refs/tags/v$ZSTD_VERSION.tar.gz" "37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3"
(
  cd "$(extract_archive "zstd-$ZSTD_VERSION" "zstd-$ZSTD_VERSION.tar.gz")"
  make -C lib clean
  make -C lib -j"${PARALLEL_JOBS:-$(sysctl -n hw.ncpu)}" libzstd
  make -C lib install PREFIX="$INSTALL_ROOT" BUILD_SHARED=1 BUILD_STATIC=0
)

validate_pkg_config_files
normalize_dependency_install_names
"$PROJECT_DIR/scripts/verify-bundled-runtime-compatibility.sh" "$INSTALL_ROOT" "$DEPLOYMENT_TARGET" --allow-prefix "$INSTALL_ROOT"

mkdir -p "$(dirname "$STAMP_FILE")"
printf '%s' "$CURRENT_STAMP_CONTENT" > "$STAMP_FILE"

cat <<EOF
Wireshark dependencies installed in $INSTALL_ROOT.
Bundled runtime libraries are built from source for macOS $DEPLOYMENT_TARGET or newer.
EOF
