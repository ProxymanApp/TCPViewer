#!/bin/sh

set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_LIB_DIR="$PROJECT_DIR/Vendor/.install/wireshark/lib"

if [ ! -d "$SOURCE_LIB_DIR" ]; then
  echo "error: Wireshark libraries are missing at $SOURCE_LIB_DIR. Run scripts/bootstrap-wireshark.sh." >&2
  exit 1
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${FRAMEWORKS_FOLDER_PATH:-}" ] || [ -z "${EXECUTABLE_PATH:-}" ]; then
  echo "error: TARGET_BUILD_DIR, FRAMEWORKS_FOLDER_PATH, and EXECUTABLE_PATH are required to stage Wireshark runtime libraries." >&2
  exit 1
fi

DESTINATION_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
CONSUMER_BINARY="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
STAMP_FILE="${SCRIPT_OUTPUT_FILE_0:-${TARGET_TEMP_DIR:-/tmp}/wireshark-runtime-staged.stamp}"
WORK_DIR="${TARGET_TEMP_DIR:-/tmp}/tcpviewer-wireshark-runtime"
QUEUE_FILE="$WORK_DIR/queue.txt"
COPIED_NAMES_FILE="$WORK_DIR/copied-names.txt"
COPIED_PATHS_FILE="$WORK_DIR/copied-paths.txt"

mkdir -p "$DESTINATION_DIR"
rm -f "$DESTINATION_DIR/.wireshark-runtime-staged"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
: > "$QUEUE_FILE"
: > "$COPIED_NAMES_FILE"
: > "$COPIED_PATHS_FILE"

is_system_dependency() {
  case "$1" in
    /usr/lib/*|/System/Library/*)
      return 0
      ;;
  esac

  return 1
}

resolve_rpath_library() {
  LIBRARY_NAME="$1"

  for LIBRARY_DIR in "$SOURCE_LIB_DIR" /opt/homebrew/lib /opt/homebrew/opt/*/lib /usr/local/lib /usr/local/opt/*/lib; do
    if [ -f "$LIBRARY_DIR/$LIBRARY_NAME" ]; then
      printf '%s\n' "$LIBRARY_DIR/$LIBRARY_NAME"
      return
    fi
  done

  return 0
}

resolve_relative_library() {
  BASE_DIR="$1"
  LIBRARY_PATH_SUFFIX="$2"
  CANDIDATE="$BASE_DIR/$LIBRARY_PATH_SUFFIX"

  if [ -f "$CANDIDATE" ]; then
    printf '%s\n' "$CANDIDATE"
    return
  fi

  return 0
}

queue_library() {
  LIBRARY_PATH="$1"
  LIBRARY_NAME="$(basename "$LIBRARY_PATH")"

  if [ ! -f "$LIBRARY_PATH" ]; then
    echo "error: required Wireshark dependency is missing: $LIBRARY_PATH" >&2
    exit 1
  fi

  if grep -Fxq "$LIBRARY_NAME" "$COPIED_NAMES_FILE" || grep -Fxq "$LIBRARY_PATH" "$QUEUE_FILE"; then
    return
  fi

  printf '%s\n' "$LIBRARY_PATH" >> "$QUEUE_FILE"
}

queue_dependency() {
  DEPENDENCY="$1"
  ORIGIN_PATH="$2"

  if is_system_dependency "$DEPENDENCY"; then
    return
  fi

  case "$DEPENDENCY" in
    @rpath/*)
      DEPENDENCY_NAME="$(basename "$DEPENDENCY")"
      RESOLVED_DEPENDENCY="$(resolve_rpath_library "$DEPENDENCY_NAME")"
      if [ -n "$RESOLVED_DEPENDENCY" ]; then
        queue_library "$RESOLVED_DEPENDENCY"
      elif [ ! -f "$DESTINATION_DIR/$DEPENDENCY_NAME" ]; then
        echo "error: unable to resolve Wireshark @rpath dependency: $DEPENDENCY" >&2
        exit 1
      fi
      ;;
    @loader_path/*)
      DEPENDENCY_SUFFIX="${DEPENDENCY#@loader_path/}"
      RESOLVED_DEPENDENCY="$(resolve_relative_library "$(dirname "$ORIGIN_PATH")" "$DEPENDENCY_SUFFIX")"
      if [ -n "$RESOLVED_DEPENDENCY" ]; then
        queue_library "$RESOLVED_DEPENDENCY"
      elif [ ! -f "$DESTINATION_DIR/$(basename "$DEPENDENCY")" ]; then
        echo "error: unable to resolve Wireshark @loader_path dependency: $DEPENDENCY" >&2
        exit 1
      fi
      ;;
    @executable_path/*)
      DEPENDENCY_SUFFIX="${DEPENDENCY#@executable_path/}"
      RESOLVED_DEPENDENCY="$(resolve_relative_library "$(dirname "$CONSUMER_BINARY")" "$DEPENDENCY_SUFFIX")"
      if [ -n "$RESOLVED_DEPENDENCY" ]; then
        queue_library "$RESOLVED_DEPENDENCY"
      else
        DEPENDENCY_NAME="$(basename "$DEPENDENCY")"
        RESOLVED_DEPENDENCY="$(resolve_rpath_library "$DEPENDENCY_NAME")"
        if [ -n "$RESOLVED_DEPENDENCY" ]; then
          queue_library "$RESOLVED_DEPENDENCY"
        elif [ ! -f "$DESTINATION_DIR/$DEPENDENCY_NAME" ]; then
          echo "error: unable to resolve Wireshark @executable_path dependency: $DEPENDENCY" >&2
          exit 1
        fi
      fi
      ;;
    /*)
      queue_library "$DEPENDENCY"
      ;;
  esac
}

copy_next_library() {
  LIBRARY_PATH="$(sed -n '1p' "$QUEUE_FILE")"
  sed '1d' "$QUEUE_FILE" > "$QUEUE_FILE.next"
  mv "$QUEUE_FILE.next" "$QUEUE_FILE"

  LIBRARY_NAME="$(basename "$LIBRARY_PATH")"
  DESTINATION_PATH="$DESTINATION_DIR/$LIBRARY_NAME"

  if grep -Fxq "$LIBRARY_NAME" "$COPIED_NAMES_FILE"; then
    return
  fi

  rm -f "$DESTINATION_PATH"
  cp -f "$LIBRARY_PATH" "$DESTINATION_PATH"
  chmod u+w "$DESTINATION_PATH"

  printf '%s\n' "$LIBRARY_NAME" >> "$COPIED_NAMES_FILE"
  printf '%s\n' "$DESTINATION_PATH" >> "$COPIED_PATHS_FILE"

  otool -L "$DESTINATION_PATH" | awk 'NR > 2 { print $1 }' > "$WORK_DIR/dependencies.txt"
  while IFS= read -r DEPENDENCY; do
    [ -n "$DEPENDENCY" ] || continue
    queue_dependency "$DEPENDENCY" "$LIBRARY_PATH"
  done < "$WORK_DIR/dependencies.txt"
}

patch_library() {
  LIBRARY_PATH="$1"
  LIBRARY_NAME="$(basename "$LIBRARY_PATH")"

  install_name_tool -id "@rpath/$LIBRARY_NAME" "$LIBRARY_PATH"
  install_name_tool -add_rpath "@loader_path" "$LIBRARY_PATH" 2>/dev/null || true

  otool -L "$LIBRARY_PATH" | awk 'NR > 2 { print $1 }' > "$WORK_DIR/patch-dependencies.txt"
  while IFS= read -r DEPENDENCY; do
    [ -n "$DEPENDENCY" ] || continue

    if is_system_dependency "$DEPENDENCY"; then
      continue
    fi

    DEPENDENCY_NAME="$(basename "$DEPENDENCY")"
    if grep -Fxq "$DEPENDENCY_NAME" "$COPIED_NAMES_FILE"; then
      install_name_tool -change "$DEPENDENCY" "@rpath/$DEPENDENCY_NAME" "$LIBRARY_PATH"
    fi
  done < "$WORK_DIR/patch-dependencies.txt"
}

patch_consumer_binary() {
  BINARY_PATH="$1"

  install_name_tool -add_rpath "@loader_path/Frameworks" "$BINARY_PATH" 2>/dev/null || true

  otool -L "$BINARY_PATH" | awk 'NR > 2 { print $1 }' > "$WORK_DIR/patch-consumer-dependencies.txt"
  while IFS= read -r DEPENDENCY; do
    [ -n "$DEPENDENCY" ] || continue

    if is_system_dependency "$DEPENDENCY"; then
      continue
    fi

    DEPENDENCY_NAME="$(basename "$DEPENDENCY")"
    if grep -Fxq "$DEPENDENCY_NAME" "$COPIED_NAMES_FILE"; then
      install_name_tool -change "$DEPENDENCY" "@rpath/$DEPENDENCY_NAME" "$BINARY_PATH"
    fi
  done < "$WORK_DIR/patch-consumer-dependencies.txt"
}

sign_code() {
  CODE_PATH="$1"
  SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

  if [ -z "$SIGN_IDENTITY" ]; then
    return
  fi

  TIMESTAMP_FLAG=""
  if [ "${CONFIGURATION:-}" = "Debug" ]; then
    TIMESTAMP_FLAG="--timestamp=none"
  fi

  codesign --force --sign "$SIGN_IDENTITY" $TIMESTAMP_FLAG "$CODE_PATH"
}

queue_library "$SOURCE_LIB_DIR/libwireshark.19.dylib"
queue_library "$SOURCE_LIB_DIR/libwiretap.16.dylib"
queue_library "$SOURCE_LIB_DIR/libwsutil.17.dylib"

while [ -s "$QUEUE_FILE" ]; do
  copy_next_library
done

while IFS= read -r COPIED_LIBRARY; do
  [ -n "$COPIED_LIBRARY" ] || continue
  patch_library "$COPIED_LIBRARY"
done < "$COPIED_PATHS_FILE"

if [ ! -f "$CONSUMER_BINARY" ]; then
  echo "error: built binary is missing at $CONSUMER_BINARY." >&2
  exit 1
fi

patch_consumer_binary "$CONSUMER_BINARY"

while IFS= read -r COPIED_LIBRARY; do
  [ -n "$COPIED_LIBRARY" ] || continue
  sign_code "$COPIED_LIBRARY"
done < "$COPIED_PATHS_FILE"

mkdir -p "$(dirname "$STAMP_FILE")"
touch "$STAMP_FILE"
