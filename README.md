# mac-mdm-migration

> Automated migration tool for corporate Macs from **Microsoft Intune** to **Jamf Pro**

![macOS](https://img.shields.io/badge/macOS-11%2B-blue?logo=apple) ![Shell](https://img.shields.io/badge/Shell-Bash-green?logo=gnubash) ![Version](https://img.shields.io/badge/version-1.1-lightgrey) ![License](https://img.shields.io/badge/license-MIT-blue)

---

## Table of Contents

- [Overview](#overview)
- [Supported Scenarios](#supported-scenarios)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [How to Run](#how-to-run)
- [Execution Flow](#execution-flow)
- [Customization](#customization)
- [Documentation](#documentation)
- [Dependencies](#dependencies)

---

## Overview

**mac-mdm-migration** is a set of Bash scripts that orchestrates the full migration of corporate Macs from Microsoft Intune to Jamf Pro. The process is fully automated, with a visual progress interface via [swiftDialog](https://github.com/swiftDialog/swiftDialog) and real-time notifications to a **Microsoft Teams** channel.

The main script (`migracao_principal.sh`) automatically detects the current Mac state and runs only the steps required — no manual intervention needed.

---

## Supported Scenarios

| Mac State | Action | Exit Code |
|---|---|---|
| Already enrolled in Jamf Pro | Runs post-migration cleanup and exits | `0` |
| Managed by Intune | Full flow: removes Intune → enrolls in Jamf | `10` (validation) |
| No MDM active | Cleans residual MS certificates → enrolls in Jamf | `20` (validation) |
| Unknown MDM | Aborts — requires manual intervention | `1` |

---

## Prerequisites

- macOS 11 (Big Sur) or later
- Must run as **root** (via Jamf Policy, ARD, or similar)
- Mac registered in **Apple Business Manager (ABM)**
- Mac assigned to a **Jamf PreStage Enrollment**
- **Azure AD App Registration** with `DeviceManagementManagedDevices.ReadWrite.All` permission
- `client_secret` provisioned in the System Keychain before execution (see [Configuration](#configuration))
- Network access to:
  - `login.microsoftonline.com`
  - `graph.microsoft.com`
  - `api.github.com`
  - Your Jamf Pro MDM server

---

## Project Structure

```
mac-mdm-migration/
├── bin/
│   ├── migracao_principal.sh        # Main orchestrator — only entry point
│   ├── validacao_pre_migracao.sh    # Step 1 — validates Mac state, detects MDM
│   ├── instalar_dependencias.sh     # Step 2 — installs swiftDialog
│   ├── remover_intune.sh            # Step 3 — removes device via Graph API
│   ├── limpar_certificados_ms.sh    # Step 3b — removes MS-ORGANIZATION-ACCESS cert
│   ├── instalar_jamf.sh             # Step 4 — enrolls Mac via ABM PreStage
│   ├── pos_migracao.sh              # Step 5 — recon, cleanup, log rotation
│   ├── notificar_teams.sh           # Sends Adaptive Cards to Teams webhook
│   ├── jq-macos-arm64               # jq binary for Apple Silicon
│   └── jq-macos-amd64               # jq binary for Intel
├── html/
│   ├── index.html                   # User-facing portal — welcome page
│   ├── novidades.html               # What's changing
│   ├── beneficios.html              # Migration benefits
│   └── faq.html                     # Frequently asked questions
├── resources/
│   └── config/
│       ├── migration_config.json    # Credentials and configuration  ← edit this
│       ├── dialog_list.json         # swiftDialog progress list structure
│       └── com.acme.mdm.migration.plist  # LaunchDaemon — starts migration on install
├── pkg/
│   ├── postinstall                  # PKG post-install script: keychain + permissions + daemon
│   └── limpeza_final.sh             # Self-destruct: removes all artifacts after migration
└── docs/
    ├── TECHNICAL_GUIDE.md           # Full technical reference for IT admins
    └── USER_GUIDE.md                # End-user guide
```

---

## Configuration

### 1. Set your company name

All scripts have a `COMPANY_NAME` variable at the top. Change it to match your organization:

```bash
readonly COMPANY_NAME="ACME"   # <── change this in every script
```

This controls the base directory:
```
/Library/Application Support/ACME MDM Migration/
```

### 2. Edit the config file

Fill in `resources/config/migration_config.json`:

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
  }
}
```

### 3. Provision the Client Secret in Keychain

The `client_secret` is **never stored in the JSON file**. Provision it in the System Keychain before deployment:

```bash
security add-generic-password \
  -s "MDMMigrationService" \
  -a "IntuneAuth" \
  -w "YOUR_CLIENT_SECRET" \
  /Library/Keychains/System.keychain
```

> The service name (`MDMMigrationService`) and account (`IntuneAuth`) are configured in `remover_intune.sh` via the `KEYCHAIN_SERVICE` and `KEYCHAIN_ACCOUNT` variables. Change them if needed.

> ⚠️ Never commit secrets to the repository.

---

## How to Run

The script must be run as root. In production, deploy it via a **Jamf Policy**, **Apple Remote Desktop**, or an MDM-managed package:

```bash
sudo bash "/Library/Application Support/ACME MDM Migration/bin/migracao_principal.sh"
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Migration completed successfully |
| `1` | Validation failure |
| `2` | Dependency installation failure |
| `3` | Intune removal failure |
| `4` | Jamf enrollment failure |

---

## Execution Flow

```
migracao_principal.sh
│
├── [Step 1] validacao_pre_migracao.sh
│     ├── exit 0  → Already in Jamf ──────────────────► post-migration → done
│     ├── exit 10 → On Intune       → full migration flow
│     ├── exit 20 → No MDM          → skip removal, enroll in Jamf
│     └── exit 1  → Error           → abort
│
├── [Step 2] instalar_dependencias.sh
│     └── Downloads swiftDialog from GitHub Releases
│         Verifies PKG signature (Team ID: PWA5E9TQ59)
│
├── [Step 3] remover_intune.sh  (only if exit 10)
│     ├── OAuth 2.0 → Microsoft Graph API
│     ├── Finds device by serial number
│     ├── POST /managedDevices/{id}/retire
│     └── Monitors MDM profile removal (loop until confirmed)
│         └── limpar_certificados_ms.sh
│               └── Removes MS-ORGANIZATION-ACCESS from user keychain
│
├── [Step 4] instalar_jamf.sh
│     ├── profiles renew -type enrollment
│     └── Monitors enrollment (20 attempts × 30s = up to 10 min)
│
└── [Step 5] pos_migracao.sh
      ├── jamf recon
      ├── Temporary file cleanup
      ├── Log rotation (max 10 MB / 7 days)
      └── Schedules self-removal of migration folder
```

---

## Customization

### Changing the MDM enrollment wait time

In `instalar_jamf.sh`, adjust the `checks` and `interval` variables:

```bash
local checks=20    # number of attempts
local interval=30  # seconds between attempts (total: 10 min)
```

### Using a different notification channel

The `notificar_teams.sh` script sends Microsoft Teams Adaptive Cards. To use a different notification system, replace the `send_notification()` function with your preferred method (Slack, webhook, email, etc.).

### Customizing the user-facing portal

Edit the HTML files in `html/` to match your company branding, logo, and messaging. The pages are loaded by swiftDialog via the `--infobuttonaction` parameter in `migracao_principal.sh`.

### State file location

The migration state is written to:
```
/Library/Application Support/<COMPANY_NAME> MDM Migration/migration_state.json
```

Possible `migration_status` values:

| Value | Description |
|---|---|
| `already_in_jamf` | Mac was already in Jamf at start |
| `needs_migration` | Intune detected, migration required |
| `intune_removed` | Intune removed successfully |
| `jamf_enrolled` | Enrolled in Jamf successfully |
| `completed` | Post-migration finalized |
| `unknown_mdm` | Unrecognized MDM — manual action required |

---

## Packaging

The tool is distributed as a macOS **PKG** built with **Jamf Composer**. The PKG installs all files, injects the Intune `client_secret` into the System Keychain, and automatically starts the migration via a LaunchDaemon.

| File | Role |
|---|---|
| `resources/com.acme.mdm.migration.plist` | LaunchDaemon — starts `migracao_principal.sh` as root on install |
| `pkg/postinstall` | PKG post-install script — sets permissions, writes secret to keychain, loads daemon |
| `pkg/limpeza_final.sh` | Self-destruct — removes the LaunchDaemon and migration folder after the process completes |

> For the full step-by-step build and deploy instructions, see the [Technical Guide — Packaging section](docs/TECHNICAL_GUIDE.md#packaging--building-the-pkg-with-jamf-composer).

---

## Documentation

| Document | Audience |
|---|---|
| [Technical Guide](docs/TECHNICAL_GUIDE.md) | IT administrators and system engineers |
| [User Guide](docs/USER_GUIDE.md) | End users whose Macs will be migrated |

Execution logs: `/Library/Application Support/<COMPANY_NAME> MDM Migration/logs/migration.log`

---

## Dependencies

| Dependency | Source | Notes |
|---|---|---|
| [swiftDialog](https://github.com/swiftDialog/swiftDialog) | Downloaded automatically | Visual progress UI |
| [jq](https://jqlang.github.io/jq/) | Bundled in `bin/` | arm64 and amd64 binaries included |
| curl | macOS native | API calls |
| profiles | macOS native | MDM management |
| security | macOS native | Keychain access |

---

## License

MIT — feel free to adapt this project to your organization's needs.