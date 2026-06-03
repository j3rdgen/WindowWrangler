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

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist's LSUIElement: ensure this
        // app runs as a menu-bar-only "accessory" — no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        // Force-init lazy properties NOW so their internal observers
        // are wired up BEFORE setupSelectionObserver / permission
        // callbacks wrap them.
        _ = lassoCoordinator
        _ = cascadeOrchestrator

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
        let modifiers: NSEvent.ModifierFlags = [.control, .option, .command]
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.period,
            action: { [weak self] in self?.cascadeDownRight() },
            label: "Cascade Down-Right"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.comma,
            action: { [weak self] in self?.cascadeDownLeft() },
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
            }
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
