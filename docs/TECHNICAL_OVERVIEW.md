# Window Wrangler — Technical Overview

Comprehensive product technical profile. Read this document when you need to reason accurately about Window Wrangler's capabilities, constraints, competitive position, or roadmap possibilities — without asking the developer follow-ups or inventing details from thin air.

**Audience:** external AI planning agents (or human strategists) preparing business plans, marketing plans, GTM plans, ICP research, competitive positioning, or roadmap prioritization from this project. Not a developer guide; see [`HANDOFF.md`](HANDOFF.md) for that.

**Currency:** as of MVP-1.0 (git tag `MVP-1.0`, commit `55b6807`, July 2026) plus a follow-on refinement pass on branch `cascade-flicker-refinement` (through commit `68e7fe8`, August 2026) that added **Plot Mode**, **Chromium native-bounds transport**, and the **bounded z-order settlement pipeline**. All three additions are reflected in §2 and §3 below. Later commits may add features not reflected here.

**How to use this document:** Section §14 at the bottom tells you which sections to pull from for which kinds of questions. If you're pressed for time, read §1, §2, §8, §9, §13, §14 first — those alone let you make sound positioning and pricing judgments.

---

## 1. Product identity

### 1.1 What it is

Window Wrangler is a macOS menu-bar utility that arranges application windows across displays and desktops. It has four distinct mechanics: **cascade** (fan-stack every window in a display in a way that keeps title bars visible), **lasso** (click-and-drag rubber-band selection of windows across multiple applications), **corral** (save a lasso selection as a named group and restore it later, including the tab lists of any browser windows in the group), and **plot** (click any window then drag to draw a rectangle — the window snaps to that rectangle on release, with edge-snap on the outer 15% of the display).

The product's differentiating idea is treating a set of windows across different apps as one addressable thing — something you can grab, move, cascade, save, and recall as a group. Most macOS window managers operate on one window at a time; Wrangler is designed around multi-window operations. Plot Mode complements the group model by giving the same user a precision-placement gesture for the individual-window moments in between.

### 1.2 Category

macOS window management utility. Sits alongside apps like Rectangle, Magnet, Moom, yabai, BetterTouchTool. Menu-bar utility form factor — no Dock icon, no main window, always-on background presence.

### 1.3 Naming

- **User-facing name:** Window Wrangler
- **Bundle identifier:** `com.jmw3.WindowWrangler`
- **Repo / project folder / Xcode target:** `WindowFan` / `WindowFanWrangler` (legacy from an earlier working name; a handoff developer can rename during production polish)

Any customer-facing surface uses "Window Wrangler."

### 1.4 Current status

- **MVP-1.0 complete + post-MVP refinement pass in flight.** All in-scope prototype features shipped and validated by the author on their daily-driver machine. Follow-on additions on branch `cascade-flicker-refinement`: Plot Mode (single-window precision placement), Chromium native-bounds transport (reliable resize where AX writes silently revert on Chrome/Brave/Edge/Opera/Vivaldi/Chromium), and a bounded z-order settlement pipeline shared by All-Apps and Selection Cascade (identity-based persistent-drift detection + async serialized reconstruction + late recommit, all budget-capped).
- **Personal prototype, not distributed.** Runs from Xcode as a local build. No code signing beyond self-sign. No notarization. No public download. No Mac App Store presence.
- **Solo developer, AI-assisted.** The project owner is not a professional developer; the code was authored primarily by Claude Code with the owner directing feature scope, testing every commit, and making product decisions.
- **Two-week development timeline** for the MVP-1.0 feature set. Corral (M8) was the largest single milestone. Post-MVP refinements landed in follow-on sessions.

---

## 2. What it does (feature inventory)

Every feature currently shipping. Section §13 explicitly enumerates features that don't exist so downstream AI planners don't invent them.

### 2.1 Cascade — single app

- Bound to `⌃⌥⌘.` (Down-Right) and `⌃⌥⌘,` (Down-Left).
- Positions every window of the frontmost app on the display containing the mouse cursor into a stair-step "fan" layout where each successive window is offset diagonally (down + right, or down + left) so every window's title bar and top edge stay visible.
- Default fan geometry: 1168×738 window size, 28pt vertical reveal (header), 58pt lateral reveal (side stagger). Reveal-tightening auto-packs the fan when it would otherwise overflow the display.
- Also available from the menu-bar dropdown.
- Multi-display aware — cascade operates on whichever display contains the mouse cursor at shortcut-fire time. Independent per-display cascade on multi-monitor setups.

### 2.2 Cascade — all apps

- Bound to `⌃⌥⌘]` (Down-Right) and `⌃⌥⌘[` (Down-Left).
- Same as single-app cascade but includes windows from every visible app on the target display, grouped by application (each app's windows form their own sub-cascade, and each subsequent app's anchor is offset laterally so the app groupings remain visually distinguishable).
- **Deterministic planning-size resolver.** Slot geometry is computed from each window's `standardTargetSize` (for size-settable apps) rather than its current mutable size — so a cascade fired after a manual resize or after Plot Mode still lands every window at the same slot on the first invocation. Fixes the "post-Plot cascade needs 4-5 invocations to converge" bug class.
- **Handles the retry / verify / z-order-enforcement pattern** to accommodate slow-to-respond apps (Chrome, Zoom) that don't complete AX-driven position updates in one pass. Includes a bounded z-order settlement pipeline: pass-1 raise, three spaced re-checkpoints (+120/+300/+500ms), a pass-4 persistent-drift decision at +1000ms, async 16ms-spaced serialized reconstruction (deepest→anchor) when persistent drift is confirmed by two consecutive complete observations, a settled reobservation at +200ms, and a conditional late recommit at +1600ms. Hard cap of 2 serialized walks per cascade generation. All work is generation-guarded so a newer cascade or Restore aborts the older settlement in flight.
- **Chromium laggard native-bounds repair.** When Chromium windows show as laggards during retry passes, the fix write routes through AppleScript `set bounds` instead of AX — AX size writes to Chromium browsers silently revert on the next runloop tick, but the AppleScript path persists.

### 2.3 Layout snapshot + restore

- Every cascade automatically captures a snapshot of the pre-cascade window positions.
- `⌃⌥⌘↑` restores that snapshot — one-shot undo of the most recent cascade.
- Not persisted across launches; in-memory only.

### 2.4 Lasso mode

- Toggled by `⌃⌥⌘C`. A small "Lasso Mode: ON" chip appears in the screen corner as a mode indicator.
- Click-and-drag draws a rubber-band selection rectangle across any location on any display, regardless of which app owns the windows underneath.
- Windows whose frames intersect the rectangle get dashed blue outlines drawn on top of them. Selection persists after the drag ends.
- Click-and-drag on an already-selected window switches to group drag mode instead of starting a new selection.
- Selection is preserved across Space (Virtual Desktop) changes but outlines are only rendered for windows on the currently-active Space.

### 2.5 Group drag

- With lasso mode on and one or more windows selected, click-and-drag on any selected window moves the entire selection together as one unit.
- Uses a Finder-style ghost preview: the outlines shift with the cursor, and the actual windows follow via AX position writes.
- On drag release, the windows snap to their final positions.
- Handles cross-display drags — the group can be dragged across multiple displays.

### 2.5a Lasso group resize

- With lasso mode on and a selection active, two circle handles (BL / BR) appear on the last-interacted selected window.
- Grab a handle and drag; the frontmost selection outline updates live and the entire selection resizes together on release. Zero AX writes fire during the drag itself — the whole authoritative resize (per-window preflight, per-PID parallel writes, settle, readback, positions-only recascade, toast) is deferred until mouse-up. This keeps the interactive surface at 60fps even for cross-app selections that include Chrome / System Settings, where mid-drag AX writes would otherwise stutter to single-digit fps.
- Fires an auto-cascade of the selection on release, with cascade direction inferred from the anchor geometry (which corner was pulled).

### 2.5b Plot Mode

- Bound to `⌃⌥⌘P`. Also available from the menu-bar dropdown.
- Single-window precision-placement gesture. State machine: enter Plot Mode → click any visible window to select it (window gets a dashed outline; the "Press Esc to End Plot Mode" pill dims to alpha 0.28) → click-and-drag anywhere to draw a destination rectangle → release to snap the window to that rectangle.
- **Edge-snap logic:** each of the four rectangle edges (N/S/E/W) independently snaps to the display edge when the drawn edge enters the outer 15% zone, with hysteresis to prevent flicker at the snap boundary. Interior coordinates are preserved exactly as drawn — no grid, no presets.
- **Chromium commit path:** Chromium windows (Chrome, Brave, Edge, Opera, Vivaldi, Chromium — matched by bundle ID) commit via AppleScript `set bounds` because Chromium apps asynchronously revert AX size writes on the next runloop tick. Non-Chromium windows commit via the standard AX position + size write. Both paths run a settled readback + one optional position-correction write to re-anchor to snap-intent edges when the app enforced a minimum size.
- **Mutually exclusive with Lasso Mode.** Activating one tears down the other. `Esc` or `⌃⌥⌘P` exits Plot Mode.
- Multi-display aware — the drawn rectangle's target display is the one containing the mouse cursor when the drag begins.

### 2.6 Corral — save

- Bound to `⌃⌥⌘S`. Only enabled when at least one window is lasso-selected.
- Presents a "Name this window group…" text pill for the user to type a name (max 50 characters), then Return to submit.
- Captures each selected window's app bundle ID, display name, window title, frame, z-order slot, and (for supported browser windows) the complete tab list (URL + tab title per tab).
- Also captures the AX document path for documents-based apps (TextEdit, Preview, Xcode, etc.) so restore can reopen the specific document.
- Persisted to `UserDefaults` as JSON. Survives app relaunches and (barring UserDefaults corruption) macOS reboots.
- Overwrite flow: saving with an existing name triggers a "Replace 'NAME'?" confirmation.
- MVP cap of 5 named corrals — enforced with a "delete one first" alert when at cap.

### 2.7 Corral — release / restore

- Bound to `⌃⌥⌘R`. Opens a centered "release menu" listing every saved corral with a red × delete button per row.
- Clicking a corral in the menu triggers restore. Also available as a submenu in the menu-bar dropdown for direct restore without opening the pill.
- Restore process:
  1. Launch or reopen any of the corral's apps that aren't currently running (using per-app strategies — `open -b <bundle>` for well-behaved apps, `open ~` for Finder, `NSWorkspace.open(fileURL:, withApplicationAt:)` for documents).
  2. Wait ~2 seconds for launched apps to register windows.
  3. For each member, either move an existing window to the saved frame (via AX) or create a new one (via AppleScript for browsers, opening the document for docs-based apps).
  4. Enforce the saved z-order so the front-most saved window ends up on top of the stack.
  5. Retry pass 2 seconds later for any Catalyst apps (Notes, Podcasts) that took longer than 2s to spawn windows.
  6. Post-restore audit: detect windows that landed on other Desktops and surface in the result toast.
- Success toast: `✓ Restored 'NAME'`. Partial-success toast lists missing members. Scatter toast fires only when at least one restored window ended up on a different Desktop than the user's current one.

### 2.8 Menu-bar dropdown

- Icon in the menu bar (SF Symbol / custom art). Clicking it opens a dropdown showing:
  - Accessibility permission status
  - Lasso mode current state + toggle
  - Plot mode current state + toggle
  - Selection count (when non-empty) + Clear button
  - Cascade Down-Right / Down-Left / All Apps variants / Restore Previous Layout
  - Corral (Save) — grayed out unless selection + not at cap
  - Release ▸ submenu with each saved corral for direct-restore + a "Manage Corrals…" item that opens the pill for delete UI
  - Launch at Login toggle
  - Reopen Setup (only shown when Accessibility isn't granted)
  - Quit
- Every menu item shows its keyboard shortcut hint.

### 2.9 Permission onboarding

- On first launch, a SwiftUI onboarding window explains that Accessibility permission is required and opens the System Settings pane directly.
- Auto-detects the grant via polling and dismisses the onboarding window without user intervention.
- Then iterates every installed supported browser and triggers macOS's Automation-permission prompt for each in one intentional burst, so subsequent Corral saves don't surface the prompt mid-flow.

### 2.10 Supported browsers (for tab capture)

- Google Chrome (stable, beta, canary, dev channels — all bundle IDs)
- Brave Browser (stable, beta, nightly)
- Microsoft Edge (stable, beta)
- Opera
- Vivaldi
- Chromium (open-source builds)
- Safari

Firefox is NOT supported — Firefox uses a different scripting bridge (WebExtensions + native messaging) that would require a substantially different implementation.

Arc is NOT supported — Arc's AppleScript dictionary differs from stock Chromium.

---

## 3. Technical architecture

### 3.1 macOS APIs used

- **Accessibility (AX)** — `AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`, `AXUIElementPerformAction(kAXRaiseAction)` for reading, writing, and z-ordering windows. Requires user grant.
- **CGWindow (Quartz)** — `CGWindowListCopyWindowInfo` for cross-app window enumeration + z-order observation. No permission required (public API).
- **AppleScript / Apple Events** — `NSAppleScript` for browser tab capture and creation (Corral) and for direct window-bounds writes on Chromium apps (Plot + Cascade laggard repair). Requires per-target Automation permission (TCC).
- **CGEventTap** — for global left-mouse-event interception during lasso mode and Plot Mode. Requires Accessibility permission (same grant as AX).
- **NSEvent local monitor** — for Escape-key handling within lasso and Plot overlays.
- **NSWorkspace** — for launching apps (`NSWorkspace.open`, `Process` invoking `/usr/bin/open`) and for `NSRunningApplication` enumeration.
- **SMAppService** — modern Login Items registration (macOS 13+) for the "Launch at Login" toggle.

### 3.2 Module structure

Codebase is organized around strict separation of concerns:

- **Boundary modules** wrap platform APIs (`AXWindowEnumerator`, `WindowMutator`, `CrossAppWindowEnumerator`, `BrowserScripting`, `GlobalEventMonitor`, `AccessibilityPermission`, `AutomationPermission`, `CoordinateSpace`).
- **Pure decision modules** contain testable logic with no platform dependencies (`FanGeometry`, `PlotGeometry`, `CascadePlanning`, `CascadeZOrderDrift`, and the pure `BrowserScripting.matchBrowserWindow` matcher).
- **State modules** own specific state (`WindowSelection`, `CorralStore`, `LayoutSnapshot`).
- **Orchestrator modules** wire the boundaries + state into user-facing flows (`CascadeOrchestrator`, `LassoCoordinator`, `CorralOrchestrator`, `PlotCoordinator`).
- **UI modules** render dedicated pieces (`SelectionOverlay`, `LassoModeHint`, `PlotOverlay`, `PlotModeHint`, `CorralNamePill`, `CorralReleaseMenu`, `CorralToast`, `MenuBuilder`, `OnboardingWindowController`).
- **App shell** wires everything together (`WindowWranglerApp`, `WindowWranglerActions`, `GlobalShortcuts`, `MenuBarIcon`).

~35 Swift source files, ~9,500 lines of code, plus a `Window WranglerTests` target with 7 test files and 96 currently-passing XCTest cases (see §12.3).

### 3.3 Coordinate spaces

macOS has two coordinate systems that Wrangler works in:

- **AX space** — top-left origin, y-axis grows down, global across all displays. Used by AX APIs and CGWindowList's bounds dictionary.
- **Cocoa space** — bottom-left origin, y-axis grows up, per-primary-screen. Used by AppKit / NSWindow / NSEvent.

`CoordinateSpace.swift` is the only module that converts between them. Every rect-typed field explicitly encodes its coordinate space in the field name (e.g., `boundsAX: CGRect` vs `frame: CGRect`).

### 3.4 Language and tooling

- **Swift** with Swift-6-mode concurrency (`@MainActor` isolation).
- **AppKit** for all UI except onboarding.
- **SwiftUI** for `OnboardingWindowController` only (it's the one screen where SwiftUI's simplicity beats AppKit's overhead).
- **Xcode 26.5+** to build. Uses `PBXFileSystemSynchronizedRootGroup` so new `.swift` files in the source directory are auto-picked up without `.pbxproj` edits.

---

## 4. Platform requirements

### 4.1 macOS versions

- **Minimum:** macOS 13 (Ventura), per `Info.plist`.
- **Developed and tested on:** macOS 26.5 (Tahoe).
- **Not actively tested on:** Ventura or Sonoma. The API surface used has been stable across those versions, but behavior is unverified.
- **Not supported:** macOS 12 or earlier (SwiftUI-first onboarding + Swift-6 concurrency both require newer SDKs).

### 4.2 App form factor

- **`LSUIElement = YES`** — menu-bar-only app. No Dock icon. No main window. No app-menu presence.
- **No login-item behavior** — currently only runs when the user manually launches it. A "launch at login" feature is deferred (see §11).

### 4.3 Hardware

- **Any Mac supported by macOS 13+.** No specific hardware requirements — the app is CPU-light, event-driven, and does no GPU work.
- **Multi-display supported** — cascade uses the display containing the mouse cursor; each display is treated independently.
- **Retina and non-Retina displays** both supported. Coordinate math handles pixel-density scaling via the standard macOS point-vs-pixel abstraction.

### 4.4 Required permissions

- **Accessibility** — mandatory. Without it, no cascade, no lasso, no corral. User grants once in System Settings.
- **Automation, per browser** — required only for Corral tab capture. If declined, Corral still saves the browser's window position; the tab list just won't be in the saved corral.
- **Files and Folders** (macOS Sequoia+) — triggered on-demand per-folder when Corral restore opens saved documents. User grants per prompt.
- **No other permissions requested** — no Screen Recording, no Camera, no Microphone, no Location, no Contacts, no Calendar, no Photos, no Reminders, no Health, no Motion, no Focus.

---

## 5. Data model

### 5.1 What's stored on disk

All persistent data lives in `UserDefaults.standard` under a single key: `com.jmw3.WindowWrangler.corrals.v1`.

Value is a JSON-encoded array of `Corral` objects. No filesystem writes outside of UserDefaults. No SQLite. No cloud store. No temp directories.

### 5.2 Corral schema

```
Corral {
    id: UUID              // stable across renames + overwrites
    name: String          // user-typed, capped at 50 chars
    capturedAt: Date      // snapshot timestamp
    members: [CorralMember]
}

CorralMember {
    appBundleID: String       // e.g. "com.google.Chrome"
    appName: String           // display name from NSRunningApplication
    windowTitle: String       // title at capture time (used as restore hint)
    frame: CGRect             // Cocoa-space frame at capture time
    zOrderIndex: Int          // 0 = frontmost within this corral
    tabs: [TabInfo]?          // non-nil only for supported-browser windows
    documentPath: String?     // POSIX path for documents-based apps
}

TabInfo {
    url: String
    title: String
}
```

### 5.3 Storage limits

- **Maximum 5 saved corrals** for MVP. Enforced by `CorralStore.save`.
- No per-corral size limit but each is small (typically <10 KB JSON).
- Total storage impact: ~50 KB max for a full store.

### 5.4 Data lifecycle

- **Never syncs anywhere.** No iCloud sync, no server upload, no analytics endpoint, no crash reporting.
- **Survives app relaunches** and macOS reboots.
- **Doesn't survive app uninstall** — UserDefaults for the bundle is cleared when the app is deleted.
- **Malformed data recovery** — decoding failures on launch reset the store to empty and log the error, rather than crash. The user loses their corrals but retains a usable app.

---

## 6. Privacy and security posture

### 6.1 What the app reads

- **All windows across all apps** — via AX and CGWindowList. Includes window frames, titles, subroles, owner PIDs, owner bundle IDs.
- **Document paths for documents-based apps** — via `kAXDocumentAttribute`. Includes full POSIX paths to the file the user has open in TextEdit / Preview / Xcode / etc.
- **Browser tab URLs and titles** — via AppleScript, for windows in a corral save. Includes the full URL of every tab in a captured browser window.

### 6.2 What the app writes

- **Window positions and sizes** — via AX, only on user-triggered actions (cascade, group drag, corral restore).
- **Corral data to UserDefaults** — only on user-triggered corral save/overwrite/delete.

### 6.3 What leaves the machine

**Nothing.** The app has no network activity. No analytics, no crash reporting, no update check, no telemetry, no cloud sync. All user data is local.

### 6.4 Sandbox / entitlements

- **Not sandboxed.** The app runs outside App Sandbox because sandboxed apps cannot read other apps' windows via AX.
- **`NSAppleEventsUsageDescription`** in `Info.plist` explains why the app requests Automation permission.
- **No hardened runtime yet** — development builds are self-signed. A production build would enable hardened runtime as a notarization prerequisite.
- **Not distributable via Mac App Store** — MAS requires sandbox, which breaks cross-app AX. Developer ID + direct distribution is the natural production path.

### 6.5 Security surface

Threats a security-minded user should consider:
- The app is a menu-bar utility with broad Accessibility permission — it has the technical ability to read + move any window on the system. A malicious version of the app could exfiltrate window titles + document paths + browser URLs.
- The app is not code-signed for public distribution. Users installing an MVP-1.0 build accept the local-development trust context.
- Automation permission per-browser means the app can send arbitrary AppleScript to those browsers — same trust considerations as any AppleScript-capable app.

None of these threats are actively exploited by the current code, but a customer evaluating the app for enterprise use would want a signed + notarized production build with a documented security posture before deployment.

---

## 7. Performance characteristics

### 7.1 Cascade

- **Single-app cascade of 5 windows:** ~50–100ms for pass 1, converges within ~1.2s including retry + verify passes.
- **All-apps cascade of 15 windows:** ~200–400ms for pass 1, converges within ~1.5s.
- **Chrome and Zoom windows** add latency inside individual passes — Chrome's runloop occasionally takes 100–300ms per window to accept an AX position write.

### 7.2 Corral save

- **Non-browser windows:** capture is dominated by AX title reads — ~10ms per window.
- **Browser windows:** each window pays a targeted AppleScript round-trip (whose-filter for the window index + tabs-for-that-window). Typical: 200–400ms per browser window.
- **Total for a corral with 5 windows including 3 browser windows:** ~800–1200ms.

### 7.3 Corral restore

- **Non-browser members:** window move via AX is 5–20ms each.
- **Browser members:** window creation via AppleScript is 100–200ms each.
- **App-launch overhead** dominates when apps aren't running: 500ms–3s per app depending on how heavy the app is (Chrome ~1s, Notes / Podcasts ~3s as Catalyst-derived apps).
- **Standard restore flow:** 2s deferred wait for launches + per-member processing + optional 2s retry pass. Typical user perception: 2–4s from click-to-restore to "everything looks right."

### 7.4 Memory footprint

- **Idle memory:** ~30–40 MB (typical AppKit menu-bar app).
- **No background workers.** No timers running. No polling loops. The app is fully event-driven — it does nothing when the user isn't actively using it.
- **CGEventTap is disabled by default.** Only enabled while lasso mode is on. When lasso is off (99% of the time), the app doesn't touch the system-wide left-mouse event stream at all.

### 7.5 CPU impact

- **Idle CPU:** effectively 0%. No polling, no timers, no work.
- **During cascade:** brief burst — a few hundred milliseconds of AX writes then done.
- **During lasso drag:** ~1–3% CPU sustained for the drag's duration (event handling + overlay redraw).
- **During browser AppleScript:** the AppleScript itself runs in the target browser's process; Wrangler's own CPU during the wait is 0%.

---

## 8. Distribution readiness — honest gap analysis

Where the app sits between "runs on my machine" and "shippable to strangers."

### 8.1 Currently working

- Builds and runs from Xcode on the developer's Mac.
- Every claimed feature works in that environment.
- Self-signed for local execution.
- Accessibility + Automation permission flows behave correctly.

### 8.2 Gaps between prototype and shippable production

**Code signing and identity.**
- Currently: local self-sign ("Sign to Run Locally").
- Production needs: Developer ID Application certificate from Apple Developer Program membership ($99/year), a stable Team ID that TCC keys against permanently, hardened runtime enabled.

**Notarization.**
- Currently: not notarized.
- Production needs: notarized via Apple's automated malware scan. Required for Gatekeeper to allow distribution to non-development-team users without ⌃-click bypass.

**Entitlements review.**
- Currently: minimal (Accessibility, AppleEvents).
- Production may need: Full Disk Access entitlement (to eliminate the Files & Folders TCC prompts on document restore for macOS Sequoia+). Requires Apple's manual review and justification.

**Distribution channel.**
- Currently: none. No installer, no DMG, no website.
- Production paths available:
  - **Direct download** — DMG or zip hosted on a website. Requires notarization for Gatekeeper acceptance. Simplest path for a paid utility.
  - **Homebrew Cask** — community distribution channel. Requires public repo + notarized binary.
  - **Mac App Store** — NOT VIABLE with current architecture. MAS requires app sandbox; sandboxed apps cannot read other apps' windows via AX. Adopting MAS would require gutting the cross-app functionality.
  - **Setapp** — subscription bundle for Mac utilities. Requires their curation process.

**Update mechanism.**
- Currently: none. Rebuild from Xcode.
- Production needs: Sparkle (the standard Mac auto-update framework) or equivalent, plus a manifest served from a website.

**Website + support surface.**
- Currently: none.
- Production minimum: a landing page describing the app, a download link, a support email or issue tracker, a privacy policy (even a one-page one), a license page.

**Legal.**
- Currently: "all rights reserved" as informal MVP status.
- Production needs: formal LICENSE file (proprietary or open source — decision), privacy policy, terms of use if collecting payment.

**Payment / distribution flow (if paid).**
- Currently: no payment mechanism.
- Production paths: Paddle, Fastspring, Gumroad, Stripe + custom license server, MAS in-app purchase (if MAS path viable — it's not).

### 8.3 What notarization would fix from the current parking lot

- **Stale TCC records after rebuilds** — a stable Team ID means grants persist across app updates. Eliminates the "granted but doesn't work" state that plagues heavy-development sessions.
- **Files & Folders prompts on document restore** — with Full Disk Access entitlement (which requires notarization + review), the per-folder prompts disappear.

### 8.4 What notarization would NOT fix

- **Multi-Space (Virtual Desktop) restore placement** — macOS-inherent, no public API. Only SIP-off private APIs can solve.
- **Cross-app AX latency** on group drag / cascade of slow apps — inherent to the AX event routing between processes.
- **AX -25211 wake-up on backgrounded apps** — inherent to macOS's AX proxy lifecycle. The 50ms retry stays in place.
- **NSAppleScript non-cancellability** — Apple provides no cancel API. Would require rewriting the scripting layer to use `AESendMessage` with `kAETimeout`.

---

## 9. Competitive landscape

Technical positioning against every macOS window manager the developer is aware of. Not an exhaustive market analysis — that's for a business planner working from this document.

### 9.1 Rectangle (free, open source)

**What it does:** keyboard-driven window snapping. Halves, quarters, thirds, maximized, restored positions. Hotkey-configurable.

**Category:** keyboard tiling utility.

**Overlap with Wrangler:** none functionally. Rectangle snaps individual windows to grid positions. Wrangler doesn't do snapping at all.

**Where Wrangler differs technically:** Wrangler's cascade layout (fan stack) is orthogonal to Rectangle's tile layouts. Rectangle has no lasso, no cross-app group operations, no named saved layouts, no browser tab awareness. Rectangle Pro adds some multi-window features but still one-window-at-a-time as the primary model.

**Distribution:** free (Rectangle) or paid $10 (Rectangle Pro). MAS + direct download.

### 9.2 Magnet (paid, ~$5)

**What it does:** near-identical to Rectangle. Keyboard-driven window snapping. Slightly different default shortcuts.

**Category:** keyboard tiling utility.

**Overlap with Wrangler:** same as Rectangle. Snap-driven, single-window, no groups.

**Distribution:** paid via Mac App Store.

### 9.3 yabai (free, open source)

**What it does:** tiling window manager. Fully automatic tiling layouts (BSP, stack, float). Deep customization via config file. Requires SIP (System Integrity Protection) partially disabled to install because it uses private CGS APIs for near-instant window moves and Space manipulation.

**Category:** tiling WM (Unix-style).

**Overlap with Wrangler:** minimal — different mental model. yabai users treat windows as tiles in a partition. Wrangler users treat groups of windows as named collections they save and recall.

**Where Wrangler differs technically:** Wrangler uses only public APIs, no SIP requirement. Trade-off: slower cross-app moves, no Space-aware manipulation. yabai's power-user audience overlaps very little with Wrangler's imagined user (someone who wants to save "a set of things I'm working on together").

**Distribution:** free, Homebrew install, requires disabling SIP.

### 9.4 Moom (paid, ~$10)

**What it does:** snap-to-grid window management PLUS "custom layouts" — save a specific window configuration for a specific app, restore later. Menu-bar utility.

**Category:** snapping + saved layouts.

**Overlap with Wrangler:** meaningful overlap on the "save + restore layout" mechanic. Moom's custom layouts and Wrangler's Corrals cover similar territory.

**Where Wrangler differs technically:**
- Moom's layouts are per-app or global; Wrangler's Corrals are named, arbitrary cross-app groups.
- Moom does NOT capture browser tabs. If you save a "research layout" in Moom that includes Chrome, the layout only restores the Chrome window's position, not the tabs it had open.
- Wrangler's Corral captures the tab list of every browser window in the group and reopens those exact tabs on restore.
- Moom has more polished snapping UI (mouse-hover-corner triggers).
- Wrangler has cross-app lasso; Moom doesn't.

**Distribution:** paid via developer's website + Mac App Store.

### 9.5 Apple's native window tiling (macOS Sequoia+)

**What it does:** basic snap-to-half / snap-to-quarter via edge-drag or the green traffic-light menu. Ships with macOS 15+.

**Category:** built-in snapping.

**Overlap with Wrangler:** none — Apple's tiling is per-window and has no group awareness.

**Impact on the market:** the "free basic snapping" tier is now covered by macOS itself. Paid snapping utilities (Magnet, Rectangle Pro) increasingly need multi-window features to justify their existence. Wrangler is well-positioned in that shift — its differentiator is exactly what Apple's tiling doesn't provide.

### 9.6 BetterTouchTool (paid, ~$20 one-time or subscription)

**What it does:** gesture and automation platform. Includes window snapping, but its core is trackpad gestures + macro automation.

**Category:** power-user automation.

**Overlap with Wrangler:** BTT can be scripted to do many things Wrangler does, but requires the user to configure gestures / actions manually. Wrangler ships opinionated behaviors out of the box.

**Where Wrangler differs technically:** Wrangler is opinionated + simple; BTT is generic + configurable. Different audience — BTT users are configuration enthusiasts; Wrangler is designed for a user who wants a purpose-built tool that "just works" for the multi-window use case.

### 9.7 Divvy, Spectacle, HyperDock, and others

Various keyboard-snapping and window-management utilities. All operate on the single-window / snapping model. None address cross-app grouping, named collections, or tab preservation.

### 9.8 Summary — competitive whitespace

Nobody currently ships:

- **Cross-app lasso** — Finder has a similar rubber-band-select gesture within Finder itself, but no utility extends this to work across arbitrary apps' windows.
- **Named window groups with browser tab preservation** — Moom's layouts don't capture tabs. Chrome extensions (Session Buddy, One Tab) capture tabs but not window positions or non-browser context. Wrangler is the only one that unifies both.
- **Group drag** across apps as a first-class primitive.
- **Draw-your-target-rectangle placement (Plot Mode).** Most window managers offer snap-to-preset (halves, thirds, quarters) or free-form drag. Plot Mode's "draw a rectangle, the window snaps to it with independent per-edge display-edge snap on the outer 15%" gesture is unusual — Moom's mouse-hover-corner has a superficially similar feel but commits to preset regions, not a user-drawn rectangle.

The competitive whitespace Wrangler occupies is "multi-window operations across apps" complemented by "precision single-window placement without a preset grid" — a category currently unfilled.

---

## 10. Known limitations

User-perspective limits. Root causes and technical detail live in [`HANDOFF.md`](HANDOFF.md); this section is what an external planner needs to know for accurate positioning without over-promising.

### 10.1 Multi-Desktop restore placement

**User-visible behavior:** if you save a Corral on one Desktop (Space) and later restore it while looking at a different Desktop, macOS may auto-swipe to the Desktop where the target apps had their most-recently-active windows. Windows always end up grouped together on one Desktop, but not always yours.

**Why:** macOS provides no public API to control which Space a window lands on. When Chrome or another app is activated during restore, macOS's own "when switching to an application, switch to a Space with open windows for the application" preference kicks in.

**Workaround for users:** turn OFF **System Settings → Desktop & Dock → Mission Control → "When switching to an application, switch to a Space with open windows for the application"**. With that off, restored windows stay on the current Desktop.

**Impact on positioning:** single-Desktop users are unaffected. Multi-Desktop users experience the auto-swipe unless they toggle the system setting. Documented in the README.

### 10.2 Group drag latency on slow apps

**User-visible behavior:** during a fast group drag of Chrome or Zoom windows, the dashed selection outlines can visibly lag the moving windows by 20–40 pixels for a frame or two before catching up on release.

**Why:** AX position writes to slow apps take multiple screen refreshes to propagate.

**Impact on positioning:** cosmetic. Not a functional issue. Rectangle, Magnet, and Apple's own tiling all exhibit the same behavior when moving another app's windows.

### 10.3 Chrome 8-window cap

**User-visible behavior:** if a user has 9 or more visible Chrome browser windows on one display AND the AX bounds of the 9th window don't exactly match its AppleScript bounds (a rare drift case), the 9th window's tabs won't save.

**Why:** Chrome's AppleScript window enumeration hangs when walking past its 25+ hidden helper windows; a per-window property access halts the entire script indefinitely. We cap enumeration at 8 to avoid the hang. The `whose bounds is {…}` shortcut has no such cap and covers the common case.

**Impact on positioning:** essentially never bites in practice. Users with 9+ visible Chrome windows on one display are extreme outliers.

### 10.4 Files & Folders TCC prompts (macOS Sequoia+)

**User-visible behavior:** on Sequoia and later, restoring a Corral with saved documents in `~/Documents`, `~/Desktop`, or `~/Downloads` triggers a per-folder "Window Wrangler wants to access files in Downloads" prompt on first restore.

**Why:** Apple's macOS Sequoia added per-folder consent for filesystem reads. `NSWorkspace.open(fileURL, …)` triggers it.

**Impact on positioning:** one-time click per folder per user. Not a functional block. A notarized production build with Full Disk Access entitlement would eliminate the prompts entirely.

### 10.5 Development-only: stale TCC state

**User-visible behavior:** ONLY seen during heavy development-build cycles. In production notarized builds, this class of problem doesn't occur.

**Why:** every rebuild in Xcode changes the app's code signature. TCC keys grants by signature. Repeated rebuilds fragment TCC's view of the app.

**Impact on positioning:** irrelevant to end users. A notarized production build with stable Team ID sidesteps entirely.

### 10.6 Occasional Chrome-scripting thread leak

**User-visible behavior:** after many failed Chrome scripting operations in one session (rare, mostly during development), the app can feel sluggish. Restart clears it.

**Why:** Apple provides no cancellation API for NSAppleScript. Timed-out scripts leak background threads.

**Impact on positioning:** rare in normal use. Documented in README as "restart if sluggish."

---

## 11. Extension surfaces — what could be built

Features not currently shipping but technically feasible with the current architecture. Sizing is rough estimate of effort for a competent macOS developer.

### 11.1 Preferences UI (M7 originally sketched, deferred)

**What:** SwiftUI preferences window with sliders for cascade offsets (vertical / horizontal reveal), preferences persisted in UserDefaults, cascade geometry reads from those settings.

**Why deferred:** the hardcoded defaults (28pt vertical, 58pt lateral) feel right in practice; no user scenario has surfaced where they don't. Revisit if a real customer scenario emerges.

**Effort:** 1–2 days.

### 11.2 Launch at login — **shipped**

Menu-bar toggle wires `SMAppService.mainApp.register()`. Managed via the standard **System Settings → General → Login Items & Extensions**. Persists across relaunches.

### 11.3 Custom keybindings

**What:** UI for users to remap the eight default shortcuts.

**Approach:** SwiftUI settings screen with a `KeyEquivalent` picker per action; settings persisted; `GlobalShortcuts` reads from settings on register.

**Effort:** 2–3 days.

### 11.4 Corral count above 5

**What:** raise the current 5-corral MVP cap. Easy config change; may want UX considerations for managing 20+ corrals (folder / tag / search).

**Effort:** 1 hour for the cap raise; 1–2 weeks if adding organization UI.

### 11.5 Auto-restore Corral on login

**What:** designate one Corral as "default"; app launches it automatically on login.

**Effort:** 1 day (assumes launch-at-login already exists).

### 11.6 More browsers

**What:** Firefox tab capture (WebExtensions + native messaging bridge), Arc tab capture (different AppleScript dictionary).

**Effort:** Firefox — 1–2 weeks (requires a companion browser extension). Arc — 3–5 days.

### 11.7 Cloud sync of Corrals

**What:** iCloud CloudKit sync or third-party (Supabase, Firebase) sync of the corral JSON.

**Effort:** 1–2 weeks including conflict resolution + UI for sync status.

### 11.8 Additional cascade layouts

**What:** grid, tile, spiral, edge-alignment — layout options beyond the current fan.

**Approach:** `FanGeometry.swift` already isolates the layout math as a pure function. New layouts are new implementations of `layout(count:targetSize:...) -> [CGRect]`.

**Effort:** 1–2 days per new layout.

### 11.9 Time-based / calendar-based Corral rotation

**What:** "Morning setup" corral opens at 9 AM automatically; "Focus mode" corral opens when Focus turns on; etc.

**Effort:** 3–5 days plus calendar/focus integration.

### 11.10 URL scheme / callback URL for automation

**What:** expose `window-wrangler://save?name=X` and `window-wrangler://restore?name=X` for automation from Shortcuts, Alfred, Raycast, etc.

**Effort:** 1–2 days.

### 11.11 Multi-monitor Corral-per-display

**What:** save one Corral that covers windows on display A, restore only on display A when the user is on display A.

**Effort:** 3–5 days.

### 11.12 Layout preview

**What:** show a thumbnail preview of what a Corral looks like when the user hovers it in the release menu.

**Effort:** 3–5 days.

### 11.13 Chrome tab capture for hidden tabs

**What:** currently we only capture the ORDER of visible tabs. Adding: pinned status, tab group memberships, etc.

**Effort:** 2–3 days.

### 11.14 Menu-bar visual density options

**What:** compact / regular / large icon variants.

**Effort:** half a day.

### 11.15 Onboarding tutorial

**What:** interactive first-run walkthrough that demonstrates the three mechanics.

**Effort:** 1 week including UI polish.

---

## 12. Development context

### 12.1 Who built it

- **Owner:** non-developer (business background). Can read code at a high level, run commands, describe observed behavior. Cannot debug Swift errors independently. Directs feature scope, tests every commit, makes product decisions.
- **Primary code author:** Claude Code (Anthropic). AI-assisted development throughout — every commit represents a validated user-tested outcome, not an AI-generated draft.
- **Handoff intent:** the owner plans to hire a professional developer for production polish (notarization, distribution, UI refinement, additional features) once the MVP is validated.

### 12.2 Timeline

- **Two-week development cycle** from initial commit to MVP-1.0.
- **Six milestones (M1–M8)** covering menu bar app foundation → cascade → lasso → group drag → layout snapshot → corral (M8 was ~40% of total effort).

### 12.3 Testing surface

- **Primary test rig:** developer's daily-driver MacBook. macOS 26.5 (Tahoe), Retina Built-in Display, various external displays connected during some sessions.
- **Manual + observational for orchestrators.** Cascade orchestration, lasso flow, Plot commit path, corral save/restore, and cross-app behavior are all validated by the developer running the app and inspecting Console logs (`subsystem:com.jmw3.WindowWrangler`).
- **XCTest coverage on pure-decision modules.** 96 tests currently passing across 7 files: `CoordinateSpaceTests`, `FanGeometryTests`, `WindowSelectionTests`, `BrowserBoundsMatcherTests` (the ambiguity-safe Chromium-window matcher), `CascadePlanningTests` (the deterministic planning-size resolver), `CascadeZOrderDriftTests` (identity-based persistent-drift detection + final-status matrix), and `SelectionCascadeSettlementTests` (parity with All-Apps + shared-timing invariants). Test target is filesystem-synchronized — new files auto-picked up.
- **What's been tested extensively:** cascade in every direction, lasso across many app configurations, corral save/restore with mixed app types, browser tab capture with Chrome (extensive), Safari (moderate), Brave / Edge / Vivaldi / Opera (spot-check), Plot Mode with Chromium and non-Chromium targets.
- **What's been tested lightly:** multi-display configurations, macOS versions other than 26.5, edge cases like extreme window counts.
- **What has NOT been tested:** older macOS versions (13, 14, 15), Apple Silicon vs Intel distinctions, Firefox (not supported), enterprise MDM environments, apps with unusual AX behavior beyond what's covered in the parking lot.

### 12.4 Development tooling

- Xcode 26.5+ with default settings, local self-signing.
- Console.app for log stream inspection (`subsystem:com.jmw3.WindowWrangler`).
- git with all commits on `main` branch (no feature branches during prototype phase).
- No CI/CD, no automated builds.

### 12.5 Repo state

- **~35 Swift source files** in the app target, ~9,500 LOC.
- **Single Xcode project**, one app target + one test target (`Window WranglerTests`) with 96 passing XCTest cases.
- **git tag `MVP-1.0`** anchors the MVP shippable state at commit `55b6807`. Follow-on work lives on branch `cascade-flicker-refinement`; current head as of this document is `68e7fe8` (bounded z-order settlement pipeline for All-Apps + Selection Cascades).
- **git remote:** `origin` → private GitHub repo. Local commits are pushed after each substantial change.
- **No external dependencies** — pure Foundation + AppKit + ApplicationServices + ServiceManagement. No CocoaPods, no Swift Package Manager dependencies, no Carthage.

---

## 13. Explicit non-features

This section exists specifically so external AI planners **don't invent features that don't exist.** If a feature isn't listed in §2, and isn't listed as a possible extension in §11, it does NOT exist in Window Wrangler. In particular:

### Not currently shipping

- **Not on Mac App Store.** No MAS listing, no App Store rating, no App Store reviews.
- **Not code-signed for public distribution.** Development build only.
- **Not notarized.** Gatekeeper will warn on other users' Macs.
- **No download page, no website, no marketing surface.** Zero distribution presence.
- **No paid tier.** No free tier either (nothing to purchase — the app doesn't exist commercially).
- **No user accounts.** Nothing to sign up for. No login.
- **No cloud sync.** Corrals are local-only, per-machine.
- **No cross-device sync** — no iCloud, no CloudKit, no other cloud store.
- **No iOS or iPadOS version.** macOS only.
- **No Windows or Linux version.** macOS-specific APIs; not portable.
- **No CLI (command-line interface).**
- **No AppleScript API for Wrangler itself.** Wrangler is not scriptable by other apps.
- **No URL scheme / callback URL** for automation (deferred, see §11.10).
- **No Shortcuts integration.** No Focus integration.
- **No custom keybindings UI.** Shortcuts are hardcoded (deferred, see §11.3).
- **No Preferences UI at all.** No settings screen exists (deferred, see §11.1).
- **No tutorial or onboarding beyond the accessibility permission flow.**
- **No update mechanism.** No Sparkle. No auto-update. No update-check-on-launch.
- **No telemetry.** No analytics. No crash reporting. Nothing sent anywhere.
- **No support surface.** No email, no forum, no issue tracker, no support hotline.
- **No collaborative features.** Cannot share corrals with other users.
- **No team / enterprise / MDM support.**
- **No calendar integration.** No time-based automation.
- **No AI features.** No LLM integration. No "smart layout suggestions." No categorization of your windows.
- **No layout preview thumbnails.** The release menu is a text-only list.
- **No search / filter across corrals** — the release menu shows all of them.
- **No corral tags, folders, or organization.**
- **No corral import/export.**

### Not planned but sometimes assumed

- **No history/versioning of corrals.** Overwriting replaces; no undo.
- **No corral scheduling** (auto-open at 9am, etc.).
- **No system-wide focus states or profiles.** Wrangler doesn't know about macOS Focus modes.
- **No integration with Stage Manager** — Stage Manager and Wrangler operate on different mental models; Wrangler doesn't interact with Stage Manager state.
- **No hot corners.** No mouse gesture triggers.
- **No touchbar UI** (irrelevant on Apple Silicon Macs without touchbar).
- **No support for multiple mice / trackpads acting independently.**
- **No screensaver integration.**
- **No dark-mode-specific / light-mode-specific behavior beyond standard AppKit adaptation.**

### Genuinely out of scope for the prototype

- Support for apps that use non-standard windowing (Electron apps that override reopen behavior, some Java Swing apps). Handled on a case-by-case basis in `openAppForRestore` dispatch.
- Support for full-screen apps in AX/CGWindow visible-windows enumeration — full-screen mode uses a different Space and macOS reports it differently.
- Support for windows on connected iPads via Universal Control — untested.

---

## 14. Guidance for external AI planners

This section is the "operating manual" for you as an AI consuming this document.

### 14.1 For pricing / GTM planning

**Pull from:** §1 (identity), §2 (feature inventory), §8 (distribution readiness), §9 (competitive landscape), §12 (development context).

**What to keep in mind:**
- The product is a personal prototype, not a shipping commercial product. Any pricing analysis is hypothetical — treat it as "what could this be priced at when shipped."
- The nearest competitors' pricing anchors:
  - Rectangle: free (Rectangle Pro: $10)
  - Magnet: $5 (MAS)
  - Moom: $10 (direct)
  - BetterTouchTool: $20 one-time or $2/month subscription
  - yabai: free (technical audience)
- Wrangler's differentiator (cross-app groups + tab preservation) supports a higher price point than pure snapping utilities. Moom's $10 is a reasonable anchor.
- MAS distribution is NOT viable (§8) — direct-download is the plausible model.

### 14.2 For target-segment / ICP research

**Pull from:** §1, §2, §9, §12.

**What to keep in mind:**
- The natural user is someone doing "context work" — juggling multiple sets of related apps and browser tabs across projects (consultants, researchers, knowledge workers, developers who switch between codebases).
- The differentiator ("groups of windows + tabs, saved and restored as one thing") maps to workflows where a "project" or "context" is a repeating unit.
- Not a good fit: single-project workers, keyboard-tiling enthusiasts (they already have Rectangle), power users who want tiling window managers (they have yabai).

### 14.3 For feature roadmap prioritization

**Pull from:** §2 (what exists), §11 (what could be built), §13 (what's explicitly out).

**What to keep in mind:**
- Anything in §11 is technically feasible with sizing estimates.
- Anything in §13 marked "Not currently shipping" but not listed in §11 is intentionally excluded — don't propose without asking the owner.
- §13 items about non-viability (MAS, sandbox, no cross-platform) should be respected — they're architectural constraints, not preferences.

### 14.4 For competitive positioning claims

**Pull from:** §9 (verified competitive analysis).

**What to keep in mind:**
- Claims in §9 are as of MVP-1.0 with the developer's knowledge of the market. Verify current pricing / feature parity before publishing.
- The "cross-app group + tab preservation" whitespace is the strongest single positioning claim.
- Don't over-claim on performance ("fastest") or completeness ("comprehensive") — the product is a prototype.

### 14.5 For technical questions

**Pull from:** §3–§7, §10.

**What to keep in mind:**
- If a technical question isn't answered here, refer to `HANDOFF.md` for developer-level depth.
- Don't speculate about internals — either it's documented or it's outside this document's scope.

### 14.6 What NEVER to do

- Do NOT invent features not listed in §2 or §11.
- Do NOT claim the product ships on MAS, has a website, has an install base, has revenue, has customers, has reviews, or has funding.
- Do NOT claim the app has been tested at scale — it's a prototype tested by one person on one machine.
- Do NOT claim performance numbers not in §7.
- Do NOT invent competitor feature comparisons not in §9.
- Do NOT commit the product to a specific distribution model — that decision is still open.
- Do NOT claim a specific target segment as validated ICP — no user research has been done yet.

### 14.7 When you're not sure

Ask the human user in your session, don't guess. They can go back to the developer for clarification. Better to have an honest "this document doesn't cover X" than to invent an answer that becomes load-bearing in a business plan.

---

*End of document. Currency: MVP-1.0 (git tag `MVP-1.0`, commit `55b6807`, July 2026) plus post-MVP refinements on branch `cascade-flicker-refinement` through commit `68e7fe8` (August 2026) — Plot Mode, Chromium native-bounds transport, bounded z-order settlement pipeline for All-Apps + Selection Cascades.*
