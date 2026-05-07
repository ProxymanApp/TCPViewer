#!/bin/bash

# Generates Info.plist files with SMJobBless requirements that match the active signing mode.
set -euo pipefail

app_bundle_identifier="com.proxyman.tcpviewer"
helper_bundle_identifier="com.proxyman.tcpviewer.helpertool"

oid_apple_developer_id_ca="1.2.840.113635.100.6.2.6"
oid_apple_developer_id_application="1.2.840.113635.100.6.1.13"
oid_apple_mac_app_store_application="1.2.840.113635.100.6.1.9"
oid_apple_wwdr_intermediate="1.2.840.113635.100.6.2.1"

resolve_path() {
    local path="$1"

    if [[ "${path}" == /* ]]; then
        printf "%s" "${path}"
    else
        printf "%s/%s" "${PROJECT_DIR}" "${path}"
    fi
}

escape_plistbuddy_string() {
    /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' <<< "$1"
}

validate_development_team() {
    local development_team="${DEVELOPMENT_TEAM:-}"

    if ! [[ "${development_team}" =~ ^[A-Z0-9]{10}$ ]]; then
        printf "%s\n" "error: Invalid DEVELOPMENT_TEAM for SMJobBless requirements: ${development_team}"
        exit 1
    fi
}

validate_development_identity() {
    local identity_name="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}"

    if ! [[ "${identity_name}" =~ ^Apple\ Development:\ .*\ \([A-Z0-9]{10}\)$ ]]; then
        printf "%s\n" "error: Invalid Apple Development signing identity for SMJobBless requirements: ${identity_name}"
        exit 1
    fi
}

development_requirement() {
    local bundle_identifier="$1"
    local identity_name="${EXPANDED_CODE_SIGN_IDENTITY_NAME}"

    printf 'identifier "%s" and anchor apple generic and certificate leaf[subject.CN] = "%s" and certificate 1[field.%s] /* exists */' \
        "${bundle_identifier}" \
        "${identity_name}" \
        "${oid_apple_wwdr_intermediate}"
}

production_requirement() {
    local bundle_identifier="$1"
    local development_team="${DEVELOPMENT_TEAM}"

    printf 'identifier "%s" and anchor apple generic and ((certificate leaf[field.%s] /* exists */) or (certificate 1[field.%s] /* exists */ and certificate leaf[field.%s] /* exists */)) and certificate leaf[subject.OU] = "%s"' \
        "${bundle_identifier}" \
        "${oid_apple_mac_app_store_application}" \
        "${oid_apple_developer_id_ca}" \
        "${oid_apple_developer_id_application}" \
        "${development_team}"
}

update_smprivileged_executables() {
    local info_plist="$1"
    local requirement="$2"
    local escaped_requirement

    escaped_requirement="$(escape_plistbuddy_string "${requirement}")"

    /usr/libexec/PlistBuddy -c "Delete :SMPrivilegedExecutables" "${info_plist}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :SMPrivilegedExecutables dict" "${info_plist}"
    /usr/libexec/PlistBuddy -c "Add :SMPrivilegedExecutables:${helper_bundle_identifier} string ${escaped_requirement}" "${info_plist}"
}

update_smauthorized_clients() {
    local info_plist="$1"
    local requirement="$2"
    local escaped_requirement

    escaped_requirement="$(escape_plistbuddy_string "${requirement}")"

    /usr/libexec/PlistBuddy -c "Delete :SMAuthorizedClients" "${info_plist}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :SMAuthorizedClients array" "${info_plist}"
    /usr/libexec/PlistBuddy -c "Add :SMAuthorizedClients: string ${escaped_requirement}" "${info_plist}"
}

template_info_plist="$(resolve_path "${TCPVIEWER_INFOPLIST_TEMPLATE_FILE:-${INFOPLIST_FILE}}")"
generated_info_plist="$(resolve_path "${INFOPLIST_FILE}")"

/bin/mkdir -p "$(/usr/bin/dirname "${generated_info_plist}")"

if [[ "${template_info_plist}" != "${generated_info_plist}" ]]; then
    /bin/cp "${template_info_plist}" "${generated_info_plist}"
fi

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
    printf "%s\n" "Skipping SMJobBless requirement update because code signing is disabled."
    exit 0
fi

# Development builds should trust the exact local certificate, while archives should trust release certificate classes.
case "${ACTION:-build}" in
    build)
        validate_development_identity
        app_requirement="$(development_requirement "${app_bundle_identifier}")"
        helper_requirement="$(development_requirement "${helper_bundle_identifier}")"
        ;;
    install)
        validate_development_team
        app_requirement="$(production_requirement "${app_bundle_identifier}")"
        helper_requirement="$(production_requirement "${helper_bundle_identifier}")"
        ;;
    *)
        printf "%s\n" "error: Unsupported Xcode ACTION for SMJobBless requirements: ${ACTION:-}"
        exit 1
        ;;
esac

case "${PRODUCT_BUNDLE_IDENTIFIER}" in
    "${app_bundle_identifier}")
        update_smprivileged_executables "${generated_info_plist}" "${helper_requirement}"
        ;;
    "${helper_bundle_identifier}")
        update_smauthorized_clients "${generated_info_plist}" "${app_requirement}"
        ;;
    *)
        printf "%s\n" "error: Unsupported PRODUCT_BUNDLE_IDENTIFIER for SMJobBless requirements: ${PRODUCT_BUNDLE_IDENTIFIER}"
        exit 1
        ;;
esac

printf "%s\n" "Updated SMJobBless requirements for ${PRODUCT_BUNDLE_IDENTIFIER}"
