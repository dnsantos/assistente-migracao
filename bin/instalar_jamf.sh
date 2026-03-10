#!/bin/bash

###############################################################################
# instalar_jamf.sh
# Enrolls the Mac in Jamf Pro via MDM (ABM PreStage)
#
# Version: 1.0
#
# Prerequisites:
#   - Mac must be in Apple Business Manager (ABM)
#   - Mac must be assigned to a Jamf PreStage Enrollment
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Enrollment timeout
#   3 - Enrollment failed
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
readonly JAMF_BINARY="/usr/local/bin/jamf"

readonly MACHINE_SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
JQ_BIN="${JQ_BIN:-}"

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
        echo "listitem: index: 3, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
}

detect_jq_if_needed() {
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        return 0
    fi
    local arch=$(uname -m)
    if [[ "$arch" == "arm64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-arm64"
    elif [[ "$arch" == "x86_64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-amd64"
    else
        return 1
    fi
    if [[ -f "${JQ_BIN}" ]]; then
        chmod +x "${JQ_BIN}" 2>/dev/null || true
        return 0
    fi
    return 1
}

###############################################################################
# INITIALIZATION
###############################################################################
log_message "========================================="
log_message "ENROLLING IN JAMF PRO"
log_message "Mac serial: ${MACHINE_SERIAL}"
log_message "========================================="

if [[ $EUID -ne 0 ]]; then
    log_message "✗ This script must be run as root"
    exit 1
fi

detect_jq_if_needed

###############################################################################
# FUNCTION: Check if already enrolled in Jamf
###############################################################################
check_jamf_enrollment() {
    log_message "Checking existing enrollment..."

    local mdm_enrollment
    mdm_enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null)

    if echo "${mdm_enrollment}" | grep -q "MDM enrollment: Yes"; then
        local mdm_server
        mdm_server=$(echo "${mdm_enrollment}" | grep "MDM server:" | cut -d: -f2- | xargs)

        if echo "${mdm_server}" | grep -qi "jamf"; then
            log_message "✓ Mac is already enrolled in Jamf"
            log_message "   Server: ${mdm_server}"
            return 0
        fi
    fi
    return 1
}

###############################################################################
# FUNCTION: Renew MDM enrollment
###############################################################################
renew_mdm_enrollment() {
    log_message "Renewing MDM enrollment..."
    update_dialog "🔄 Renewing MDM enrollment..."

    log_message "Running: profiles renew -type enrollment"

    if "${PROFILES_CMD}" renew -type enrollment 2>&1 | tee -a "${MAIN_LOG}"; then
        log_message "✓ Renewal command executed"
        return 0
    else
        log_message "✗ Renewal command failed"
        return 1
    fi
}

###############################################################################
# FUNCTION: Monitor Jamf enrollment
###############################################################################
monitor_jamf_enrollment() {
    local checks=20
    local interval=30
    local max_time=$((checks * interval))

    log_message "Monitoring Jamf enrollment..."
    log_message "   Max attempts: ${checks}"
    log_message "   Interval: ${interval}s"
    log_message "   Max wait time: $((max_time / 60)) minutes"

    for ((i = 1; i <= checks; i++)); do
        update_dialog "⏳ Waiting for Jamf enrollment (${i}/${checks})..."

        log_message "Attempt ${i}/${checks}: checking enrollment..."
        sleep $interval

        local mdm_enrollment
        mdm_enrollment=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null)

        if echo "${mdm_enrollment}" | grep -q "MDM enrollment: Yes"; then
            local mdm_server
            mdm_server=$(echo "${mdm_enrollment}" | grep "MDM server:" | cut -d: -f2- | xargs)

            if echo "${mdm_server}" | grep -qi "jamf"; then
                log_message "✓ Jamf enrollment confirmed (attempt ${i}/${checks})"
                log_message "   Server: ${mdm_server}"
                update_dialog "✅ Enrolled in Jamf"
                return 0
            else
                log_message "   MDM active but not Jamf: ${mdm_server}"
            fi
        else
            log_message "   Waiting for enrollment..."
        fi
    done

    log_message "✗ Timeout: enrollment not confirmed after ${checks} attempts ($((max_time / 60)) minutes)"
    update_dialog "✗ Enrollment timeout"
    return 1
}

###############################################################################
# FUNCTION: Verify Jamf binary
###############################################################################
verify_jamf_binary() {
    log_message "Verifying Jamf binary..."
    update_dialog "🔍 Verifying Jamf binary..."

    if [[ -f "${JAMF_BINARY}" ]]; then
        local jamf_version
        jamf_version=$("${JAMF_BINARY}" version 2>/dev/null || echo "unknown")
        log_message "✓ Jamf binary installed"
        log_message "   Version: ${jamf_version}"
        log_message "   Path: ${JAMF_BINARY}"
        return 0
    else
        log_message "⚠ Jamf binary not found at ${JAMF_BINARY}"
        log_message "   It will be installed automatically via Jamf policy"
        return 1
    fi
}

###############################################################################
# FUNCTION: Validate JSS connectivity
###############################################################################
validate_jss() {
    if [[ ! -f "${JAMF_BINARY}" ]]; then
        log_message "⚠ Jamf binary not available — skipping JSS validation"
        return 0
    fi

    log_message "Validating JSS connectivity..."
    sleep 60
    update_dialog "📋 Validating JSS connection..."

    if "${JAMF_BINARY}" startup 2>&1 | tee -a "${MAIN_LOG}"; then
        log_message "✓ JSS is reachable"
        return 0
    else
        log_message "⚠ JSS validation failed (non-critical)"
        return 1
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

    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local temp_file="${STATE_FILE}.tmp"
        "${JQ_BIN}" \
            '.mdm_type = "jamf" | .migration_status = "jamf_enrolled"' \
            "${STATE_FILE}" >"${temp_file}" 2>/dev/null

        if [[ -f "${temp_file}" ]]; then
            mv "${temp_file}" "${STATE_FILE}"
            log_message "✓ State file updated"
        fi
    else
        sed -i '' 's/"mdm_type": "none"/"mdm_type": "jamf"/' "${STATE_FILE}" 2>/dev/null || true
        log_message "✓ State file updated (via sed)"
    fi
}

###############################################################################
# MAIN
###############################################################################
if check_jamf_enrollment; then
    log_message "Mac already enrolled in Jamf — nothing to do"
    update_dialog "✅ Already enrolled in Jamf"
    verify_jamf_binary && validate_jss
    exit 0
fi

update_dialog "🔄 Starting Jamf enrollment..."
renew_mdm_enrollment || {
    log_message "✗ Failed to renew MDM enrollment"
    update_dialog "✗ Enrollment failed"
    exit 1
}
monitor_jamf_enrollment || exit 2
verify_jamf_binary
validate_jss
update_migration_state

update_dialog "✅ Jamf enrolled successfully"
log_message "========================================="
log_message "✓ JAMF PRO ENROLLMENT COMPLETE"
log_message "Elapsed time: ~$((SECONDS / 60)) minute(s)"
log_message "========================================="

exit 0
