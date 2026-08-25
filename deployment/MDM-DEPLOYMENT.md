# Window Wrangler — Enterprise MDM Deployment

Instructions for deploying Window Wrangler to a managed Mac fleet with all permissions pre-granted, so end users never see a permission dialog.

## What you're distributing

Three artifacts land on managed Macs:

1. **`dist/WindowWrangler-<version>.pkg`** — the Developer-ID-Installer-signed installer package. Places `Window Wrangler.app` at `/Applications/Window Wrangler.app`. Notarized + stapled — Gatekeeper accepts it silently on Macs where MDM allows installer packages.
2. **`deployment/WindowWrangler-Accessibility-PPPC.mobileconfig`** — pre-approves the Accessibility permission Window Wrangler needs to enumerate and move windows across applications.
3. **`deployment/WindowWrangler-AppleEvents-PPPC.mobileconfig`** — pre-approves the Automation (Apple Events) permissions Window Wrangler needs to script installed browsers for Corral browser-tab capture, Recall browser-tab recreation, Plot Chromium native bounds, and Cascade Chromium native repair.

## Identity

- **Bundle ID:** `com.jmw3.WindowWrangler`
- **Team ID:** `7V4AJFNJKM`
- **Organization:** Northstar-Purpose Enterprises LLC
- **Install path (fixed by PKG):** `/Applications/Window Wrangler.app`
- **App type:** menu-bar utility (`LSUIElement=YES`) — no Dock icon, no main window.

## Designated requirement (Code Requirement used in PPPC)

```
anchor apple generic and identifier "com.jmw3.WindowWrangler" and (certificate leaf[field.1.2.840.113635.100.6.1.9] or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "7V4AJFNJKM")
```

This is the exact requirement `codesign -dr - "/Applications/Window Wrangler.app"` returns on a copy installed from the notarized PKG (with the `/* exists */` comments removed for schema validity — the semantics are unchanged).

## Deployment order

Deploy in this order to any managed Mac:

1. **PPPC profiles first.** Both `.mobileconfig` files. Order between the two doesn't matter; both must land before the user runs Cascade / Lasso / Corral for the first time.
2. **PKG second.** Once permissions are pre-granted, install the PKG. Window Wrangler will launch (typically at next login — it registers as a login item via user action, or the user launches it manually the first time).

If the PKG lands before the PPPC profiles, the user will see the standard permission dialogs the first time each protected feature runs. Not a functional failure — just defeats the point of profile-based pre-approval.

## Permissions granted by each profile

### `WindowWrangler-Accessibility-PPPC.mobileconfig`

| Service | Bundle | Result |
|---------|--------|--------|
| Accessibility | `com.jmw3.WindowWrangler` | Allowed |

Without this, every AX-based feature (Cascade, Lasso, Plot, Corral, Restore, Selection Cascade) hard-fails.

### `WindowWrangler-AppleEvents-PPPC.mobileconfig`

| Sender | Receiver | Result |
|--------|----------|--------|
| `com.jmw3.WindowWrangler` | `com.google.Chrome` (also covers Chrome Beta / Dev / Canary via the receiver's OR-clause) | Allowed |
| `com.jmw3.WindowWrangler` | `com.apple.Safari` | Allowed |

Ten other supported browsers (Brave, Edge, Opera, Vivaldi channels) are listed in [PPPC-AppleEvents-Receiver-Requirements.md](PPPC-AppleEvents-Receiver-Requirements.md) with instructions for capturing their real Code Requirements when the browsers are installed on a reference Mac. If those receivers are absent from the profile, Window Wrangler still functions with those browsers — the user will just see a one-time macOS permission dialog for each browser the first time it's scripted.

## Vendor guidance

The two `.mobileconfig` files are standard PPPC profiles using `com.apple.TCC.configuration-profile-policy`. Every major macOS MDM accepts them; the upload/assignment mechanics differ per platform.

- **Jamf Pro:** Computers → Configuration Profiles → Upload → select the `.mobileconfig` → scope to the target group. Repeat for each of the two profiles.
- **Kandji:** Library → Custom Profiles → Upload → select `.mobileconfig` → assign to Blueprint(s).
- **Microsoft Intune:** Devices → macOS → Configuration profiles → Create → Templates → Custom → Upload `.mobileconfig` → assign to group.
- **Mosyle:** Management → Profiles → Custom Profile → Upload `.mobileconfig` → assign to devices.
- **Any MDM implementing Apple's DDM / traditional profile channel:** upload as an arbitrary configuration profile.

No vendor-specific keys or extensions are used — the profiles are portable across all four platforms above.

## Distributing the PKG

Every MDM can install PKGs the same way it installs other software. Because the PKG is notarized and Developer-ID-Installer-signed, Gatekeeper accepts it silently:

- **Jamf Pro:** Add PKG as a package, deploy via policy.
- **Kandji:** Library → Custom App → upload PKG.
- **Microsoft Intune:** macOS apps → line-of-business app → upload PKG.
- **Mosyle:** Apps and Books → macOS PKG → upload.

## Verifying the deployed installation on a managed Mac

After the PKG lands, verify on the endpoint:

```bash
# App is installed at the expected path:
ls -ld "/Applications/Window Wrangler.app"

# Signature checks out (should show Developer ID Application, Team ID 7V4AJFNJKM):
codesign -dv --verbose=4 "/Applications/Window Wrangler.app"

# Gatekeeper accepts the install:
spctl -a -t exec -vvv "/Applications/Window Wrangler.app"

# TCC records for the app (should include Accessibility + AppleEvents entries granted by profile):
# Note: TCC's SQLite lives in a protected location; the below requires
# Full Disk Access for the shell you run it from. Not required for
# functional verification — the app either works or doesn't.
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, auth_value FROM access WHERE client='com.jmw3.WindowWrangler';"
```

## What Window Wrangler will NOT do on a managed Mac even with these profiles

- It will not access files in `~/Documents`, `~/Desktop`, or `~/Downloads` without triggering the macOS Sequoia+ "Files & Folders" TCC prompt. This affects the Corral Recall path when restoring saved documents. A future Full Disk Access entitlement (requires Apple's per-app review) would eliminate that prompt. Not included in this deployment package.
- It will not read TCC records for other apps.
- It will not persist any user data outside `~/Library/Preferences/com.jmw3.WindowWrangler.plist` (Corral saves, Restore-previous-layout snapshots — all local, all in that plist).
- It performs zero network activity.

## Rollback

To remove Window Wrangler from a managed Mac:

1. Unassign both `.mobileconfig` profiles from the target device / group. The system automatically removes the pre-granted permissions on next check-in.
2. Push an app-uninstall action (per your MDM's mechanism) to remove `/Applications/Window Wrangler.app`.
3. Optionally clear residual preferences: `defaults delete com.jmw3.WindowWrangler` from a management script.

The PPPC profile removal is instant. The app removal follows your MDM's normal uninstall behavior.
