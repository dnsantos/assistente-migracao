#!/bin/bash

###############################################################################
# limpar_certificados_ms.sh
# Removes the MS-ORGANIZATION-ACCESS certificate from the user keychain
#
# Version: 1.0
#
# Exit Codes:
#   0 - Success (certificate removed or not found)
#   1 - Error (not running as root or no user logged in)
###############################################################################

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME" # <── change this
readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
# ──────────────────────────────────────────────────────────────────────────────

readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migration.log"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"

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
# INITIALIZATION
###############################################################################
log_message "========================================="
log_message "REMOVING MS-ORGANIZATION-ACCESS CERTIFICATE"
log_message "========================================="

if [[ $EUID -ne 0 ]]; then
    log_message "✗ This script must be run as root"
    exit 1
fi

LOGGED_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "none")

if [[ "$LOGGED_USER" == "none" ]] || [[ "$LOGGED_USER" == "root" ]]; then
    log_message "⚠ No user logged in — cannot remove certificate"
    update_dialog "⚠ No user logged in"
    exit 1
fi

log_message "Logged in user: ${LOGGED_USER}"

###############################################################################
# FUNCTION: Remove MS-ORGANIZATION-ACCESS from user keychain
###############################################################################
delete_ms_organization_access() {
    local user_keychain="/Users/${LOGGED_USER}/Library/Keychains/login.keychain-db"

    if [[ ! -f "$user_keychain" ]]; then
        log_message "✗ User keychain not found: ${user_keychain}"
        update_dialog "✗ Keychain not found"
        return 1
    fi

    log_message "Searching for MS-ORGANIZATION-ACCESS certificate..."
    update_dialog "🔍 Searching for MS-ORGANIZATION-ACCESS..."

    KEY_INFO=$(security find-certificate -a "$user_keychain" 2>/dev/null)
    sleep 1

    if [[ -n "$KEY_INFO" ]]; then
        if echo "$KEY_INFO" | grep -qi "MS-ORGANIZATION-ACCESS"; then
            log_message "   ✓ MS-ORGANIZATION-ACCESS certificate found"
            update_dialog "🧹 Removing certificate..."

            CERT_INFO=$(echo "$KEY_INFO" | grep -B 10 "MS-ORGANIZATION-ACCESS" | grep '"alis"' | cut -d'"' -f4)

            if [[ -n "$CERT_INFO" ]]; then
                log_message "   Certificate name: ${CERT_INFO}"

                if /usr/bin/security delete-certificate -c "$CERT_INFO" "$user_keychain" >/dev/null 2>&1; then
                    log_message "   ✓ Certificate removed successfully"
                    update_dialog "✅ Certificate removed"
                    sleep 60
                    return 0
                else
                    log_message "   ✗ Failed to remove certificate — check permissions"
                    update_dialog "⚠ Failed to remove certificate"
                    return 1
                fi
            else
                log_message "   ⚠ Could not extract certificate name"
                update_dialog "⚠ Error extracting certificate name"
                return 1
            fi
        else
            log_message "   ✓ MS-ORGANIZATION-ACCESS certificate not found"
            update_dialog "✅ Certificate not found"
            return 0
        fi
    else
        log_message "   ✓ No certificates found in keychain"
        update_dialog "✅ Keychain empty"
        return 0
    fi
}

###############################################################################
# MAIN
###############################################################################
delete_ms_organization_access

log_message "========================================="
log_message "✓ CERTIFICATE CHECK COMPLETE"
log_message "========================================="

exit 0
