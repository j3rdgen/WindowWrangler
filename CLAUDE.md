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

Known limitations of the current AX-based approach (not blocking for prototype; the handoff developer should evaluate with full context):
- M6 group drag on slow apps (Chrome, Zoom): during a hard, fast drag the selection outlines can visibly drift 20–40 pixels off the moving windows for a frame or two before catching up on release. Root cause is inherent to Accessibility API cross-app latency — our AX position write travels to the target app's runloop, is applied to its NSWindow, and reaches WindowServer, all of which can take more than one screen refresh for slow apps. Every code-level lever inside AX is already pulled (fast panel pan, read-back pacing, read-before-write ordering, position-only writes). Further reduction requires either a moderate refactor (CVDisplayLink-driven overlay updates — may cut drift in half but not eliminate it) or a real overhaul (CGS/SkyLight private APIs like yabai uses — near-instant moves, but requires disabling SIP, is undocumented, and Apple can break it any macOS release). Rectangle, Magnet, and Apple's own window-tiling all exhibit the same lag when moving another app's windows.

When ready to revisit, raise it explicitly ("let's clear the parking lot" or call out a specific item). Don't surface these as nags during normal development.
