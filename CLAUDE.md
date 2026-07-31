Window Wrangler (working folder: WindowFan)
Project overview
A macOS menu bar utility for arranging windows. Two core mechanics: (1) cascade — stagger a set of windows in a fan layout that preserves title bar and tab visibility; (2) lasso — hold Option+W and click-drag to rubber-band-select windows across apps, then operate on them as a group (apply cascade, or drag them as one). This is a personal prototype phase — NOT for distribution yet. Goal is to validate the core mechanics on my own machine before hiring a developer for production polish.
The product name everywhere user-facing is "Window Wrangler". The repo folder, Xcode project internals, and bundle identifier still say "WindowFan" or "WindowFanWrangler" for legacy reasons; the handoff developer can collapse these later with proper tooling.
My profile
I am a non-developer using AI as the primary code author. I can read code at a high level, run commands you give me, and describe behavior I observe — but I cannot debug Swift errors on my own. When something doesn't work, I'll describe what I see and you'll diagnose. Be explicit and step-by-step.
Tech stack

Language: Swift
UI framework: AppKit for menu bar (NSStatusItem, NOT SwiftUI's MenuBarExtra — has known bugs); AppKit for selection overlay window and onboarding
Preferences UI: SwiftUI is fine
Target: macOS 13 minimum (Ventura), built on macOS Tahoe 26.5 with Xcode 26.5
App type: Menu bar only (LSUIElement = YES), no Dock icon, no main window

Architecture principles

Coordinate spaces: AX (Accessibility) APIs use top-left global origin. Cocoa uses bottom-left per-screen origin. ALWAYS convert at module boundaries via a CoordinateSpace utility — never mix them in the same function.
Pure geometry: Fan math lives in pure functions that take and return CGRects with NO AX calls. Testable in isolation.
AX layer separate: Window enumeration and mutation are wrapped in dedicated modules (AXWindowEnumerator, WindowMutator) that the rest of the app calls into.
Selection state separate: The set of currently-selected windows lives in a WindowSelection module. Other components read/write through it; nothing else holds direct window references long-term.
Global event capture isolated: CGEventTap callbacks live in a dedicated module. The lasso/select flow reacts to events; it does not own the tap.
No premature optimization: Instant snaps are fine for cascade. During multi-window group drag, use an overlay-ghost cluster preview (Finder-style) rather than live multi-window AX calls — simpler and feels smoother.

Scope: IN for prototype

Menu bar app
Accessibility permission onboarding
Cascade frontmost app's windows in both directions (down-right and down-left)
Lasso selection: hold Option+W and click-drag to rubber-band-select windows across apps. Selection persists. Visual highlights via transparent overlay window.
Apply cascade to the lasso selection (Cascade Selected Down-Right / Down-Left)
Multi-window group drag: dragging any selected window moves the whole group with a Finder-style cluster preview at the cursor; snap to final positions on release. Works seamlessly across multiple displays (single extended coordinate space via AX). Limited to the current Space — see OUT scope.
Keyboard shortcuts to cascade and to restore previous layout
Adjustable header reveal and lateral reveal in preferences

Scope: OUT for prototype (do not build)

Code signing, notarization, distribution
Mac App Store packaging
Layout save/restore by name (post-MVP)
Named groups — save a selection with a name and recall it later (post-MVP; may become a paid feature)
Cross-Space (multi-desktop) group drag — macOS doesn't expose public APIs for programmatic Space-to-Space window movement; defer until a different mechanism is acceptable
Window size memory
Animation beyond what's needed for "feel" — no decorative animation
Browser session features
Installer or website

Working style

Pause and confirm at each milestone before moving on
When I report a bug, ask for specifics rather than guessing
Prefer fewer, focused changes over big sweeping rewrites
Commit to git at each milestone with a clear message

Parking lot (deferred — revisit later, not blocking current milestones)

Source-control / project hygiene items I want to handle later, not now:
- Push the repo to a private GitHub remote so the code is backed up off this Mac (currently the repo only exists locally; if the SSD dies, everything is lost). One-time auth setup needed.
- Tag completed milestones in git (e.g., `git tag M4`, `M5`) so they're navigable by name instead of commit SHA.
- Add a README.md at the project root summarizing what the app is, how to build it, and prerequisites — first file a handoff developer would look for.
- Add a LICENSE file (default "all rights reserved" is fine for prototype but should be explicit).
- Audit `.gitignore` to confirm no build artifacts / DerivedData / sensitive files are tracked.
- Adopt a feature-branch + PR workflow (currently committing straight to `main`). Not needed for solo work; matters at handoff.
- Set up release builds with semantic versioning (e.g., `0.1.0`). Relevant when we move toward distribution, not before.

Scope items deferred from the prototype phase:
- M7 (originally: adjustable header reveal + lateral reveal in a Preferences UI). Shape sketched: SwiftUI Preferences window with sliders for the vertical and horizontal offsets, values persisted in `UserDefaults`, cascade math reads from those settings so subsequent cascades reflect the new values. Deferred because the hardcoded defaults feel right in practice — user hasn't hit a case where the current offsets look wrong. Revisit if a specific scenario surfaces where the current stagger doesn't work, or as a polish item post-handoff.

- Multi-window resize via lasso corner handles — **shipped**. Two circle handles on the last-interacted selected window (BL / BR only); grab one, drag, the whole selection resizes on release. Implementation departs from the original "live-resize the frontmost during the drag" spec in one important way: the drag now updates the overlay outline only, with zero AX writes until mouse-up. Live-resizing the real Chrome / System Settings window mid-drag over synchronous AX IPC was single-digit-fps and read as sticky no matter how the writes were scheduled (tried both blocking-on-main and coalesced-background — chunky either way). Deferring the whole authoritative resize (per-window preflight, per-PID parallel writes, settle, readback, toast, positions-only recascade) to release removes AX latency from the interactive path entirely. Same feel across every app, including known-slow ones. Only the frontmost outline resizes during the drag; secondary outlines stay at their captured original frames until release, because per-app minimum sizes / character-grid snapping / non-settable dialogs mean we can't honestly promise sibling sizes ahead of time. Lesson worth carrying: for interactive gestures, treat the overlay as the interactive surface and use AX only for the authoritative commit — trying to make cross-app AX writes track a 60fps cursor is a losing game. Same pattern would likely help M6 group drag on slow apps (see known-limitations below), though group drag needs live positions for its cross-display teleport logic so the change would be less trivial than the resize version was.

Known limitations of the current AX-based approach (not blocking for prototype; the handoff developer should evaluate with full context):
- M6 group drag on slow apps (Chrome, Zoom): during a hard, fast drag the selection outlines can visibly drift 20–40 pixels off the moving windows for a frame or two before catching up on release. Root cause is inherent to Accessibility API cross-app latency — our AX position write travels to the target app's runloop, is applied to its NSWindow, and reaches WindowServer, all of which can take more than one screen refresh for slow apps. Every code-level lever inside AX is already pulled (fast panel pan, read-back pacing, read-before-write ordering, position-only writes). Further reduction requires either a moderate refactor (CVDisplayLink-driven overlay updates — may cut drift in half but not eliminate it) or a real overhaul (CGS/SkyLight private APIs like yabai uses — near-instant moves, but requires disabling SIP, is undocumented, and Apple can break it any macOS release). Rectangle, Magnet, and Apple's own window-tiling all exhibit the same lag when moving another app's windows.

- M8 Corral tab capture / restore hits several macOS TCC (Transparency, Consent, and Control) fragilities that this prototype can't fully fix from user code:
  - Browser tab capture requires per-target Automation permission. Handled correctly at onboarding via `AEDeterminePermissionToAutomateTarget` — a prompt fires for each installed supported browser, user grants, subsequent scripting works. But if the Automation permission grant becomes stale (has been observed after multiple debug rebuilds change the app's code signature), TCC continues to report "granted" while the actual `NSAppleScript.executeAndReturnError` call silently returns empty output after ~8 seconds. The only reliable reset paths — `tccutil reset AppleEvents com.jmw3.WindowWrangler` from Terminal, and toggling the entry off/on in System Settings > Privacy & Security > Automation — have both been observed to freeze the user's machine during this prototype's development. These are documented macOS bugs, not something the app can work around. A production release, properly codesigned + notarized with a stable Team ID, would produce stable TCC records that don't invalidate on every build and would sidestep both. Handoff developer should evaluate whether the notarized build's TCC behavior differs before treating this as a real feature bug.
  - Reading files from ~/Documents, ~/Desktop, or ~/Downloads triggers macOS Sequoia's "Files & Folders" TCC prompt on every folder the app touches. Corral restore's `NSWorkspace.open(fileURL, withApplicationAt:)` for saved documents hits this. A production build with a Full Disk Access entitlement would eliminate these prompts, but that entitlement requires proper notarization and system-review approval. Dev builds see the prompt per folder as expected.
  - LaunchServices fallbacks (`/usr/bin/open -b <bundle> URL1 URL2 …` for browsers, `/usr/bin/open ~` for Finder) are in place and work when AppleScript is unavailable — the browser window will materialize even without tab data, so users always get something back on restore. The tab data itself only makes it into the Corral when AppleScript is working.

- macOS `applicationShouldHandleReopen` is per-app: most well-behaved apps (Preview, TextEdit) create a fresh default window when `/usr/bin/open -b <bundle>` is invoked on a running-but-windowless instance. Chrome and Finder don't — Chrome needs URLs (or `about:blank`) passed as arguments, Finder needs a folder path. Notes and Podcasts (both Catalyst apps derived from iOS) usually DO respond to `open -b` reopen but can take 3–5 seconds to actually spawn the window. Corral restore handles Chrome/Finder via app-specific dispatch in `openAppForRestore`, and does one retry pass 2s after the initial find-and-move to catch slower Catalyst reopens. New apps a user adds to Corrals that share these quirks (some Electron apps have been observed to) would need their own case in that dispatch.

- Multi-Space (Virtual Desktop) restore is a macOS-inherent limitation. Corral saves and restores window frames in global pixel coordinates, but macOS doesn't expose a public API to (a) read which Space a window is on, (b) move a window between Spaces programmatically, or (c) tell another app which Space to create its new window on. Practical impact: if the user was on Desktop 2 during save and closes a window like Podcasts before restore, the app's reopen logic decides which Space the new window lands on — often the app's own "last-active" Space, which may not be the user's current Space. yabai works around this via CGS/SkyLight private APIs and requires disabling SIP; Rectangle, Magnet, and Apple's own tiling all place restored windows on the current Space regardless of origin. The Corral parking-lot entry above about M6 group drag covers the same underlying limitation from the other direction. A production build would face the same constraint — this is macOS, not a build-quality issue.

- macOS AX `-25211` (`kAXErrorAPIDisabled`) on backgrounded/idle apps: on Sequoia+, `AXUIElementCopyAttributeValue(kAXWindows)` returns `-25211` for apps whose AX proxy is in an "asleep" state — Console, Finder, Preview, Notes, Podcasts, and most other backgrounded apps have all been observed hitting this simultaneously during a cascade, resulting in only the recently-active apps (Chrome, Xcode) participating. `AXWindowEnumerator.windows(of:)` handles this with a one-shot 50ms-delay retry: the first call typically wakes the proxy up, and the second call succeeds (logged as `kAXWindows recovered after -25211 retry`). Rectangle, Magnet, and yabai all rely on the same wake-up-then-retry pattern; without it, coverage of "just cascade everything" would be inconsistent shot-to-shot. If a future macOS release changes the wake-up latency, the 50ms may need bumping.

- Chrome AppleScript `tab`-class shadowing (M8.3): inside `tell application id "com.google.Chrome"`, the identifier `tab` refers to Chrome's `tab` **class object** (Chrome models tabs as first-class AppleScript objects), NOT AppleScript's built-in tab-character constant. Writing `& tab &` as a field separator makes Chrome coerce its class to the string `"tab"`, producing garbage output any downstream parser can't split. Every Chrome/Safari script builder in `BrowserScripting.swift` therefore declares `set tabCh to (ASCII character 9)` and `set lf to (ASCII character 10)` OUTSIDE its `tell` block and uses those unambiguously. Anyone adding new Chrome scripts must follow the same pattern — the failure mode is silent, and the symptom (parser returns 0 windows) hides the cause completely. Cost us hours to diagnose the first time. Chrome's dictionary also defines `linefeed` in some contexts, so `lf` is declared outside for the same reason.

- Chrome hidden helper windows + 8-window cap (M8.3): Chrome's `windows` AppleScript collection includes 25+ hidden helper windows (extensions popups, DevTools panels, PWA hosts, tab-detach shadows) on typical developer machines. Walking these via a per-window `bounds` or `tabs` access reliably hangs Chrome's scripting handler indefinitely (5s+ timeouts observed on machines with 30+ Chrome windows total). All Chrome enumeration scripts cap at `count of windows > 8 then set winCount to 8` — Chrome's `windows` collection is z-ordered (frontmost first), so top-8 always covers all user-visible browser windows. If a user genuinely has 9+ simultaneously-visible Chrome browser windows on one display, the 9th+ won't be reachable by the enumeration fallback; the `whose bounds is {…}` shortcut has no cap and covers it. The full snapshot script (`chromiumSnapshotScript`, used at restore for URL-overlap matching) shares the same cap.

- NSAppleScript timeout guard (M8.3): `NSAppleScript.executeAndReturnError` blocks the calling thread until the target app responds — with no cancellation API. If Chrome hangs, the calling thread hangs forever. `BrowserScripting.runScriptWithTimeout` wraps every call in a 5-second semaphore-bounded background dispatch: after 5s we abandon the wait and return nil. The underlying script keeps running in a leaked background thread (we can't kill it), which log-tail confirms — timed-out scripts occasionally emit their completion log 15–30s later. In practice this doesn't accumulate meaningfully because the tab-class fix made timeouts rare, but if the app ever appears sluggish after many failed Chrome saves in one session, thread starvation from leaked scripts is the likely cause; a restart clears it.

When ready to revisit, raise it explicitly ("let's clear the parking lot" or call out a specific item). Don't surface these as nags during normal development.
