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

The main script (`main.sh`) automatically detects the current Mac state and runs only the steps required — no manual intervention needed.

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
│   ├── config.sh                        # Shared config — change COMPANY_NAME here
│   ├── main.sh                          # Main orchestrator — only entry point
│   ├── validate.sh                      # Step 1 — validates Mac state, detects MDM
│   ├── install_dependencies.sh          # Step 2 — installs swiftDialog
│   ├── remove_intune.sh                 # Step 3 — removes device via Graph API
│   ├── clean_certificates.sh            # Step 3b — removes MS-ORGANIZATION-ACCESS cert
│   ├── install_jamf.sh                  # Step 4 — enrolls Mac via ABM PreStage
│   ├── post_migration.sh                # Step 5 — recon, cleanup, log rotation
│   ├── notify_teams.sh                  # Sends Adaptive Cards to Teams webhook
│   ├── jq-macos-arm64                   # jq binary for Apple Silicon
│   └── jq-macos-amd64                   # jq binary for Intel
├── html/
│   ├── images/                          # Screenshots/GIFs shown in whats_new.html  ← add yours here
│   ├── index.html                       # User-facing portal — welcome page
│   ├── whats_new.html                   # What's changing
│   ├── benefits.html                    # Migration benefits
│   └── faq.html                         # Frequently asked questions
├── pkg/
│   ├── LaunchDaemon/
│   │   └── com.acme.mdm-migration.plist # LaunchDaemon — starts migration on install
│   └── scripts/
│       ├── postinstall                  # PKG post-install: keychain injection + permissions + daemon load
│       └── cleanup.sh                   # Self-destruct: removes all artifacts after migration completes
├── resources/
│   └── config/
│       ├── migration_config.json        # Credentials and configuration  ← edit this
│       └── dialog_list.json             # swiftDialog progress list structure
└── docs/
    ├── TECHNICAL_GUIDE.md               # Full technical reference for IT admins
    └── USER_GUIDE.md                    # End-user guide
```

---

## Configuration

### 0. Add images to the user portal

The `html/whats_new.html` page has slots for screenshots and screen recordings that illustrate each change to end users. The image tags are **commented out by default** — add your own files and uncomment the lines.

**1.** Create the folder `html/images/` and place your files there:

| File | Content |
|---|---|
| `images/login_sso.png` (or `.gif`) | Screenshot of the Jamf Connect login screen |
| `images/request_admin.mov` (or `.gif`) | Screen recording showing how to request admin access |
| `images/usb_block_message.png` | Screenshot of the USB blocked alert |
| `images/wallpaper.png` | Screenshot of the corporate wallpaper |

**2.** In `whats_new.html`, uncomment the corresponding line in each card and update the `src` to match your filename. Example:

```html
<!-- before -->
<!-- <img src="./images/login_sso.gif" alt="New login screen" onclick="showModal(this)"> -->

<!-- after -->
<img src="./images/login_sso.png" alt="New login screen" onclick="showModal(this)">
```

> Images are optional — each card displays its text content correctly even without a visual.

---

### 1. Set your company name

`COMPANY_NAME` is defined **once** in `bin/config.sh` and sourced by all scripts. Change it there only:

```bash
readonly COMPANY_NAME="ACME"   # <── change this once
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

> The service name (`MDMMigrationService`) and account (`IntuneAuth`) are configured in `remove_intune.sh` via the `KEYCHAIN_SERVICE` and `KEYCHAIN_ACCOUNT` variables. Change them if needed.

> ⚠️ Never commit secrets to the repository.

---

## How to Run

The script must be run as root. In production, deploy it via a **Jamf Policy**, **Apple Remote Desktop**, or an MDM-managed package:

```bash
sudo bash "/Library/Application Support/ACME MDM Migration/bin/main.sh"
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
main.sh
│
├── Resume check (reads migration_state.json on every start)
│     ├── completed      → exit immediately, nothing to do
│     ├── jamf_enrolled  → skip Steps 1–4, resume at Step 5
│     ├── intune_removed → skip Steps 1–3, resume at Step 4
│     └── empty / needs_migration → full flow below
│
├── [Step 1] validate.sh
│     ├── exit 0  → Already in Jamf ──────────────────► post-migration → done
│     ├── exit 10 → On Intune       → full migration flow
│     ├── exit 20 → No MDM          → skip removal, enroll in Jamf
│     └── exit 1  → Error           → abort
│
├── [Step 2] install_dependencies.sh
│     └── Downloads swiftDialog from GitHub Releases
│         Verifies PKG signature (Team ID: PWA5E9TQ59)
│         Skips if installed version already meets minimum (v2.3.0)
│
├── [Step 3] remove_intune.sh  (only if exit 10)
│     ├── OAuth 2.0 → Microsoft Graph API
│     ├── Finds device by serial number
│     ├── POST /managedDevices/{id}/retire
│     ├── Writes migration_status = "intune_removed" ← resume point
│     ├── Monitors MDM profile removal (timeout: 600s, token auto-refresh)
│     └── clean_certificates.sh
│           └── Removes MS-ORGANIZATION-ACCESS from user keychain
│
├── [Step 4] install_jamf.sh
│     ├── profiles renew -type enrollment
│     └── Monitors enrollment (20 attempts × 30s = up to 10 min)
│
└── [Step 5] post_migration.sh
      ├── jamf recon
      ├── Temporary file cleanup
      ├── Log rotation (max 10 MB / 7 days)
      └── Schedules self-removal of migration folder
```

### Resume after unexpected restart

If the Mac restarts mid-migration (power loss, forced reboot), the LaunchDaemon starts `main.sh` again automatically. The script reads `migration_status` from `migration_state.json` and resumes from the correct step:

| `migration_status` | Behavior on restart |
|---|---|
| _(empty or file missing)_ | Starts from Step 1 |
| `needs_migration` | Starts from Step 1 |
| `intune_removed` | **Skips to Step 4** — Intune already removed |
| `jamf_enrolled` | **Skips to Step 5** — runs post-migration only |
| `completed` | Exits immediately — nothing to do |

---

## Customization

### Changing the MDM enrollment wait time

In `install_jamf.sh`, adjust the `checks` and `interval` variables:

```bash
local checks=20    # number of attempts
local interval=30  # seconds between attempts (total: 10 min)
```

### Using a different notification channel

The `notify_teams.sh` script sends Microsoft Teams Adaptive Cards. To use a different notification system, replace the `send_notification()` function with your preferred method (Slack, webhook, email, etc.).

### Customizing the user-facing portal

Edit the HTML files in `html/` to match your company branding, logo, and messaging. The pages are loaded by swiftDialog via the `--infobuttonaction` parameter in `main.sh`.

### State file location

The migration state is written to:
```
/Library/Application Support/<COMPANY_NAME> MDM Migration/migration_state.json
```

Possible `migration_status` values:

| Value | Description | Resume behavior |
|---|---|---|
| `already_in_jamf` | Mac was already in Jamf at start | Runs post-migration only |
| `needs_migration` | Intune detected, migration required | Starts from Step 1 |
| `no_mdm_enroll_jamf` | No MDM detected, will enroll directly | Starts from Step 1 |
| `intune_removed` | Intune removed successfully | **Resumes at Step 4** |
| `jamf_enrolled` | Enrolled in Jamf successfully | **Resumes at Step 5** |
| `completed` | Post-migration finalized | Exits immediately |
| `unknown_mdm` | Unrecognized MDM — manual action required | Aborts |

---

## Packaging

The tool is distributed as a macOS **PKG** built with **Jamf Composer**. The PKG installs all files, injects the Intune `client_secret` into the System Keychain, and automatically starts the migration via a LaunchDaemon.

| File | Role |
|---|---|
| `resources/com.acme.mdm.migration.plist` | LaunchDaemon — starts `main.sh` as root on install |
| `pkg/postinstall` | PKG post-install script — sets permissions, writes secret to keychain, loads daemon |
| `pkg/cleanup.sh` | Self-destruct — removes the LaunchDaemon and migration folder after the process completes |

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