#!/bin/bash
##
## limpeza_final.sh
##
## Self-destruct script — removes all migration artifacts after the process
## completes. Called asynchronously by pos_migracao.sh via nohup so that it
## runs after the main script has already exited.
##
## Removes:
##   - The LaunchDaemon (unloads + deletes the plist)
##   - The entire migration folder under /Library/Application Support/
##   - Itself (this script, staged in /private/tmp/)
##
## ── CONFIGURATION ─────────────────────────────────────────────────────────────
readonly COMPANY_NAME="ACME" # <── change this
readonly BASE_DIR="/Library/Application Support/${COMPANY_NAME} MDM Migration"
readonly PLIST_NAME="com.acme.mdm.migration" # <── match your plist Label
readonly PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}.plist"
# ──────────────────────────────────────────────────────────────────────────────

# Give the main script time to finish writing logs before we delete everything
sleep 10

echo "[limpeza_final] Starting cleanup..."

# 1. Unload and remove the LaunchDaemon
if [[ -f "${PLIST_PATH}" ]]; then
    /bin/launchctl bootout system "${PLIST_PATH}" 2>/dev/null || true
    rm -f "${PLIST_PATH}"
    echo "[limpeza_final] ✓ LaunchDaemon removed"
fi

# 2. Remove the migration folder (logs, state file, scripts, binaries)
if [[ -d "${BASE_DIR}" ]]; then
    rm -rf "${BASE_DIR}"
    echo "[limpeza_final] ✓ Migration folder removed"
fi

echo "[limpeza_final] ✓ Cleanup complete"

# 3. Self-destruct — remove this script
rm -f "$0"
