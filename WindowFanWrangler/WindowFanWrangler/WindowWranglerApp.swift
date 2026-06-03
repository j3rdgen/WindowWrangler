//
//  WindowWranglerApp.swift
//  Window Wrangler
//
//  Created by John Wilson on 5/26/26.
//
//  Menu-bar-only entry point, permission-state-aware menu, onboarding,
//  and (since M4) the actual cascade and restore actions on the
//  frontmost app's windows.
//
//  Uses AppKit (NSApplicationDelegate + NSStatusItem) per CLAUDE.md —
//  SwiftUI's MenuBarExtra has known bugs and is avoided.
//

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

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

    /// Pre-cascade snapshot for Restore Previous Layout. nil until the
    /// user has fanned at least once.
    private var lastSnapshot: LayoutSnapshot?

    /// The most recently activated app that ISN'T us. Tracked via
    /// NSWorkspace.didActivateApplicationNotification so we know the
    /// user's actual current app even when our menu's click handler
    /// fires inside our own process (which can briefly make us
    /// "frontmost" via NSWorkspace.shared.frontmostApplication).
    private var lastUserApp: NSRunningApplication?

    /// Global keyboard shortcuts (⌃⌥⌘+arrow keys for the cascade
    /// actions, plus ⌃⌥⌘↑ for restore).
    private let shortcuts = GlobalShortcuts()

    /// Cross-app window selection produced by the M5 lasso flow.
    private let windowSelection = WindowSelection()

    /// Orchestrates the M5 lasso flow (input → hit-test → selection
    /// → overlay rendering). Held strongly here so its monitors stay
    /// alive for the app's lifetime.
    private lazy var lassoCoordinator = LassoCoordinator(selection: windowSelection)

    // MARK: - Cascade policy constants
    //
    // Buffer the cascade away from the screen edges so the layout has
    // breathing room. The top stays at 0 because NSScreen.visibleFrame
    // already excludes the menu bar; only the left/right/bottom need
    // additional padding. These will become user-configurable in M8.

    private let cascadeMarginTop: CGFloat = 0
    private let cascadeMarginLeft: CGFloat = 30
    private let cascadeMarginRight: CGFloat = 30
    private let cascadeMarginBottom: CGFloat = 30

    /// Each cascaded window is resized to this fraction of the cascade's
    /// available screen area. 0.70 = 70% × 70%. Leaves enough room for
    /// cascade reveals to fit comfortably while keeping windows readable.
    private let cascadeWindowSizeFraction: CGFloat = 0.70

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist's LSUIElement: ensure this
        // app runs as a menu-bar-only "accessory" — no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        // Force-init lassoCoordinator NOW (it's lazy var) so its
        // selection.onChange handler is in place BEFORE we wrap it
        // for the menu in setupSelectionObserver below.
        _ = lassoCoordinator
        startPermissionMonitoring()
        startActiveAppTracking()
        warmUpAccessibility()
        setupGlobalShortcuts()
        setupSelectionObserver()
    }

    /// LassoCoordinator already listens to selection changes for overlay
    /// rendering. We need a separate observation hook for the menu to
    /// show/hide the "Selection: N windows" header. To avoid stomping
    /// each other's `onChange` closures, we wrap.
    ///
    /// MUST be called AFTER `lassoCoordinator` is initialized (which
    /// happens in `applicationDidFinishLaunching` via a forced reference).
    /// Otherwise lassoCoordinator's lazy init would overwrite our
    /// wrapper.
    private func setupSelectionObserver() {
        let existing = windowSelection.onChange
        windowSelection.onChange = { [weak self] in
            existing?()
            self?.rebuildMenu()
        }
    }

    // MARK: - Global keyboard shortcuts

    private func setupGlobalShortcuts() {
        // Just register bindings. The monitor itself is started/stopped
        // by the permission state handler — NSEvent's global monitor
        // for keyDown requires Accessibility permission to actually
        // receive events, and registering it before permission is
        // granted leaves it permanently dead even after permission
        // becomes available.
        //
        // ⌃⌥⌘+arrows: chord uses all four bottom-row modifiers (no Shift),
        // and arrow keys with this exact modifier combo are not bound by
        // macOS, browsers, IDEs, VoiceOver, or any common window manager.
        let modifiers: NSEvent.ModifierFlags = [.control, .option, .command]
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.rightArrow,
            action: { [weak self] in self?.cascadeDownRight() },
            label: "Cascade Down-Right"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.leftArrow,
            action: { [weak self] in self?.cascadeDownLeft() },
            label: "Cascade Down-Left"
        ))
        shortcuts.register(.init(
            modifiers: modifiers,
            keyCode: KeyCode.upArrow,
            action: { [weak self] in self?.restoreLayout() },
            label: "Restore Previous Layout"
        ))
    }

    /// Issues a throw-away AX enumeration shortly after launch so the
    /// framework's cold-start latency happens BEFORE the user's first
    /// cascade attempt. Without this, the first cascade tends to have
    /// slight sizing inconsistencies because AX writes don't fully
    /// settle within our pass windows on cold start. We delay 0.8s so
    /// the user's foreground app at launch has time to be detected and
    /// load its AX tree.
    private func warmUpAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard let app = self.resolveTargetApp() else { return }
            // Just enumerate — don't mutate anything. This triggers the
            // AX framework to fully initialize and the target app to
            // build its accessibility tree.
            _ = AXWindowEnumerator.windows(of: app)
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
            // Skip ourselves — we never want to operate on our own (zero) windows.
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            self.lastUserApp = app
        }
    }

    /// Returns the best guess at the user's current foreground app.
    /// Order matters: the menu-bar-owning app is sampled at the moment
    /// of resolution (real-time), so it reflects "what app the user
    /// is actually in RIGHT NOW." The tracked last-active app is a
    /// fallback for the rare cases where menuBarOwningApplication
    /// returns nil. Frontmost is the last-resort fallback (it can
    /// briefly return us during our own click handlers, hence why
    /// it's last).
    ///
    /// Earlier ordering used `lastUserApp` first, which caused a
    /// "warm-up bug": at launch, lastUserApp was seeded with whatever
    /// was frontmost (often Xcode after a ⌘R build) and stuck there
    /// until the workspace activation observer fired. The first
    /// cascade would target the stale app.
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
    /// immediately with the current value, then again only on changes.
    private func startPermissionMonitoring() {
        permission.startPolling { [weak self] granted in
            guard let self else { return }
            let wasTrusted = self.isTrusted
            self.isTrusted = granted
            self.rebuildMenu()

            NSLog("[\(AppInfo.displayName)] Permission state: " +
                  "wasTrusted=\(wasTrusted) granted=\(granted) " +
                  "onboardingWindow=\(self.onboardingWindow == nil ? "nil" : "exists")")

            if !granted && self.onboardingWindow == nil {
                NSLog("[\(AppInfo.displayName)] Triggering showOnboarding()")
                self.showOnboarding()
                self.shortcuts.stop()
                self.lassoCoordinator.stop()
            } else if !granted && self.onboardingWindow != nil {
                // Window already exists but maybe closed/hidden — re-present it.
                NSLog("[\(AppInfo.displayName)] Onboarding window exists; re-presenting")
                self.onboardingWindow?.presentOnboarding()
                self.shortcuts.stop()
                self.lassoCoordinator.stop()
            } else if granted && !wasTrusted {
                NSLog("[\(AppInfo.displayName)] Permission just granted; dismissing onboarding")
                self.dismissOnboarding()
                // Now that AX is authorized, start the global shortcut
                // monitor + lasso monitors (both require AX), and
                // re-run the AX warmup (which failed earlier without
                // permission).
                self.shortcuts.start()
                self.lassoCoordinator.start()
                self.warmUpAccessibility()
                NSLog("[\(AppInfo.displayName)] Global shortcuts + lasso started")
            }
        }
    }

    private func showOnboarding() {
        NSLog("[\(AppInfo.displayName)] showOnboarding: creating controller")
        let controller = OnboardingWindowController()
        controller.onWindowClosed = { [weak self] in
            NSLog("[\(AppInfo.displayName)] Onboarding window closed by user (X button)")
            self?.onboardingWindow = nil
        }
        onboardingWindow = controller
        controller.presentOnboarding()
        NSLog("[\(AppInfo.displayName)] showOnboarding: presentOnboarding() returned")
    }

    private func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Permission status header — read-only indicator
        let header = NSMenuItem(
            title: isTrusted
                ? "Accessibility: ✓ Granted"
                : "Accessibility: ⚠︎ Not granted",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Lasso selection state, if any.
        if windowSelection.count > 0 {
            let plural = windowSelection.count == 1 ? "" : "s"
            let selectionHeader = NSMenuItem(
                title: "Selection: \(windowSelection.count) window\(plural)",
                action: nil,
                keyEquivalent: ""
            )
            selectionHeader.isEnabled = false
            menu.addItem(selectionHeader)

            let clearItem = NSMenuItem(
                title: "Clear Selection",
                action: #selector(clearSelection),
                keyEquivalent: ""
            )
            clearItem.target = self
            clearItem.isEnabled = true
            menu.addItem(clearItem)

            menu.addItem(.separator())
        }

        // Cascade actions — one per direction. The keyEquivalent here
        // is purely for visual display in the menu; the actual firing
        // is handled by GlobalShortcuts (since we're an accessory app
        // and macOS won't fire menu shortcuts when we're not frontmost).
        let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

        let cascadeRightItem = NSMenuItem(
            title: "Cascade Down-Right",
            action: #selector(cascadeDownRight),
            keyEquivalent: "\u{F703}"  // NSRightArrowFunctionKey
        )
        cascadeRightItem.keyEquivalentModifierMask = shortcutModifiers
        cascadeRightItem.target = self
        cascadeRightItem.isEnabled = isTrusted
        menu.addItem(cascadeRightItem)

        let cascadeLeftItem = NSMenuItem(
            title: "Cascade Down-Left",
            action: #selector(cascadeDownLeft),
            keyEquivalent: "\u{F702}"  // NSLeftArrowFunctionKey
        )
        cascadeLeftItem.keyEquivalentModifierMask = shortcutModifiers
        cascadeLeftItem.target = self
        cascadeLeftItem.isEnabled = isTrusted
        menu.addItem(cascadeLeftItem)

        let restoreItem = NSMenuItem(
            title: "Restore Previous Layout",
            action: #selector(restoreLayout),
            keyEquivalent: "\u{F700}"  // NSUpArrowFunctionKey
        )
        restoreItem.keyEquivalentModifierMask = shortcutModifiers
        restoreItem.target = self
        // Only enabled if we have AX permission AND a snapshot to restore.
        restoreItem.isEnabled = isTrusted && lastSnapshot != nil
        menu.addItem(restoreItem)

        if !isTrusted {
            menu.addItem(.separator())
            let reopenItem = NSMenuItem(title: "Reopen Setup…",
                                        action: #selector(reopenOnboarding),
                                        keyEquivalent: "")
            reopenItem.target = self
            reopenItem.isEnabled = true
            menu.addItem(reopenItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(AppInfo.displayName)",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func cascadeDownRight() {
        performCascade(direction: .downRight)
    }

    @objc private func cascadeDownLeft() {
        performCascade(direction: .downLeft)
    }

    /// Common cascade implementation — enumerate the frontmost app's
    /// windows, snapshot their current frames, compute target frames,
    /// and apply them in batch.
    private func performCascade(direction: CascadeDirection) {
        guard isTrusted else {
            NSLog("[\(AppInfo.displayName)] Cascade aborted: AX permission not granted")
            return
        }

        guard let targetApp = resolveTargetApp() else {
            NSLog("[\(AppInfo.displayName)] Cascade aborted: no user app could be resolved")
            return
        }
        let targetAppName = targetApp.localizedName ?? "?"
        NSLog("[\(AppInfo.displayName)] Cascade resolved target app: '\(targetAppName)'")

        let windows = AXWindowEnumerator.windows(of: targetApp)

        guard !windows.isEmpty else {
            NSLog("[\(AppInfo.displayName)] Cascade no-op: no windows found in '\(targetAppName)'")
            return
        }
        guard windows.count > 1 else {
            NSLog("[\(AppInfo.displayName)] Cascade no-op: only 1 window in '\(targetAppName)'")
            return
        }

        // Snapshot current state BEFORE moving anything, so Restore works.
        lastSnapshot = LayoutSnapshot(from: windows)

        // Determine the screen this cascade should live within. We use
        // the visible frame (excludes menu bar + Dock) of the display
        // that contains the front window's center, then apply the
        // cascade margins so the layout has breathing room from the
        // screen edges.
        let anchorCenter = CGPoint(x: windows[0].frame.midX,
                                   y: windows[0].frame.midY)
        let rawScreen = CoordinateSpace.visibleScreenFrame(containing: anchorCenter)
        let screen = CGRect(
            x: rawScreen.minX + cascadeMarginLeft,
            y: rawScreen.minY + cascadeMarginBottom,
            width: rawScreen.width - cascadeMarginLeft - cascadeMarginRight,
            height: rawScreen.height - cascadeMarginTop - cascadeMarginBottom
        )

        // Compute the uniform target size: a fraction of the available
        // screen area. Adapts to whichever display the cascade lives on.
        let targetSize = CGSize(
            width: screen.width * cascadeWindowSizeFraction,
            height: screen.height * cascadeWindowSizeFraction
        )

        // Pass 1: apply the cascade immediately.
        let count1 = applyCascadePass(
            windows: windows,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        NSLog("[\(AppInfo.displayName)] Cascade \(direction) on '\(targetAppName)' pass 1: " +
              "\(count1)/\(windows.count) windows moved")

        // Three retries at progressively longer delays. Apps with
        // settling logic (Chrome with DevTools, etc.) need time between
        // attempts. Pass 2 at 120ms catches transient clamps quickly;
        // pass 3 at 500ms catches slow settlers that need a full
        // layout cycle; pass 4 at 1000ms catches the most stubborn
        // (Chrome windows that incrementally accept resize across
        // multiple attempts — observed ~200px progress per 400ms gap).
        scheduleCascadePass(after: 0.12, label: "pass 2",
                            app: targetApp, name: targetAppName,
                            screen: screen, targetSize: targetSize,
                            direction: direction)
        scheduleCascadePass(after: 0.50, label: "pass 3",
                            app: targetApp, name: targetAppName,
                            screen: screen, targetSize: targetSize,
                            direction: direction)
        scheduleCascadePass(after: 1.00, label: "pass 4",
                            app: targetApp, name: targetAppName,
                            screen: screen, targetSize: targetSize,
                            direction: direction)

        // Diagnostic verification at +1200ms — purely reads sizes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) { [weak self] in
            guard self != nil else { return }
            let verification = AXWindowEnumerator.windows(of: targetApp)
            let wantedW = Int(targetSize.width.rounded())
            let wantedH = Int(targetSize.height.rounded())
            NSLog("[\(AppInfo.displayName)] Cascade verify: target size \(wantedW)×\(wantedH)")
            for (i, w) in verification.enumerated() {
                let gotW = Int(w.frame.width.rounded())
                let gotH = Int(w.frame.height.rounded())
                let mark = (abs(gotW - wantedW) > 4 || abs(gotH - wantedH) > 4)
                    ? "✗ REVERTED" : "✓ stuck"
                NSLog("[\(AppInfo.displayName)] Cascade verify[\(i)]: \(gotW)×\(gotH)  \(mark)")
            }
        }

        rebuildMenu()  // Re-enable Restore now that we have a snapshot.
    }

    /// Applies one cascade computation + mutation pass. Returns the
    /// number of windows successfully moved.
    private func applyCascadePass(
        windows: [EnumeratedWindow],
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection
    ) -> Int {
        let currentFrames = windows.map(\.frame)
        let targetFrames = FanGeometry.computeCascade(
            windows: currentFrames,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        let moves = zip(windows, targetFrames).map { window, target in
            (axWindow: window.axElement, target: target)
        }
        return WindowMutator.applyBatch(moves)
    }

    /// Schedules a delayed retry pass — re-enumerates the windows of
    /// the target app and applies the cascade again. Used to catch
    /// apps that need settling time between attempts (Chrome with
    /// DevTools, etc.).
    ///
    /// Early-exits if all windows are already at the target frame —
    /// most apps and most cases accept the cascade fully on pass 1,
    /// so re-poking them is wasteful and produces visible jitter.
    private func scheduleCascadePass(
        after delay: TimeInterval,
        label: String,
        app: NSRunningApplication,
        name: String,
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let refreshed = AXWindowEnumerator.windows(of: app)
            guard refreshed.count > 1 else { return }

            // Skip if everyone's already at target — this is the
            // fast path for apps that accept cascade cleanly on pass 1.
            if self.allWindowsAtTarget(refreshed, targetSize: targetSize) {
                NSLog("[\(AppInfo.displayName)] Cascade \(direction) on '\(name)' \(label): " +
                      "skipped — already converged")
                return
            }

            let count = self.applyCascadePass(
                windows: refreshed,
                screen: screen,
                targetSize: targetSize,
                direction: direction
            )
            NSLog("[\(AppInfo.displayName)] Cascade \(direction) on '\(name)' \(label): " +
                  "\(count)/\(refreshed.count) windows moved")
        }
    }

    /// True if every window's current frame matches `targetSize`
    /// (within a 4pt tolerance for rounding noise).
    private func allWindowsAtTarget(
        _ windows: [EnumeratedWindow],
        targetSize: CGSize
    ) -> Bool {
        let wantedW = Int(targetSize.width.rounded())
        let wantedH = Int(targetSize.height.rounded())
        return windows.allSatisfy { w in
            let gotW = Int(w.frame.width.rounded())
            let gotH = Int(w.frame.height.rounded())
            return abs(gotW - wantedW) <= 4 && abs(gotH - wantedH) <= 4
        }
    }

    @objc private func restoreLayout() {
        guard isTrusted else {
            NSLog("[\(AppInfo.displayName)] Restore aborted: AX permission not granted")
            return
        }
        guard let snapshot = lastSnapshot, !snapshot.isEmpty else {
            NSLog("[\(AppInfo.displayName)] Restore no-op: no previous layout to restore")
            return
        }

        let moves = snapshot.entries.map { entry in
            (axWindow: entry.axElement, target: entry.frame)
        }
        let successCount = WindowMutator.applyBatch(moves)

        NSLog("[\(AppInfo.displayName)] Restore: " +
              "\(successCount)/\(moves.count) windows restored")

        // One-shot: after restoring, drop the snapshot so the user
        // doesn't restore stale state on a subsequent cascade.
        lastSnapshot = nil
        rebuildMenu()
    }

    @objc private func reopenOnboarding() {
        if let existing = onboardingWindow {
            existing.presentOnboarding()
        } else {
            showOnboarding()
        }
    }

    @objc private func clearSelection() {
        windowSelection.clear()
    }
}
