#!/bin/sh

# Validates local-only Xcode build settings that are intentionally not committed.
is_blank() {
    [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

missing=0
team_id="${TCPVIEWER_DEVELOPMENT_TEAM:-}"
build_key="${TCPVIEWER_BUILD_KEY:-}"
development_team="${DEVELOPMENT_TEAM:-}"

if is_blank "${team_id}"; then
    echo "error: Missing TCPVIEWER_DEVELOPMENT_TEAM. Copy Config/TCPViewer.local.xcconfig.example to Config/TCPViewer.local.xcconfig and set your Apple Development Team ID."
    missing=1
elif ! printf '%s' "${team_id}" | /usr/bin/grep -Eq '^[A-Z0-9]{10}$'; then
    echo "error: TCPVIEWER_DEVELOPMENT_TEAM must be a 10-character Apple Team ID, for example ABCDE12345."
    missing=1
fi

if is_blank "${build_key}"; then
    echo "error: Missing TCPVIEWER_BUILD_KEY. Copy Config/TCPViewer.local.xcconfig.example to Config/TCPViewer.local.xcconfig and set a private build key."
    missing=1
fi

if [ "${missing}" -eq 0 ] && [ "${development_team}" != "${team_id}" ]; then
    echo "error: DEVELOPMENT_TEAM must resolve from TCPVIEWER_DEVELOPMENT_TEAM for Xcode signing."
    missing=1
fi

exit "${missing}"
