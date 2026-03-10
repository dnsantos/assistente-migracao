#!/bin/bash

###############################################################################
# remover_intune.sh
# Removes the Mac from Microsoft Intune management via Graph API
#
# Version: 1.2
#
# Exit Codes:
#   0 - Success
#   1 - Credential or configuration error
#   2 - Device not found in Intune
#   3 - Retire command failed
#   4 - Timeout waiting for MDM profile removal
###############################################################################

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME" # <── change this
readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
# ──────────────────────────────────────────────────────────────────────────────

readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migration.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly CONFIG_FILE="${BASE_DIR}/resources/config/migration_config.json"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly PROFILES_CMD="/usr/bin/profiles"

# Keychain entry — must match what was provisioned before deployment
readonly KEYCHAIN_SERVICE="MDMMigrationService" # <── change this
readonly KEYCHAIN_ACCOUNT="IntuneAuth"          # <── change this

readonly MACHINE_SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
JQ_BIN=""

if [[ ! -d "${LOGS_DIR}" ]]; then
    mkdir -p "${LOGS_DIR}"
fi

log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

update_dialog() {
    local statustext="$1"
    if [[ -f "${DIALOG_LOG}" ]]; then
        echo "listitem: index: 2, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
}

###############################################################################
# FUNCTION: Detect jq binary
###############################################################################
detect_jq_binary() {
    local arch=$(uname -m)
    log_message "Detecting system architecture..."

    if [[ "$arch" == "arm64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-arm64"
        log_message "✓ Architecture: Apple Silicon (arm64)"
    elif [[ "$arch" == "x86_64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-amd64"
        log_message "✓ Architecture: Intel (x86_64)"
    else
        log_message "✗ Unsupported architecture: ${arch}"
        return 1
    fi

    if [[ ! -f "${JQ_BIN}" ]]; then
        log_message "✗ jq binary not found: ${JQ_BIN}"
        return 1
    fi

    chmod +x "${JQ_BIN}" 2>/dev/null || true
    log_message "✓ jq binary: ${JQ_BIN}"
    return 0
}

###############################################################################
# INITIALIZATION
###############################################################################
log_message "========================================="
log_message "REMOVING INTUNE ENROLLMENT"
log_message "Mac serial: ${MACHINE_SERIAL}"
log_message "========================================="

if [[ $EUID -ne 0 ]]; then
    log_message "✗ This script must be run as root"
    exit 1
fi

if ! detect_jq_binary; then
    log_message "✗ Failed to configure jq binary"
    update_dialog "✗ Configuration error (jq not found)"
    exit 1
fi

###############################################################################
# FUNCTION: Load Intune credentials from config file
###############################################################################
load_intune_credentials() {
    log_message "Loading Intune credentials..."
    update_dialog "🔑 Loading credentials..."

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_message "✗ Config file not found: ${CONFIG_FILE}"
        update_dialog "✗ Config file not found"
        return 1
    fi

    if ! "${JQ_BIN}" . "${CONFIG_FILE}" >/dev/null 2>&1; then
        log_message "✗ Invalid JSON in config file"
        update_dialog "✗ Invalid JSON format"
        return 1
    fi

    INTUNE_TENANT_ID=$("${JQ_BIN}" -r '.intune.tenant_id // empty' "${CONFIG_FILE}" 2>/dev/null)
    INTUNE_CLIENT_ID=$("${JQ_BIN}" -r '.intune.client_id // empty' "${CONFIG_FILE}" 2>/dev/null)
    INTUNE_CLIENT_SECRET=$(/usr/bin/security find-generic-password \
        -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w \
        /Library/Keychains/System.keychain 2>/dev/null)

    if [[ -z "${INTUNE_TENANT_ID}" ]] || [[ -z "${INTUNE_CLIENT_ID}" ]] || [[ -z "${INTUNE_CLIENT_SECRET}" ]]; then
        log_message "✗ Intune credentials not fully configured"
        log_message "   Tenant ID: ${INTUNE_TENANT_ID:+(set)}"
        log_message "   Client ID: ${INTUNE_CLIENT_ID:+(set)}"
        log_message "   Secret:    ${INTUNE_CLIENT_SECRET:+(set in keychain)}"
        update_dialog "✗ Credentials not configured"
        return 1
    fi

    log_message "✓ Credentials loaded"
    log_message "   Tenant ID: ${INTUNE_TENANT_ID}"
    log_message "   Client ID: ${INTUNE_CLIENT_ID}"
    return 0
}

###############################################################################
# FUNCTION: Get Microsoft Graph access token
###############################################################################
get_graph_token() {
    log_message "Obtaining Microsoft Graph access token..."
    update_dialog "🔐 Authenticating with Microsoft Graph..."

    token=$(curl --silent --location --request POST \
        "https://login.microsoftonline.com/${INTUNE_TENANT_ID}/oauth2/v2.0/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${INTUNE_CLIENT_ID}" \
        --data-urlencode "scope=https://graph.microsoft.com/.default" \
        --data-urlencode "client_secret=${INTUNE_CLIENT_SECRET}" \
        --data-urlencode "grant_type=client_credentials" |
        "${JQ_BIN}" -r '.access_token // empty')

    if [[ -z "$token" ]]; then
        log_message "✗ Failed to obtain access token"
        update_dialog "✗ Authentication failed"
        return 1
    fi

    log_message "✓ Access token obtained"
    return 0
}

###############################################################################
# FUNCTION: Find device in Intune by serial number
###############################################################################
find_device_in_intune() {
    log_message "Searching for device in Intune..."
    log_message "   Serial number: ${MACHINE_SERIAL}"
    update_dialog "🔍 Searching for ${MACHINE_SERIAL} in Intune..."

    local response
    response=$(curl --silent \
        "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?\$filter=serialNumber%20eq%20%27${MACHINE_SERIAL}%27" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json")

    if [[ -z "$response" ]]; then
        log_message "✗ Error querying Intune API"
        update_dialog "✗ Intune API error"
        return 1
    fi

    device_id=$(echo "$response" | "${JQ_BIN}" -r '.value[0].id // empty')
    local serial_found
    serial_found=$(echo "$response" | "${JQ_BIN}" -r '.value[0].serialNumber // empty')

    if [[ -n "$device_id" ]] && [[ -n "$serial_found" ]]; then
        log_message "✓ Device found in Intune"
        log_message "   Serial: ${serial_found}"
        log_message "   Device ID: ${device_id}"
        update_dialog "✓ Device found (${serial_found})"
        return 0
    else
        log_message "✗ Device not found in Intune"
        log_message "   Serial searched: ${MACHINE_SERIAL}"
        update_dialog "✗ Device not found in Intune"
        return 1
    fi
}

###############################################################################
# FUNCTION: Retire device via Graph API
###############################################################################
retire_device() {
    log_message "Retiring device..."
    log_message "   Device ID: ${device_id}"
    update_dialog "🔄 Retiring device..."

    local response
    response=$(curl --silent --write-out "\n%{http_code}" \
        -X POST "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/${device_id}/retire" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data-raw '')

    local http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "204" ]]; then
        log_message "✓ Retire command sent successfully (HTTP ${http_code})"
        update_dialog "✓ Retire command sent"
        return 0
    else
        log_message "✗ Retire command failed (HTTP ${http_code})"
        log_message "   Response: $(echo "$response" | head -n -1)"
        update_dialog "✗ Retire command failed"
        return 1
    fi
}

###############################################################################
# FUNCTION: Monitor MDM profile removal (infinite loop)
###############################################################################
monitor_mdm_removal() {
    local interval=30
    local counter=1
    local elapsed_minutes=0

    log_message "Monitoring MDM profile removal..."
    log_message "   Check interval: ${interval}s"
    log_message "   Mode: waiting until removal is confirmed"

    while true; do
        elapsed_minutes=$(((counter * interval) / 60))

        if [[ $elapsed_minutes -eq 0 ]]; then
            update_dialog "⏳ Waiting for MDM removal..."
        else
            update_dialog "⏳ Waiting for MDM removal... (${elapsed_minutes} min)"
        fi

        log_message "Check #${counter} (${elapsed_minutes}m elapsed): verifying MDM profile..."

        local mdm_enrollment
        mdm_enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null | grep "MDM enrollment" || true)

        if [[ "$mdm_enrollment" != *"Yes"* ]]; then
            log_message "✓ MDM profile removed after ~${elapsed_minutes} minutes"
            update_dialog "✅ MDM profile removed"
            return 0
        else
            log_message "   MDM still active — waiting ${interval}s..."
        fi

        sleep $interval
        ((counter++))
    done
}

###############################################################################
# FUNCTION: Clean up residual Intune components
###############################################################################
cleanup_intune_components() {
    log_message "Cleaning up residual Intune components..."
    update_dialog "🧹 Cleaning Intune components..."

    local cleaned=0

    if [[ -f "/Library/Preferences/com.microsoft.CompanyPortal.plist" ]]; then
        rm -f "/Library/Preferences/com.microsoft.CompanyPortal.plist" 2>/dev/null && ((cleaned++))
        log_message "✓ Removed Company Portal preferences"
    fi

    if [[ -d "/Library/Application Support/Microsoft/Intune" ]]; then
        rm -rf "/Library/Application Support/Microsoft/Intune" 2>/dev/null && ((cleaned++))
        log_message "✓ Removed Intune cache"
    fi

    for daemon in /Library/LaunchDaemons/com.microsoft.intune.* /Library/LaunchAgents/com.microsoft.intune.*; do
        if [[ -f "${daemon}" ]]; then
            launchctl unload "${daemon}" 2>/dev/null
            rm -f "${daemon}" 2>/dev/null && ((cleaned++))
            log_message "✓ Removed: $(basename ${daemon})"
        fi
    done

    if [[ $cleaned -gt 0 ]]; then
        log_message "✓ Cleanup complete (${cleaned} item(s) removed)"
    else
        log_message "✓ No additional components found"
    fi
}

###############################################################################
# FUNCTION: Update state file
###############################################################################
update_migration_state() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_message "⚠ State file not found — skipping update"
        return 0
    fi

    log_message "Updating state file..."
    local temp_file="${STATE_FILE}.tmp"

    "${JQ_BIN}" \
        '.mdm_type = "none" | .migration_status = "intune_removed"' \
        "${STATE_FILE}" >"${temp_file}" 2>/dev/null

    if [[ -f "${temp_file}" ]]; then
        mv "${temp_file}" "${STATE_FILE}"
        log_message "✓ State file updated"
    else
        log_message "⚠ Failed to update state file"
    fi
}

###############################################################################
# MAIN
###############################################################################
load_intune_credentials || exit 1
get_graph_token || exit 1
find_device_in_intune || exit 2
retire_device || exit 3
monitor_mdm_removal || exit 4
cleanup_intune_components
update_migration_state

update_dialog "✅ Intune removed successfully"
log_message "========================================="
log_message "✓ INTUNE REMOVED SUCCESSFULLY"
log_message "Elapsed time: ~$((SECONDS / 60)) minute(s)"
log_message "========================================="

exit 0
