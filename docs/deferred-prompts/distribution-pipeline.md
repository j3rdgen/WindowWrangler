# DEVELOPER ID SIGNING + NOTARIZATION + DMG/PKG + ENTERPRISE PPPC

**Status:** DEFERRED — run AFTER Apple Developer registration is complete and the real Developer ID Application + Developer ID Installer certificates are installed in the local keychain.

**How to invoke:** open a fresh Claude Code session and paste the entire prompt below verbatim. The prompt is self-contained and enforces its own safety gates.

**Before running:** replace `<TEAMID>` and `<NAME>` with the real values from the installed certificates. Do NOT guess these values — check `security find-identity -v -p codesigning` and copy the exact string.

**Why this is a separate task:** distribution pipeline work cannot begin without real Developer ID certificates. Attempting it with ad-hoc / self-signed identities would produce an artifact that fails Gatekeeper and cannot be notarized. The prior `hardened-runtime` branch put the Hardened Runtime configuration + apple-events entitlement in place; this task is the follow-up that actually signs, notarizes, packages, and generates MDM deployment material.

---

## THE FULL PROMPT TO PASTE

Work on a new branch named:

distribution-pipeline

Use this prompt ONLY after the real Developer ID certificates are installed.

Actual Team ID:

<TEAMID>

Actual certificate/organization name:

<NAME>

Replace those placeholders with the real values BEFORE executing.

DO NOT guess the Team ID or certificate name.

GOAL

Create a repeatable, fail-closed Window Wrangler release pipeline that produces:

1. Developer ID-signed + Hardened Runtime Window Wrangler.app
2. signed + notarized direct-download DMG
3. signed + notarized enterprise deployment PKG
4. Accessibility PPPC deployment profile
5. Apple Events PPPC deployment profile
6. repeatable verification output
7. release documentation

Do not change Window Wrangler application logic.

Do not commit or push.

--------------------------------------------------
REPOSITORY SAFETY — DO FIRST
--------------------------------------------------

1. Run:

   git status
   git diff

2. Verify the reviewed Hardened Runtime work from the hardened-runtime branch is already incorporated into the branch/base this release pipeline should use.

3. If the working tree is dirty:
   - DO NOT stash
   - DO NOT reset
   - DO NOT revert
   - DO NOT discard
   - DO NOT automatically commit
   - STOP and report

4. If clean:
   create/switch to:

   distribution-pipeline

5. Leave resulting work uncommitted for review.

--------------------------------------------------
STEP 1 — VERIFY THE ACTUAL CERTIFICATES
--------------------------------------------------

Inventory installed signing identities.

Confirm the exact presence of:

Developer ID Application: <NAME> (<TEAMID>)

and:

Developer ID Installer: <NAME> (<TEAMID>)

Use Keychain/security tooling.

Print the exact identities that will be used.

DO NOT substitute:

- Apple Development
- Apple Distribution
- Mac App Distribution
- ad-hoc signing
- self-signed identities
- another Team ID

If either required Developer ID identity is missing:

STOP.

--------------------------------------------------
STEP 2 — RE-AUDIT SHIPPED EXECUTABLE CODE
--------------------------------------------------

Reuse the executable/nested-code inventory from the Hardened Runtime work.

Confirm no new executable code has appeared.

Verify every executable shipping inside Window Wrangler is correctly signed.

Do not use:

codesign --deep

as a substitute for understanding or manually signing nested code.

`--deep` may be used for verification.

If manual signing is needed, sign nested executable code in the correct inside-out order.

--------------------------------------------------
STEP 3 — CREATE A REPEATABLE RELEASE SCRIPT
--------------------------------------------------

Use the repository's existing scripting/tooling conventions.

Create something equivalent to:

scripts/release.sh

Prefer the standard Xcode archive/export workflow where appropriate:

xcodebuild archive
xcodebuild -exportArchive

Do not invent a parallel build system.

Use strict/fail-closed shell behavior where compatible, such as:

set -euo pipefail

The release script must exit nonzero on any required failure.

--------------------------------------------------
STEP 4 — BUILD THE TRUE RELEASE APP
--------------------------------------------------

Produce the final Release app.

Requirements:

- correct Developer ID Application identity
- Team ID = <TEAMID>
- Hardened Runtime enabled
- secure timestamp
- reviewed production entitlements
- intentionally unsandboxed
- Apple Events entitlement on the executable that sends Apple Events
- app-sandbox absent
- get-task-allow absent/false
- no unauthorized Hardened Runtime exceptions

Do not modify product logic.

Do not re-sign randomly after export.

Use Xcode's normal signing/export process unless manual signing is actually necessary and justified.

--------------------------------------------------
STEP 5 — VERIFY THE APP BEFORE PACKAGING
--------------------------------------------------

Run:

codesign --verify --deep --strict --verbose=4 "/path/to/Window Wrangler.app"

Run:

codesign -dv --verbose=4 "/path/to/Window Wrangler.app"

Run:

codesign -d --entitlements :- "/path/to/Window Wrangler.app"

Run:

codesign -dr - "/path/to/Window Wrangler.app"

Capture the exact designated requirement.

Verify:

- Developer ID Application authority
- correct Team ID
- Hardened Runtime/runtime option
- secure timestamp
- apple-events entitlement
- app-sandbox absent
- get-task-allow absent/false
- no unauthorized runtime exceptions
- nested code verifies

Abort release if any mismatch exists.

--------------------------------------------------
STEP 6 — CREATE THE DIRECT-DOWNLOAD DMG
--------------------------------------------------

Create a deterministic staging directory.

DMG must contain the final verified:

Window Wrangler.app

Optionally include an Applications convenience link if consistent with the intended install UX.

Do not modify the .app after app verification.

Sign the final DMG with:

Developer ID Application: <NAME> (<TEAMID>)

Do not use Developer ID Installer to sign the DMG.

Verify the DMG's signature.

--------------------------------------------------
STEP 7 — CREATE THE ENTERPRISE PKG
--------------------------------------------------

Create a component installer package targeting:

/Applications/Window Wrangler.app

Use the same final already-signed .app as the component.

Sign the .pkg with:

Developer ID Installer: <NAME> (<TEAMID>)

Do NOT re-sign Window Wrangler.app with the Installer certificate.

Verify:

pkgutil --check-signature "/path/to/WindowWrangler.pkg"

Abort if expected Developer ID Installer identity / Team ID is absent.

--------------------------------------------------
STEP 8 — CONFIGURE NOTARYTOOL CREDENTIAL HANDLING
--------------------------------------------------

Do not hardcode:

- Apple ID
- app-specific password
- API key
- issuer ID
- key ID
- private key
- other secrets

Require a notarytool Keychain profile, for example:

window-wrangler-notary

Print the command the user should run to create it.

For Apple ID authentication, provide a template like:

xcrun notarytool store-credentials "window-wrangler-notary" \
  --apple-id "<APPLE_ID>" \
  --team-id "<TEAMID>" \
  --password "<APP_SPECIFIC_PASSWORD>"

Do not fill in secrets.

Do not echo secrets in logs.

If the current environment supports/preferably uses App Store Connect API-key authentication, document the equivalent secure notarytool Keychain-profile setup.

--------------------------------------------------
STEP 9 — NOTARIZE THE DMG
--------------------------------------------------

Submit:

xcrun notarytool submit "/path/to/WindowWrangler.dmg" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

Capture the submission ID.

If status is not accepted:

- fetch/display notarization log
- exit nonzero
- do not staple
- do not report release success

--------------------------------------------------
STEP 10 — NOTARIZE THE PKG
--------------------------------------------------

Submit:

xcrun notarytool submit "/path/to/WindowWrangler.pkg" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

Capture submission ID.

Same failure behavior:

anything other than accepted = release failure.

--------------------------------------------------
STEP 11 — STAPLE BOTH ARTIFACTS
--------------------------------------------------

After accepted notarization:

xcrun stapler staple "/path/to/WindowWrangler.dmg"

xcrun stapler staple "/path/to/WindowWrangler.pkg"

Then:

xcrun stapler validate "/path/to/WindowWrangler.dmg"

xcrun stapler validate "/path/to/WindowWrangler.pkg"

Any failure must terminate the release process.

--------------------------------------------------
STEP 12 — VERIFY WITH THE CORRECT GATEKEEPER ASSESSMENTS
--------------------------------------------------

APP:

On macOS versions with the tool available, prefer:

syspolicy_check distribution "/path/to/Window Wrangler.app"

If unavailable, use:

spctl -a -t exec -vvv "/path/to/Window Wrangler.app"

Do NOT use `-t install` as the primary .app assessment.

DMG:

spctl -a -t open -vvv \
  --context context:primary-signature \
  "/path/to/WindowWrangler.dmg"

PKG:

spctl -a -t install -vvv "/path/to/WindowWrangler.pkg"

Also:

pkgutil --check-signature "/path/to/WindowWrangler.pkg"

And run stapler validation for both DMG and PKG.

--------------------------------------------------
STEP 13 — VERIFY THE APP INSIDE THE DMG
--------------------------------------------------

Mount the final DMG read-only.

Inspect the contained:

Window Wrangler.app

Verify again:

- codesign
- Developer ID identity
- Team ID
- Hardened Runtime
- entitlements
- Gatekeeper/distribution result

Ensure it is the exact intended release build.

Unmount cleanly.

--------------------------------------------------
STEP 14 — VERIFY THE PKG PAYLOAD
--------------------------------------------------

Inspect package metadata/payload enough to prove:

- correct Window Wrangler.app is packaged
- destination is /Applications
- embedded application remains Developer ID Application signed
- package itself is Developer ID Installer signed

Do not silently package a stale/different build.

--------------------------------------------------
STEP 15 — RELEASE OUTPUT DIRECTORY
--------------------------------------------------

Produce a clean output structure such as:

dist/
  WindowWrangler-<version>.dmg
  WindowWrangler-<version>.pkg
  checksums.txt
  release-verification.txt

Generate SHA-256 checksums.

Record:

- version
- build number
- git commit
- Team ID
- Developer ID Application identity
- Developer ID Installer identity
- notarization submission IDs
- SHA-256 values

Do not include credentials.

--------------------------------------------------
STEP 16 — GENERATE ACCESSIBILITY PPPC
--------------------------------------------------

Generate enterprise deployment material from the FINAL Developer ID-signed app.

First extract the exact designated requirement:

codesign -dr - "/path/to/Window Wrangler.app"

Do not invent it.

Create:

deployment/WindowWrangler-Accessibility-PPPC.mobileconfig

Use the current Apple PPPC payload schema.

Window Wrangler identity:

Identifier:
com.jmw3.WindowWrangler

IdentifierType:
bundleID

CodeRequirement:
exact requirement extracted from final Developer ID-signed app

Create real UUIDs.

Use the appropriate device/system scope for MDM deployment.

Validate:

plutil -lint deployment/WindowWrangler-Accessibility-PPPC.mobileconfig

The Accessibility profile should authorize Window Wrangler's required Accessibility access for managed deployment.

--------------------------------------------------
STEP 17 — GENERATE APPLE EVENTS PPPC
--------------------------------------------------

Window Wrangler also sends Apple Events to external applications.

Accessibility PPPC alone is NOT the complete enterprise TCC deployment solution.

Generate:

deployment/WindowWrangler-AppleEvents-PPPC.mobileconfig

Window Wrangler is the SENDER.

Use:

bundle ID:
com.jmw3.WindowWrangler

and:

the exact final Window Wrangler CodeRequirement.

Audit the actual current BrowserScripting/native-transport support list from the source code.

Expected targets may include:

- Safari
- Google Chrome
- Chrome variants
- Brave variants
- Microsoft Edge variants
- Opera
- Vivaldi
- Chromium

Use the repository as authority.

Do not blindly use this expected list if source differs.

--------------------------------------------------
STEP 18 — DO NOT INVENT RECEIVER CODE REQUIREMENTS
--------------------------------------------------

For each supported browser installed locally, extract its actual designated requirement using:

codesign -dr - "/path/to/Browser.app"

The Apple Events PPPC entries must identify:

Window Wrangler = sender
Browser = receiver

using the current Apple PPPC schema.

For supported browsers NOT installed:

DO NOT invent:

- certificate requirements
- Team IDs
- designated requirements

Instead create:

deployment/PPPC-AppleEvents-Receiver-Requirements.md

Include:

browser
bundle ID
expected installation path
command to extract designated requirement
status: captured / unavailable

The generated .mobileconfig should contain only validated receiver definitions.

--------------------------------------------------
STEP 19 — VALIDATE PPPC FILES
--------------------------------------------------

Use the current:

com.apple.TCC.configuration-profile-policy

schema.

Do not guess AppleEvents PPPC field names.

Inspect/use the current schema applicable to supported macOS deployment.

Run:

plutil -lint

for every generated .mobileconfig.

A syntactically valid profile is not considered functional proof.

Document that PPPC must be tested through MDM on a managed test Mac.

--------------------------------------------------
STEP 20 — ENTERPRISE OUTPUT
--------------------------------------------------

Produce:

deployment/
  WindowWrangler-Accessibility-PPPC.mobileconfig
  WindowWrangler-AppleEvents-PPPC.mobileconfig
  PPPC-AppleEvents-Receiver-Requirements.md
  MDM-DEPLOYMENT.md

MDM-DEPLOYMENT.md should document:

- Window Wrangler bundle ID
- final designated requirement
- Accessibility PPPC purpose
- Apple Events PPPC purpose
- browser receivers included
- browser receivers still awaiting verified requirements
- PKG installation artifact
- expected /Applications installation path

Mention compatibility with MDM platforms such as:

- Jamf
- Kandji
- Microsoft Intune
- Mosyle

but do not invent vendor-specific configuration unless separately requested.

--------------------------------------------------
STEP 21 — FINAL SIGNED/NOTARIZED REGRESSION TEST
--------------------------------------------------

This is the definitive test.

Use the actual final Developer ID-signed/notarized application.

Test:

APP LIFECYCLE:

- launch
- quit
- relaunch

ACCESSIBILITY:

- Cascade All Apps DR
- Cascade All Apps DL
- Selection Cascade
- Lasso
- Plot
- Restore Previous Layout
- multi-display if available

AUTOMATION:

- Corral browser-tab capture
- Recall browser-tab recreation
- Plot Chromium native bounds
- Cascade Chromium native repair

PERMISSIONS:

Test deliberately:

1. existing authorization state
2. fresh Apple Events state
3. Apple Events denied
4. Apple Events subsequently granted

Use TCC reset only for intentional fresh-permission testing.

Do not modify permission copy.

--------------------------------------------------
STEP 22 — FRESH/DOWNLOADED-MAC TEST INSTRUCTIONS
--------------------------------------------------

Produce exact instructions for validating the final DMG from a separate/fresh macOS account or Mac.

The test should cover:

- Gatekeeper
- notarization
- first launch
- Accessibility onboarding
- Automation onboarding
- Cascade
- Lasso
- Plot
- Corral
- Recall
- Restore

Do not claim consumer direct-distribution readiness until this test is successfully completed.

Also document a separate MDM-managed test for:

- PKG deployment
- Accessibility PPPC
- Apple Events PPPC

--------------------------------------------------
DO NOT CHANGE APPLICATION LOGIC
--------------------------------------------------

Do not refactor:

- BrowserScripting
- Cascade
- Plot
- Lasso
- Corral
- Recall
- Restore
- AX enumeration
- z-order settlement
- Chromium transport

If signing/notarization exposes a functional defect:

STOP and report it separately before modifying application code.

--------------------------------------------------
DO NOT MODIFY PERMISSION/MARKETING COPY
--------------------------------------------------

Do not change:

- Accessibility permission-dialog wording
- NSAppleEventsUsageDescription wording
- onboarding positioning
- competitor references
- marketing copy

--------------------------------------------------
DOCUMENTATION
--------------------------------------------------

Update appropriate technical/release documentation for:

- Developer ID direct distribution
- Hardened Runtime
- effective entitlements
- DMG release
- enterprise PKG
- notarytool
- stapling
- Gatekeeper verification
- Accessibility PPPC
- Apple Events PPPC
- certificate identities
- release verification
- fresh-machine testing
- MDM testing

Do not place secrets/private keys/passwords/Apple IDs into repository documentation.

--------------------------------------------------
FINAL REPORT
--------------------------------------------------

Return one structured report containing:

1. Repository safety
   - initial git status
   - final git status
   - branch
   - files changed
   - no commit/push
   - no secrets added

2. Signing identities
   - exact Developer ID Application identity
   - exact Developer ID Installer identity
   - Team ID

3. Application
   - version
   - build number
   - bundle ID
   - Developer ID authority
   - Hardened Runtime status
   - timestamp status
   - effective entitlements
   - designated requirement

4. DMG
   - final path
   - signature result
   - notarization ID
   - notarization status
   - staple result
   - Gatekeeper result
   - SHA-256

5. PKG
   - final path
   - Installer identity
   - pkgutil result
   - notarization ID
   - notarization status
   - staple result
   - Gatekeeper result
   - SHA-256

6. PPPC
   - Window Wrangler code requirement
   - Accessibility profile
   - Apple Events profile
   - validated browser receivers included
   - receivers still requiring requirements
   - plutil results

7. Application regression results
   - Cascade
   - Selection
   - Lasso
   - Plot
   - Restore
   - Corral
   - Recall
   - Chromium native paths

8. Remaining manual validation
   - fresh/quarantined Mac
   - MDM-managed test Mac
   - any unsupported/unavailable browser receiver requirement

Leave all work uncommitted for review.
