# Window Wrangler — Release Testing

Exhaustive test protocol for validating a Developer-ID-signed, notarized, stapled DMG + PKG release before it goes to users. Every check listed here has caught a real issue at some point in the app's development; do not skip them for a "trivial" release.

## When to run this

- After every `scripts/release.sh` + `scripts/notarize.sh` cycle that produces a new `dist/WindowWrangler-<version>.{dmg,pkg}`.
- After any code signing / Info.plist / entitlements / Xcode version change.
- Before publishing the release publicly.

## Prerequisites

- The two artifacts sitting in `dist/`.
- `dist/release-verification.txt` open in another window so you can cross-check the version, git commit, and SHA-256s at the end.

---

## Part 1 — Fresh-account DMG test (consumer-direct install path)

This exercises what a first-time user will experience when they download the DMG from your website and install it themselves.

### Setup

Prefer running this on a **freshly-created macOS user account** on your development Mac, or on a **separate Mac that has never had Window Wrangler installed**. Either isolates the test from your existing TCC records / preferences that could mask problems a new user would hit.

- Fresh user account (recommended): System Settings → Users & Groups → Add User → make it a Standard user → log out of your normal account → log into the new one.
- Separate Mac (better): pick any Mac running macOS 13+.

### 1.1 Gatekeeper acceptance

Copy the DMG to the test account's Downloads folder (via AirDrop, USB stick, or a shared drive — DO NOT `cp` from your admin account into the test account's home directory in a way that skips the Gatekeeper quarantine bit; downloading through Safari from a shared local file server preserves quarantine correctly).

Double-click the DMG. Expected: **it opens without a Gatekeeper warning.** If macOS says "Window Wrangler.dmg cannot be opened because it is from an unidentified developer" or "cannot be verified" — stop, the DMG isn't properly notarized + stapled. Run `xcrun stapler validate` locally to confirm the ticket is attached.

### 1.2 First launch

Drag `Window Wrangler.app` from the mounted DMG onto the Applications shortcut. Open Applications, double-click Window Wrangler.

Expected sequence:
1. macOS may show a **one-time** "Window Wrangler is an app downloaded from the Internet. Are you sure you want to open it?" dialog. Click Open. (This is Gatekeeper's normal first-run confirmation for downloaded apps, distinct from the "unidentified developer" block.)
2. Menu bar icon appears.
3. On first click of the menu, or on first Cascade shortcut press, macOS shows: **"Window Wrangler would like to control … via Accessibility"** — click Open System Settings → toggle Window Wrangler on. Restart Window Wrangler (menu → Quit, then relaunch).

Not expected:
- "Unidentified developer" — means notarization / stapling broken.
- Immediate crash — inspect Console.app for the crash log and abort testing.

### 1.3 Accessibility features

Confirm each of these works using their default shortcuts:
- Cascade All Apps Down-Right (`⌃⌥⌘]`) — outline pulse then windows cascade.
- Cascade All Apps Down-Left (`⌃⌥⌘[`) — pulse then cascade opposite direction.
- Single-app Cascade Down-Right (`⌃⌥⌘.`) — pulses only frontmost app's windows, then cascades them.
- Single-app Cascade Down-Left (`⌃⌥⌘,`) — same, opposite direction.
- Lasso: hold Option+W, click-drag across windows — rubber-band selects them.
- Lasso group drag: drag any selected window — the group moves together.
- Plot Mode: menu → Enter Plot Mode → click a window → drag to reposition.
- Restore Previous Layout (menu → Restore Previous Layout) after a cascade — windows return to pre-cascade positions.

Multi-display: if the test Mac has more than one display, verify the same shortcuts work on the display the mouse cursor is on, without pulling windows off other displays.

### 1.4 Automation features (browser scripting)

Ensure at least Google Chrome and Safari are installed on the test Mac. If either is fresh, launch it once and open a couple of tabs before testing.

- Corral capture (menu → Save to Corral): the first save that touches a browser triggers "Window Wrangler would like to control Google Chrome" — click OK. Second save: no dialog, tab data captured silently.
- Repeat for Safari.
- Recall a corralled group (menu → the saved corral): browser windows reopen at their saved positions with their saved tab URLs.
- Cascade a workspace with Chrome windows open — Chromium native repair kicks in transparently; no dialog.

### 1.5 Post-test cleanup

- Uninstall: drag Window Wrangler from Applications to Trash, empty Trash.
- (Optional) Clear TCC records: System Settings → Privacy & Security → Accessibility → toggle Window Wrangler off; same under Automation. Removes the "was granted, then app uninstalled" ghost entries.
- Log out of the test user account and delete it if it was created for this test.

---

## Part 2 — MDM-managed PKG + PPPC test

This exercises the enterprise path — a Mac managed by an MDM receives the PKG + both PPPC profiles, and end users never see permission dialogs.

### Prerequisites

- An MDM you can push test profiles from (Jamf / Kandji / Intune / Mosyle / MicroMDM / OpenMDM — any works).
- A test Mac enrolled in that MDM. Must be a Mac that has never had Window Wrangler installed.
- The three deployable files:
  - `dist/WindowWrangler-<version>.pkg`
  - `deployment/WindowWrangler-Accessibility-PPPC.mobileconfig`
  - `deployment/WindowWrangler-AppleEvents-PPPC.mobileconfig`

Follow the vendor-specific upload instructions in `deployment/MDM-DEPLOYMENT.md`.

### 2.1 Push profiles FIRST, then PKG

The order matters: if the PKG installs before the profiles arrive, the user will see permission dialogs the first time each feature runs (dialogs work but defeat the pre-approval).

1. Assign both `.mobileconfig` profiles to the test device. Wait for the device to check in (varies by MDM — typically <1 minute if the device is online). Confirm on the test Mac: **System Settings → Privacy & Security → Profiles** (or `profiles list` from Terminal) — both should be listed as installed.
2. Push the PKG install command via the MDM. Wait for install.

### 2.2 Verify the deployed .app

On the test Mac:
```bash
ls -ld "/Applications/Window Wrangler.app"
codesign --verify --deep --strict --verbose=4 "/Applications/Window Wrangler.app"
codesign -dv --verbose=4 "/Applications/Window Wrangler.app"
```

Expected:
- App present at the path.
- `codesign --verify` reports "valid on disk" and "satisfies its Designated Requirement".
- `codesign -dv` shows `Authority=Developer ID Application: Northstar-Purpose Enterprises LLC (7V4AJFNJKM)` + `TeamIdentifier=7V4AJFNJKM` + `Runtime Version=…` + `Timestamp=…`.

### 2.3 Launch + verify NO permission dialogs

Launch Window Wrangler (from the Applications folder or via the MDM's launch mechanism).

Expected: menu-bar icon appears, no permission dialogs.

Trigger Cascade / Lasso / Corral / Recall as in Part 1. **Expected: still no permission dialogs.** The PPPC profiles pre-approved everything.

If a dialog DOES appear:
- Accessibility dialog → the Accessibility PPPC profile isn't installed or its CodeRequirement doesn't match the installed app. Re-check the profile is present and verify its `<CodeRequirement>` string matches `codesign -dr - "/Applications/Window Wrangler.app"` output.
- Automation dialog for Chrome / Safari → same problem with the Apple Events PPPC profile.
- Automation dialog for Brave / Edge / Opera / Vivaldi → expected — those browsers aren't in the current PPPC profile. See `deployment/PPPC-AppleEvents-Receiver-Requirements.md` for how to add them.

### 2.4 Rollback test

From the MDM: unassign both `.mobileconfig` profiles. Wait for check-in. On the test Mac: **System Settings → Privacy & Security → Accessibility** — Window Wrangler should be listed but toggled off (permission revoked by profile removal). Similarly under Automation.

Push a PKG uninstall (or use `sudo rm -rf "/Applications/Window Wrangler.app"` if your MDM doesn't have a canned uninstall). Confirm the app is gone.

---

## Part 3 — Local regression on the dev Mac

Same 4-shortcut / 5-feature battery as your normal day-to-day testing, but run it *specifically after* the notarized release is complete. This catches any regression the signing / notarization / packaging step introduced.

- Cascade Down-Right + Down-Left (both `⌃⌥⌘]`/`⌃⌥⌘[` and `⌃⌥⌘.`/`⌃⌥⌘,`).
- Lasso select + group drag + multi-window resize.
- Plot Mode navigation.
- Corral save + Recall restore.
- Restore Previous Layout after a cascade.
- Multi-display flow if you have >1 display.

For each of these you're validating that the app produced by `scripts/release.sh` behaves identically to the Debug build you develop against. If any feature has drifted between Debug and Release, that's a signing / entitlement / stripping issue, not a feature bug — dig into what release-only work Xcode is doing that the Debug build isn't (dSYM stripping, symbol stripping, dead code stripping, etc.).

---

## Failure playbook

Common failure modes and their real causes:

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Gatekeeper: "cannot be verified" | Notarization missing or staple not attached | Re-run `xcrun stapler staple` and `xcrun stapler validate` |
| Gatekeeper: "damaged and can't be opened" | Quarantine bit + missing staple, OR signature broke | Verify signature with `codesign --verify --deep --strict`; if OK, re-notarize + staple |
| Permission dialog appears with PPPC profile installed | CodeRequirement mismatch OR profile scope wrong | `codesign -dr -` the installed .app, compare to the `<CodeRequirement>` in the .mobileconfig |
| App launches but Cascade / Lasso silently do nothing | Accessibility not actually granted (dialog was dismissed) OR permission dialog was hidden | System Settings → Privacy & Security → Accessibility → confirm toggle is ON, restart the app |
| Corral browser save takes 8+ seconds and returns empty | Automation grant is stale (recent rebuild fragmented TCC records) | Fresh-signed notarized releases fix this; if this happens on a notarized build, `tccutil reset AppleEvents com.jmw3.WindowWrangler` (only in intentional testing — this command has been observed to hang macOS during heavy dev cycles, use sparingly) |
| Notarize submit fails with "invalid" | Signature broken, get-task-allow present, or entitlements have blocked runtime exceptions | Read Apple's returned log via `xcrun notarytool log <submission-id> --keychain-profile window-wrangler-notary`; the JSON tells you exactly which file / issue |

---

## When you can call the release shippable

All three parts pass:
- Part 1 — fresh account or fresh Mac accepts + runs the DMG.
- Part 2 — MDM push results in a dialog-free install.
- Part 3 — every feature works identically to Debug on the developer's own Mac.

Cross-check the `dist/release-verification.txt` values against what's actually installed:
- SHA-256 of the local `.dmg` matches what testers verify from the download source.
- Git commit in the report matches `HEAD` of the repo the artifact was built from.

Only then post the DMG for download or hand the PKG to enterprise operators.
