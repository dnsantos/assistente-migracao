# Technical Guide — Mac MDM Migration

> **Audience:** IT administrators and system engineers  
> **Tool:** mac-mdm-migration · Intune → Jamf Pro  
> **Version:** 1.1

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Directory Structure](#directory-structure)
4. [Configuration](#configuration)
5. [Provisioning the Client Secret](#provisioning-the-client-secret)
6. [Execution Flow](#execution-flow)
7. [Exit Codes](#exit-codes)
8. [State File Reference](#state-file-reference)
9. [Logs](#logs)
10. [swiftDialog Command Pipe](#swiftdialog-command-pipe)
11. [Troubleshooting](#troubleshooting)

---

## Overview

**mac-mdm-migration** automates the migration of corporate Macs from Microsoft Intune to Jamf Pro. The process runs headlessly, with a visual progress interface via [swiftDialog](https://github.com/swiftDialog/swiftDialog) and real-time notifications to a Microsoft Teams channel.

The entry point is always `migracao_principal.sh`. It detects the current Mac state and runs only the required steps.

---

## Prerequisites

| Requirement | Details |
|---|---|
| macOS | 11 (Big Sur) or later |
| Execution context | Must run as **root** (Jamf Policy, ARD, or equivalent) |
| Apple Business Manager | Mac must be registered in ABM |
| Jamf PreStage | Mac must be assigned to a PreStage Enrollment |
| Azure AD App | App Registration with `DeviceManagementManagedDevices.ReadWrite.All` |
| Network | Access to `login.microsoftonline.com`, `graph.microsoft.com`, `api.github.com`, and your Jamf server |
| Client Secret | Provisioned in System Keychain **before** execution |

---

## Directory Structure

```
/Library/Application Support/<COMPANY_NAME> MDM Migration/
├── bin/
│   ├── migracao_principal.sh        # Orchestrator — only entry point
│   ├── validacao_pre_migracao.sh    # Step 1 — Mac state detection
│   ├── instalar_dependencias.sh     # Step 2 — swiftDialog install
│   ├── remover_intune.sh            # Step 3 — Graph API retire
│   ├── limpar_certificados_ms.sh    # Step 3b — removes MS-ORGANIZATION-ACCESS
│   ├── instalar_jamf.sh             # Step 4 — ABM PreStage enrollment
│   ├── pos_migracao.sh              # Step 5 — recon, cleanup, log rotation
│   ├── notificar_teams.sh           # Teams Adaptive Card notifications
│   ├── jq-macos-arm64               # Bundled jq binary (Apple Silicon)
│   └── jq-macos-amd64               # Bundled jq binary (Intel)
├── html/
│   ├── index.html                   # User-facing portal — welcome page
│   ├── novidades.html               # What's changing
│   ├── beneficios.html              # Migration benefits
│   └── faq.html                     # Frequently asked questions
├── resources/
│   └── config/
│       ├── migration_config.json    # Credentials and settings  ← edit this
│       └── dialog_list.json         # swiftDialog progress list
├── logs/
│   └── migration.log                # Main execution log
└── migration_state.json             # Runtime state file
```

> The base path is controlled by `COMPANY_NAME` in each script (default: `ACME`). Change it once and all paths update automatically.

---

## Configuration

Edit `resources/config/migration_config.json` before deployment:

```json
{
  "intune": {
    "tenant_id":         "YOUR_TENANT_ID",
    "client_id":         "YOUR_CLIENT_ID",
    "teams_webhook_url": "https://outlook.office.com/webhook/...",
    "removal_timeout":   300
  },
  "organization": {
    "name":               "ACME Corp",
    "notification_email": "it-support@acme.com"
  },
  "settings": {
    "debug_mode": false,
    "log_level":  "info"
  }
}
```

> ⚠️ **Never store `client_secret` in the JSON file.** Use the System Keychain (see next section).

---

## Provisioning the Client Secret

The `client_secret` must be stored in the **System Keychain** on each target Mac before the migration runs. The Keychain service name and account are configured via variables in `remover_intune.sh`:

```bash
readonly KEYCHAIN_SERVICE="MDMMigrationService"   # <── change if needed
readonly KEYCHAIN_ACCOUNT="IntuneAuth"             # <── change if needed
```

To provision the secret (run as root, or push via Jamf Policy):

```bash
security add-generic-password \
  -s "MDMMigrationService" \
  -a "IntuneAuth" \
  -w "YOUR_CLIENT_SECRET" \
  /Library/Keychains/System.keychain
```

> To verify the secret is present without revealing it:
> ```bash
> security find-generic-password -s "MDMMigrationService" -a "IntuneAuth" /Library/Keychains/System.keychain
> ```

---

## Execution Flow

```
migracao_principal.sh
│
├── [Step 1] validacao_pre_migracao.sh
│     ├── exit 0  → Already in Jamf ──────────────────► pos_migracao → exit 0
│     ├── exit 10 → On Intune        → full migration flow
│     ├── exit 20 → No MDM           → skip removal, enroll in Jamf directly
│     └── exit 1  → Error            → abort, notify Teams
│
├── [Step 2] instalar_dependencias.sh  (only if Dialog not present)
│     └── Downloads swiftDialog from GitHub Releases
│         Verifies PKG signature (Team ID: PWA5E9TQ59)
│         Installs to /usr/local/bin/dialog
│
├── [Step 3] remover_intune.sh  (only on exit 10)
│     ├── OAuth2 client_credentials → Microsoft Graph token
│     ├── GET /managedDevices?$filter=serialNumber eq '<serial>'
│     ├── POST /managedDevices/{id}/retire  (HTTP 204 expected)
│     ├── Loop: profiles status -type enrollment (every 30s until MDM removed)
│     └── limpar_certificados_ms.sh
│           └── security delete-certificate MS-ORGANIZATION-ACCESS (user keychain)
│
├── [Step 4] instalar_jamf.sh
│     ├── profiles renew -type enrollment
│     └── Loop: check MDM enrollment (20 × 30s = up to 10 min)
│           └── Confirms MDM server contains "jamf"
│
└── [Step 5] pos_migracao.sh
      ├── jamf recon
      ├── Temporary file cleanup
      ├── Log rotation (max 10 MB / keeps 7 days)
      ├── notificar_teams.sh "completed" (async)
      └── Self-removal of migration folder (via nohup)
```

---

## Exit Codes

### `migracao_principal.sh`

| Code | Meaning |
|---|---|
| `0` | Migration completed successfully |
| `1` | Validation failure (see `validacao_pre_migracao.sh`) |
| `2` | Dependency installation failure |
| `3` | Intune removal failure |
| `4` | Jamf enrollment failure |

### `validacao_pre_migracao.sh`

| Code | Meaning |
|---|---|
| `0` | Mac already enrolled in Jamf Pro — no migration needed |
| `1` | Error (not root, incompatible macOS, or unknown MDM) |
| `10` | Mac is on Intune — full migration required |
| `20` | No active MDM — enroll directly in Jamf |

### `remover_intune.sh`

| Code | Meaning |
|---|---|
| `0` | Intune removed successfully |
| `1` | Credential or config error |
| `2` | Device not found in Intune |
| `3` | Retire API call failed |
| `4` | Timeout waiting for MDM profile removal |

---

## State File Reference

The state file is written and updated throughout the migration:

```
/Library/Application Support/<COMPANY_NAME> MDM Migration/migration_state.json
```

**Fields:**

| Field | Type | Description |
|---|---|---|
| `validation_date` | string (ISO 8601) | Timestamp of the validation step |
| `os_version` | string | macOS version detected at start |
| `current_user` | string | Logged-in user at time of execution |
| `disk_space_gb` | number | Available disk space in GB |
| `mdm_enrolled` | boolean | Whether MDM was active at validation |
| `mdm_server` | string | MDM server URL detected |
| `mdm_type` | string | `intune`, `jamf`, `none`, or `unknown` |
| `needs_migration` | boolean | Whether migration was required |
| `migration_status` | string | Current status (see values below) |
| `completion_date` | string (ISO 8601) | Set by `pos_migracao.sh` on success |

**`migration_status` values:**

| Value | Set by | Meaning |
|---|---|---|
| `already_in_jamf` | validacao | Mac was already in Jamf at start |
| `needs_migration` | validacao | Intune detected, migration required |
| `no_mdm_enroll_jamf` | validacao | No MDM — will enroll directly |
| `unknown_mdm` | validacao | Unrecognized MDM — requires manual intervention |
| `intune_removed` | remover_intune | Intune successfully retired |
| `jamf_enrolled` | instalar_jamf | Jamf enrollment confirmed |
| `completed` | pos_migracao | Post-migration finalized successfully |

---

## Logs

**Main log:**
```
/Library/Application Support/<COMPANY_NAME> MDM Migration/logs/migration.log
```

Log rotation is handled by `pos_migracao.sh`:
- Maximum size: **10 MB** (rotated with timestamp suffix)
- Retention: **7 days**

**Log format:**
```
[YYYY-MM-DD HH:MM:SS] message
```

**Status prefixes:**
- `✓` — success
- `✗` — failure / error
- `⚠` — warning (non-fatal)

---

## swiftDialog Command Pipe

After Step 2, the orchestrator controls swiftDialog via a named pipe:

```
/var/tmp/dialog_migration.log
```

**Commands used:**

```bash
# Update list item
echo "listitem: index: 2, status: wait, statustext: Removing Intune..." >> /var/tmp/dialog_migration.log
echo "listitem: index: 2, status: success, statustext: Done" >> /var/tmp/dialog_migration.log
echo "listitem: index: 2, status: fail, statustext: Failed" >> /var/tmp/dialog_migration.log

# Update main icon and message
echo "icon: SF=checkmark.circle.fill,color=green" >> /var/tmp/dialog_migration.log
echo "message: Migration completed!" >> /var/tmp/dialog_migration.log

# Show action button and close
echo "button1text: Done" >> /var/tmp/dialog_migration.log
echo "quit:" >> /var/tmp/dialog_migration.log
```

**List item indexes:**

| Index | Step |
|---|---|
| 0 | 1. Validation |
| 1 | 2. Install Dependencies |
| 2 | 3. Remove Intune |
| 3 | 4. Enroll in Jamf |
| 4 | 5. Finalization |

---

## Troubleshooting

### Migration fails at Step 1 (Validation)

**Symptom:** `✗ Validation failed` immediately  
**Check:**
- Is the script running as root? (`sudo` or Jamf Policy)
- macOS version is 11 or later? (`sw_vers -productVersion`)
- Review `migration.log` for the specific error

---

### Step 2 fails: swiftDialog not installed

**Symptom:** `✗ Failed to install swiftDialog`  
**Check:**
- Is the Mac connected to the internet?
- Can it reach `api.github.com`? (`curl -s https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest`)
- Check if the jq binary is present and executable:
  ```bash
  ls -la "/Library/Application Support/<COMPANY_NAME> MDM Migration/bin/"
  ```

---

### Step 3 fails: Device not found in Intune

**Symptom:** `✗ Device not found in Intune` (exit code 2)  
**Check:**
- Is the serial number correct? (`system_profiler SPHardwareDataType | grep Serial`)
- Is the device registered in Intune under that serial?
- Is the Azure AD app permission consented at the tenant level?

---

### Step 3 fails: Timeout waiting for MDM removal

**Symptom:** `✗ Timeout: enrollment not confirmed` (exit code 4 on remover_intune)  
**Check:**
- The retire command was acknowledged (HTTP 204 in the log) — Intune sends the command but delivery depends on the MDM check-in interval
- Increase `removal_timeout` in `migration_config.json` (default: 300s)
- Verify network connectivity to Microsoft endpoints

---

### Step 4 fails: Jamf enrollment timeout

**Symptom:** Enrollment check times out after 20 attempts  
**Check:**
- Is the Mac in Apple Business Manager?
- Is it assigned to the correct PreStage in Jamf?
- Try running `profiles renew -type enrollment` manually as root
- Check Jamf server connectivity: `curl -sk https://<your-jamf-server>/healthCheck.html`

---

### Teams notifications not sending

**Symptom:** Migration completes but no Teams message received  
**Check:**
- Is `teams_webhook_url` set in `migration_config.json`?
- Is the webhook URL still valid? (Teams webhooks can expire)
- Test manually:
  ```bash
  curl -X POST -H "Content-Type: application/json" \
    -d '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"Test"}]}}]}' \
    "YOUR_WEBHOOK_URL"
  ```

---

### Loop / header repeated hundreds of times in log

**Symptom:** The banner `MDM MIGRATION ASSISTANT` and `Step 1/5` repeat hundreds of times within the same second  
**Cause:** The main script is being called recursively (e.g., sourced instead of executed, or a `while` loop without `exec`)  
**Fix:** Ensure `migracao_principal.sh` is called with `bash /path/to/migracao_principal.sh` and **not** sourced with `.` or `source`