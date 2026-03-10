#!/bin/bash

###############################################################################
# notificar_teams.sh
# Sends notifications to Microsoft Teams via Adaptive Cards webhook
#
# Version: 1.3
#
# Parameters:
#   $1 - Status: "started" | "completed" | "failure"
#   $2 - Error message (only for "failure" status)
#
# Exit Codes:
#   0 - Success
#   1 - Error
#
# Setup:
#   Set the Teams webhook URL in resources/config/migration_config.json
#   under .intune.teams_webhook_url
###############################################################################

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME" # <── change this
readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
# ──────────────────────────────────────────────────────────────────────────────

readonly LOGS_DIR="${BASE_DIR}/logs"
readonly MAIN_LOG="${LOGS_DIR}/migration.log"
readonly STATE_FILE="${BASE_DIR}/migration_state.json"
readonly CONFIG_FILE="${BASE_DIR}/resources/config/migration_config.json"

JQ_BIN="${JQ_BIN:-}"

if [[ ! -d "${LOGS_DIR}" ]]; then
    mkdir -p "${LOGS_DIR}"
fi

log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" | tee -a "${MAIN_LOG}"
}

detect_jq_if_needed() {
    if [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then return 0; fi
    local arch=$(uname -m)
    if [[ "$arch" == "arm64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-arm64"
    elif [[ "$arch" == "x86_64" ]]; then
        JQ_BIN="${BASE_DIR}/bin/jq-macos-amd64"
    else
        log_message "⚠ Unsupported architecture"
        return 1
    fi
    if [[ -f "${JQ_BIN}" ]]; then
        chmod +x "${JQ_BIN}" 2>/dev/null || true
        export JQ_BIN
        return 0
    fi
    log_message "⚠ jq not found: ${JQ_BIN}"
    return 1
}

###############################################################################
# INITIALIZATION
###############################################################################
if [[ -z "$1" ]]; then
    log_message "✗ Error: status not provided to notificar_teams.sh"
    exit 1
fi

readonly status="$1"
readonly error_message="${2:-"Not specified"}"
webhook_url=""

detect_jq_if_needed

###############################################################################
# FUNCTION: Read webhook URL from config
###############################################################################
read_webhook_url() {
    if [[ -f "${CONFIG_FILE}" ]] && [[ -n "${JQ_BIN}" ]] && [[ -f "${JQ_BIN}" ]]; then
        webhook_url=$("${JQ_BIN}" -r '.intune.teams_webhook_url // ""' "${CONFIG_FILE}")
    fi

    if [[ -z "${webhook_url}" ]]; then
        log_message "⚠ Teams webhook URL not configured — skipping notification"
        return 1
    fi
    return 0
}

###############################################################################
# FUNCTION: Build and send Adaptive Card
###############################################################################
send_notification() {
    log_message "Sending Teams notification: ${status}"

    local os_version=$(sw_vers -productVersion)
    local computer_name=$(scutil --get ComputerName 2>/dev/null || hostname)
    local serial=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
    local logged_user=$(stat -f "%Su" /dev/console 2>/dev/null || echo "N/A")

    local start_date=$(awk 'NR==1 {print $1, $2}' "${MAIN_LOG}" | tr -d '[]')
    local end_date="In progress..."
    local duration="N/A"

    if [[ "$status" != "started" ]]; then
        end_date=$(date '+%Y-%m-%d %H:%M:%S')
        local start_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S" "$start_date" "+%s" 2>/dev/null)
        local end_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S" "$end_date" "+%s" 2>/dev/null)
        if [[ -n "$start_seconds" ]] && [[ -n "$end_seconds" ]]; then
            local diff_seconds=$((end_seconds - start_seconds))
            duration="${diff_seconds}s"
        fi
    fi

    local title=""
    local error_section=""

    case "$status" in
    started) title="🚀 Migration Started" ;;
    completed) title="✅ Migration Completed Successfully" ;;
    failure)
        title="❌ Migration Failed"
        error_section=$(
            cat <<EOF
,
{
    "type": "TextBlock",
    "text": "**Error**",
    "weight": "Bolder"
},
{
    "type": "TextBlock",
    "text": "${error_message}",
    "wrap": true
}
EOF
        )
        ;;
    esac

    local adaptive_card_payload
    adaptive_card_payload=$(
        cat <<EOF
{
    "type": "message",
    "attachments": [
        {
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "body": [
                    {
                        "type": "TextBlock",
                        "text": "${title}",
                        "weight": "Bolder",
                        "size": "Large"
                    }
                    ${error_section}
                    ,
                    {
                        "type": "FactSet",
                        "facts": [
                            { "title": "Computer:", "value": "${computer_name}" },
                            { "title": "Serial:",   "value": "${serial}" },
                            { "title": "User:",     "value": "${logged_user}" },
                            { "title": "Start:",    "value": "${start_date}" },
                            { "title": "End:",      "value": "${end_date}" },
                            { "title": "Duration:", "value": "${duration}" }
                        ]
                    }
                ]
            }
        }
    ]
}
EOF
    )

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "${adaptive_card_payload}" "${webhook_url}")

    if [[ "$response" -eq 200 ]]; then
        log_message "✓ Teams notification sent successfully"
        return 0
    else
        log_message "✗ Failed to send notification (HTTP: ${response})"
        return 1
    fi
}

###############################################################################
# MAIN
###############################################################################
read_webhook_url || exit 1
send_notification || exit 1
exit 0
