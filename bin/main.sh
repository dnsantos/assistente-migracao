#!/bin/bash
set -euo pipefail

###############################################################################
# main.sh
# Orchestrates the full MDM migration process: Intune → Jamf Pro
#
# Version: 1.3
#
# Flow:
#   1. Validation        (text mode)
#   2. Install Dependencies → loads swiftDialog
#   3. Remove Intune     (with Dialog)
#   4. Enroll in Jamf    (with Dialog)
#   5. Post-migration    (with Dialog)
#
# Resume logic:
#   If the Mac restarts mid-migration, the previous migration_status from
#   migration_state.json is read and the process resumes from the correct
#   step instead of starting over.
#
# Exit Codes:
#   0 - Success
#   1 - Validation failure
#   2 - Dependency installation failure
#   3 - Intune removal failure
#   4 - Jamf enrollment failure
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

require_root

DIALOG_AVAILABLE=false

###############################################################################
# HELPERS
###############################################################################
check_dialog() {
    if [[ -f "${DIALOG_BIN}" ]]; then
        DIALOG_AVAILABLE=true
        return 0
    fi
    DIALOG_AVAILABLE=false
    return 1
}

update_list_item() {
    local index="$1" status="$2" statustext="$3"
    send_dialog "listitem: index: ${index}, status: ${status}, statustext: ${statustext}"
}

start_migration_dialog() {
    [[ "$DIALOG_AVAILABLE" != true ]] && return 0
    rm -f "${DIALOG_LOG}"

    local machine_name serial
    machine_name=$(scutil --get ComputerName 2>/dev/null || hostname)
    serial=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

    "${DIALOG_BIN}" \
        --title "${COMPANY_NAME} MDM Migration" \
        --message "### Intune → Jamf Pro Migration<br><br>**Computer:** ${machine_name}<br>**Serial:** ${serial}<br><br>Track the migration progress below. You can continue using your Mac normally." \
        --messagefont "size=13" \
        --button1text "none" \
        --width 750 --height 550 \
        --position "center" --ontop --moveable \
        --jsonfile "${BASE_DIR}/resources/config/dialog_list.json" \
        --commandfile "${DIALOG_LOG}" &

    sleep 2
    log_message "✓ Visual interface started"
}

finish_migration_dialog() {
    local success="$1" message="$2"
    [[ "$DIALOG_AVAILABLE" != true ]] || [[ ! -f "${DIALOG_LOG}" ]] && return 0

    if [[ $success -eq 0 ]]; then
        send_dialog "icon: SF=checkmark.circle.fill,color=green"
        send_dialog "message: ### ✅ Migration Complete!\n\n${message}\n\nThe Mac has been successfully migrated from Intune to Jamf Pro."
        send_dialog "button1text: Done"
    else
        send_dialog "icon: SF=xmark.circle.fill,color=red"
        send_dialog "message: ### ✗ Migration Failed\n\n${message}\n\nCheck the logs for details."
        send_dialog "button1text: Close"
    fi

    sleep 5
    send_dialog "quit:"
    rm -f "${DIALOG_LOG}"
}

###############################################################################
# FUNCTION: Read previous migration status from state file
###############################################################################
read_previous_status() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        echo ""
        return
    fi

    if [[ -n "${JQ_BIN:-}" ]] && [[ -f "${JQ_BIN}" ]]; then
        "${JQ_BIN}" -r '.migration_status // empty' "${STATE_FILE}" 2>/dev/null || echo ""
    else
        grep -o '"migration_status": *"[^"]*"' "${STATE_FILE}" 2>/dev/null \
            | cut -d'"' -f4 || echo ""
    fi
}

###############################################################################
# INITIALIZATION
###############################################################################
log_message "========================================="
log_message "${COMPANY_NAME} MDM MIGRATION"
log_message "Intune → Jamf Pro"
log_message "========================================="

detect_jq || true
check_dialog

###############################################################################
# RESUME LOGIC — check state before doing anything
###############################################################################
PREVIOUS_STATUS=$(read_previous_status)

if [[ -n "${PREVIOUS_STATUS}" ]]; then
    log_message "ℹ Previous migration status found: '${PREVIOUS_STATUS}'"
fi

case "${PREVIOUS_STATUS}" in

    completed)
        log_message "✓ Migration already completed — nothing to do"
        exit 0
        ;;

    jamf_enrolled)
        log_message "↩ Resuming from Step 5 (Jamf already enrolled — running post-migration)"
        log_message ""

        check_dialog && start_migration_dialog && sleep 2
        update_list_item 0 "success" "Resumed"
        update_list_item 1 "success" "Resumed"
        update_list_item 2 "success" "Resumed"
        update_list_item 3 "success" "Jamf enrollment confirmed"
        update_list_item 4 "wait" "Running final cleanup..."

        log_message "Step 5/5: Finalizing migration..."
        [[ -f "${BIN_DIR}/post_migration.sh" ]] && "${BIN_DIR}/post_migration.sh"
        update_list_item 4 "success" "Done"
        finish_migration_dialog 0 "All steps completed successfully!"
        exit 0
        ;;

    intune_removed)
        log_message "↩ Resuming from Step 4 (Intune already removed — enrolling in Jamf)"
        log_message ""

        check_dialog && start_migration_dialog && sleep 2
        update_list_item 0 "success" "Resumed"
        update_list_item 1 "success" "Resumed"
        update_list_item 2 "success" "Intune removed"

        # Fall through to Step 4
        log_message "Step 4/5: Enrolling in Jamf Pro..."
        update_list_item 3 "wait" "Preparing Jamf enrollment..."

        if [[ -f "${BIN_DIR}/install_jamf.sh" ]]; then
            set +e; "${BIN_DIR}/install_jamf.sh"; JAMF_RESULT=$?; set -e
            if [[ $JAMF_RESULT -ne 0 ]]; then
                log_message "✗ Failed to enroll in Jamf"
                update_list_item 3 "fail" "Jamf enrollment failed"
                finish_migration_dialog 1 "Could not enroll the Mac in Jamf Pro"
                "${BIN_DIR}/notify_teams.sh" "failure" "Could not enroll the Mac in Jamf Pro" &
                exit 4
            fi
            update_list_item 3 "success" "Jamf enrollment successful"
        else
            log_message "✗ install_jamf.sh not found"
            update_list_item 3 "error" "Script not found"
            finish_migration_dialog 1 "Jamf enrollment script not found"
            "${BIN_DIR}/notify_teams.sh" "failure" "Jamf enrollment script not found" &
            exit 4
        fi

        log_message "Step 5/5: Finalizing migration..."
        update_list_item 4 "wait" "Running final cleanup..."
        [[ -f "${BIN_DIR}/post_migration.sh" ]] && "${BIN_DIR}/post_migration.sh"
        update_list_item 4 "success" "Done"
        finish_migration_dialog 0 "All steps completed successfully!"
        exit 0
        ;;

    needs_migration|no_mdm_enroll_jamf|"")
        # Normal flow — start from Step 1
        log_message "Starting full migration flow..."
        ;;

    *)
        log_message "⚠ Unrecognized previous status '${PREVIOUS_STATUS}' — starting from Step 1"
        ;;
esac

###############################################################################
# INTRO DIALOG (only on fresh start)
###############################################################################
if [[ "$DIALOG_AVAILABLE" == true ]]; then
    log_message "✓ swiftDialog available — showing intro dialog"
    "${DIALOG_BIN}" \
        --title "${COMPANY_NAME} MDM Migration" \
        --messagefont "size=13" \
        --message "Your Mac is about to be migrated to a new management platform.<br><br>This process is **automatic** and takes approximately **15–30 minutes**.<br><br>You can continue using your Mac normally during the migration." \
        --button1text "Start Migration" \
        --infobuttontext "Learn more" \
        --infobuttonaction "file://${BASE_DIR}/html/index.html" \
        --hidedefaultkeyboardaction

    start_migration_dialog
    sleep 2
else
    log_message "TEXT MODE — visual interface will load after dependencies are installed"
    log_message "Follow progress in: ${MAIN_LOG}"
fi

# Notify Teams that migration has started
"${BIN_DIR}/notify_teams.sh" "started" &

###############################################################################
# STEP 1: VALIDATION
###############################################################################
log_message ""
log_message "Step 1/5: Validating Mac state..."
update_list_item 0 "wait" "Validating Mac state..."

if [[ ! -f "${BIN_DIR}/validate.sh" ]]; then
    log_message "✗ Script not found: validate.sh"
    update_list_item 0 "error" "Script not found"
    finish_migration_dialog 1 "Validation script not found"
    "${BIN_DIR}/notify_teams.sh" "failure" "Validation script not found" &
    exit 1
fi

set +e; "${BIN_DIR}/validate.sh"; VALIDATION_RESULT=$?; set -e

if [[ $VALIDATION_RESULT -eq 0 ]]; then
    log_message "Mac is already in Jamf — running post-migration only"
    update_list_item 0 "success" "Mac already in Jamf"
    update_list_item 1 "success" "Not required"
    update_list_item 2 "success" "Not required"
    update_list_item 3 "success" "Not required"
    update_list_item 4 "wait" "Running post-migration tasks..."
    [[ -f "${BIN_DIR}/post_migration.sh" ]] && "${BIN_DIR}/post_migration.sh"
    update_list_item 4 "success" "Done"
    finish_migration_dialog 0 "This Mac is already correctly configured in Jamf Pro."
    "${BIN_DIR}/notify_teams.sh" "completed" &
    exit 0

elif [[ $VALIDATION_RESULT -eq 10 ]]; then
    log_message "✓ Validation — Mac is on Intune"
    update_list_item 0 "success" "Mac found on Intune"

elif [[ $VALIDATION_RESULT -eq 20 ]]; then
    log_message "✓ Validation — No MDM, will enroll directly in Jamf"
    update_list_item 0 "success" "No MDM — enrolling in Jamf"
    update_list_item 1 "success" "Not required"
    update_list_item 2 "wait" "Removing Microsoft certificates..."
    if [[ -f "${BIN_DIR}/clean_certificates.sh" ]]; then
        "${BIN_DIR}/clean_certificates.sh" \
            && update_list_item 2 "success" "Certificates removed" \
            || update_list_item 2 "success" "Checked (with warnings)"
    else
        update_list_item 2 "success" "Not available"
    fi

else
    log_message "✗ Validation failed (code: ${VALIDATION_RESULT})"
    update_list_item 0 "fail" "Validation failed"
    local_msg="Error during validation. Check the logs for details."
    [[ $VALIDATION_RESULT -eq 1 ]] && local_msg="Mac is managed by an unknown MDM. This tool only supports Intune or unmanaged Macs."
    finish_migration_dialog 1 "${local_msg}"
    "${BIN_DIR}/notify_teams.sh" "failure" "${local_msg}" &
    exit 1
fi

###############################################################################
# STEP 2: DEPENDENCIES
###############################################################################
if [[ $VALIDATION_RESULT -ne 20 ]]; then
    log_message ""
    log_message "Step 2/5: Installing dependencies..."
    update_list_item 1 "wait" "Installing swiftDialog..."

    if [[ -f "${BIN_DIR}/install_dependencies.sh" ]]; then
        set +e; "${BIN_DIR}/install_dependencies.sh"; DEP_RESULT=$?; set -e

        if [[ $DEP_RESULT -ne 0 ]]; then
            log_message "✗ Failed to install dependencies"
            update_list_item 1 "fail" "Installation failed"
            finish_migration_dialog 1 "Failed to install required dependencies"
            "${BIN_DIR}/notify_teams.sh" "failure" "Failed to install required dependencies" &
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
        log_message "⚠ install_dependencies.sh not found (skipping)"
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

    if [[ -f "${BIN_DIR}/remove_intune.sh" ]]; then
        set +e; "${BIN_DIR}/remove_intune.sh"; REMOVE_RESULT=$?; set -e

        if [[ $REMOVE_RESULT -ne 0 ]]; then
            log_message "✗ Failed to remove Intune (code: ${REMOVE_RESULT})"
            update_list_item 2 "fail" "Failed to remove Intune"
            finish_migration_dialog 1 "Could not remove Intune management"
            "${BIN_DIR}/notify_teams.sh" "failure" "Could not remove Intune management" &
            exit 3
        fi

        update_list_item 2 "wait" "Removing Microsoft certificates..."
        [[ -f "${BIN_DIR}/clean_certificates.sh" ]] && "${BIN_DIR}/clean_certificates.sh" || true
        update_list_item 2 "success" "Intune removed successfully"
    else
        log_message "✗ remove_intune.sh not found"
        update_list_item 2 "error" "Script not found"
        finish_migration_dialog 1 "Intune removal script not found"
        "${BIN_DIR}/notify_teams.sh" "failure" "Intune removal script not found" &
        exit 3
    fi

elif [[ $VALIDATION_RESULT -eq 20 ]]; then
    log_message ""
    log_message "Step 3/5: Cleaning residual Microsoft certificates..."
    update_list_item 2 "wait" "Removing Microsoft certificates..."
    if [[ -f "${BIN_DIR}/clean_certificates.sh" ]]; then
        "${BIN_DIR}/clean_certificates.sh" \
            && update_list_item 2 "success" "Certificates removed" || true
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

if [[ -f "${BIN_DIR}/install_jamf.sh" ]]; then
    set +e; "${BIN_DIR}/install_jamf.sh"; JAMF_RESULT=$?; set -e

    if [[ $JAMF_RESULT -ne 0 ]]; then
        log_message "✗ Failed to enroll in Jamf"
        update_list_item 3 "fail" "Jamf enrollment failed"
        finish_migration_dialog 1 "Could not enroll the Mac in Jamf Pro"
        "${BIN_DIR}/notify_teams.sh" "failure" "Could not enroll the Mac in Jamf Pro" &
        exit 4
    fi
    update_list_item 3 "success" "Jamf enrollment successful"
else
    log_message "✗ install_jamf.sh not found"
    update_list_item 3 "error" "Script not found"
    finish_migration_dialog 1 "Jamf enrollment script not found"
    "${BIN_DIR}/notify_teams.sh" "failure" "Jamf enrollment script not found" &
    exit 4
fi

###############################################################################
# STEP 5: POST-MIGRATION
###############################################################################
log_message ""
log_message "Step 5/5: Finalizing migration..."
update_list_item 4 "wait" "Running final cleanup..."

if [[ -f "${BIN_DIR}/post_migration.sh" ]]; then
    "${BIN_DIR}/post_migration.sh"
    update_list_item 4 "success" "Done"
else
    log_message "⚠ post_migration.sh not found (skipping)"
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
