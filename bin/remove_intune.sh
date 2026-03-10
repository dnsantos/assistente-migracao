#!/bin/bash
set -euo pipefail

###############################################################################
# remove_intune.sh
# Removes the Mac from Microsoft Intune management via Graph API
#
# Version: 1.3
#
# Exit Codes:
#   0 - Success
#   1 - Credential or configuration error
#   2 - Device not found in Intune
#   3 - Retire command failed
#   4 - Timeout waiting for MDM profile removal
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

require_root
detect_jq || { log_message "✗ jq binary not found"; exit 1; }

# Maximum time (seconds) to wait for MDM profile removal
readonly MDM_REMOVAL_TIMEOUT=600   # 10 minutes
readonly MDM_REMOVAL_INTERVAL=30

readonly MACHINE_SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

# Graph API token — refreshed automatically if expired
GRAPH_TOKEN=""
TOKEN_OBTAINED_AT=0
readonly TOKEN_TTL=3500  # refresh 100s before the 3600s expiry

log_message "========================================="
log_message "REMOVING INTUNE ENROLLMENT"
log_message "Mac serial: ${MACHINE_SERIAL}"
log_message "========================================="

###############################################################################
# FUNCTION: Load credentials from config + keychain
###############################################################################
load_credentials() {
    log_message "Loading Intune credentials..."
    send_dialog "listitem: index: 2, statustext: 🔑 Loading credentials..."

    [[ ! -f "${CONFIG_FILE}" ]] && { log_message "✗ Config file not found: ${CONFIG_FILE}"; return 1; }
    "${JQ_BIN}" . "${CONFIG_FILE}" >/dev/null 2>&1 || { log_message "✗ Invalid JSON in config file"; return 1; }

    INTUNE_TENANT_ID=$("${JQ_BIN}" -r '.intune.tenant_id // empty' "${CONFIG_FILE}")
    INTUNE_CLIENT_ID=$("${JQ_BIN}" -r '.intune.client_id // empty' "${CONFIG_FILE}")
    INTUNE_CLIENT_SECRET=$(/usr/bin/security find-generic-password \
        -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w \
        /Library/Keychains/System.keychain 2>/dev/null || true)

    if [[ -z "${INTUNE_TENANT_ID}" ]] || [[ -z "${INTUNE_CLIENT_ID}" ]] || [[ -z "${INTUNE_CLIENT_SECRET}" ]]; then
        log_message "✗ Intune credentials not fully configured"
        log_message "   Tenant ID : ${INTUNE_TENANT_ID:+(set)}"
        log_message "   Client ID : ${INTUNE_CLIENT_ID:+(set)}"
        log_message "   Secret    : ${INTUNE_CLIENT_SECRET:+(set in keychain)}"
        return 1
    fi

    log_message "✓ Credentials loaded"
    return 0
}

###############################################################################
# FUNCTION: Obtain (or refresh) a Graph API token
###############################################################################
get_graph_token() {
    local now
    now=$(date +%s)
    local age=$(( now - TOKEN_OBTAINED_AT ))

    if [[ -n "${GRAPH_TOKEN}" ]] && [[ $age -lt $TOKEN_TTL ]]; then
        return 0  # token still valid
    fi

    log_message "Obtaining Microsoft Graph access token..."
    send_dialog "listitem: index: 2, statustext: 🔐 Authenticating..."

    GRAPH_TOKEN=$(curl --silent --fail --max-time 30 \
        -X POST "https://login.microsoftonline.com/${INTUNE_TENANT_ID}/oauth2/v2.0/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${INTUNE_CLIENT_ID}" \
        --data-urlencode "scope=https://graph.microsoft.com/.default" \
        --data-urlencode "client_secret=${INTUNE_CLIENT_SECRET}" \
        --data-urlencode "grant_type=client_credentials" \
        | "${JQ_BIN}" -r '.access_token // empty')

    if [[ -z "${GRAPH_TOKEN}" ]]; then
        log_message "✗ Failed to obtain access token"
        return 1
    fi

    TOKEN_OBTAINED_AT=$(date +%s)
    log_message "✓ Access token obtained"
    return 0
}

###############################################################################
# FUNCTION: Find device in Intune
###############################################################################
find_device() {
    log_message "Searching for device in Intune (serial: ${MACHINE_SERIAL})..."
    send_dialog "listitem: index: 2, statustext: 🔍 Searching in Intune..."

    local response
    response=$(curl --silent --fail --max-time 30 \
        "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?\$filter=serialNumber%20eq%20%27${MACHINE_SERIAL}%27" \
        -H "Authorization: Bearer ${GRAPH_TOKEN}" \
        -H "Accept: application/json")

    DEVICE_ID=$("${JQ_BIN}" -r '.value[0].id // empty' <<< "$response")
    local serial_found
    serial_found=$("${JQ_BIN}" -r '.value[0].serialNumber // empty' <<< "$response")

    if [[ -z "${DEVICE_ID}" ]]; then
        log_message "✗ Device not found in Intune (serial: ${MACHINE_SERIAL})"
        return 1
    fi

    log_message "✓ Device found — serial: ${serial_found} | ID: ${DEVICE_ID}"
    return 0
}

###############################################################################
# FUNCTION: Send retire command
###############################################################################
retire_device() {
    log_message "Sending retire command (device: ${DEVICE_ID})..."
    send_dialog "listitem: index: 2, statustext: 🔄 Retiring device..."

    local http_code
    http_code=$(curl --silent --fail --max-time 30 \
        --write-out "%{http_code}" --output /dev/null \
        -X POST "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/${DEVICE_ID}/retire" \
        -H "Authorization: Bearer ${GRAPH_TOKEN}" \
        -H "Content-Type: application/json")

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "204" ]]; then
        log_message "✓ Retire command accepted (HTTP ${http_code})"
        return 0
    else
        log_message "✗ Retire command failed (HTTP ${http_code})"
        return 1
    fi
}

###############################################################################
# FUNCTION: Wait for MDM profile removal — with timeout and token refresh
###############################################################################
monitor_mdm_removal() {
    local elapsed=0
    local attempt=1

    log_message "Monitoring MDM profile removal (timeout: ${MDM_REMOVAL_TIMEOUT}s)..."

    while [[ $elapsed -lt $MDM_REMOVAL_TIMEOUT ]]; do
        local elapsed_min=$(( elapsed / 60 ))
        send_dialog "listitem: index: 2, statustext: ⏳ Waiting for MDM removal... (${elapsed_min}m)"
        log_message "Check #${attempt} (${elapsed_min}m elapsed): verifying MDM profile..."

        local enrollment
        enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null | grep "MDM enrollment" || true)

        if [[ "$enrollment" != *"Yes"* ]]; then
            log_message "✓ MDM profile removed after ~${elapsed_min} minute(s)"
            send_dialog "listitem: index: 2, statustext: ✅ MDM profile removed"
            return 0
        fi

        # Refresh token proactively before it expires
        get_graph_token || log_message "⚠ Token refresh failed — will retry"

        log_message "   MDM still active — waiting ${MDM_REMOVAL_INTERVAL}s..."
        sleep $MDM_REMOVAL_INTERVAL
        elapsed=$(( elapsed + MDM_REMOVAL_INTERVAL ))
        (( attempt++ ))
    done

    log_message "✗ Timeout: MDM profile not removed after ${MDM_REMOVAL_TIMEOUT}s"
    send_dialog "listitem: index: 2, statustext: ✗ Timeout waiting for MDM removal"
    return 1
}

###############################################################################
# FUNCTION: Clean up residual Intune components
###############################################################################
cleanup_intune_components() {
    log_message "Cleaning up residual Intune components..."
    send_dialog "listitem: index: 2, statustext: 🧹 Cleaning Intune components..."

    local cleaned=0

    if [[ -f "/Library/Preferences/com.microsoft.CompanyPortal.plist" ]]; then
        rm -f "/Library/Preferences/com.microsoft.CompanyPortal.plist" 2>/dev/null && (( cleaned++ )) || true
        log_message "✓ Removed Company Portal preferences"
    fi

    if [[ -d "/Library/Application Support/Microsoft/Intune" ]]; then
        rm -rf "/Library/Application Support/Microsoft/Intune" 2>/dev/null && (( cleaned++ )) || true
        log_message "✓ Removed Intune cache"
    fi

    for daemon in /Library/LaunchDaemons/com.microsoft.intune.* /Library/LaunchAgents/com.microsoft.intune.*; do
        if [[ -f "${daemon}" ]]; then
            launchctl unload "${daemon}" 2>/dev/null || true
            rm -f "${daemon}" 2>/dev/null && (( cleaned++ )) || true
            log_message "✓ Removed: $(basename "${daemon}")"
        fi
    done

    log_message "✓ Cleanup complete (${cleaned} item(s) removed)"
}

###############################################################################
# MAIN
###############################################################################
load_credentials  || exit 1
get_graph_token   || exit 1
find_device       || exit 2
retire_device     || exit 3

# Write resume checkpoint immediately after retire is accepted by Microsoft.
# This ensures that if the Mac restarts during the monitoring loop,
# main.sh will resume at Step 4 instead of retrying the retire call.
update_state "migration_status" "intune_removed"

monitor_mdm_removal || exit 4
cleanup_intune_components

send_dialog "listitem: index: 2, statustext: ✅ Intune removed successfully"
log_message "========================================="
log_message "✓ INTUNE REMOVED SUCCESSFULLY"
log_message "Elapsed time: ~$((SECONDS / 60)) minute(s)"
log_message "========================================="
exit 0
