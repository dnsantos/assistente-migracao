#!/bin/bash

###############################################################################
# migracao_principal.sh
# Orchestrates the full MDM migration process: Intune → Jamf Pro
#
# Version: 1.1
#
# Description:
#   Main orchestrator script. Starts in text mode and loads the visual
#   interface after installing swiftDialog in Step 2.
#
# Flow:
#   1. Validation (no Dialog)
#   2. Install Dependencies → installs swiftDialog
#   3. Remove Intune (with Dialog)
#   4. Enroll in Jamf (with Dialog)
#   5. Post-migration cleanup (with Dialog)
#
# Exit Codes:
#   0 - Success
#   1 - Validation failure
#   2 - Dependency installation failure
#   3 - Intune removal failure
#   4 - Jamf enrollment failure
#
# Configuration:
#   Edit BASE_DIR and COMPANY_NAME to match your environment.
###############################################################################

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME" # <── change this
readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
# ──────────────────────────────────────────────────────────────────────────────

readonly BIN_DIR="${BASE_DIR}/bin"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migration.log"
readonly DIALOG_BIN="/usr/local/bin/dialog"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly JSON_TEMPLATE="${BASE_DIR}/resources/config"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"

DIALOG_AVAILABLE=false
JQ_BIN=""

if [[ ! -d "${LOGS_DIR}" ]]; then
    mkdir -p "${LOGS_DIR}"
fi

###############################################################################
# FUNCTION: Logging
###############################################################################
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

###############################################################################
# FUNCTION: Update JSON state file
###############################################################################
update_state_with_jq() {
    local key="$1"
    local value="$2"

    if [[ -z "${JQ_BIN}" ]] || [[ ! -f "${JQ_BIN}" ]]; then
        log_message "⚠ JQ not found, cannot update state: ${key}=${value}"
        return 1
    fi

    if [[ ! -f "${STATE_FILE}" ]]; then
        echo "{}" >"${STATE_FILE}"
    fi

    local temp_file="${STATE_FILE}.tmp"
    "${JQ_BIN}" --arg key "$key" --arg value "$value" '.[$key] = $value' "${STATE_FILE}" >"${temp_file}" 2>/dev/null

    if [[ -f "${temp_file}" ]] && [[ -s "${temp_file}" ]]; then
        mv "${temp_file}" "${STATE_FILE}"
        return 0
    else
        log_message "✗ Failed to update JSON state: ${key}=${value}"
        rm -f "${temp_file}" 2>/dev/null
        return 1
    fi
}

###############################################################################
# INITIALIZATION
###############################################################################
log_message "========================================="
log_message "${COMPANY_NAME} MDM MIGRATION ASSISTANT"
log_message "Intune → Jamf Pro"
log_message "========================================="

if [[ $EUID -ne 0 ]]; then
    log_message "✗ This script must be run as root"
    exit 1
fi

log_message "✓ Running as root"

###############################################################################
# FUNCTION: Detect architecture and set up jq
###############################################################################
detect_and_setup_jq() {
    local arch=$(uname -m)
    log_message "Detecting architecture: ${arch}"

    if [[ "$arch" == "arm64" ]]; then
        JQ_BIN="${BIN_DIR}/jq-macos-arm64"
    elif [[ "$arch" == "x86_64" ]]; then
        JQ_BIN="${BIN_DIR}/jq-macos-amd64"
    else
        log_message "⚠ Unsupported architecture: ${arch}"
        return 1
    fi

    if [[ -f "${JQ_BIN}" ]]; then
        chmod +x "${JQ_BIN}" 2>/dev/null || true
        export JQ_BIN
        log_message "✓ jq configured: ${JQ_BIN}"
        return 0
    else
        log_message "⚠ jq binary not found: ${JQ_BIN}"
        return 1
    fi
}

###############################################################################
# FUNCTION: Check if swiftDialog is available
###############################################################################
check_dialog() {
    if [[ -f "${DIALOG_BIN}" ]]; then
        DIALOG_AVAILABLE=true
        log_message "✓ swiftDialog available"
        return 0
    else
        DIALOG_AVAILABLE=false
        log_message "⚠ swiftDialog not yet available"
        return 1
    fi
}

###############################################################################
# FUNCTION: Launch swiftDialog with progress list
###############################################################################
start_migration_dialog() {
    if [[ "$DIALOG_AVAILABLE" != true ]]; then
        log_message "⚠ Dialog not available — skipping visual interface"
        return 1
    fi

    rm -f "${DIALOG_LOG}"
    log_message "Starting visual interface..."

    local machine_name=$(scutil --get ComputerName 2>/dev/null || hostname)
    local serial_number=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

    "${DIALOG_BIN}" \
        --title "${COMPANY_NAME} MDM Migration" \
        --message "### Intune → Jamf Pro Migration<br><br>**Computer:** ${machine_name}<br>**Serial:** ${serial_number}<br><br>Track the migration progress below. You can continue using your Mac normally." \
        --messagefont "size=13" \
        --button1text "none" \
        --width 750 \
        --height 550 \
        --position "center" \
        --ontop \
        --moveable \
        --jsonfile "$JSON_TEMPLATE/dialog_list.json" \
        --commandfile "${DIALOG_LOG}" &

    sleep 2
    log_message "✓ Visual interface started"
    return 0
}

###############################################################################
# FUNCTION: Update list item in swiftDialog
###############################################################################
update_list_item() {
    local index="$1"
    local status="$2" # wait, success, fail, error, pending
    local statustext="$3"

    if [[ "$DIALOG_AVAILABLE" == true ]] && [[ -f "${DIALOG_LOG}" ]]; then
        echo "listitem: index: ${index}, status: ${status}, statustext: ${statustext}" >>"${DIALOG_LOG}"
    fi
}

###############################################################################
# FUNCTION: Finalize swiftDialog
###############################################################################
finish_migration_dialog() {
    local success="$1"
    local message="$2"

    if [[ "$DIALOG_AVAILABLE" != true ]] || [[ ! -f "${DIALOG_LOG}" ]]; then
        return 0
    fi

    if [[ $success -eq 0 ]]; then
        echo "icon: SF=checkmark.circle.fill,color=green" >>"${DIALOG_LOG}"
        echo "message: ### ✅ Migration Complete!\n\n${message}\n\nThe Mac has been successfully migrated from Intune to Jamf Pro." >>"${DIALOG_LOG}"
        echo "button1text: Done" >>"${DIALOG_LOG}"
    else
        echo "icon: SF=xmark.circle.fill,color=red" >>"${DIALOG_LOG}"
        echo "message: ### ✗ Migration Failed\n\n${message}\n\nCheck the logs for details." >>"${DIALOG_LOG}"
        echo "button1text: Close" >>"${DIALOG_LOG}"
    fi

    sleep 5
    echo "quit:" >>"${DIALOG_LOG}"
    rm -f "${DIALOG_LOG}"
}

###############################################################################
# Initial setup
###############################################################################
detect_and_setup_jq
check_dialog

if [[ "$DIALOG_AVAILABLE" == true ]]; then
    log_message "✓ swiftDialog available — launching visual interface"
    "$DIALOG_BIN" \
        --title "${COMPANY_NAME} MDM Migration" \
        --messagefont "size=13" \
        --message "Your Mac is about to be migrated to a new management platform.<br><br>This process is **automatic** and takes approximately **15–30 minutes**.<br><br>You can continue using your Mac normally during the migration." \
        --button1text "Start Migration" \
        --infobuttontext "Learn more" \
        --infobuttonaction "file://$BASE_DIR/html/index.html" \
        --hidedefaultkeyboardaction

    start_migration_dialog
    sleep 2
else
    log_message "========================================="
    log_message "TEXT MODE — visual interface will load after dependencies are installed"
    log_message "Follow progress in logs: ${MAIN_LOG}"
    log_message "========================================="
fi

###############################################################################
# STEP 1: VALIDATION
###############################################################################
log_message ""
log_message "Step 1/5: Validating Mac state..."
update_list_item 0 "wait" "Validating Mac state..."

if [[ ! -f "${BIN_DIR}/validacao_pre_migracao.sh" ]]; then
    log_message "✗ Script not found: validacao_pre_migracao.sh"
    update_list_item 0 "error" "Script not found"
    finish_migration_dialog 1 "Validation script not found"
    "${BIN_DIR}/notificar_teams.sh" "failure" "Validation script not found" &
    exit 1
fi

"${BIN_DIR}/validacao_pre_migracao.sh"
VALIDATION_RESULT=$?

if [[ $VALIDATION_RESULT -eq 0 ]]; then
    log_message "Mac is already in Jamf — no action needed"
    update_list_item 0 "success" "Mac already in Jamf"
    update_list_item 1 "success" "Not required"
    update_list_item 2 "success" "Not required"
    update_list_item 3 "success" "Not required"

    log_message ""
    log_message "Step 5/5: Finalizing..."
    update_list_item 4 "wait" "Running post-migration tasks..."

    if [[ -f "${BIN_DIR}/pos_migracao.sh" ]]; then
        "${BIN_DIR}/pos_migracao.sh"
        log_message "✓ Post-migration complete"
        update_list_item 4 "success" "Done"
    else
        update_list_item 4 "success" "Not required"
    fi

    finish_migration_dialog 0 "This Mac is already correctly configured in Jamf Pro."
    "${BIN_DIR}/notificar_teams.sh" "completed" &
    exit 0

elif [[ $VALIDATION_RESULT -eq 10 ]]; then
    log_message "✓ Validation complete — Mac is on Intune"
    update_list_item 0 "success" "Mac found on Intune"

elif [[ $VALIDATION_RESULT -eq 20 ]]; then
    log_message "✓ Validation complete — No MDM, will enroll directly in Jamf"
    update_list_item 0 "success" "No MDM — enrolling in Jamf"

    log_message ""
    log_message "Step 2/5: Dependencies..."
    update_list_item 1 "success" "Not required"

    log_message ""
    log_message "Step 3/5: Cleaning residual Microsoft certificates..."
    update_list_item 2 "wait" "Removing Microsoft certificates..."

    if [[ -f "${BIN_DIR}/limpar_certificados_ms.sh" ]]; then
        "${BIN_DIR}/limpar_certificados_ms.sh"
        if [[ $? -eq 0 ]]; then
            update_list_item 2 "success" "Certificates removed"
        else
            update_list_item 2 "success" "Checked (with warnings)"
        fi
    else
        update_list_item 2 "success" "Not available"
    fi

else
    log_message "✗ Validation failed (code: ${VALIDATION_RESULT})"
    update_list_item 0 "fail" "Validation failed"

    local error_message="Error during validation.\n\nCheck the logs for details."
    if [[ $VALIDATION_RESULT -eq 1 ]]; then
        error_message="Mac is managed by an unknown MDM.\n\nThis tool only supports Intune or unmanaged Macs."
    fi

    finish_migration_dialog 1 "${error_message}"
    "${BIN_DIR}/notificar_teams.sh" "failure" "${error_message}" &
    exit 1
fi

###############################################################################
# STEP 2: DEPENDENCIES (only if not exit 20)
###############################################################################
if [[ $VALIDATION_RESULT -ne 20 ]]; then
    log_message ""
    log_message "Step 2/5: Installing dependencies..."
    update_list_item 1 "wait" "Installing swiftDialog..."

    if [[ -f "${BIN_DIR}/instalar_dependencias.sh" ]]; then
        "${BIN_DIR}/instalar_dependencias.sh"
        if [[ $? -ne 0 ]]; then
            log_message "✗ Failed to install dependencies"
            update_list_item 1 "fail" "Installation failed"
            finish_migration_dialog 1 "Failed to install required dependencies"
            "${BIN_DIR}/notificar_teams.sh" "failure" "Failed to install required dependencies" &
            exit 2
        fi
        log_message "✓ Dependencies installed"
        update_list_item 1 "success" "Dependencies installed"

        if [[ "$DIALOG_AVAILABLE" == false ]]; then
            check_dialog
            if [[ "$DIALOG_AVAILABLE" == true ]]; then
                start_migration_dialog
                sleep 3
                update_list_item 0 "success" "Mac found on Intune"
                update_list_item 1 "success" "Dependencies installed"
            fi
        fi
    else
        log_message "⚠ Dependency script not found (skipping)"
        update_list_item 1 "success" "Not required"
    fi
fi

###############################################################################
# STEP 3: REMOVE INTUNE / CLEAN CERTIFICATES
###############################################################################
if [[ $VALIDATION_RESULT -eq 10 ]]; then
    log_message ""
    log_message "Step 3/5: Removing Intune enrollment..."
    update_list_item 2 "wait" "Connecting to Intune..."

    if [[ -f "${BIN_DIR}/remover_intune.sh" ]]; then
        "${BIN_DIR}/remover_intune.sh"
        if [[ $? -ne 0 ]]; then
            log_message "✗ Failed to remove Intune"
            update_list_item 2 "fail" "Failed to remove Intune"
            finish_migration_dialog 1 "Could not remove Intune management"
            "${BIN_DIR}/notificar_teams.sh" "failure" "Could not remove Intune management" &
            exit 3
        fi
        log_message "✓ Intune removed successfully"

        update_list_item 2 "wait" "Removing Microsoft certificates..."
        if [[ -f "${BIN_DIR}/limpar_certificados_ms.sh" ]]; then
            "${BIN_DIR}/limpar_certificados_ms.sh"
            log_message "✓ Microsoft certificates removed"
        fi
        update_list_item 2 "success" "Intune removed successfully"
    else
        log_message "✗ Script remover_intune.sh not found"
        update_list_item 2 "error" "Script not found"
        finish_migration_dialog 1 "Intune removal script not found"
        "${BIN_DIR}/notificar_teams.sh" "failure" "Intune removal script not found" &
        exit 3
    fi

elif [[ $VALIDATION_RESULT -eq 20 ]]; then
    log_message ""
    log_message "Step 3/5: Cleaning residual Microsoft certificates..."
    update_list_item 2 "wait" "Removing Microsoft certificates..."

    if [[ -f "${BIN_DIR}/limpar_certificados_ms.sh" ]]; then
        "${BIN_DIR}/limpar_certificados_ms.sh"
        update_list_item 2 "success" "Certificates removed"
    else
        update_list_item 2 "success" "Not available"
    fi
fi

###############################################################################
# STEP 4: ENROLL IN JAMF
###############################################################################
log_message ""
log_message "Step 4/5: Enrolling in Jamf Pro..."
update_list_item 3 "wait" "Preparing Jamf enrollment..."

if [[ -f "${BIN_DIR}/instalar_jamf.sh" ]]; then
    "${BIN_DIR}/instalar_jamf.sh"
    if [[ $? -ne 0 ]]; then
        log_message "✗ Failed to enroll in Jamf"
        update_list_item 3 "fail" "Jamf enrollment failed"
        finish_migration_dialog 1 "Could not enroll the Mac in Jamf Pro"
        "${BIN_DIR}/notificar_teams.sh" "failure" "Could not enroll the Mac in Jamf Pro" &
        exit 4
    fi
    log_message "✓ Jamf enrollment successful"
    update_list_item 3 "success" "Jamf enrollment successful"
else
    log_message "✗ Script instalar_jamf.sh not found"
    update_list_item 3 "error" "Script not found"
    finish_migration_dialog 1 "Jamf enrollment script not found"
    "${BIN_DIR}/notificar_teams.sh" "failure" "Jamf enrollment script not found" &
    exit 4
fi

###############################################################################
# STEP 5: POST-MIGRATION
###############################################################################
log_message ""
log_message "Step 5/5: Finalizing migration..."
update_list_item 4 "wait" "Running final cleanup..."

if [[ -f "${BIN_DIR}/pos_migracao.sh" ]]; then
    "${BIN_DIR}/pos_migracao.sh"
    log_message "✓ Post-migration complete"
    update_list_item 4 "success" "Done"
else
    log_message "⚠ pos_migracao.sh not found (skipping)"
    update_list_item 4 "success" "Not required"
fi

###############################################################################
# DONE
###############################################################################
log_message ""
log_message "========================================="
log_message "✓ MIGRATION COMPLETED SUCCESSFULLY"
log_message "Total time: ~$((SECONDS / 60)) minute(s)"
log_message "========================================="

finish_migration_dialog 0 "All steps completed successfully!"
exit 0
