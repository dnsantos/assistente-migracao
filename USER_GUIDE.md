# User Guide — Mac MDM Migration

> **Audience:** End users whose Macs will be migrated  
> **Process:** Intune → Jamf Pro  

---

## What is happening?

Your Mac is being migrated to a new device management platform. This change strengthens security, simplifies IT support, and improves your day-to-day experience.

The migration is **automatic** — you don't need to do anything technical. The process runs in the background and takes approximately **15–30 minutes**. You can **continue using your Mac normally** while it runs.

---

## Before the migration — checklist

Please complete the following **before the migration starts**:

- [ ] **Save all open files** — although no restart is forced during migration, it is good practice
- [ ] **Back up important files** to OneDrive or another cloud storage solution
- [ ] **Check your password** — after migration, your Mac password must sync with your corporate account. Passwords containing the characters **`~ ` ' " ^`** or very long passwords may cause login issues. Change yours at the Microsoft portal if needed
- [ ] **Connect to your corporate network or VPN** — required for the migration to reach Microsoft and Jamf servers
- [ ] **Plug in your charger** — the process takes up to 30 minutes; avoid running it on battery only

---

## What to expect during the migration

Once the migration starts, a progress window will appear on your screen:

| Step | What is happening |
|---|---|
| **1. Validation** | Checking your Mac's current state |
| **2. Install Dependencies** | Downloading the progress interface tool |
| **3. Remove Intune** | Your Mac is being retired from Microsoft Intune |
| **4. Enroll in Jamf** | Your Mac is enrolling in the new management platform |
| **5. Finalization** | Cleaning up and updating the inventory |

> Each step updates in real time. You can minimize the window and continue working.

---

## What changes after the migration

### 🔐 Login with Jamf Connect

After the migration, your next Mac login will use **Jamf Connect**, which keeps your Mac password synchronized with your corporate account. Simply enter your usual corporate credentials (same as Microsoft 365 / Outlook).

> **Important:** If your password contains `~ ` ' " ^` or is unusually long, change it at the Microsoft portal before your next login.

---

### 🛡️ Temporary admin access

You are no longer a permanent administrator on your Mac. Admin access is granted **on demand, for 5 minutes**, via Jamf Connect.

**How to request admin access:**

1. Click the **Jamf Connect** icon in the menu bar (top-right of your screen)
2. Select **"Request Admin Privileges"**
3. Enter the reason for your request
4. You will have admin access for **5 minutes**

This keeps your Mac secure without blocking your work.

---

### 🚫 USB devices

Unauthorized USB storage devices (flash drives, external hard drives) are **blocked automatically** to protect corporate data. An alert will appear on your screen if you plug one in.

If you need access to a specific USB device for work, contact IT support to request an exception.

---

### 🖼️ Wallpaper

Your Mac will display the **company wallpaper** after migration. Custom wallpaper changes are managed by policy and cannot be changed by users.

---

## Frequently Asked Questions

**How do I log in after the migration?**  
Use your existing corporate credentials (same as Outlook / Microsoft 365). Jamf Connect handles the login and keeps your password in sync.

---

**I forgot my password or can't log in. What do I do?**  
Reset your password at the Microsoft portal (Office / Outlook settings), then restart your Mac. Jamf Connect will sync the new password automatically. If you remain locked out, contact IT support.

---

**I'm no longer an admin — how do I install apps?**  
Use the **Jamf Connect** menu bar icon to request temporary admin access (5 minutes). This is sufficient for most installations.

---

**My USB drive is blocked. What should I do?**  
Contact IT support and explain your use case. The team can grant an exception for specific devices if needed.

---

**Will my files be deleted during the migration?**  
No. Local files are not touched during the migration. However, we recommend backing up to OneDrive as a precaution before the process starts.

---

**Will my Mac restart during the migration?**  
The migration itself does not force a restart. After enrollment, Jamf Pro may push a policy that requests a restart. Follow the on-screen instructions if prompted.

---

**The migration seems stuck. What should I do?**  
Some steps (especially removing Intune) can take up to 10 minutes while waiting for Microsoft servers to respond. If the window shows no progress for more than **20 minutes**, contact IT support and share the log file located at:

```
/Library/Application Support/<COMPANY_NAME> MDM Migration/logs/migration.log
```

---

**What information does the new management platform see?**  
The management platform only monitors corporate security configurations (encryption, MDM enrollment, security policies). It does not access your personal files, messages, browser history, or camera.

---

## Need help?

Contact your IT support team and provide:
- Your Mac's serial number (`Apple menu → About This Mac → More Info`)
- The log file at `/Library/Application Support/<COMPANY_NAME> MDM Migration/logs/migration.log`