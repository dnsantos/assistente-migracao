#!/bin/bash

###############################################################################
# pos_migracao.sh
# Post-migration: cleanup and finalization
#
# Version: 1.0
#
# Exit Codes:
#   0 - Success
#   1 - Not running as root
###############################################################################

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME" # <── change this
readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
# ──────────────────────────────────────────────────────────────────────────────

readonly BIN_DIR="${BASE_DIR}/bin"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migration.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly JAMF_BINARY="/usr/local/bin/jamf"

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
        echo "listitem: index: 4, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
}

detect_jq_if_needed() {
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then return 0; fi
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
log_message "POST-MIGRATION FINALIZATION"
log_message "========================================="

if [[ $EUID -ne 0 ]]; then
    log_message "✗ This script must be run as root"
    exit 1
fi

detect_jq_if_needed

###############################################################################
# FUNCTION: Run jamf recon
###############################################################################
run_jamf_recon() {
    log_message ""
    log_message "Updating Jamf inventory..."
    update_dialog "📊 Updating Jamf inventory..."

    if [[ ! -f "${JAMF_BINARY}" ]]; then
        log_message "⚠ Jamf binary not found — inventory will update automatically"
        return 0
    fi

    if "${JAMF_BINARY}" recon 2>&1 | tee -a "${MAIN_LOG}"; then
        log_message "✓ Inventory updated successfully"
        return 0
    else
        log_message "⚠ Failed to update inventory (non-critical)"
        return 1
    fi
}

###############################################################################
# FUNCTION: Clean temporary files
###############################################################################
cleanup_temp_files() {
    log_message ""
    log_message "Cleaning temporary files..."
    update_dialog "🧹 Cleaning temporary files..."

    local cleaned=0
    local temp_files=(
        "/private/tmp/com.jamf*"
        "/private/tmp/InstallationCheck*"
        "/var/tmp/dialog_migration.log.json"
    )

    for pattern in "${temp_files[@]}"; do
        if compgen -G "$pattern" >/dev/null 2>&1; then
            rm -f $pattern 2>/dev/null && ((cleaned++))
            log_message "   ✓ Removed: ${pattern}"
        fi
    done

    if [[ $cleaned -gt 0 ]]; then
        log_message "✓ ${cleaned} temporary file(s) removed"
    else
        log_message "✓ No temporary files found"
    fi
}

###############################################################################
# FUNCTION: Rotate old logs
###############################################################################
rotate_old_logs() {
    log_message ""
    log_message "Checking log rotation..."
    update_dialog "📋 Checking logs..."

    if [[ -f "${MAIN_LOG}" ]]; then
        local log_size=$(stat -f%z "${MAIN_LOG}" 2>/dev/null || echo 0)
        local max_size=$((10 * 1024 * 1024)) # 10 MB

        if [[ $log_size -gt $max_size ]]; then
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            local archived_log="${MAIN_LOG}.${timestamp}"
            cp "${MAIN_LOG}" "${archived_log}"
            echo "" >"${MAIN_LOG}"
            log_message "✓ Log rotated: $(basename ${archived_log})"
        fi
    fi

    find "${LOGS_DIR}" -name "*.log.*" -type f -mtime +7 -delete 2>/dev/null
    log_message "✓ Old logs checked (keeping last 7 days)"
}

###############################################################################
# FUNCTION: Update final state
###############################################################################
update_final_state() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_message "⚠ State file not found"
        return 0
    fi

    log_message ""
    log_message "Updating final migration state..."
    update_dialog "💾 Saving final state..."

    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local temp_file="${STATE_FILE}.tmp"
        local completion_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        "${JQ_BIN}" \
            --arg date "$completion_date" \
            '.migration_status = "completed" | .completion_date = $date' \
            "${STATE_FILE}" >"${temp_file}" 2>/dev/null

        if [[ -f "${temp_file}" ]]; then
            mv "${temp_file}" "${STATE_FILE}"
            log_message "✓ Final state updated"
        fi
    else
        sed -i '' 's/"migration_status": "[^"]*"/"migration_status": "completed"/' "${STATE_FILE}" 2>/dev/null
        log_message "✓ Final state updated (via sed)"
    fi
}

###############################################################################
# FUNCTION: Verify final enrollment
###############################################################################
verify_final_enrollment() {
    log_message ""
    log_message "Verifying final enrollment..."
    update_dialog "✅ Verifying enrollment..."

    local mdm_enrollment
    mdm_enrollment=$(/usr/bin/profiles status -type enrollment 2>/dev/null)

    if echo "${mdm_enrollment}" | grep -q "MDM enrollment: Yes"; then
        local mdm_server
        mdm_server=$(echo "${mdm_enrollment}" | grep "MDM server:" | cut -d: -f2- | xargs)
        log_message "✓ Enrollment verified:"
        log_message "   MDM active: Yes"
        log_message "   Server: ${mdm_server}"

        if echo "${mdm_server}" | grep -qi "jamf"; then
            log_message "   ✓ Confirmed: Jamf Pro"
            return 0
        else
            log_message "   ⚠ MDM server is not Jamf: ${mdm_server}"
            return 1
        fi
    else
        log_message "⚠ MDM not yet active — enrollment may still be finalizing"
        return 1
    fi
}

###############################################################################
# FUNCTION: Print summary
###############################################################################
show_summary() {
    log_message ""
    log_message "========================================="
    log_message "MIGRATION SUMMARY"
    log_message "========================================="

    if [[ -f "${STATE_FILE}" ]] && [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local os_version=$("${JQ_BIN}" -r '.os_version // "N/A"' "${STATE_FILE}")
        local validation_date=$("${JQ_BIN}" -r '.validation_date // "N/A"' "${STATE_FILE}")
        local mdm_type=$("${JQ_BIN}" -r '.mdm_type // "N/A"' "${STATE_FILE}")
        log_message "   macOS:       ${os_version}"
        log_message "   Start date:  ${validation_date}"
        log_message "   Current MDM: ${mdm_type}"
    fi

    local serial=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
    local computer_name=$(scutil --get ComputerName 2>/dev/null || hostname)
    log_message "   Computer: ${computer_name}"
    log_message "   Serial:   ${serial}"
    log_message ""
    log_message "✓ Migration completed successfully!"
    log_message "   Next steps:"
    log_message "   1. Jamf policies will be applied automatically"
    log_message "   2. Allow ~10 minutes for full synchronization"
    log_message "   3. Restart if prompted by a Jamf policy"
    log_message "========================================="
}

###############################################################################
# MAIN
###############################################################################
run_jamf_recon
cleanup_temp_files
rotate_old_logs
update_final_state
verify_final_enrollment
show_summary

update_dialog "✅ Finalization complete"

log_message ""
log_message "Scheduling self-removal of migration folder in 10 seconds..."
update_dialog "🗑️ Scheduling cleanup..."

"${BIN_DIR}/notificar_teams.sh" "completed" &
sleep 5

cd "/private/tmp"
nohup "/private/tmp/limpeza_final.sh" >/dev/null 2>&1 &
sleep 5

log_message ""
log_message "========================================="
log_message "✓ POST-MIGRATION COMPLETE"
log_message "Total migration time: ~$((SECONDS / 60)) minute(s)"
log_message "========================================="

exit 0
