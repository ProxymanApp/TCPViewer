#!/bin/sh

set -eu

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  echo "error: TARGET_BUILD_DIR and UNLOCALIZED_RESOURCES_FOLDER_PATH are required to stage open source notices." >&2
  exit 1
fi

DESTINATION_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/OpenSourceLicenses"
STAMP_FILE="${SCRIPT_OUTPUT_FILE_0:-${TARGET_TEMP_DIR:-/tmp}/open-source-notices-staged.stamp}"

copy_notice() {
  SOURCE_PATH="$1"
  DESTINATION_NAME="$2"

  if [ ! -f "$SOURCE_PATH" ]; then
    echo "error: required open source notice is missing: $SOURCE_PATH" >&2
    exit 1
  fi

  cp -f "$SOURCE_PATH" "$DESTINATION_DIR/$DESTINATION_NAME"
}

write_runtime_manifest() {
  MANIFEST_PATH="$DESTINATION_DIR/RUNTIME_LIBRARIES.txt"
  FRAMEWORKS_DIR="$TARGET_BUILD_DIR/${FRAMEWORKS_FOLDER_PATH:-Contents/Frameworks}"

  {
    echo "Runtime frameworks and libraries included in this TCP Viewer app bundle"
    echo "Generated during the Xcode build by scripts/stage-open-source-notices.sh."
    echo

    # Keep a reviewable runtime list so release notices can stay complete.
    if [ -d "$FRAMEWORKS_DIR" ]; then
      {
        find "$FRAMEWORKS_DIR" -type d -name "*.framework" -print
        find "$FRAMEWORKS_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) -print
      } | sed "s|$TARGET_BUILD_DIR/||" | sort
    else
      echo "No Frameworks directory was present when this manifest was generated."
    fi
  } > "$MANIFEST_PATH"
}

rm -rf "$DESTINATION_DIR"
mkdir -p "$DESTINATION_DIR"

copy_notice "$PROJECT_DIR/LICENSE" "TCPViewer-LICENSE.txt"
copy_notice "$PROJECT_DIR/COPYING" "GPL-2.0.txt"
copy_notice "$PROJECT_DIR/SOURCE_CODE_OFFER.md" "SOURCE_CODE_OFFER.md"
copy_notice "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "THIRD_PARTY_NOTICES.md"
copy_notice "$PROJECT_DIR/Vendor/Wireshark/COPYING" "Wireshark-COPYING.txt"
copy_notice "$PROJECT_DIR/Vendor/Wireshark/README.md" "Wireshark-README.md"
copy_notice "$PROJECT_DIR/Vendor/HexFiend/License.txt" "HexFiend-LICENSE.txt"
write_runtime_manifest

mkdir -p "$(dirname "$STAMP_FILE")"
touch "$STAMP_FILE"
