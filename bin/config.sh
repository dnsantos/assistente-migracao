#!/bin/bash
##
## config.sh
##
## Shared configuration loaded by all migration scripts via:
##   source "${SCRIPT_DIR}/config.sh"
##
## Change COMPANY_NAME and keychain identifiers here — nowhere else.
##

# ── CHANGE THESE ──────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME"
readonly KEYCHAIN_SERVICE="MDMMigrationService"
readonly KEYCHAIN_ACCOUNT="IntuneAuth"
# ──────────────────────────────────────────────────────────────────────────────

readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
readonly BIN_DIR="${BASE_DIR}/bin"
readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migration.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly CONFIG_FILE="${BASE_DIR}/resources/config/migration_config.json"
readonly DIALOG_BIN="/usr/local/bin/dialog"
readonly DIALOG_LOG="/var/tmp/dialog_migration.log"
readonly PROFILES_CMD="/usr/bin/profiles"
readonly JAMF_BINARY="/usr/local/bin/jamf"
readonly CLEANUP_SCRIPT="/private/tmp/cleanup.sh"

# Ensure log directory exists
[[ ! -d "${LOGS_DIR}" ]] && mkdir -p "${LOGS_DIR}"

###############################################################################
# SHARED: Logging
###############################################################################
log_message() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

###############################################################################
# SHARED: Detect jq binary by architecture
###############################################################################
detect_jq() {
    # Re-use inherited JQ_BIN if already set and valid
    if [[ -n "${JQ_BIN:-}" ]] && [[ -f "${JQ_BIN}" ]]; then
        return 0
    fi

    local arch
    arch=$(uname -m)

    case "$arch" in
        arm64)   JQ_BIN="${BIN_DIR}/jq-macos-arm64" ;;
        x86_64)  JQ_BIN="${BIN_DIR}/jq-macos-amd64" ;;
        *)
            log_message "⚠ Unsupported architecture: ${arch}"
            return 1
            ;;
    esac

    if [[ ! -f "${JQ_BIN}" ]]; then
        log_message "⚠ jq binary not found: ${JQ_BIN}"
        return 1
    fi

    chmod +x "${JQ_BIN}" 2>/dev/null || true
    export JQ_BIN
    return 0
}

###############################################################################
# SHARED: Update a field in the JSON state file
###############################################################################
update_state() {
    local field="$1"
    local value="$2"

    [[ ! -f "${STATE_FILE}" ]] && return 0

    if [[ -n "${JQ_BIN:-}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local tmp="${STATE_FILE}.tmp"
        "${JQ_BIN}" --arg v "$value" ".${field} = \$v" "${STATE_FILE}" > "${tmp}" 2>/dev/null \
            && mv "${tmp}" "${STATE_FILE}"
    else
        sed -i '' "s/\"${field}\": \"[^\"]*\"/\"${field}\": \"${value}\"/" "${STATE_FILE}" 2>/dev/null || true
    fi
}

###############################################################################
# SHARED: Write to swiftDialog command pipe
###############################################################################
send_dialog() {
    [[ -f "${DIALOG_LOG}" ]] && echo "$1" >> "${DIALOG_LOG}"
}

###############################################################################
# SHARED: Root check
###############################################################################
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "✗ This script must be run as root"
        exit 1
    fi
}
