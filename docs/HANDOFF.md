# Window Wrangler — Handoff Guide

For a developer taking over the codebase. Read this once, then use it as a map when questions surface.

- **[README.md](../README.md)** is the porch: what it is, how to build, first-run permissions.
- **[TECHNICAL_OVERVIEW.md](TECHNICAL_OVERVIEW.md)** is for external planners / business tooling — it describes the product profile, not the code.
- **This document** is the code map: architecture, patterns, gotchas, and the parking-lot state as of MVP-1.0.

---

## Development context

- **Solo dev, non-developer.** The person who owns this project can read code at a high level, run commands you give them, and describe observed behavior, but cannot debug Swift errors independently. Any issue reported comes with a Console log and a description; diagnosis is your job.
- **AI as primary code author.** Written with Claude Code as the primary author over ~2 weeks. Every commit represents a validated user-tested outcome, not an AI-generated draft. If a commit exists, the associated behavior was verified.
- **Prototype phase.** The goal was to validate the core mechanics (cascade, lasso, corral) on the author's own machine before hiring a developer for production polish. That means: no code signing beyond local self-sign, no notarization, no distribution wiring, no unit tests beyond a scaffolded target that isn't wired up.
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

- **`Log.swift`** — `os.Logger` categories: `app`, `ax`, `cascade`, `lasso`, `permission`, `corral`. Console filter for our subsystem is `subsystem:com.jmw3.WindowWrangler`. Everything is subsystem-scoped so you can filter noise from other apps.
- **`AppInfo.swift`** — Small helper for the app's own display name (`Bundle.main` lookup).
- **`CoordinateSpace.swift`** — AX ↔ Cocoa conversion. `CoordinateSpace.axRect(fromCocoa:)` and `cocoaRect(fromAX:)` are the workhorse converters. Also has `screen(containing:)` used by the modal panels for center-on-mouse-screen positioning.

### AX and window enumeration

- **`AXWindowEnumerator.swift`** — `windows(of: NSRunningApplication) -> [EnumeratedWindow]`. Reads `kAXWindowsAttribute`. Includes the **one-shot 50ms retry on `-25211`** (kAXErrorAPIDisabled) that wakes up backgrounded apps' AX proxies. Filters by subrole (`AXStandardWindow`, `AXDialog`, `AXFloatingWindow`), scoping out popovers, menus, minimized windows. Finder's Desktop backdrop gets its own explicit filter.
- **`CrossAppWindowEnumerator.swift`** — `allVisibleWindows() -> [VisibleWindow]`. Wraps `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` + `.excludeDesktopElements`. Filters out our own PID, system overlays, alpha-zero windows, sub-200×100 clutter, and Finder desktop pseudo-windows by size heuristic. Returns Cocoa frames (already converted).
- **`WindowMutator.swift`** — writes AX position + size. `setFrame(_, of:)` does the size-position-size dance that defeats most app-side clamping. `applyBatch(_)` fires multiple moves in one runloop pass for cascade's per-window updates. This is the ONLY place that writes AX attributes.

### Cascade

- **`FanGeometry.swift`** — pure geometry. Given `(count, targetSize, reveal, screen, direction)`, produces the ordered array of target rects. Reveal-tightening (packing windows tighter when they'd overflow) lives here.
- **`CascadeOrchestrator.swift`** — top-level flow for both single-app and all-apps cascade. Runs pass 1 immediately, schedules retries at +0.12/0.5/1.0s to nudge laggards, then verifies. Captures a layout snapshot before each cascade for the "Restore Previous Layout" shortcut. Cross-app z-order enforcement is here (`enforceCascadeZOrder`). Fires `onSnapshotChanged` (menu rebuild) and `onWindowsMoved` (lasso overlay refresh) callbacks.
- **`LayoutSnapshot.swift`** — data type for the pre-cascade window layout that "Restore Previous Layout" replays.

### Lasso and selection

- **`WindowSelection.swift`** — the current selection: ordered `[VisibleWindow]` + observer callback. `replace(with:)` mutates and fires `onChange`. Nothing else holds long-term window references.
- **`GlobalEventMonitor.swift`** — the `CGEventTap` (mouse: leftMouseDown/Dragged/Up) + an `NSEvent` local monitor for Escape. **The tap is created disabled** and only enabled while lasso mode is on (`setTapActive(_:)`) — see the "CGEventTap safety" section below. Two exceptions pass clicks through even while lasso is on: the macOS menu bar (any click above `visibleFrame.maxY`) and any of our own visible interactive windows (name pill, release menu, alerts) so modals stay clickable.
- **`LassoCoordinator.swift`** — orchestrator for the lasso flow: rubber-band selection updates, group drag with per-frame overlay pan, mode-hint show/hide. Owns an `[CGWindowID: AXUIElement]` cache rebuilt on every `selection.onChange` — used by `refreshSelectionOverlay()` to read fresh AX positions after cascade so outlines follow the windows without CGWindowList's lag. Also owns the sleep/session-lock observers that force lasso off when the machine idles.
- **`SelectionOverlay.swift`** — the borderless NSPanel that draws the dashed selection outlines and the rubber-band lasso rectangle. Group-drag fast path (`beginGroupDrag`/`updateGroupDrag`/`endGroupDrag`) blits the panel origin via `setFrameOrigin` without re-drawing, avoiding overlay lag during fast drags.
- **`LassoModeHint.swift`** — the small "Lasso Mode: ON" chip in the corner.

### Corral

- **`Corral.swift`** — `Corral`, `CorralMember`, `TabInfo` value types. `Codable` for UserDefaults persistence.
- **`CorralStore.swift`** — persistence: loads/saves the corral list to `UserDefaults.standard` under `com.jmw3.WindowWrangler.corrals.v1`. Enforces the 5-corral cap. Fires `onChange` for the menu to refresh its Release submenu.
- **`CorralOrchestrator.swift`** — save + restore flow. Save: preflight → name pill → capture members (AX title, doc path, browser tabs) → persist or overwrite. Restore: launch/reopen apps → 2s wait → move existing / open new per member → optional 2s retry pass. Idempotency: `alreadyAtTarget(member:)` skips re-restoring what's already at the saved frame. `hasWindowOnCurrentDesktop(bundleID:)` decides current-Space-aware open path. Post-restore scatter audit counts members not landed on current Desktop and surfaces in the result toast.
- **`CorralNamePill.swift`** — the modal name-entry pill.
- **`CorralReleaseMenu.swift`** — the modal release-menu with per-corral rows and delete buttons.
- **`CorralToast.swift`** — the ephemeral success / progress / scatter toast.
- **`CorralPanelHelpers.swift`** — shared `KeyablePanel` (NSPanel that accepts key events), `ButtonTarget` (@objc closure bridge), `centerCorralPanel(_)` (mouse-screen centering). Three UI files use these.

### Browser scripting

- **`BrowserScripting.swift`** — everything AppleScript for browsers. Chromium family + Safari. Bundle-ID addressing (`tell application id "…"`), 8-window enumeration cap, `whose bounds is {…}` shortcut for targeted lookup, timeout guard on every script call, per-bundle Automation permission tracking. See the "Landmines" section for the `tab`-class shadowing trap.
- **`AutomationPermission.swift`** — thin Swift wrapper around `AEDeterminePermissionToAutomateTarget`. Returns `granted`/`denied`/`notAvailable`/`other(OSStatus)`. Also `openSystemSettings()` to jump to the Automation panel.

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

There's a `Window WranglerTests` target in the Xcode project but it isn't populated. All validation during MVP development was manual, user-driven, and observed through Console.app logs.

If you're going to add tests, start with `FanGeometry.swift` — it's pure geometry, takes rects, returns rects, no AX. `CoordinateSpace.swift` next. The orchestrators are harder to test without mocking half of AppKit.

---

## The parking lot as of MVP-1.0

Items intentionally deferred from the prototype phase. The user (project owner) is aware of each. Not surprises.

### Repo hygiene

- **Push to a private GitHub remote** — currently local-only. If the SSD dies, everything is lost.
- **README.md** — this one exists; the parking-lot item is complete.
- **LICENSE** — currently just "all rights reserved" in the README; should be a formal file.
- **`.gitignore` audit** — confirm no DerivedData / secrets / build artifacts tracked.
- **Feature-branch + PR workflow** — currently committing straight to `main`. Fine for solo work; matters at handoff.
- **Semantic version releases** — will be relevant when moving toward distribution.

### Scope items deferred from prototype

- **M7 — adjustable header + lateral reveal in a Preferences UI.** Sketched: a SwiftUI Preferences window with two sliders (vertical / horizontal cascade offsets), values persisted in `UserDefaults`, cascade geometry code reads from those settings. Deferred because the hardcoded defaults (28pt header reveal, 60pt lateral reveal) feel right in practice — no scenario has surfaced where they don't. Revisit if one does.

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

If you're going to add a browser feature: read `BrowserScripting.swift` in full FIRST. The `tab`-class shadowing landmine will bite you otherwise.

If you're going to touch the event tap: read `GlobalEventMonitor.swift` and the "CGEventTap safety" section above in full. The default-disabled invariant is load-bearing.

If you're going to add a modal UI: read `CorralPanelHelpers.swift` — it hosts the three shared symbols (`KeyablePanel`, `ButtonTarget`, `centerCorralPanel`) that the existing modals use. Follow the pattern instead of rolling your own.
