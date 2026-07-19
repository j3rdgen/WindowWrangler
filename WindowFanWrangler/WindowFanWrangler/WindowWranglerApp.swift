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
    private lazy var lassoCoordinator = LassoCoordinator(selection: windowSelection)

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
    /// picks up whatever the user has currently lassoed. The
    /// suspend/resume closures let the orchestrator pause lasso
    /// mode's mouse-event consumption while any of its modal UI
    /// (name pill, replace-confirm alert, no-selection alert) is
    /// on-screen — without this, lasso's CGEventTap would swallow
    /// the click needed to focus the pill or dismiss the alert.
    private lazy var corralOrchestrator = CorralOrchestrator(
        store: corralStore,
        selection: windowSelection,
        isTrusted: { [weak self] in self?.isTrusted ?? false },
        suspendMouseCapture: { [weak self] in
            self?.lassoCoordinator.suspendMouseConsumption()
        },
        resumeMouseCapture: { [weak self] in
            self?.lassoCoordinator.resumeMouseConsumption()
        }
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
        _ = cascadeOrchestrator
        _ = corralOrchestrator

        // Menu must rebuild whenever the snapshot becomes available
        // or is consumed (cascade creates, restore consumes), so the
        // Restore item's enabled state stays accurate.
        cascadeOrchestrator.onSnapshotChanged = { [weak self] in
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
        let mouseDisplay = CoordinateSpace.screen(containing: NSEvent.mouseLocation)
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascade(
                direction: direction,
                targetScreen: mouseDisplay
            )
        }
    }

    /// Shortcut-triggered all-apps cascade. Same mouse-display capture
    /// + defer pattern as `shortcutCascade`. Routes to the orchestrator's
    /// all-apps method, which cascades every visible app's windows on
    /// the mouse-cursor's display.
    private func shortcutCascadeAllApps(direction: CascadeDirection) {
        let mouseDisplay = CoordinateSpace.screen(containing: NSEvent.mouseLocation)
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascadeAllApps(
                direction: direction,
                targetScreen: mouseDisplay
            )
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
            selectionCount: windowSelection.count,
            hasSnapshot: cascadeOrchestrator.hasSnapshot
        )
        statusItem?.menu = MenuBuilder.build(state: state, target: self)
    }

    // MARK: - WindowWranglerActions

    @objc func cascadeDownRight() {
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascade(direction: .downRight)
        }
    }

    @objc func cascadeDownLeft() {
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascade(direction: .downLeft)
        }
    }

    @objc func cascadeAllAppsDownRight() {
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascadeAllApps(direction: .downRight)
        }
    }

    @objc func cascadeAllAppsDownLeft() {
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.performCascadeAllApps(direction: .downLeft)
        }
    }

    @objc func restoreLayout() {
        runAfterMenuDismiss { [weak self] in
            self?.cascadeOrchestrator.restoreLayout()
        }
    }

    @objc func toggleLassoFromMenu() {
        // Lasso toggle is safe to run synchronously — it doesn't touch
        // AX, doesn't enumerate windows, and the user is comfortable
        // with the click → response feeling immediate.
        lassoCoordinator.toggleLassoMode()
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
        // Preflight (permission, empty selection, at-cap) is cheap and
        // safe to run synchronously; the heavier snapshot work fires
        // only after the user submits the name pill, at which point the
        // menu is long dismissed.
        corralOrchestrator.beginSave()
    }

    @objc func corralRelease() {
        // Preflight is cheap; the release menu itself renders
        // immediately. The actual restore work only runs after the
        // user picks a corral from the menu.
        corralOrchestrator.beginRelease()
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
