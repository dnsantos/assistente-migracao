#!/bin/bash

###############################################################################
# validacao_pre_migracao.sh
# Validates the current Mac state and determines migration path
#
# Version: 1.1
#
# Exit Codes:
#   0  - Mac is already enrolled in Jamf Pro (no action needed)
#   1  - Error (not root, incompatible macOS, or unknown MDM)
#   10 - Mac is on Intune → full migration required
#   20 - No MDM active → enroll directly in Jamf
###############################################################################

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME" # <── change this
readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
# ──────────────────────────────────────────────────────────────────────────────

readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migration.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly PROFILES_CMD="/usr/bin/profiles"

JQ_BIN="${JQ_BIN:-}"

if [[ ! -d "${LOGS_DIR}" ]]; then
    mkdir -p "${LOGS_DIR}"
else
    rm -f "${MAIN_LOG}" 2>/dev/null || true
fi

###############################################################################
# FUNCTION: Detect jq if not inherited
###############################################################################
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

log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

###############################################################################
# VALIDATIONS
###############################################################################
log_message "========================================="
log_message "MAC STATE VALIDATION"
log_message "========================================="

detect_jq_if_needed

# 1. Root check
log_message "1. Checking permissions..."
if [[ $EUID -ne 0 ]]; then
    log_message "✗ This script must be run as root"
    exit 1
fi
log_message "✓ Running as root"

# 2. macOS version
log_message "2. Checking macOS version..."
OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
log_message "   macOS version: ${OS_VERSION}"

if [[ $OS_MAJOR -lt 11 ]]; then
    log_message "✗ macOS 11 (Big Sur) or later required. Current: ${OS_VERSION}"
    exit 1
fi
log_message "✓ macOS version compatible"

# 3. Detect MDM
log_message "3. Checking MDM enrollment..."
MDM_ENROLLMENT=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null)

MDM_ENROLLED=false
MDM_SERVER=""
MDM_TYPE="none"

if echo "${MDM_ENROLLMENT}" | grep -q "MDM enrollment: Yes"; then
    MDM_ENROLLED=true
    MDM_SERVER=$(echo "${MDM_ENROLLMENT}" | grep "MDM server:" | cut -d: -f2- | xargs)
    log_message "   MDM Enrollment: Yes"
    log_message "   MDM Server: ${MDM_SERVER}"

    if echo "${MDM_SERVER}" | grep -qi "jamf"; then
        MDM_TYPE="jamf"
        log_message "✓ Detected: Jamf Pro"
    elif echo "${MDM_SERVER}" | grep -qi "microsoft\|intune\|manage.microsoft.com"; then
        MDM_TYPE="intune"
        log_message "✓ Detected: Microsoft Intune"
    else
        MDM_TYPE="unknown"
        log_message "⚠ Unknown MDM: ${MDM_SERVER}"
    fi

    if echo "${MDM_ENROLLMENT}" | grep -q "User Approved"; then
        log_message "   User Approved: Yes"
    else
        log_message "⚠ MDM is not User Approved — user interaction may be required"
    fi
else
    log_message "   MDM Enrollment: No"
fi

# 4. Create state file
log_message "4. Creating state file..."
CURRENT_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "none")
AVAILABLE_SPACE=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')

cat >"${STATE_FILE}" <<EOF
{
    "validation_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "os_version": "${OS_VERSION}",
    "current_user": "${CURRENT_USER}",
    "disk_space_gb": ${AVAILABLE_SPACE:-0},
    "mdm_enrolled": ${MDM_ENROLLED},
    "mdm_server": "${MDM_SERVER}",
    "mdm_type": "${MDM_TYPE}",
    "needs_migration": false,
    "migration_status": ""
}
EOF
log_message "✓ State file created: ${STATE_FILE}"

###############################################################################
# FUNCTION: Update state using jq
###############################################################################
update_state_with_jq() {
    local field="$1"
    local value="$2"

    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        local temp_file="${STATE_FILE}.tmp"
        "${JQ_BIN}" ".${field} = \"${value}\"" "${STATE_FILE}" >"${temp_file}" 2>/dev/null
        if [[ -f "${temp_file}" ]]; then
            mv "${temp_file}" "${STATE_FILE}"
            return 0
        fi
    fi
    # Fallback
    sed -i '' "s/\"${field}\": \"[^\"]*\"/\"${field}\": \"${value}\"/" "${STATE_FILE}" 2>/dev/null || true
}

###############################################################################
# DECISION LOGIC
###############################################################################
log_message "========================================="

# CASE 1: Already in Jamf
if [[ "${MDM_TYPE}" == "jamf" ]]; then
    log_message "✓ VALIDATION PASSED — Mac already enrolled in Jamf Pro"
    log_message "  Server: ${MDM_SERVER}"
    log_message "  No action required"
    update_state_with_jq "migration_status" "already_in_jamf"
    exit 0
fi

# CASE 2: On Intune → full migration
if [[ "${MDM_TYPE}" == "intune" ]]; then
    log_message "✓ VALIDATION PASSED — Mac is on Intune"
    log_message "  Migration to Jamf Pro required"

    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        temp_file="${STATE_FILE}.tmp"
        "${JQ_BIN}" '.needs_migration = true | .migration_status = "needs_migration"' \
            "${STATE_FILE}" >"${temp_file}" 2>/dev/null
        [[ -f "${temp_file}" ]] && mv "${temp_file}" "${STATE_FILE}"
    else
        sed -i '' 's/"needs_migration": false/"needs_migration": true/' "${STATE_FILE}" 2>/dev/null || true
        sed -i '' 's/"migration_status": ""/"migration_status": "needs_migration"/' "${STATE_FILE}" 2>/dev/null || true
    fi
    exit 10
fi

# CASE 3: Unknown MDM
if [[ "${MDM_TYPE}" == "unknown" ]]; then
    log_message "✗ VALIDATION FAILED — Unknown MDM detected"
    log_message "  Server: ${MDM_SERVER}"
    log_message "  This tool only supports Intune or unmanaged Macs"
    update_state_with_jq "migration_status" "unknown_mdm"
    exit 1
fi

# CASE 4: No MDM → enroll directly in Jamf
log_message "⚠ VALIDATION — No active MDM"
log_message "  Mac will be enrolled directly in Jamf Pro"
update_state_with_jq "migration_status" "no_mdm_enroll_jamf"
exit 20
