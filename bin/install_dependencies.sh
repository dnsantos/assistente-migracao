#!/bin/bash
set -euo pipefail

###############################################################################
# install_dependencies.sh
# Installs swiftDialog from the latest GitHub release
#
# Version: 1.2
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

require_root

# Minimum swiftDialog version required
readonly MIN_DIALOG_VERSION="2.3.0"
readonly EXPECTED_TEAM_ID="PWA5E9TQ59"

log_message "========================================="
log_message "INSTALLING DEPENDENCIES"
log_message "========================================="

detect_jq || true

###############################################################################
# FUNCTION: Compare semantic versions  (returns 0 if $1 >= $2)
###############################################################################
version_gte() {
    printf '%s\n%s' "$2" "$1" | sort -C -V
}

###############################################################################
# FUNCTION: Install swiftDialog
###############################################################################
install_dialog() {
    # Check if already installed and meets minimum version
    if [[ -f "${DIALOG_BIN}" ]]; then
        local current_version
        current_version=$("${DIALOG_BIN}" --version 2>/dev/null | tr -d '[:space:]' || echo "0.0.0")
        log_message "   swiftDialog found: v${current_version}"

        if version_gte "${current_version}" "${MIN_DIALOG_VERSION}"; then
            log_message "✓ swiftDialog v${current_version} meets minimum requirement (>= ${MIN_DIALOG_VERSION})"
            return 0
        else
            log_message "⚠ swiftDialog v${current_version} is below minimum v${MIN_DIALOG_VERSION} — upgrading"
        fi
    else
        log_message "   swiftDialog not found — installing"
    fi

    log_message "Querying GitHub API for latest release..."
    local api_response
    api_response=$(curl --silent --fail \
        --max-time 30 \
        "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest")

    local dialog_url
    if [[ -n "${JQ_BIN:-}" ]] && [[ -f "${JQ_BIN}" ]]; then
        dialog_url=$(echo "${api_response}" | \
            "${JQ_BIN}" -r '.assets[] | select(.name | endswith(".pkg")) | .browser_download_url' | head -1)
        local latest_version
        latest_version=$(echo "${api_response}" | "${JQ_BIN}" -r '.tag_name // "unknown"' | tr -d 'v')
        log_message "   Latest version: ${latest_version}"
    else
        dialog_url=$(echo "${api_response}" | \
            awk -F '"' '/browser_download_url/ && /pkg"/ { print $4; exit }')
    fi

    if [[ -z "${dialog_url}" ]]; then
        log_message "✗ Failed to extract download URL from GitHub API"
        return 1
    fi

    log_message "   Download URL: ${dialog_url}"
    log_message "Downloading swiftDialog..."

    local temp_dir
    temp_dir=$(mktemp -d "/private/tmp/install_dialog.XXXXXX")
    local pkg_path="${temp_dir}/Dialog.pkg"

    if ! curl --location --silent --fail --max-time 120 "${dialog_url}" -o "${pkg_path}"; then
        log_message "✗ Download failed"
        rm -rf "${temp_dir}"
        return 1
    fi

    log_message "✓ Download complete — verifying signature..."
    local team_id
    team_id=$(spctl -a -vv -t install "${pkg_path}" 2>&1 | awk '/origin=/ {print $NF}' | tr -d '()')
    log_message "   Team ID found: ${team_id}"

    if [[ "${team_id}" != "${EXPECTED_TEAM_ID}" ]]; then
        log_message "✗ Signature verification failed"
        log_message "   Expected: ${EXPECTED_TEAM_ID}"
        log_message "   Found:    ${team_id}"
        rm -rf "${temp_dir}"
        return 1
    fi

    log_message "✓ Signature verified — installing..."
    if ! installer -pkg "${pkg_path}" -target / >> "${MAIN_LOG}" 2>&1; then
        log_message "✗ Installation failed"
        rm -rf "${temp_dir}"
        return 1
    fi

    rm -rf "${temp_dir}"

    if [[ ! -f "${DIALOG_BIN}" ]]; then
        log_message "✗ Post-install verification failed — binary not found"
        return 1
    fi

    local installed_version
    installed_version=$("${DIALOG_BIN}" --version 2>/dev/null | tr -d '[:space:]' || echo "unknown")
    log_message "✓ swiftDialog v${installed_version} installed successfully"
    return 0
}

###############################################################################
# MAIN
###############################################################################
install_dialog || { log_message "✗ Failed to install swiftDialog"; exit 1; }

log_message "========================================="
log_message "✓ DEPENDENCIES INSTALLED SUCCESSFULLY"
log_message "========================================="
exit 0
