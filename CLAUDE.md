WindowFan
Project overview
A macOS menu bar utility that arranges windows in staggered "fan" layouts, preserving title and tab visibility across stacked windows. This is a personal prototype phase — NOT for distribution yet. Goal is to validate the core mechanic on my own machine before hiring a developer for production polish.
My profile
I am a non-developer using AI as the primary code author. I can read code at a high level, run commands you give me, and describe behavior I observe — but I cannot debug Swift errors on my own. When something doesn't work, I'll describe what I see and you'll diagnose. Be explicit and step-by-step.
Tech stack

Language: Swift
UI framework: AppKit for menu bar (NSStatusItem, NOT SwiftUI's MenuBarExtra — has known bugs)
Preferences UI: SwiftUI is fine
Target: macOS 13 minimum (Ventura), built on macOS Tahoe 26.5 with Xcode 26.5
App type: Menu bar only (LSUIElement = YES), no Dock icon, no main window

Architecture principles

Coordinate spaces: AX (Accessibility) APIs use top-left global origin. Cocoa uses bottom-left per-screen origin. ALWAYS convert at module boundaries via a CoordinateSpace utility — never mix them in the same function.
Pure geometry: Fan math lives in pure functions that take and return CGRects with NO AX calls. Testable in isolation.
AX layer separate: Window enumeration and mutation are wrapped in dedicated modules (AXWindowEnumerator, WindowMutator) that the rest of the app calls into.
No premature optimization: Instant snaps are fine, no animation in prototype.

Scope: IN for prototype

Menu bar app
Accessibility permission onboarding
Fan frontmost app's windows in one direction (down-right)
Keyboard shortcut to fan and to restore previous layout
Adjustable header reveal and lateral reveal in preferences

Scope: OUT for prototype (do not build)

Code signing, notarization, distribution
Mac App Store packaging
Layout save/restore by name
Window size memory
Stack movement / group movement
Multiple fan directions
Animation
Browser session features
Installer or website

Working style

Pause and confirm at each milestone before moving on
When I report a bug, ask for specifics rather than guessing
Prefer fewer, focused changes over big sweeping rewrites
Commit to git at each milestone with a clear message
