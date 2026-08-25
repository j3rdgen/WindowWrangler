# Apple Events PPPC — Browser Receiver Requirements

This document tracks the state of each supported browser's Code Requirement string, used inside `WindowWrangler-AppleEvents-PPPC.mobileconfig` to pre-approve Window Wrangler's Automation permission for that receiver.

**Rule enforced by the release pipeline:** receiver Code Requirements are extracted from the ACTUAL codesign output on an install of the browser, never invented. Requirements captured from `codesign -dr - <path-to-Browser.app>`. When a browser is not installed on the machine that generated this profile, the entry is documented here as "unavailable" and NOT added to the .mobileconfig — inventing a requirement risks accepting a spoofed helper as the real browser.

## Currently captured (present in `WindowWrangler-AppleEvents-PPPC.mobileconfig`)

| Bundle ID | Path (extraction) | Team ID | Status |
|-----------|---------|---------|--------|
| `com.google.Chrome` | `/Applications/Google Chrome.app` | `EQHXZ8M8AV` | ✓ Captured. Google's DR uses an `identifier` OR-clause that also matches Chrome Beta, Dev, and Canary — one PPPC entry covers all four Chrome channels. |
| `com.apple.Safari` | `/Applications/Safari.app` | Apple (platform) | ✓ Captured. Minimal `identifier … and anchor apple` requirement — Safari is bundled with macOS. |

## Awaiting capture (NOT in `WindowWrangler-AppleEvents-PPPC.mobileconfig`)

For each browser below: install it on any Mac, run the `codesign` command in the "Extraction command" column, then hand the resulting Code Requirement string back to whoever is regenerating the PPPC profile — they'll add an `<AEReceiver…>` block matching the format of the existing Chrome / Safari entries.

| Bundle ID | Expected install path | Extraction command |
|-----------|-----------------------|--------------------|
| `com.google.Chrome.beta` | `/Applications/Google Chrome Beta.app` | Covered by Chrome's OR-clause — no separate PPPC entry needed. |
| `com.google.Chrome.canary` | `/Applications/Google Chrome Canary.app` | Covered by Chrome's OR-clause — no separate PPPC entry needed. |
| `com.google.Chrome.dev` | `/Applications/Google Chrome Dev.app` | Covered by Chrome's OR-clause — no separate PPPC entry needed. |
| `com.brave.Browser` | `/Applications/Brave Browser.app` | `codesign -dr - "/Applications/Brave Browser.app"` |
| `com.brave.Browser.beta` | `/Applications/Brave Browser Beta.app` | `codesign -dr - "/Applications/Brave Browser Beta.app"` — may share Brave's OR-clause; verify. |
| `com.brave.Browser.nightly` | `/Applications/Brave Browser Nightly.app` | `codesign -dr - "/Applications/Brave Browser Nightly.app"` |
| `com.microsoft.edgemac` | `/Applications/Microsoft Edge.app` | `codesign -dr - "/Applications/Microsoft Edge.app"` |
| `com.microsoft.edgemac.Beta` | `/Applications/Microsoft Edge Beta.app` | `codesign -dr - "/Applications/Microsoft Edge Beta.app"` |
| `com.operasoftware.Opera` | `/Applications/Opera.app` | `codesign -dr - "/Applications/Opera.app"` |
| `com.vivaldi.Vivaldi` | `/Applications/Vivaldi.app` | `codesign -dr - "/Applications/Vivaldi.app"` |

### How to add a captured requirement to the profile

1. Run the extraction command; copy everything after `designated =>`.
2. Strip any `/* … */` comment blocks (comments are illegal in the PPPC XML string).
3. Open `deployment/WindowWrangler-AppleEvents-PPPC.mobileconfig`.
4. Duplicate the last `<dict>` inside the `AppleEvents` `<array>` and change:
   - `AEReceiverIdentifier` → the browser's bundle ID
   - `AEReceiverCodeRequirement` → the captured requirement
   - `Comment` → note the browser's Team ID for anyone auditing later
5. Re-run `plutil -lint deployment/WindowWrangler-AppleEvents-PPPC.mobileconfig` to confirm the file still parses.
6. If the receiver's Code Requirement already covers additional bundle IDs via an OR-clause (as Chrome's does), note it in this document — don't add duplicate entries for the same underlying signature.

### Impact of a missing receiver on end users

If a Mac has, say, Brave installed but the profile does not include a Brave receiver entry:
- Window Wrangler will still work with Brave *if* the user has already granted Automation permission for Brave in `System Settings → Privacy & Security → Automation`.
- If the user has not granted Automation for Brave, they will see the standard macOS "Window Wrangler wants to control Brave" dialog on first use. Handling this correctly is what the app's `AutomationPermission.check` + onboarding flow already do — the PPPC profile just eliminates the dialog for managed / large-scale deployments.
- Chrome + Safari (already in the profile) work permission-dialog-free out of the box.

The profile is additive: users can also grant permissions manually alongside whatever the profile pre-approves.
