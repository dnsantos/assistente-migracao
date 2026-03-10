#!/bin/bash
set -euo pipefail

###############################################################################
# validate.sh
# Validates the current Mac state and determines migration path
#
# Version: 1.2
#
# Exit Codes:
#   0  - Mac is already enrolled in Jamf Pro (no action needed)
#   1  - Error (not root, incompatible macOS, or unknown MDM)
#   10 - Mac is on Intune → full migration required
#   20 - No MDM active → enroll directly in Jamf
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

require_root

log_message "========================================="
log_message "MAC STATE VALIDATION"
log_message "========================================="

detect_jq || true  # jq optional at this stage

# 1. macOS version
log_message "1. Checking macOS version..."
OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
log_message "   macOS version: ${OS_VERSION}"

if [[ $OS_MAJOR -lt 11 ]]; then
    log_message "✗ macOS 11 (Big Sur) or later required. Current: ${OS_VERSION}"
    exit 1
fi
log_message "✓ macOS version compatible"

# 2. Disk space check
log_message "2. Checking available disk space..."
AVAILABLE_SPACE_MB=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
readonly MIN_SPACE_MB=200
log_message "   Available: ${AVAILABLE_SPACE_MB} MB (minimum required: ${MIN_SPACE_MB} MB)"

if [[ ${AVAILABLE_SPACE_MB:-0} -lt $MIN_SPACE_MB ]]; then
    log_message "✗ Insufficient disk space: ${AVAILABLE_SPACE_MB} MB available, ${MIN_SPACE_MB} MB required"
    exit 1
fi
log_message "✓ Disk space OK"

# 3. Detect MDM
log_message "3. Checking MDM enrollment..."
MDM_ENROLLMENT=$("${PROFILES_CMD}" status -type enrollment 2>/dev/null || true)

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

cat > "${STATE_FILE}" << EOF
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

log_message "========================================="

# CASE 1: Already in Jamf
if [[ "${MDM_TYPE}" == "jamf" ]]; then
    log_message "✓ VALIDATION PASSED — Mac already enrolled in Jamf Pro"
    update_state "migration_status" "already_in_jamf"
    exit 0
fi

# CASE 2: On Intune → full migration
if [[ "${MDM_TYPE}" == "intune" ]]; then
    log_message "✓ VALIDATION PASSED — Mac is on Intune — migration required"
    local_tmp="${STATE_FILE}.tmp"
    if [[ -n "${JQ_BIN:-}" ]] && [[ -f "${JQ_BIN}" ]]; then
        "${JQ_BIN}" '.needs_migration = true | .migration_status = "needs_migration"' \
            "${STATE_FILE}" > "${local_tmp}" 2>/dev/null && mv "${local_tmp}" "${STATE_FILE}"
    else
        sed -i '' 's/"needs_migration": false/"needs_migration": true/' "${STATE_FILE}" 2>/dev/null || true
        sed -i '' 's/"migration_status": ""/"migration_status": "needs_migration"/' "${STATE_FILE}" 2>/dev/null || true
    fi
    exit 10
fi

# CASE 3: Unknown MDM
if [[ "${MDM_TYPE}" == "unknown" ]]; then
    log_message "✗ VALIDATION FAILED — Unknown MDM: ${MDM_SERVER}"
    log_message "  This tool only supports Intune or unmanaged Macs"
    update_state "migration_status" "unknown_mdm"
    exit 1
fi

# CASE 4: No MDM
log_message "⚠ VALIDATION — No active MDM — will enroll directly in Jamf"
update_state "migration_status" "no_mdm_enroll_jamf"
exit 20
