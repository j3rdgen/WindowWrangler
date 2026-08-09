# Window Wrangler — Handoff Guide

For a developer taking over the codebase. Read this once, then use it as a map when questions surface.

- **[README.md](../README.md)** is the porch: what it is, how to build, first-run permissions.
- **[TECHNICAL_OVERVIEW.md](TECHNICAL_OVERVIEW.md)** is for external planners / business tooling — it describes the product profile, not the code.
- **This document** is the code map: architecture, patterns, gotchas, and the parking-lot state as of MVP-1.0.

---

## Development context

- **Solo dev, non-developer.** The person who owns this project can read code at a high level, run commands you give them, and describe observed behavior, but cannot debug Swift errors independently. Any issue reported comes with a Console log and a description; diagnosis is your job.
- **AI as primary code author.** Written with Claude Code as the primary author. Every commit represents a validated user-tested outcome, not an AI-generated draft. If a commit exists, the associated behavior was verified.
- **Prototype phase.** The goal was to validate the core mechanics (cascade, lasso, corral, plot) on the author's own machine before hiring a developer for production polish. That means: no code signing beyond local self-sign, no notarization, no distribution wiring. A test target does exist and holds 141 tests — see the Testing section below.
- **Post-MVP additions in flight (branch `cascade-flicker-refinement`).** Six concrete refinements have landed on top of MVP-1.0 and are documented throughout this guide: (1) **Plot Mode** — a single-window precision placement gesture bound to `⌃⌥⌘P` (click a window, drag to draw a rectangle, release to snap the window to that rectangle with edge-snap on the outer 15% of the display); (2) **Chromium native-bounds transport** — Plot's Chromium commit path and Cascade's Chromium laggard repair now route through AppleScript `set bounds` because Chromium browsers silently revert AX size writes on the next runloop tick; (3) **bounded z-order settlement pipeline** — a shared All-Apps + Selection identity-based persistent-drift detector that escalates to async serialized reconstruction only when two consecutive complete observations agree the same slots are wrong, with a max-2-walks-per-generation budget and a conditional late recommit at +1600ms; (4) **observation-starvation escalation** — when CGWindowList observations stay incomplete across the whole settlement window (Grammarly / Notes / Podcasts unmappable on this Mac), pass 4 escalates via the same serialized reconstruction instead of silently exiting; new `.unresolvedObservationIncomplete` final status reports these cases truthfully; (5) **pass-4 observe-first + progress-gated walk #2** — pass 4 and both post-walk reobservations now use a pure observation helper (zero AXRaise), and walk #2 fires only when walk #1 produced observation-coverage progress (5/8 → 7/8 is progress; 7/8 → 7/8 is a structural plateau and walk #2 is suppressed); (6) **two-phase correction ownership + geometry-quiescence barrier** — pass 1 remains the sole PROVISIONAL correction owner, every intermediate stage (+300ms, pass 2/3 converged, pass 2/3 post-write, Chromium native-repair success + failure→AX callbacks, Selection intermediate checkpoints) is observation-only, and pass 4's serialized reconstruction defers via a `pendingFinalSettlement` marker until the tracked native-repair set drains — collapsing cold cascades from 5-11 visible re-stackings to 1-2. Also (7) **Plot cursor hit-test AX-only fallback** — when CGWindowList's bounds lag AX after a recent plot commit, cursor-hit-test walks the visible apps' fresh AX windows directly so users can re-Plot the same window immediately without exiting-and-manually-resizing.
- **Target: macOS 13 (Ventura) minimum.** Developed and tested on macOS 26.5 (Tahoe). Xcode 26.5+ to build. Swift + AppKit throughout; SwiftUI only for `OnboardingWindowController`.

---

## Architecture principles

Per the project's original CLAUDE.md, the codebase enforces a few strict separations:

1. **Coordinate spaces are converted at module boundaries.** Accessibility (AX) APIs use top-left global origin. Cocoa uses bottom-left per-screen origin. `CoordinateSpace.swift` is the ONLY place that converts between them. Every other module works in one space or the other and states its coordinate space in the type name (`boundsAX` vs `frame`).
2. **Pure geometry is separate from AX.** Fan-cascade math lives in `FanGeometry.swift` as pure functions that take and return `CGRect` — no AX calls, testable in isolation.
3. **AX layer is wrapped.** `AXWindowEnumerator.swift` (reads) and `WindowMutator.swift` (writes) are the only files that touch `AXUIElement` for enumeration and mutation. Everything else calls into them.
4. **Selection state is isolated.** `WindowSelection.swift` owns the set of currently-selected windows. Nothing else stores window references long-term. Callers subscribe to `selection.onChange` for updates.
5. **Global event capture is isolated.** `GlobalEventMonitor.swift` owns the `CGEventTap`. The lasso flow reacts to callbacks; nothing else touches the tap.

If you find yourself reaching across those boundaries — e.g., an orchestrator calling `AXUIElementCopyAttributeValue` directly, or geometry code enumerating windows — you're doing the wrong thing. Add a helper to the appropriate boundary module.

---

## Module map

Alphabetical, grouped by role.

### Foundation

- **`Log.swift`** — `os.Logger` categories: `app`, `ax`, `cascade`, `lasso`, `permission`, `corral`, `plot`, `mutator`, `shortcuts`, `ui`. Console filter for our subsystem is `subsystem:com.jmw3.WindowWrangler`. Everything is subsystem-scoped so you can filter noise from other apps.
- **`AppInfo.swift`** — Small helper for the app's own display name (`Bundle.main` lookup).
- **`CoordinateSpace.swift`** — AX ↔ Cocoa conversion. `CoordinateSpace.axRect(fromCocoa:)` and `cocoaRect(fromAX:)` are the workhorse converters. Also has `screen(containing:)` used by the modal panels for center-on-mouse-screen positioning.

### AX and window enumeration

- **`AXWindowEnumerator.swift`** — `windows(of: NSRunningApplication) -> [EnumeratedWindow]`. Reads `kAXWindowsAttribute`. Includes the **one-shot 50ms retry on `-25211`** (kAXErrorAPIDisabled) that wakes up backgrounded apps' AX proxies. Filters by subrole (`AXStandardWindow`, `AXDialog`, `AXFloatingWindow`), scoping out popovers, menus, minimized windows. Finder's Desktop backdrop gets its own explicit filter.
- **`CrossAppWindowEnumerator.swift`** — `allVisibleWindows() -> [VisibleWindow]`. Wraps `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` + `.excludeDesktopElements`. Filters out our own PID, system overlays, alpha-zero windows, sub-200×100 clutter, and Finder desktop pseudo-windows by size heuristic. Returns Cocoa frames (already converted).
- **`WindowMutator.swift`** — writes AX position + size. `setFrame(_, of:)` does the size-position-size dance that defeats most app-side clamping. `applyBatch(_)` fires multiple moves in one runloop pass for cascade's per-window updates. This is the ONLY place that writes AX attributes.

### Cascade

- **`FanGeometry.swift`** — pure geometry. Given `(count, targetSize, reveal, screen, direction)`, produces the ordered array of target rects. Reveal-tightening (packing windows tighter when they'd overflow) lives here.
- **`CascadePlanning.swift`** — pure planning-size resolver. `resolveCascadePlanningSize(currentFrame, standardTargetSize, isSizeSettable)` decouples slot geometry from each window's mutable current size. Size-settable windows plan at `standardTargetSize` deterministically; non-settable windows preserve their current natural size. Fixes the "post-Plot cascade needs multiple invocations to converge" class of bug — planned slot positions no longer drift with mutable window state. Feature-flagged (`useDeterministicPlanningSizesForAllAppsCascade`) for rollback.
- **`CascadeZOrderDrift.swift`** — pure decision layer for the z-order settlement pipeline. `ZOrderMismatchRecord` (per-checkpoint history entry with slot-index Set + matchedCount + plannedCount coverage fields), `ZOrderFinalStatus` (9-variant final outcome including `.unresolvedObservationIncomplete` for the observation-starvation terminal), and three pure decision helpers: `isPersistentDrift(history)` (two consecutive complete-observation non-empty checkpoints with overlapping slot identities), `isObservationStarved(history)` (≥2 consecutive incomplete records ending at the latest checkpoint — the escalation trigger for cold cascades where CGWindowList can't map the full plan), and `postWalkMadeObservationProgress(bestPreWalkMatchedCount:postWalkMatchedCount:postWalkIncomplete:)` (walk-#2 gate — only fires when coverage strictly improved). `CascadeZOrderSettlementTiming` named constants (raise spacing 16ms, settled reobservation 200ms, late recommit earliest +1600ms, max 2 walks per generation). No AX, no state — testable in isolation.
- **`CascadeOrchestrator.swift`** — top-level flow for single-app, all-apps, and selection cascades. Runs pass 1 immediately (the sole PROVISIONAL correction owner — full-walk fallback allowed here when observation is incomplete), schedules retries at +0.12/0.5/1.0s. Captures a layout snapshot before each cascade for the "Restore Previous Layout" shortcut. Also owns the **z-order settlement pipeline** with three-round refinement:
  - **Two-phase correction ownership** (`useSingleOwnerZOrderSettlement`): pass 1 = provisional; pass 4 = authoritative final settlement; every intermediate stage between them is observation-only via `intermediateZOrderCheckpoint(plans:context:)`. This includes +300ms re-raise, pass 2/3 converged z-recheck, pass 2/3 post-write callbacks, Chromium native-repair success + native-failure→AX-fallback callbacks. `observeCascadeZOrderOnly(plans:context:)` runs the pure matcher, records the checkpoint into drift history for the settlement decision, logs `[observe-only]`, and fires zero raises. Under the pre-fix design each intermediate stage could fire a fallback full walk — for a cold Chromium-heavy cascade that produced 5-11 visible re-stackings per generation. Now: 1-2 max.
  - **Pass-4 observe-first** (`runPassFourZOrderCheckpoint` split into a wrapper + `runPassFourZOrderCheckpointCore`): the wrapper checks `nativeRepairCountForCurrentGeneration()` (the geometry-quiescence barrier) — non-zero means capture `pendingFinalSettlement` and return without touching windows. Every native-repair completion callback invokes `resumePendingFinalSettlementIfQuiescent(generation:)`; when the count drains to zero, a FRESH pure observation runs and the core fires. The core is observe-first classify: complete-correct → settle; persistent-drift → serialized reconstruction; observation-starvation → serialized reconstruction; complete-wrong-not-persistent → one ordinary correction; single-trailing-incomplete → truthful finalize (no blind full walk).
  - **Post-walk purity + progress-gated walk #2** (`scheduleSettledReobservation`, `handlePostWalkIncomplete`): after a serialized walk, reobservation uses the pure helper (zero AXRaise). If post-walk is complete + correct → settle; complete + wrong → schedule late recommit; incomplete AND coverage improved over `zOrderPreWalkBestMatchedCount` → schedule late recommit; incomplete AND no progress → finalize `.unresolvedObservationIncomplete` immediately (the retry-flicker fix).
  - **Idempotent finalization** (`finalizeZOrderSettlement(status:generation:reason:)`): every terminal current-generation branch emits exactly one `Stage 3 z-order settlement: FINAL — status=..., reason='...', generation=n` log line via a `zOrderFinalStatusEmitted` flag. Silent pass-4 exits are gone.
  - **Legacy `enforceCascadeZOrder`** remains for the Pass 1 provisional correction and the pass-4 case-4 "complete + isolated wrong, ordinary correction" branch. Its internal fallback-full-walk logic still lives here for those two callers.
  - Selection Cascade shares the exact same pipeline via `scheduleSelectionZOrderCheckpoint` (final pass) and `intermediateZOrderCheckpoint` (intermediate passes).
  - Chromium cascade laggards still route through `BrowserScripting.setBrowserWindowBoundsNearFrame` — that path unchanged; only the z-order response to its completion callback changed (now observation-only).
  - Fires `onSnapshotChanged` (menu rebuild) and `onWindowsMoved` (lasso overlay refresh) callbacks.
- **`LayoutSnapshot.swift`** — data type for the pre-cascade window layout that "Restore Previous Layout" replays.

### Lasso and selection

- **`WindowSelection.swift`** — the current selection: ordered `[VisibleWindow]` + observer callback. `replace(with:)` mutates and fires `onChange`. Nothing else holds long-term window references.
- **`GlobalEventMonitor.swift`** — the `CGEventTap` (mouse: leftMouseDown/Dragged/Up) + an `NSEvent` local monitor for Escape. **The tap is created disabled** and only enabled while lasso mode is on (`setTapActive(_:)`) — see the "CGEventTap safety" section below. Two exceptions pass clicks through even while lasso is on: the macOS menu bar (any click above `visibleFrame.maxY`) and any of our own visible interactive windows (name pill, release menu, alerts) so modals stay clickable.
- **`LassoCoordinator.swift`** — orchestrator for the lasso flow: rubber-band selection updates, group drag with per-frame overlay pan, mode-hint show/hide. Owns an `[CGWindowID: AXUIElement]` cache rebuilt on every `selection.onChange` — used by `refreshSelectionOverlay()` to read fresh AX positions after cascade so outlines follow the windows without CGWindowList's lag. Also owns the sleep/session-lock observers that force lasso off when the machine idles.
- **`SelectionOverlay.swift`** — the borderless NSPanel that draws the dashed selection outlines and the rubber-band lasso rectangle. Group-drag fast path (`beginGroupDrag`/`updateGroupDrag`/`endGroupDrag`) blits the panel origin via `setFrameOrigin` without re-drawing, avoiding overlay lag during fast drags.
- **`LassoModeHint.swift`** — the small "Lasso Mode: ON" chip in the corner.

### Plot Mode

Single-window precision placement — bound to `⌃⌥⌘P`. Click to select, drag to draw, release to place.

- **`PlotCoordinator.swift`** — the state machine (`inactive` / `awaitingWindow` / `windowSelected` / `pendingGesture` / `drawingPlot` / `committing`). Wires mouse events from `GlobalEventMonitor.onPlotMouseDown/Dragged/Up`. Mutually exclusive with Lasso — activation hooks fire `willActivate` to tear down the conflicting mode. Commit flow branches on target app's bundle ID: Chromium windows route through `BrowserScripting.setBrowserWindowBoundsNearFrame` (AppleScript bounds — persists where AX size reverts on Chrome/Brave/Edge/Opera/Vivaldi/Chromium); everything else uses the standard `WindowMutator.setFrame` AX path. Both paths run a settled readback + one optional `PlotGeometry.correctForConstraints` position write to anchor to the drawn snap edge when the app enforced a minimum size. Feature-flagged (`useBrowserNativeBoundsForPlot`) for rollback. Logs completion with `transport=browser-native | ax-fallback(nativeFailure=X) | ax` and settled-frame vs requested-frame diagnostics. **Cursor hit-test** (`resolveEligibleWindow(at:)`) has a two-tier fallback: fast path uses `CrossAppWindowEnumerator.allVisibleWindows().first(where: { $0.frame.contains(point) })` and resolves AX from that CGWindow; if no CGWindow's frame contains the point (the "just-plotted window, CGWindow bounds still lag AX" case), an AX-only fallback iterates unique PIDs from the same `all` list and queries `AXWindowEnumerator.windows(of:)` for each — returning the first fresh AX window whose current frame contains the point. Logs `AX-only fallback matched … — CGWindowList frame stale after recent plot` when the fallback saves the day. Fixes the "plot same window 2-3 times then can't reselect it without manual resize" reproduction.
- **`PlotGeometry.swift`** — pure snap + validation. `computePlotArea(rawRect:, visibleFrame:, previous:)` returns `(finalRect, PlotSnapState)` — each of N/S/E/W independently snaps to the display edge when the raw edge enters the outer 15% zone (with hysteresis to prevent flicker at the boundary). `correctForConstraints(actualSize:, requested:, intent:, visibleFrame:)` re-anchors to snap-intent edges when the app enforced a minimum size. Minimum area 80×60pt; drag threshold 6pt. No AppKit, no AX.
- **`PlotModeHint.swift`** — the persistent "Press Esc to End Plot Mode" pill. `show()` / `hide()` / `hideImmediately()` / `dim()` / `undim()` (dims to alpha 0.28 after a window is selected so the pill doesn't obscure the drawing area).
- **`PlotOverlay.swift`** — per-display NSPanel overlays that render the selected-window outline (dashed blue), the live Plot Area preview (translucent fill + snapped-edge emphasis), and the landing pulse around the final settled frame. Generation-guarded so a mode-teardown mid-animation can't leave overlays visible.

### Corral

- **`Corral.swift`** — `Corral`, `CorralMember`, `TabInfo` value types. `Codable` for UserDefaults persistence.
- **`CorralStore.swift`** — persistence: loads/saves the corral list to `UserDefaults.standard` under `com.jmw3.WindowWrangler.corrals.v1`. Enforces the 5-corral cap. Fires `onChange` for the menu to refresh its Release submenu.
- **`CorralOrchestrator.swift`** — save + restore flow. Save: preflight → name pill → capture members (AX title, doc path, browser tabs) → persist or overwrite. Restore: launch/reopen apps → 2s wait → move existing / open new per member → optional 2s retry pass. Idempotency: `alreadyAtTarget(member:)` skips re-restoring what's already at the saved frame. `hasWindowOnCurrentDesktop(bundleID:)` decides current-Space-aware open path. Post-restore scatter audit counts members not landed on current Desktop and surfaces in the result toast.
- **`CorralNamePill.swift`** — the modal name-entry pill.
- **`CorralReleaseMenu.swift`** — the modal release-menu with per-corral rows and delete buttons.
- **`CorralToast.swift`** — the ephemeral success / progress / scatter toast.
- **`CorralPanelHelpers.swift`** — shared `KeyablePanel` (NSPanel that accepts key events), `ButtonTarget` (@objc closure bridge), `centerCorralPanel(_)` (mouse-screen centering). Three UI files use these.

### Browser scripting

- **`BrowserScripting.swift`** — everything AppleScript for browsers. Chromium family + Safari. Bundle-ID addressing (`tell application id "…"`), 8-window enumeration cap, `whose bounds is {…}` shortcut for targeted lookup, timeout guard on every script call, per-bundle Automation permission tracking. Two API surfaces:
  - **Corral tab capture / restore** (existing): `snapshotBrowserWindowNearFrame`, `moveBrowserWindow`, `openBrowserWindow` — full snapshot + tab enumeration + window creation for the save/restore flow.
  - **Native window-bounds transport** (Plot + Cascade laggard repair): `supportsNativeWindowBounds(bundleID:)` (Chromium bundles only — Safari's AX writes are already reliable), `setBrowserWindowBoundsNearFrame(bundleID:, currentBoundsAX:, targetBoundsAX:) async → BrowserBoundsMoveResult` (fresh bounds enumeration → pure ambiguity-safe `matchBrowserWindow` → immediate bounds write; no tabs fetched, no snapshot cache used). Non-blocking via `runScriptAsync` that races the AppleScript against `Task.sleep(timeout)` on a background queue. Used by PlotCoordinator's Chromium commit path and CascadeOrchestrator's Chromium laggard repair — Chrome asynchronously reverts AX size writes on its next runloop tick, but the AppleScript `bounds` write goes through Chrome's Apple Event handler and persists. See the "Landmines" section for the `tab`-class shadowing trap.
- **`AutomationPermission.swift`** — thin Swift wrapper around `AEDeterminePermissionToAutomateTarget`. Returns `granted`/`denied`/`notAvailable`/`other(OSStatus)`. Also `openSystemSettings()` to jump to the Automation panel. Native-bounds transport calls this with `askIfNeeded: false` so Plot / Cascade never surface a Chrome-permission prompt mid-interaction — onboarding already ran the request pass.

### App shell

- **`WindowWranglerApp.swift`** — the AppDelegate. Wires everything together: lazy-instantiates coordinators, sets up permission monitoring, registers global shortcuts, wires `cascadeOrchestrator.onWindowsMoved` → `lassoCoordinator.refreshSelectionOverlay()`, wires `corralStore.onChange` → menu rebuild. `applicationDidFinishLaunching` orchestrates the sequence.
- **`WindowWranglerActions.swift`** — @objc protocol with every menu action. MenuBuilder wires NSMenuItem targets to methods declared here; AppDelegate implements them.
- **`MenuBuilder.swift`** — pure NSMenu construction. `build(state:target:)` returns a fresh NSMenu reflecting `State`. Stateless — call again to rebuild.
- **`MenuBarIcon.swift`** — provides the SF Symbol or custom icon for the status item.
- **`GlobalShortcuts.swift`** — the `CGEventTap`-based shortcut dispatcher. Registers `(modifiers, keyCode) → action` bindings; the tap intercepts keydowns and routes them.
- **`OnboardingWindowController.swift`** — SwiftUI onboarding window that requests Accessibility. Detected as granted via `AccessibilityPermission.isTrusted()` polling.
- **`AccessibilityPermission.swift`** — `isTrusted()` wrapper for `AXIsProcessTrustedWithOptions`. `openSystemSettings()` to jump to the Accessibility panel.

---

## Build and signing

### Development

Standard Xcode build. Signing identity is "Sign to Run Locally." Every rebuild re-signs the binary with a new signature (Xcode's default for local development), which is important context for the TCC section below.

Bundle identifier is `com.jmw3.WindowWrangler`. Change it to your Team's namespace before shipping.

### What production would require

Not implemented, but worth documenting the gap:

1. **Developer ID or Apple Distribution certificate** for stable code signing.
2. **Team ID** — anchors TCC records to a persistent identity so grants survive rebuilds.
3. **Notarization** — Apple's automated malware scan; required for Gatekeeper to allow the app on other users' machines without ⌃-click bypass.
4. **Entitlements review** for:
   - `com.apple.security.automation.apple-events` — already used, needs entry per target browser bundle ID in `Info.plist`'s `NSAppleEventsUsageDescription` context.
   - **Full Disk Access** (if you want to eliminate the Files & Folders TCC prompts on document restore for Sequoia+). This requires Apple's manual review.
5. **Info.plist hardening** — usage description strings that Apple's reviewer wants to see for every gated capability.
6. **MAS distribution** would additionally require sandbox entitlements, which would likely break the cross-app AX behavior (sandboxed apps can't read other apps' windows). MAS is probably not a viable path; Developer ID + direct distribution is the natural route.

The distinction that matters most: **notarization gives the app a stable Team ID that TCC keys against.** Every rebuild in development changes the signature; TCC's per-signature records fragment, leading to the "granted but doesn't work" state described below. Notarized production builds have one signature that persists.

---

## TCC (Transparency, Consent, Control) — the permission model

TCC is macOS's permission system. Two of its buckets matter to Wrangler:

### Accessibility

Required to read/move other apps' windows. Granted once, in **System Settings → Privacy & Security → Accessibility**. The `AccessibilityPermission` module handles the request path and polls `AXIsProcessTrustedWithOptions` to detect the grant.

### Automation (per target)

Required to send Apple Events to another app (AppleScript). Granted per-target — the first time we send an event to Chrome, macOS pops a "Window Wrangler wants to control Google Chrome" dialog. If the user allows, subsequent events succeed silently.

We use `AEDeterminePermissionToAutomateTarget` (via `AutomationPermission.check`) rather than running a benign AppleScript to probe permission — the API surfaces the prompt on first ask and returns a clean status on subsequent calls. During onboarding we iterate every installed supported browser and request permission for each, so the user gets all prompts in one intentional burst.

### The stale-signature failure mode

**The pathology:** repeated Xcode rebuilds change the app's code signature. TCC keys grants by signature. After several rebuilds, TCC's database can enter a state where:

- The Automation panel in System Settings shows the browser as "allowed" for Window Wrangler
- `AEDeterminePermissionToAutomateTarget` returns `.granted`
- But actual `NSAppleScript.executeAndReturnError` calls silently return empty output after 5–8 seconds

The scripting call isn't rejected — it's answered with `""`. No error. Just nothing.

**Why we care:** this is a development-only problem. Notarized production builds with a stable Team ID don't fragment TCC records. The parking-lot has this documented as a "notarization would fix" item.

**What we can't do:** both public reset paths for TCC — `tccutil reset AppleEvents com.jmw3.WindowWrangler` and toggling the entry in System Settings — have been observed **freezing the user's Mac** during this prototype's development. Documented macOS bugs; not something the app can work around. Do not automate either.

**The workaround we ship:** the 5-second timeout guard on every AppleScript call (see `BrowserScripting.runScriptWithTimeout`) keeps the app responsive even if a script hangs. When it fails, Corral just saves the browser's window position without tab data — degraded, not broken.

### Files and Folders (Sequoia+)

macOS Sequoia added per-folder prompts for anything reading files from `~/Documents`, `~/Desktop`, or `~/Downloads`. Corral restore's `NSWorkspace.open(fileURL, withApplicationAt:)` for document members triggers this. Users see a "Window Wrangler wants to access files in Downloads" dialog on first restore per folder.

**What would fix it:** Full Disk Access entitlement on a notarized build. Requires Apple's manual review.

---

## The CGEventTap safety story

`GlobalEventMonitor` owns a `CGEventTap` for left-mouse events. It's the mechanism that turns click-and-drag into lasso selection while lasso mode is on.

**The default-disabled invariant.** The tap is **created disabled** at startup. It's only enabled when `LassoCoordinator.toggleLassoMode` turns lasso on, and immediately disabled when lasso turns off. When lasso is off (99% of the time), macOS routes left-mouse events directly to their targets without ever calling our callback.

**Why this matters.** CGEventTap callbacks that misbehave can hose the entire system's click flow — clicks disappear until macOS notices the callback timeout and disables the tap. During this project's development, one such incident required a forced restart to recover. By keeping the tap idle unless the user has explicitly engaged lasso mode, we eliminate the class of "background app freezes clicks after machine goes idle" failures.

**Sleep / session-lock observers.** `LassoCoordinator.wireIdleSafetyObservers` subscribes to `NSWorkspace.willSleepNotification` and `sessionDidResignActiveNotification`. When either fires while lasso is active, we force lasso off (which disables the tap) before macOS transitions state. Prevents the tap from coming back from sleep in a stuck state.

**The two pass-through exceptions** (in `handleMouseEvent`):

1. **Menu bar** — any click whose y-coord is above `visibleFrame.maxY` passes through unchanged. So the user can click our own menu-bar icon and any system menu bar item while lasso is on.
2. **Our own visible windows** — iterating `NSApp.windows` for anything with `!ignoresMouseEvents`, matching by frame. So the name pill, release menu, and NSAlerts remain interactable while lasso is on.

The overlay windows (`SelectionOverlay`, `LassoModeHint`) have `ignoresMouseEvents = true` and are correctly filtered out — clicks over them still get consumed for lasso as intended.

---

## Coordinate spaces — the recurring gotcha

macOS has two coordinate systems for windows and points:

- **AX / CoreGraphics** — top-left origin, y-axis grows down, global (all displays in one plane). This is what `kAXPosition`/`kAXSize` and `CGWindowListCopyWindowInfo`'s bounds dictionary return.
- **Cocoa / AppKit** — bottom-left origin, y-axis grows up, per-primary-screen. This is what `NSWindow.frame` and `NSEvent.mouseLocation` use.

The whole codebase converts at boundaries. `CoordinateSpace.axRect(fromCocoa:)` and `CoordinateSpace.cocoaRect(fromAX:)` are the two workhorses. Every type field that stores a rect makes its space explicit in the name:

- `frame: CGRect` — Cocoa
- `boundsAX: CGRect` — AX

If you're debugging a "window moves to the wrong place" bug, always check what coordinate space each value is in before doing arithmetic. `CrossAppWindowEnumerator` returns Cocoa frames after converting from CGWindowList's AX bounds. `AXWindowEnumerator` returns Cocoa frames too (converts internally). `WindowMutator.setFrame` takes Cocoa frames (converts to AX before writing).

The lasso overlay draws in Cocoa space (that's what NSPanel and NSView use). The event tap returns AX coordinates (`event.location`); `GlobalEventMonitor.locationInCocoaCoords` converts before passing to the lasso callbacks.

---

## Testing

**141 tests currently passing**, all XCTest, running under the `Window WranglerTests` target (Xcode filesystem-synchronized group — new test files in that folder are auto-picked up). Coverage is on the pure-geometry / pure-decision modules; the orchestrators remain user-validated through Console logs.

Current test files:

- **`CoordinateSpaceTests.swift`** — AX ↔ Cocoa round-trip identity, negative-coordinate displays, primary-display pivot rules.
- **`FanGeometryTests.swift`** — cascade layout with anchor override, natural-vs-rigid shifting, reveal reduction, empty input, single-window special case.
- **`WindowSelectionTests.swift`** — selection state semantics (`replace(with:)` fires only on actual change, duplicate-ID collapse, frames ordered by windowID).
- **`BrowserBoundsMatcherTests.swift`** — the pure `BrowserScripting.matchBrowserWindow` matcher: exact/near/no/beyond-tolerance/tied/duplicate/ordered-alignment/negative-coord scenarios + `supportsNativeWindowBounds` bundle-ID coverage.
- **`CascadePlanningTests.swift`** — resolver invariance (settable → always target size), non-settable preservation, negative-coord independence, end-to-end `fitFrame` determinism (Set A vs Set B with different current sizes → identical target for settable windows), old-behavior regression proof.
- **`CascadeZOrderDriftTests.swift`** — persistent-drift detection identity semantics: transient burst vs recurring pattern, disjoint vs overlapping slots, incomplete-observation handling, warm-cascade zero-correction, cold-start pattern reproduction, `zOrderStatusIsSettled` matrix.
- **`SelectionCascadeSettlementTests.swift`** — parity with All-Apps: drift detection with Selection labels, warm zero-raise, transient-drift clearing, reported failure reproduction, shared final-status handling, shared timing constants (no forks).
- **`CascadeZOrderStarvationTests.swift`** — the observation-starvation detector: streak semantics (empty / 1-record / 2-consecutive / 3+ / streak-must-end-at-latest / churn cases), independence from persistent-drift, exact cold-start trace regression (3/7→3/7→3/7→5/7→5/7 pattern), match-ratio-independence proof, `.unresolvedObservationIncomplete` final-status matrix.
- **`CascadeZOrderProgressTests.swift`** — the walk-#2 progress gate: complete-observation-not-this-function's-decision, coverage-increased-progress, equal-coverage-plateau, regressed-coverage-not-progress, baseline-zero cases, exact reported-plateau regressions (5/6, 7/8), improving 5/8→7/8 permits-walk-#2, `ZOrderMismatchRecord` matched/planned field round-trip, coupling regression guards against detectors.
- **`CascadeZOrderCorrectionOwnershipTests.swift`** — the two-phase correction-owner + geometry-quiescence model: exact reported worst-case (gen-24 style) intermediate-records-produce-correct-pass-4 regression, structural plateau walk-2 suppression, warm-cascade detectors quiet, intermediate observations feed persistent-drift, Selection warm + plateau parity, pre-walk-best computable from record history.

If you add tests: pure modules first (`FanGeometry`, `CoordinateSpace`, `PlotGeometry`, `CascadePlanning`, `CascadeZOrderDrift`, `BrowserScripting.matchBrowserWindow`). Orchestrators (`PlotCoordinator`, `CascadeOrchestrator`, `LassoCoordinator`, `CorralOrchestrator`) remain harder to unit-test without extensive AX + AppKit mocking — for those the manual test matrices in past commit messages are the reference.

---

## The parking lot as of current session

Items intentionally deferred. The user (project owner) is aware of each. Not surprises.

### Repo hygiene

- **Private GitHub remote** — now `origin` at `github.com/j3rdgen/WindowWrangler.git`. Push cadence: after each substantial commit.
- **README.md, HANDOFF.md, TECHNICAL_OVERVIEW.md** — this doc set exists; kept current alongside code changes.
- **LICENSE** — currently just "all rights reserved" in the README; should be a formal file.
- **`.gitignore` audit** — confirm no DerivedData / secrets / build artifacts tracked.
- **Feature-branch + PR workflow** — currently working on `cascade-flicker-refinement`, direct-commit style. Fine for solo work; matters at handoff.
- **Semantic version releases** — will be relevant when moving toward distribution.

### Scope items deferred from prototype

- **M7 — adjustable header + lateral reveal in a Preferences UI.** Sketched: a SwiftUI Preferences window with two sliders (vertical / horizontal cascade offsets), values persisted in `UserDefaults`, cascade geometry code reads from those settings. Deferred because the hardcoded defaults (28pt header reveal, 60pt lateral reveal) feel right in practice — no scenario has surfaced where they don't. Revisit if one does.
- **Uniform window sizing** — capture the frontmost window's current dimensions via `⌃⌥⌘U`, apply as target size to every subsequent cascade until cleared. Sketched in the CLAUDE.md parking-lot with concrete implementation details. Small addition (~30 lines new `UniformSize.swift`, two menu items, one target-size site in `CascadeOrchestrator`). Not blocking anything; revisit when a real need surfaces.

### Recently resolved (previously parking-lot)

- **Chrome AX size revert during cascade / Plot** — resolved via Chromium native-bounds AppleScript transport (see BrowserScripting module). AX writes are still the default for non-Chromium; Chromium windows go through `set bounds of window N` which persists.
- **Post-Plot cascade required 4-5 invocations to converge** — resolved via deterministic planning-size resolver (`CascadePlanning`). Slot geometry now uses `standardTargetSize` for size-settable windows regardless of current dimensions.
- **Intermittent wrong-depth after cascade** — resolved via bounded z-order settlement pipeline (per-generation drift history, pass-4 persistent-drift escalation, async 16ms-spaced serialized reconstruction, conditional late recommit at +1600ms, max 2 walks). Applies to All-Apps and Selection cascades.
- **Lasso auto-cascade after multi-window resize occasionally wrong depth** — resolved by extending the settlement pipeline to `performCascadeOnSelection` with the same +120/+300/+500/+1000ms checkpoints and shared escalation.
- **Cold-start cascade silent-exit when observations remain incomplete** — resolved via observation-starvation escalation. `CascadeZOrderDrift.isObservationStarved` detects ≥2 consecutive incomplete records; pass 4 escalates via the same serialized reconstruction with trigger `observation-starvation`. New `.unresolvedObservationIncomplete` final status reports the terminal state truthfully when public observation genuinely cannot verify.
- **Multi-pass retry flicker (5-11 visible re-stackings per cold Chromium cascade)** — resolved via two-phase correction ownership. Pass 1 is the sole PROVISIONAL correction owner; every intermediate stage (+300ms, pass 2/3 converged, pass 2/3 post-write, Chromium native-repair success + failure→AX callbacks, Selection intermediate) is observation-only via `intermediateZOrderCheckpoint`. Pass 4 is the sole AUTHORITATIVE correction owner, deferred via a `pendingFinalSettlement` marker + `nativeRepairCountForCurrentGeneration()` quiescence barrier until Chromium native-repair callbacks drain. Cold cascades now produce 1-2 visible re-stackings max.
- **Redundant walk #2 on structural observation plateaus** — resolved via progress-gated walk #2. `postWalkMadeObservationProgress` decides: strictly-improved coverage permits walk #2; equal or worse coverage (structural plateau like 5/6 → 5/6 or 7/8 → 7/8) suppresses walk #2 and finalizes truthfully. Removes the second serialized walk when there's no evidence it would help.
- **Cascade during lasso mode** (positioning + z-order issues while windows were outlined) — resolved as a side-effect of the two-phase correction ownership work + reduced AX-write volume during settlement. No longer reproducible.
- **Plot cursor hit-test fails after 2-3 back-to-back plots of the same window** — resolved via `PlotCoordinator.resolveEligibleWindow` AX-only fallback: when CGWindow bounds lag AX after a recent plot, the cursor-hit-test iterates unique PIDs from `allVisibleWindows()` and queries each app's fresh AX windows to find one whose current frame contains the click. Users can now re-plot the same window immediately.

### Known limitations (macOS-inherent or design trade-offs, not bugs)

Listed here for the handoff developer to evaluate with full production context.

**M6 group drag latency on Chrome / Zoom.** During fast drags of Chrome or Zoom windows, the dashed selection outlines can drift 20–40 pixels ahead of the actual windows for a frame or two before catching up on release. Root cause: AX writes travel to the target app's runloop, get applied, propagate to WindowServer — for slow apps this takes multiple screen refreshes. Every code-level lever inside AX is already pulled (fast panel pan, read-back pacing, read-before-write ordering, position-only writes). Further reduction requires either a CVDisplayLink-driven overlay update loop (~50% improvement) or CGS/SkyLight private APIs (yabai's approach — requires SIP off).

**Multi-Space (Virtual Desktop) restore.** macOS provides no public API to (a) read which Space a window is on, (b) move a window between Spaces, or (c) tell an app which Space to spawn a new window on. On restore, non-browser windows on other Spaces are AX-moved to their saved frames (still on their Space — visually invisible until you swipe there). Browser windows created via AppleScript `make new window` land where macOS decides — usually the browser's most-recently-active Space, which may not match the user's current Desktop. Documented as user-facing behavior in the README, with the system-setting workaround.

**AX -25211 (`kAXErrorAPIDisabled`) wake-up.** Backgrounded apps' AX proxies return `-25211` on first query until macOS "wakes them up." `AXWindowEnumerator.windows(of:)` retries once after 50ms; usually succeeds on the second call (`kAXWindows recovered after -25211 retry` in the log). If a future macOS release changes wake-up latency, bump the 50ms.

**Chrome hidden helper windows.** Chrome's `windows` AppleScript collection includes 25+ hidden helper windows (extension popups, DevTools panels, PWA hosts, tab-detach shadows). Walking these via per-window property access hangs Chrome's scripting handler indefinitely. All Chrome enumeration scripts cap at 8 windows (`if winCount > 8 then set winCount to 8`) — Chrome's `windows` collection is z-ordered, so top-8 covers all realistic user-visible browser windows. The `whose bounds is {…}` shortcut has no cap and covers the edge where a lassoed window falls outside top-8.

**NSAppleScript no cancellation API.** `NSAppleScript.executeAndReturnError` blocks the calling thread until the target app responds — Apple provides no cancellation API. `runScriptWithTimeout` wraps every call in a 5-second semaphore-bounded background dispatch: after 5s the wait returns nil. The underlying script keeps running in a background thread we can't kill (log-tail confirms — timed-out scripts occasionally emit their completion log 15–30s later). In practice this doesn't accumulate meaningfully because the tab-class fix made timeouts rare, but if the app ever feels sluggish after many failed Chrome saves in one session, restart to clear leaked threads. Real fix: rewrite the scripting layer using `AESendMessage` with `kAETimeout`, which is cancellable. Significant work.

---

## Landmines

Traps that will bite anyone extending the code who hasn't read this section.

### Chrome / Safari `tab`-class shadowing in AppleScript

**The trap.** Inside `tell application id "com.google.Chrome"`, the identifier `tab` refers to Chrome's `tab` **class object** (Chrome models browser tabs as first-class AppleScript objects), **not** AppleScript's built-in tab-character constant. Writing `& tab &` as a field separator makes Chrome coerce its `tab` class to the string `"tab"`, producing garbage output any downstream parser can't split.

**The symptom.** Silent failure. Chrome returns a valid non-empty result, but every field separator is the literal string `"tab"` instead of `\t`. Any parser that splits on `\t` gets zero fields per line and reports "0 windows found." No error, no exception, no log signal — just empty results.

**The fix in place.** Every Chrome/Safari script builder in `BrowserScripting.swift` declares:

```applescript
set tabCh to (ASCII character 9)
set lf to (ASCII character 10)
```

**OUTSIDE** the `tell application id "…"` block, and uses `tabCh` and `lf` unambiguously as separators inside. Same for Safari — it also defines a `tab` class in its dictionary.

**If you add a new Chrome script,** you MUST follow this pattern. Do not write `& tab &` inside the tell block, ever. The failure mode is silent and the symptom (parser returns 0 windows) hides the cause completely. Cost hours to diagnose the first time.

### AX ↔ CGWindowID gap

Public AX API provides no way to map an `AXUIElement` to a `CGWindowID` or vice versa. The two identifier spaces don't cross-reference.

**Why this matters.** After a cascade moves windows via AX, our selection overlay needs to draw outlines at the windows' new positions. The overlay tracks windows by `CGWindowID` (from `CGWindowListCopyWindowInfo`). But CGWindowList's frame data lags AX writes by several hundred milliseconds for cross-app windows. Reading frames from CGWindowList right after `WindowMutator.applyBatch` returns stale (pre-move) frames — outlines appear to lag by one cascade pass.

**Our workaround.** `LassoCoordinator` maintains an `[CGWindowID: AXUIElement]` cache, populated when the selection changes (windows are stationary then, so a PID+frame match reliably resolves each CGWindowID to its AX element). `refreshSelectionOverlay()` reads fresh positions directly from each cached AX element via `kAXPosition` + `kAXSize` — synchronous and reflects our own AX writes.

**If you need the mapping generically** (e.g., for a future feature): the standard trick is the private `_AXUIElementGetWindow(AXUIElementRef, CGWindowID*)` SPI. Used by yabai, Rectangle's newer builds, and Moom. Undocumented but stable across ~15 years of macOS releases. Adding it accepts a fragility risk in exchange for a robust mapping. Not used here because the prototype requirement was public API only.

### CGWindowList staleness

`CGWindowListCopyWindowInfo` frames lag AX writes by hundreds of ms for cross-app windows (Chrome especially). If you read a window's frame from CGWindowList immediately after moving it via AX, you'll see the pre-move frame. Either wait 500ms+ or read from AX directly.

### Chrome `activate` triggers Space switch

Removed from `openChromiumWindowScript` for exactly this reason. Chrome's AppleScript `activate` command, when Chrome has windows on a different Space than the user, triggers macOS's "switch to Space with app's windows" behavior. macOS auto-swipes to Chrome's Space before the new window lands, creating a visible half-second Desktop flash.

**Fix in place.** `openChromiumWindowScript` does NOT run `activate` before `make new window`. The window creation still works — AppleScript's `tell application` semantics auto-launch a not-running target, and the window is created without frontmost activation.

### `/usr/bin/open -b <bundleID>` triggers Space switch (browsers only)

Same class of bug as `activate`. When Chrome is running with windows on other Desktops, `open -b com.google.Chrome` activates Chrome via LaunchServices, which triggers the same "switch to app's Space" behavior. Auto-swipes the user off their current Desktop.

**Fix in place.** `CorralOrchestrator.openAppForRestore` skips `/usr/bin/open -b` entirely for browsers. Browsers get their windows created via AppleScript in `restoreBrowserMember` → `openChromiumWindowScript`, which doesn't activate. Non-browsers still get `open -b` as their launch path.

### Chromium apps asynchronously revert AX size writes

**The trap.** Chrome, Brave, Edge, Opera, Vivaldi, and other Chromium-derived browsers accept `AXUIElementSetAttributeValue(kAXSizeAttribute, …)` writes and immediately report the new size — then, on the next Chrome runloop tick (~15–30ms), silently revert the size to whatever they think it should be. Position writes are honored; size writes bounce. No error, no log signal.

**Where it bit us.** (1) Cascade end-shot verification saw the position at target but size back to pre-cascade, flagging every Chrome window as a "laggard" and re-cascading in an infinite loop. (2) Plot Mode's draw-your-rectangle gesture worked for every app except Chrome — user drags a 1000×600 area, Chrome ends up at its previous size, position was correct.

**Fix in place.** Chromium windows (bundle IDs matched via `BrowserScripting.supportsNativeWindowBounds`) route through `BrowserScripting.setBrowserWindowBoundsNearFrame`, which uses AppleScript `set bounds of window N to {x1, y1, x2, y2}` — a single atomic write through Chrome's Apple Event handler. The bounds path is not subject to the AX size-revert behavior; Chrome persists the write. `PlotCoordinator` and `CascadeOrchestrator` both branch on `supportsNativeWindowBounds(bundleID:)` and pick the native transport for those bundles.

**If you add a new mutation path** that changes size on cross-app windows, mirror the branch. AX-only for Safari (its AX writes are reliable), AppleScript-bounds for Chromium. Feature-flagged (`useBrowserNativeBoundsForPlot`) — flip off if a specific Chrome version regresses the AppleScript path.

### Observe/correct separation — the correction-ownership invariant

**The rule.** For a single cascade generation there is exactly ONE provisional correction owner (pass 1) and exactly ONE authoritative final correction owner (pass 4, deferred until geometry quiescence). Every stage between them observes and records; it does NOT correct.

**Why.** Pre-fix, every intermediate stage called `enforceCascadeZOrder`, which fires a fallback full walk when observation is incomplete. For a cold Chromium-heavy cascade with a chronically-unmappable window (Grammarly / Notes / Podcasts on this Mac), that produced up to 11 visible re-stackings per generation — one per stage-that-decided-to-correct. Each Chromium native-repair completion (× N Chromium windows) added its own walk, and the pass-4 serialized reconstruction interleaved with in-flight native-repair callbacks, producing walk-inside-walk churn.

**The discipline.** Any new call site that runs after pass 1 and before final settlement MUST use `intermediateZOrderCheckpoint(plans:context:)`, not `enforceCascadeZOrder`. That dispatcher routes through `observeCascadeZOrderOnly` when `useSingleOwnerZOrderSettlement` is true (default) — records the checkpoint into drift history for the settlement decision, fires zero AXRaise, logs `[observe-only]`.

**Pass 4 quiescence barrier.** `runPassFourZOrderCheckpoint` (the wrapper, NOT the core) checks `nativeRepairCountForCurrentGeneration()` first. If non-zero, it captures `pendingFinalSettlement = (plans, generation, context)` and returns without touching windows. Every native-repair completion callback invokes `resumePendingFinalSettlementIfQuiescent(generation:)`; when the count drains to zero, it takes a FRESH pure observation and calls the core (which is the observe-first classifier). This prevents serialized-reconstruction raises from interleaving with in-flight native-repair writes.

**Two paths from the discipline are still corrective.** Don't confuse them with intermediate stages:
- **Pass 1 immediate enforcement** — provisional owner. Calls `enforceCascadeZOrder`, which is allowed to fire the front-prefix corrector OR (on incomplete observation) one fallback full walk. This is the user's immediate best-effort z-order.
- **Pass 4 case-4 ordinary correction** — for the "complete + isolated wrong, not persistent" branch, `runPassFourZOrderCheckpointCore` still calls `enforceCascadeZOrder` to run one front-prefix correction. Documented in the code comment.

**If you add a new callback** (retry pass, cross-app rescue, geometry-drain hook, etc.), read the "two-phase correction ownership" doc-comment in `CascadeOrchestrator.swift` before adding a z-order operation. The default should be `intermediateZOrderCheckpoint(plans:context:)`. Escalating to a correction from an intermediate site re-introduces the multi-pass flicker class of bug.

### CGWindowList z-order vs observed reality gap

**The trap.** `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` returns windows in front-to-back z-order, and we use that ordering to observe what stack order actually took effect after `AXUIElementPerformAction(kAXRaiseAction)` calls during cascade. But CGWindowList's z-order snapshot lags the WindowServer state by up to hundreds of ms for cross-app windows — so a well-formed pass-1 cascade can appear to leave 3 windows at the wrong depth when in reality every raise landed correctly and the observation itself is stale.

**Where it bit us.** Cold-start cascades with 5+ apps consistently reported "3 windows still drifted" at pass-2 checkpoint, escalated to serialized reconstruction, and produced a visible re-stacking flicker — even though a subsequent complete observation 200ms later showed correct order. The persistent-drift detector's job is to distinguish "same slot keeps drifting across TWO consecutive complete observations" (real) from "one stale observation" (fake).

**Fix in place.** `CascadeZOrderDrift.isPersistentDrift(history)` requires **two consecutive complete-observation non-empty checkpoints with overlapping slot identities** before escalating. `observationIncomplete` records don't count. This is why the pipeline schedules four spaced checkpoints (+120/+300/+500/+1000ms) — the spacing lets CGWindowList catch up between reads, so single-checkpoint stale reads don't cascade into cosmetic serialized-reconstruction walks. Also why the final status can downgrade `.observationIncomplete` → `.settledNoCorrection` once a later complete observation confirms.

**If you add another z-order verification path**, use the same primitives — never trigger corrective action on a single observation, never use count-only heuristics (a two-window drift that shifts identity across reads is not persistent), and always let the drift history carry the incomplete-observation flag.

### Plot cursor hit-test needs the AX-only fallback for repeat-plot

**The trap.** `PlotCoordinator.resolveEligibleWindow(at:)` calls `CrossAppWindowEnumerator.allVisibleWindows().first(where: { $0.frame.contains(point) })` to find the topmost window under a click. If that returns nil, the user sees `No eligible window under cursor at (X, Y)` and Plot Mode is stuck until they click somewhere else or exit.

**The failure mode.** Right after a Plot commits, the moved window's actual AX position updates immediately, but CGWindowList continues to report the pre-plot frame for several hundred ms. Reproducer: plot Finder, then immediately re-enter Plot Mode and try to click on Finder at its new location. CGWindowList still reports Finder at the OLD position; the click point is over the NEW position; `frame.contains(point)` returns false for every candidate; `first(where:)` returns nil; Plot emits "No eligible window under cursor" even though Finder IS visually right there.

**Fix in place.** `resolveEligibleWindow` has a two-tier resolution:
1. Fast path (unchanged): topmost CGWindow whose frame contains the point.
2. AX-only fallback (new): if no CGWindow contains the point, iterate unique PIDs from the same `allVisibleWindows()` list and query each app's fresh AX windows. Return the first whose current AX frame contains the click. Logs `AX-only fallback matched … — CGWindowList frame stale after recent plot`.

**Safety.** The fallback only queries PIDs already in `allVisibleWindows()` — that list is pre-filtered against own PID, Dock, menu extras, Desktop backdrop, size-minimum failures, and non-standard subroles. It can't accidentally pick up the Dock or a system UI overlay. `AXWindowEnumerator.windows(of:)` applies its own subrole allowlist. Front-to-back z-order is preserved via unique-PID iteration in original list order.

**If you add other cursor-hit-test call sites** (single-app cascade under cursor, lasso window-under-cursor, etc.), consider whether the same CGWindow-stale-bounds issue can bite you and pattern the same two-tier resolution.

### `NSRunningApplication.runningApplications(withBundleIdentifier:).first` is unreliable for multi-PID apps

Console (and some other Apple system apps) can have multiple concurrent PIDs for a single bundle. Window ownership can land on any of them. `.first` is not deterministic.

**Fix in place.** `CorralOrchestrator.findWindow` iterates all PIDs for the target bundle ID and uses the first PID whose AX enumeration returns non-empty windows. Not perfect (still doesn't handle "multiple PIDs, all with windows"), but handles the common Console pattern.

---

## Development environment

- **macOS 26.5 (Tahoe)** — primary test target.
- **macOS 13 (Ventura) minimum** per `Info.plist`. Not actively tested on Ventura or Sonoma.
- **Xcode 26.5+** to build. Swift 6-mode enabled; the codebase uses `@MainActor` isolation extensively.
- **Retina Built-in Display** — primary test surface. Multi-display setups were tested lightly (secondary Thunderbolt display attached during some sessions). Multi-display cascade uses the display containing the mouse cursor at shortcut-fire time — see `WindowWranglerApp.shortcutCascade` for the pattern.
- **Personal test rig** — the developer's daily-driver machine. All observed behavior is on that specific hardware / macOS install / TCC state. See the "TCC" section for how developer state can drift from production reality.

---

## Where to start

If you're new to the codebase and want to understand it fastest:

1. Read this document once end-to-end.
2. Skim `CLAUDE.md` for the original project intent and working-style notes.
3. Read `CascadeOrchestrator.swift` (single-app cascade is the simplest working orchestrator).
4. Read `LassoCoordinator.swift` to see how the input event → selection → overlay flow wires together.
5. Read `CorralOrchestrator.swift` last — the biggest orchestrator, the most gotchas, but structured similarly to the others.

If you're going to add a browser feature: read `BrowserScripting.swift` in full FIRST. The `tab`-class shadowing landmine will bite you otherwise. Chromium size writes also need the native-bounds transport, not AX — see the "Chromium apps asynchronously revert AX size writes" landmine.

If you're going to touch the event tap: read `GlobalEventMonitor.swift` and the "CGEventTap safety" section above in full. The default-disabled invariant is load-bearing.

If you're going to add a modal UI: read `CorralPanelHelpers.swift` — it hosts the three shared symbols (`KeyablePanel`, `ButtonTarget`, `centerCorralPanel`) that the existing modals use. Follow the pattern instead of rolling your own.

If you're going to touch cascade z-order enforcement: read `CascadeZOrderDrift.swift` (pure primitives) AND both the "CGWindowList z-order vs observed reality gap" and "Observe/correct separation — the correction-ownership invariant" landmines before writing any corrective action. Two rules together: (1) never trigger correction on a single observation — persistent-drift requires two consecutive complete-observation records; (2) never add a corrective call outside pass 1 or pass-4's core — every intermediate stage must be observation-only via `intermediateZOrderCheckpoint`. Violating either re-introduces a class of flicker bug that took multiple sessions to eliminate.

If you're going to touch Plot Mode's cursor hit-test: read `PlotCoordinator.resolveEligibleWindow` and the "Plot cursor hit-test needs the AX-only fallback for repeat-plot" landmine. The two-tier CGWindow-then-AX resolution is the fix for the "can't reselect the window I just plotted" bug — don't collapse it back to a single lookup.
