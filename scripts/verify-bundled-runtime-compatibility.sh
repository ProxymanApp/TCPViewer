#!/bin/sh

set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <app-or-directory> [maximum-macos-version] [--allow-prefix <path> ...]" >&2
  exit 2
fi

ROOT_PATH="$1"
MAXIMUM_MACOS_VERSION="${2:-15.0}"
shift
if [ "$#" -gt 0 ]; then
  shift
fi

ALLOW_PREFIXES=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-prefix)
      shift
      if [ "$#" -eq 0 ]; then
        echo "error: --allow-prefix requires a path." >&2
        exit 2
      fi
      ALLOW_PREFIXES="${ALLOW_PREFIXES}
$1"
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -e "$ROOT_PATH" ]; then
  echo "error: compatibility scan path does not exist: $ROOT_PATH" >&2
  exit 1
fi

version_gt() {
  /usr/bin/ruby -e '
    def version(value)
      value.to_s.split(".").map(&:to_i)
    end
    exit((version(ARGV[0]) <=> version(ARGV[1])) == 1 ? 0 : 1)
  ' "$1" "$2"
}

macho_minos() {
  otool -l "$1" 2>/dev/null | awk '
    /LC_BUILD_VERSION/ { in_build = 1; next }
    in_build && /minos / { print $2; exit }
    /LC_VERSION_MIN_MACOSX/ { in_legacy = 1; next }
    in_legacy && /version / { print $2; exit }
  '
}

is_macho() {
  otool -h "$1" >/dev/null 2>&1
}

is_allowed_prefix_path() {
  PATH_VALUE="$1"

  case "$PATH_VALUE" in
    /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*)
      return 0
      ;;
  esac

  OLD_IFS="$IFS"
  IFS='
'
  for PREFIX in $ALLOW_PREFIXES; do
    [ -n "$PREFIX" ] || continue
    case "$PATH_VALUE" in
      "$PREFIX"/*)
        IFS="$OLD_IFS"
        return 0
        ;;
    esac
  done
  IFS="$OLD_IFS"

  return 1
}

TMP_FAILURES="${TMPDIR:-/tmp}/tcpviewer-runtime-compatibility-$$.txt"
TMP_SELF_IDS="${TMPDIR:-/tmp}/tcpviewer-runtime-compatibility-self-ids-$$.txt"
trap 'rm -f "$TMP_FAILURES" "$TMP_SELF_IDS"' EXIT
: > "$TMP_FAILURES"

find "$ROOT_PATH" -type f -print | while IFS= read -r FILE_PATH; do
  if ! is_macho "$FILE_PATH"; then
    continue
  fi

  MINOS="$(macho_minos "$FILE_PATH")"
  if [ -n "$MINOS" ] && version_gt "$MINOS" "$MAXIMUM_MACOS_VERSION"; then
    printf '%s\n' "minos $MINOS > $MAXIMUM_MACOS_VERSION: $FILE_PATH" >> "$TMP_FAILURES"
  fi

  otool -D "$FILE_PATH" 2>/dev/null | sed -n '/):$/d; 1!p' > "$TMP_SELF_IDS"
  while IFS= read -r INSTALL_ID; do
    [ -n "$INSTALL_ID" ] || continue
    case "$INSTALL_ID" in
      /opt/homebrew/*|/usr/local/*)
        printf '%s\n' "machine-local install ID $INSTALL_ID in $FILE_PATH" >> "$TMP_FAILURES"
        ;;
    esac
  done < "$TMP_SELF_IDS"

  otool -L "$FILE_PATH" 2>/dev/null | sed -n '/^[[:space:]]/ { s/^[[:space:]]*//; s/ (compatibility.*$//; p; }' | while IFS= read -r DEPENDENCY; do
    [ -n "$DEPENDENCY" ] || continue
    if grep -Fxq "$DEPENDENCY" "$TMP_SELF_IDS"; then
      continue
    fi

    case "$DEPENDENCY" in
      /opt/homebrew/*|/usr/local/*)
        printf '%s\n' "machine-local dependency $DEPENDENCY referenced by $FILE_PATH" >> "$TMP_FAILURES"
        ;;
      /*)
        if ! is_allowed_prefix_path "$DEPENDENCY"; then
          printf '%s\n' "unexpected absolute dependency $DEPENDENCY referenced by $FILE_PATH" >> "$TMP_FAILURES"
        fi
        ;;
    esac
  done
done

if [ -s "$TMP_FAILURES" ]; then
  echo "error: bundled runtime compatibility check failed:" >&2
  sed 's/^/  - /' "$TMP_FAILURES" >&2
  exit 1
fi

echo "Bundled runtime compatibility check passed for $ROOT_PATH."
