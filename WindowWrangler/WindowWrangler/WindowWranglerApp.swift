//
//  WindowWranglerApp.swift
//  Window Wrangler
//
//  Menu-bar-only entry point. AppDelegate now scopes down to:
//    - App lifecycle + .accessory activation policy
//    - Accessibility permission monitoring + onboarding presentation
//    - Status item + menu rebuild (delegates shape to MenuBuilder)
//    - Active app tracking (menuBarOwningApplication / NSWorkspace)
//    - Wiring between modules (lasso ↔ menu, cascade ↔ menu,
//      global shortcuts ↔ actions)
//
//  Cascade + restore logic lives in CascadeOrchestrator.
//  Menu construction lives in MenuBuilder.
//  Lasso flow lives in LassoCoordinator.
//
//  Uses AppKit (NSApplicationDelegate + NSStatusItem) per CLAUDE.md —
//  SwiftUI's MenuBarExtra has known bugs and is avoided.
//

import AppKit
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate, WindowWranglerActions {

    /// Manual entry point. With `@main` on an NSObject subclass, Swift
    /// looks for a `static func main()`. We wire up NSApplication
    /// ourselves rather than going through SwiftUI's App protocol.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - State

    /// Strong reference so the menu bar slot isn't deallocated.
    private var statusItem: NSStatusItem!

    /// Wrapper around AX permission API. Polls for state changes.
    private let permission = AccessibilityPermission()

    /// Onboarding window, kept alive while it's open.
    private var onboardingWindow: OnboardingWindowController?

    /// Last-known permission state. Used to build the menu synchronously
    /// and to detect just-granted/just-revoked transitions.
    private var isTrusted: Bool = false

    /// The most recently activated app that ISN'T us. Tracked via
    /// NSWorkspace.didActivateApplicationNotification so we know the
    /// user's actual current app even when our menu's click handler
    /// fires inside our own process (which can briefly make us
    /// "frontmost" via NSWorkspace.shared.frontmostApplication).
    private var lastUserApp: NSRunningApplication?

    /// Global keyboard shortcuts (⌃⌥⌘. / ⌃⌥⌘, for the cascade
    /// actions, ⌃⌥⌘↑ for restore, ⌃⌥⌘C to toggle lasso mode).
    private let shortcuts = GlobalShortcuts()

    /// Cross-app window selection produced by the M5 lasso flow.
    private let windowSelection = WindowSelection()

    /// Orchestrates the M5 lasso flow (input → hit-test → selection
    /// → overlay rendering). Held strongly so its monitors stay alive
    /// for the app's lifetime.
    /// Shared per-display overlay renderer. Owned at app scope so
    /// `LassoCoordinator` and `CascadeFeedbackController` can render
    /// to the same panels without one instance's per-display panels
    /// stacking on top of the other's. Neither consumer touches the
    /// other's rendering slots (Lasso writes `showLassoRect` /
    /// `setSelectionFrames`, Cascade pulse writes `setPulseState`).
    private let selectionOverlay = SelectionOverlay()

    private lazy var lassoCoordinator = LassoCoordinator(
        selection: windowSelection,
        overlay: selectionOverlay
    )

    /// Cascade acknowledgement-pulse controller. Draws the immediate
    /// ON→OFF→ON→OFF flash around currently-visible windows so the
    /// user sees Window Wrangler react instantly, independent of any
    /// external app's AX latency. Purely cosmetic — never blocks
    /// `performCascadeAllApps`, never mutates Lasso / Plot / Cascade
    /// state, never issues AX calls. Feature-flagged via
    /// `useCascadeAcknowledgementPulse` so it can be disabled if it
    /// ever feels wrong.
    private lazy var cascadeFeedbackController = CascadeFeedbackController(
        overlay: selectionOverlay
    )

    /// Master flag for the Cascade acknowledgement-pulse feature. Set
    /// to `false` to fully disable the pulse (all shortcut handlers
    /// bypass the blink; the controller is never invoked). Retained
    /// as a named constant so future rollback is one line rather than
    /// picking apart the shortcut handler.
    private let useCascadeAcknowledgementPulse = true

    /// Owns Plot Mode — the single-window snap-to-drawn-area flow.
    /// Shares the GlobalEventMonitor tap with Lasso; the two modes
    /// are arbitrated to be mutually exclusive by the toggle routes
    /// below. Injected with the same AX trust closure.
    private lazy var plotCoordinator = PlotCoordinator(
        eventMonitor: lassoCoordinator.sharedEventMonitor,
        isTrusted: { [weak self] in self?.isTrusted ?? false }
    )

    /// Owns the cascade + restore flow. Injected with closures that
    /// resolve the current target app and the live AX trust state.
    /// Using closures (rather than direct references) lets the
    /// orchestrator stay testable without dragging AppDelegate types
    /// into its interface.
    private lazy var cascadeOrchestrator = CascadeOrchestrator(
        resolveTargetApp: { [weak self] in self?.resolveTargetApp() },
        isTrusted: { [weak self] in self?.isTrusted ?? false }
    )

    /// Persistent store of named window groups (M8 Corral feature).
    /// Loads from UserDefaults on init; menu builder observes
    /// `onChange` (wired in M8.4) to refresh its Release submenu
    /// whenever a corral is added, overwritten, deleted, or renamed.
    private let corralStore = CorralStore()

    /// Owns the Corral save/restore flow. Shares the same
    /// `windowSelection` the lasso populates, so triggering save
    /// picks up whatever the user has currently lassoed.
    private lazy var corralOrchestrator = CorralOrchestrator(
        store: corralStore,
        selection: windowSelection,
        isTrusted: { [weak self] in self?.isTrusted ?? false }
    )

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist's LSUIElement: ensure this
        // app runs as a menu-bar-only "accessory" — no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Single-instance enforcement. Any other running Window Wrangler
        // process is a zombie — most often from Xcode's debug session
        // not fully cleaning up on stop, or from launching once from
        // Finder and once from Xcode. Zombies matter here because our
        // lasso CGEventTap is session-wide: a stray process with
        // isLassoModeActive=true silently consumes every left-click on
        // every desktop, making the whole Mac feel frozen. Force-quit
        // any siblings on launch so only THIS instance holds a tap.
        forceQuitOtherInstances()

        setupStatusItem()
        // Force-init lazy properties NOW so their internal observers
        // are wired up BEFORE setupSelectionObserver / permission
        // callbacks wrap them.
        _ = lassoCoordinator
        _ = plotCoordinator
        _ = cascadeOrchestrator
        _ = corralOrchestrator

        // Plot mode arbitration + menu refresh.
        // - willActivate: fires when Plot Mode is turning ON. Tear
        //   down Lasso first if it's active so the modes are truly
        //   mutually exclusive at the tap layer.
        // - onPlotModeChanged: rebuild the menu so its "Plot Mode: On/Off"
        //   state stays in sync.
        plotCoordinator.willActivate = { [weak self] in
            guard let self else { return }
            if self.lassoCoordinator.isLassoModeActive {
                self.lassoCoordinator.toggleLassoMode()  // turn off
            }
        }
        plotCoordinator.onPlotModeChanged = { [weak self] _ in
            self?.rebuildMenu()
        }

        // Escape router — GlobalEventMonitor has a single escape
        // callback. Lasso already installs one in its wireEvents();
        // we wrap it so Plot also gets a shot. Whichever mode is
        // actually active handles the press (each is a no-op when
        // not active).
        let existingEscape = lassoCoordinator.sharedEventMonitor.onEscapePressed
        lassoCoordinator.sharedEventMonitor.onEscapePressed = { [weak self] in
            self?.plotCoordinator.handleEscape()
            existingEscape?()
        }

        // Menu must rebuild whenever the snapshot becomes available
        // or is consumed (cascade creates, restore consumes), so the
        // Restore item's enabled state stays accurate.
        cascadeOrchestrator.onSnapshotChanged = { [weak self] in
            self?.rebuildMenu()
        }

        // Refresh lasso selection outlines after every cascade pass
        // so they track windows to their new positions. Uses AX reads
        // (fresh) instead of CGWindowList (lags AX writes).
        cascadeOrchestrator.onWindowsMoved = { [weak self] in
            self?.lassoCoordinator.refreshSelectionOverlay()
        }

        // After a multi-window resize, re-cascade the resized
        // windows using the most-recent cascade direction so a
        // fan-arranged group stays a fan at the new size. Uses the
        // resized windows' own display as the cascade target.
        //
        // `intendedSize` is the user's drag-target size (before any
        // per-app clamping); passing it as the cascade's slot width
        // avoids the "stuck frontmost inflates the whole fan" case,
        // and preserveWindowSizes=true keeps the cascade from
        // re-writing sizes the apps have already refused (which
        // otherwise showed up as a visible "extra shrink" 200ms
        // after mouseUp).
        lassoCoordinator.onResizeCompleted = { [weak self] windows, intendedSize in
            guard let self, let first = windows.first,
                  let screen = CoordinateSpace.screen(containing: first.frame) else { return }
            // Infer cascade direction from the anchor's current x
            // position relative to the other selected windows, NOT
            // from lastCascadeDirection. A stale last-direction can
            // flip the fan (e.g. user cascaded DR then DL then
            // resized — resize would inherit DL even though the fan
            // was already re-arranged). Comparing geometry preserves
            // whatever visual layout the user is actually looking at.
            // Fully app-agnostic.
            let others = windows.dropFirst().map { $0.frame.origin.x }
            let inferredDirection: CascadeDirection
            if others.isEmpty {
                inferredDirection = self.cascadeOrchestrator.lastCascadeDirection
            } else {
                let anchorX = first.frame.origin.x
                let othersAverageX = others.reduce(0, +) / CGFloat(others.count)
                inferredDirection = anchorX > othersAverageX ? .downRight : .downLeft
            }
            self.cascadeOrchestrator.performCascadeOnSelection(
                windows,
                direction: inferredDirection,
                targetScreen: screen,
                overrideTargetSize: intendedSize,
                preserveWindowSizes: true
            )
        }

        // Menu must also rebuild whenever the corral list changes
        // (save / overwrite / delete / rename) so the "Release ▸"
        // submenu stays fresh — same pattern as the snapshot hook.
        corralStore.onChange = { [weak self] in
            self?.rebuildMenu()
        }

        startPermissionMonitoring()
        startActiveAppTracking()
        cascadeOrchestrator.warmUpAccessibility()
        setupGlobalShortcuts()
        setupSelectionObserver()
    }

    /// LassoCoordinator already listens to selection changes for overlay
    /// rendering. We add a separate hook for the menu to show/hide the
    /// "Selection: N windows" header — wrapping (not replacing) the
    /// existing `onChange` closure.
    ///
    /// MUST be called AFTER `lassoCoordinator` is initialized via the
    /// forced lazy reference in `applicationDidFinishLaunching`.
    private func setupSelectionObserver() {
        let existing = windowSelection.onChange
        windowSelection.onChange = { [weak self] in
            existing?()
            self?.rebuildMenu()
        }
        lassoCoordinator.onLassoModeChanged = { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    // MARK: - Global keyboard shortcuts

    private func setupGlobalShortcuts() {
        // Register bindings; the monitor itself is started/stopped by
        // the permission state handler (NSEvent global keyDown monitor
        // requires AX permission to receive events at all).
        //
        // Cascade Right/Left use ⌃⌥⌘. / ⌃⌥⌘, because macOS Tahoe claims
        // ⌃⌥⌘→ / ⌃⌥⌘← for system window-tiling and consumes them
        // before our global monitor can see them.
        //
        // Shortcut-triggered cascade routes through a separate path
        // from menu-triggered cascade so we can use the mouse-cursor's
        // display as the cascade target (most-recent attention signal).
        // Menu-triggered actions use the @objc methods at the bottom
        // of this file, which fall back to the front window's display.
        let modifiers: NSEvent.ModifierFlags = [.control, .option, .command]
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.period,
            action: { [weak self] in self?.shortcutCascade(direction: .downRight) },
            label: "Cascade Down-Right"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.comma,
            action: { [weak self] in self?.shortcutCascade(direction: .downLeft) },
            label: "Cascade Down-Left"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.upArrow,
            action: { [weak self] in self?.restoreLayout() },
            label: "Restore Previous Layout"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.c,
            action: { [weak self] in self?.toggleLassoFromMenu() },
            label: "Toggle Lasso Mode"
        ))

        // All-apps cascade — uses `⌃⌥⌘[` / `⌃⌥⌘]` instead of the
        // single-app `⌃⌥⌘,` / `⌃⌥⌘.`. The bracket characters are a
        // natural mnemonic for direction ([ → left, ] → right) and
        // the three-modifier chord on brackets is unclaimed by macOS
        // (Tahoe window-tiling only takes the arrow-key variants).
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.rightBracket,
            action: { [weak self] in self?.shortcutCascadeAllApps(direction: .downRight) },
            label: "Cascade All Apps Down-Right"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.leftBracket,
            action: { [weak self] in self?.shortcutCascadeAllApps(direction: .downLeft) },
            label: "Cascade All Apps Down-Left"
        ))

        // M8 Corral feature. ⌃⌥⌘S opens the name pill for the
        // current lasso selection; ⌃⌥⌘R opens the release menu
        // listing every saved corral. Both routes are safe to run
        // synchronously — preflight (permission, empty selection,
        // at-cap) is cheap and any AX/AppleScript work happens
        // after the user commits to an action from within the
        // respective UI, not on the shortcut press itself.
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.s,
            action: { [weak self] in self?.corralSave() },
            label: "Corral (Save Window Group)"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.r,
            action: { [weak self] in self?.corralRelease() },
            label: "Release (Open Window Group)"
        ))

        // Plot (Snap Window to Drawn Area) — single-window precision
        // placement. Toggle-on if inactive; toggle-off (same as Escape)
        // if active. Mutually exclusive with Lasso; PlotCoordinator's
        // willActivate hook ends Lasso first when needed.
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.p,
            action: { [weak self] in self?.togglePlotFromMenu() },
            label: "Plot (Snap Window to Drawn Area)"
        ))
    }

    /// Shortcut-triggered cascade. Captures the mouse cursor's location
    /// *now* (before any deferral), looks up the corresponding display,
    /// and passes it to the orchestrator so the cascade operates only
    /// on the windows of the display the user is currently looking at
    /// — even when other displays are connected and have windows from
    /// the same app.
    ///
    /// The mouse-cursor lookup is done synchronously at trigger time
    /// so the cursor's position at the moment the user pressed the
    /// shortcut is what wins. Deferring the actual cascade work by one
    /// runloop tick keeps the timing consistent with the menu path
    /// (harmless ~1ms wait, helps if anything else is in flight).
    private func shortcutCascade(direction: CascadeDirection) {
        endPlotBeforeConflictingAction()
        let mouseDisplay = CoordinateSpace.screen(containing: NSEvent.mouseLocation)

        // Cascade acknowledgement pulse for single-app cascade —
        // scoped ONLY to the resolved target app's windows on the
        // target display so the outlines match exactly what will
        // move. Uses `CrossAppWindowEnumerator.allVisibleWindows()`
        // (the cheap CG snapshot) filtered by owner PID + display.
        // Slight drift is possible if frontmost changes between here
        // and the orchestrator's own `resolveTargetApp()`; the pulse
        // is cosmetic, so a mildly-inaccurate outline is fine.
        //
        // Cascade dispatch is delayed by exactly the pulse duration
        // so the pulse fully completes and its outlines clear before
        // any window motion begins — same "pulse-then-move" sequence
        // as the All-Apps path. On the fast/warm single-app cascade
        // path this replaces visible overlap with clean visual
        // separation; on slow paths the 150ms extra is imperceptible.
        let cascadeDelay: TimeInterval
        let pulseGeneration: UInt64
        if useCascadeAcknowledgementPulse,
           let targetApp = resolveTargetApp() {
            let targetPID = targetApp.processIdentifier
            let rects = CrossAppWindowEnumerator.allVisibleWindows()
                .filter { $0.ownerPID == targetPID }
                .filter { win in
                    guard let disp = mouseDisplay else { return true }
                    return win.frame.intersects(disp.frame)
                }
                .map { $0.frame }
            pulseGeneration = cascadeFeedbackController.blink(rects: rects)
            cascadeDelay = cascadeFeedbackController.pulseDuration
        } else {
            pulseGeneration = 0
            cascadeDelay = 0
        }

        runAfterMenuDismiss { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + cascadeDelay) { [weak self] in
                self?.cascadeOrchestrator.performCascade(
                    direction: direction,
                    targetScreen: mouseDisplay,
                    onFirstWriteWillDispatch: { [weak self] in
                        self?.cascadeFeedbackController.dismiss(
                            generation: pulseGeneration
                        )
                    }
                )
            }
        }
    }

    /// Shortcut-triggered all-apps cascade. Same mouse-display capture
    /// + defer pattern as `shortcutCascade`. Routes to the orchestrator's
    /// all-apps method, which cascades every visible app's windows on
    /// the mouse-cursor's display.
    ///
    /// `shortcutReceivedAt` captures the exact monotonic moment the
    /// shortcut handler recognized the action — that becomes t=0 for
    /// the per-generation `CascadeLatencyTrace`. Every downstream stage
    /// (menu-dismiss dispatch hop, Task-@MainActor hop, cascade entry,
    /// enumeration, planning, first write) is measured against this
    /// origin so shortcut→firstWrite is exact end-to-end.
    private func shortcutCascadeAllApps(direction: CascadeDirection) {
        let shortcutReceivedAt = CascadeLatencyTrace.now()
        endPlotBeforeConflictingAction()
        let mouseDisplay = CoordinateSpace.screen(containing: NSEvent.mouseLocation)

        // Cascade acknowledgement pulse. Snapshot visible windows via
        // the cheap CG-backed enumerator, kick off the pulse
        // synchronously. CG blind-spot apps (Notes / Podcasts /
        // Grammarly) may not blink; the actual Cascade will still
        // move them via AX. That cosmetic gap is deliberate — CG is
        // not authoritative.
        //
        // Cascade dispatch is delayed by exactly the pulse duration
        // so the pulse fully completes and its outlines clear BEFORE
        // any window motion begins. On the fast/warm Cascade path
        // (~100-225ms shortcut→firstWrite) the pulse was previously
        // overlapping window motion, leaving static outlines behind
        // moving windows — user-reported "lag." Sequencing them
        // sacrifices ~150ms of raw reaction time in exchange for
        // clean visual separation. On the slow (Zoom-open ~1500ms)
        // path the extra 150ms is imperceptible.
        //
        // The `onFirstWriteWillDispatch` dismiss hook stays as
        // belt-and-suspenders — with the delay in place the pulse
        // will always be complete by the time it fires, so the
        // callback becomes a benign no-op.
        let cascadeDelay: TimeInterval
        let pulseGeneration: UInt64
        if useCascadeAcknowledgementPulse {
            let rects = CrossAppWindowEnumerator.allVisibleWindows()
                .map { $0.frame }
            pulseGeneration = cascadeFeedbackController.blink(rects: rects)
            cascadeDelay = cascadeFeedbackController.pulseDuration
        } else {
            pulseGeneration = 0
            cascadeDelay = 0
        }

        runAfterMenuDismiss { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + cascadeDelay) { [weak self] in
                Task { @MainActor in
                    await self?.cascadeOrchestrator.performCascadeAllApps(
                        direction: direction,
                        targetScreen: mouseDisplay,
                        shortcutReceivedAt: shortcutReceivedAt,
                        onFirstWriteWillDispatch: { [weak self] in
                            self?.cascadeFeedbackController.dismiss(
                                generation: pulseGeneration
                            )
                        }
                    )
                }
            }
        }
    }

    // MARK: - Active app tracking

    /// Subscribes to workspace activation notifications so we always
    /// know the user's current foreground app, independent of any API
    /// quirks at click time.
    private func startActiveAppTracking() {
        // Seed with the current frontmost app at launch (if it's not us).
        if let current = NSWorkspace.shared.frontmostApplication,
           current.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastUserApp = current
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            // Skip ourselves — never want to operate on our own (zero) windows.
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            self.lastUserApp = app

            // If the onboarding window is open, an app activation is
            // very likely the user switching BACK from System Settings
            // after toggling our permission. Force an immediate
            // permission re-check so the onboarding window can dismiss
            // without waiting for the next poll tick — keeps the
            // "closes automatically" promise honest.
            if self.onboardingWindow != nil {
                self.permission.forceRecheck()
            }
        }
    }

    /// Returns the best guess at the user's current foreground app.
    /// Order matters: the menu-bar-owning app is sampled at the moment
    /// of resolution (real-time), so it reflects "what app the user is
    /// actually in RIGHT NOW." The tracked last-active app is a fallback
    /// for rare cases where menuBarOwningApplication returns nil.
    /// Frontmost is the last-resort fallback (it can briefly return us
    /// during our own click handlers, hence why it's last).
    ///
    /// Earlier ordering used `lastUserApp` first, which caused a
    /// "warm-up bug": at launch, lastUserApp was seeded with whatever
    /// was frontmost (often Xcode after a ⌘R build) and stuck there
    /// until the workspace activation observer fired. The first cascade
    /// would target the stale app.
    private func resolveTargetApp() -> NSRunningApplication? {
        let myBundle = Bundle.main.bundleIdentifier
        if let menuBar = NSWorkspace.shared.menuBarOwningApplication,
           menuBar.bundleIdentifier != myBundle {
            return menuBar
        }
        if let tracked = lastUserApp, tracked.bundleIdentifier != myBundle {
            return tracked
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != myBundle {
            return frontmost
        }
        return nil
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let icon = MenuBarIcon.image()
            icon.accessibilityDescription = AppInfo.displayName
            button.image = icon
        }

        rebuildMenu()
    }

    // MARK: - Permission monitoring

    /// Begins polling the AX permission state. The callback fires once
    /// immediately with the current value, then only on changes.
    private func startPermissionMonitoring() {
        permission.startPolling { [weak self] granted in
            guard let self else { return }
            let wasTrusted = self.isTrusted
            self.isTrusted = granted
            self.rebuildMenu()

            Log.permission.notice(
                "State: wasTrusted=\(wasTrusted, privacy: .public) granted=\(granted, privacy: .public) onboardingWindow=\(self.onboardingWindow == nil ? "nil" : "exists", privacy: .public)"
            )

            if !granted && self.onboardingWindow == nil {
                Log.permission.notice("Triggering showOnboarding()")
                self.showOnboarding()
                self.shortcuts.stop()
                self.lassoCoordinator.stop()
            } else if !granted && self.onboardingWindow != nil {
                // Window already exists but maybe closed/hidden — re-present it.
                Log.permission.notice("Onboarding window exists; re-presenting")
                self.onboardingWindow?.presentOnboarding()
                self.shortcuts.stop()
                self.lassoCoordinator.stop()
            } else if granted && !wasTrusted {
                Log.permission.notice("Permission just granted; dismissing onboarding")
                self.dismissOnboarding()
                // Now that AX is authorized, start the global shortcut
                // monitor + lasso monitors (both require AX), and re-run
                // the AX warmup (which failed earlier without permission).
                self.shortcuts.start()
                self.lassoCoordinator.start()
                self.cascadeOrchestrator.warmUpAccessibility()
                Log.permission.notice("Global shortcuts + lasso started")
                // Fire the Automation-permission prompt for every
                // installed browser now — the user is in "granting
                // permissions" mode having just handled Accessibility,
                // so getting all the browser prompts here (as one
                // batch) is the least intrusive place to ask. Also
                // surfaces any previously-denied permission so we can
                // guide the user to System Settings.
                BrowserScripting.requestAutomationPermissionsForInstalledBrowsers()
                self.notifyIfAutomationDenied()
            }
        }
    }

    /// Called after `requestAutomationPermissionsForInstalledBrowsers`.
    /// If any browsers ended up denied — either macOS TCC recorded a
    /// previous "Don't Allow" (won't re-prompt) or the automation
    /// record is stale from an earlier signature — we surface an
    /// alert pointing the user at System Settings > Privacy >
    /// Automation, which is the only place they can flip the toggle
    /// back. Wording stays browser-agnostic so users installing new
    /// browsers later understand the pattern applies to those too.
    private func notifyIfAutomationDenied() {
        let denied = BrowserScripting.deniedBundles
        guard !denied.isEmpty else { return }
        let names: [String] = denied.compactMap { bundleID -> String? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return bundleID
            }
            return (Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String) ?? bundleID
        }.sorted()

        let alert = NSAlert()
        alert.messageText = "Enable browser control for Corral tab restore"
        alert.informativeText = """
            For each browser you want to save and restore tabs from — currently \(names.joined(separator: ", ")) — \
            Window Wrangler needs macOS's "Automation" permission.

            Open System Settings > Privacy & Security > Automation, find Window Wrangler, and enable the toggle for each browser you use. \
            The same steps apply to any browser (Chrome, Safari, Brave, Edge, etc.) you install later.

            If a toggle looks stuck, flip it off and on to reset it.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AutomationPermission.openSystemSettings()
        }
    }

    private func showOnboarding() {
        Log.ui.info("showOnboarding: creating controller")
        let controller = OnboardingWindowController()
        controller.onWindowClosed = { [weak self] in
            Log.ui.info("Onboarding window closed by user (X button)")
            self?.onboardingWindow = nil
        }
        onboardingWindow = controller
        controller.presentOnboarding()
        Log.ui.info("showOnboarding: presentOnboarding() returned")
    }

    private func dismissOnboarding() {
        // Belt-and-suspenders: orderOut first (immediate hide from
        // screen) AND close (invokes windowWillClose for cleanup).
        // close() alone is normally enough, but on some macOS releases
        // it's been observed to delay the actual hide by a frame; the
        // explicit orderOut guarantees the window is off-screen right
        // now so the user sees an instant response to the permission
        // grant.
        onboardingWindow?.window?.orderOut(nil)
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let state = MenuBuilder.State(
            isTrusted: isTrusted,
            lassoModeActive: lassoCoordinator.isLassoModeActive,
            plotModeActive: plotCoordinator.isPlotModeActive,
            selectionCount: windowSelection.count,
            hasSnapshot: cascadeOrchestrator.hasSnapshot,
            corrals: corralStore.corrals,
            corralsAtCap: corralStore.isAtCap,
            launchAtLoginEnabled: LoginItemManager.isEnabled
        )
        statusItem?.menu = MenuBuilder.build(state: state, target: self)
    }

    // MARK: - WindowWranglerActions

    @objc func cascadeDownRight() {
        endPlotBeforeConflictingAction()
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascade(direction: .downRight)
        }
    }

    @objc func cascadeDownLeft() {
        endPlotBeforeConflictingAction()
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascade(direction: .downLeft)
        }
    }

    @objc func cascadeAllAppsDownRight() {
        endPlotBeforeConflictingAction()
        runAfterMenuDismiss { [weak self] in
            Task { @MainActor in
                await self?.cascadeOrchestrator.performCascadeAllApps(direction: .downRight)
            }
        }
    }

    @objc func cascadeAllAppsDownLeft() {
        endPlotBeforeConflictingAction()
        runAfterMenuDismiss { [weak self] in
            Task { @MainActor in
                await self?.cascadeOrchestrator.performCascadeAllApps(direction: .downLeft)
            }
        }
    }

    @objc func restoreLayout() {
        endPlotBeforeConflictingAction()
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.restoreLayout()
        }
    }

    /// Ends Plot Mode before any Fan / Cascade / Restore / Corral
    /// action fires. Per spec: "Incompatible Window Wrangler commands
    /// cannot start concurrently." The concrete failure mode this
    /// prevents: cascade's per-app AX enumeration can block the main
    /// thread for several seconds, and Plot's CGEventTap has a ~75ms
    /// callback budget. If Plot's tap is still armed while cascade
    /// runs, mouse events queue up, macOS times out and disables the
    /// tap, and the user feels a system-wide freeze until cascade
    /// finishes. Turning Plot off first releases the tap so mouse
    /// input flows normally during cascade.
    private func endPlotBeforeConflictingAction() {
        if plotCoordinator.isPlotModeActive {
            plotCoordinator.endPlotMode()
        }
    }

    @objc func toggleLassoFromMenu() {
        // Lasso toggle is safe to run synchronously — it doesn't touch
        // AX, doesn't enumerate windows, and the user is comfortable
        // with the click → response feeling immediate.
        //
        // Mode arbitration: Lasso and Plot are mutually exclusive. If
        // Plot is currently active and the user turns on Lasso, end
        // Plot cleanly first via its own teardown path.
        if plotCoordinator.isPlotModeActive {
            plotCoordinator.endPlotMode()
        }
        lassoCoordinator.toggleLassoMode()
    }

    @objc func togglePlotFromMenu() {
        // Toggle Plot Mode. If Lasso is active, PlotCoordinator's
        // `willActivate` hook (installed in applicationDidFinishLaunching)
        // tears it down before Plot starts receiving events.
        plotCoordinator.togglePlotMode()
    }

    @objc func clearSelection() {
        windowSelection.clear()
    }

    @objc func reopenOnboarding() {
        if let existing = onboardingWindow {
            existing.presentOnboarding()
        } else {
            showOnboarding()
        }
    }

    @objc func corralSave() {
        endPlotBeforeConflictingAction()
        // Preflight (permission, empty selection, at-cap) is cheap and
        // safe to run synchronously; the heavier snapshot work fires
        // only after the user submits the name pill, at which point the
        // menu is long dismissed.
        corralOrchestrator.beginSave()
    }

    @objc func corralRelease() {
        endPlotBeforeConflictingAction()
        // Preflight is cheap; the release menu itself renders
        // immediately. The actual restore work only runs after the
        // user picks a corral from the menu.
        corralOrchestrator.beginRelease()
    }

    /// Menu bar "Release ▸" submenu callback. The sender is the
    /// NSMenuItem whose `representedObject` carries the corral's UUID.
    @objc func restoreCorralFromMenu(_ sender: Any) {
        endPlotBeforeConflictingAction()
        guard let item = sender as? NSMenuItem,
              let id = item.representedObject as? UUID else {
            Log.corral.error("restoreCorralFromMenu: sender missing UUID representedObject")
            return
        }
        corralOrchestrator.restoreCorral(byID: id)
    }

    /// Toggles the Login Item registration and rebuilds the menu so
    /// the checkmark reflects the new state on next open.
    @objc func toggleLaunchAtLogin() {
        LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
        rebuildMenu()
    }

    // MARK: - Zombie prevention + clean shutdown

    /// On launch, force-terminates any other Window Wrangler process
    /// that's already running. Called before we install our own
    /// CGEventTap so the OS never has two Window Wrangler taps
    /// competing for left-mouse events at the same session level.
    ///
    /// The concrete failure mode this prevents: an old debug build
    /// left over from a previous Xcode run that still has
    /// `isLassoModeActive == true`. That stray process silently
    /// consumes every left-mouse click across the entire user session
    /// — the visible symptom is "I can't click anything on my Mac,
    /// need to reboot." Killing siblings here means the moment this
    /// build launches, we're guaranteed to be the only one holding
    /// a mouse tap.
    private func forceQuitOtherInstances() {
        guard let myBundle = Bundle.main.bundleIdentifier else { return }
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: myBundle)
            .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
        guard !siblings.isEmpty else { return }
        Log.app.notice(
            "Found \(siblings.count, privacy: .public) other Window Wrangler instance(s) — force-quitting to prevent duplicate event taps"
        )
        for sibling in siblings {
            sibling.forceTerminate()
        }
    }

    /// Explicit teardown on normal quit. macOS releases our CGEventTap
    /// when the process dies, so this is mostly belt-and-suspenders,
    /// but calling stop() explicitly gives us deterministic log lines
    /// ("GlobalEventMonitor: stopped") so a debug session can be sure
    /// the tap actually released before the process exited.
    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("applicationWillTerminate — releasing lasso + shortcut taps")
        lassoCoordinator.stop()
        shortcuts.stop()
        // Cancel any pending Cascade acknowledgement-pulse phase
        // timers so a late-firing asyncAfter cannot resurrect the
        // overlay after teardown.
        cascadeFeedbackController.stop()
    }

    // MARK: - Menu/shortcut timing

    /// Defers AX-touching work to the next main-runloop tick.
    ///
    /// When the user clicks a status-item menu item, Window Wrangler
    /// briefly owns the menu bar (the status item activated us). If we
    /// run AX enumeration *during* the click handler, the target app's
    /// accessibility tree can be in a transient state — some windows
    /// aren't yet (or no longer) reported by `kAXWindowsAttribute`,
    /// which produces a cascade that "misses some windows" and a
    /// snapshot that's then incomplete for Restore.
    ///
    /// Deferring by a single runloop tick (≈ a millisecond) lets the
    /// menu fully dismiss and the target app fully reactivate before
    /// the AX query fires. Shortcut invocations route through the
    /// same path; the extra tick is imperceptible for them and avoids
    /// a class of "menu sometimes loses windows" bugs.
    private func runAfterMenuDismiss(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
