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
        startPermissionMonitoring()
        startActiveAppTracking()
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

    /// Returns the best guess at the user's current foreground app,
    /// preferring (in order): the tracked last-active app, the menu
    /// bar owner, the frontmost app. Falls back through these because
    /// any one of them may briefly point at us during a click handler.
    private func resolveTargetApp() -> NSRunningApplication? {
        let myBundle = Bundle.main.bundleIdentifier
        if let tracked = lastUserApp, tracked.bundleIdentifier != myBundle {
            return tracked
        }
        if let menuBar = NSWorkspace.shared.menuBarOwningApplication,
           menuBar.bundleIdentifier != myBundle {
            return menuBar
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

            if !granted && self.onboardingWindow == nil {
                self.showOnboarding()
            } else if granted && !wasTrusted {
                self.dismissOnboarding()
            }
        }
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController()
        controller.onWindowClosed = { [weak self] in
            self?.onboardingWindow = nil
        }
        onboardingWindow = controller
        controller.presentOnboarding()
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

        // Cascade actions — one per direction.
        let cascadeRightItem = NSMenuItem(
            title: "Cascade Down-Right",
            action: #selector(cascadeDownRight),
            keyEquivalent: ""
        )
        cascadeRightItem.target = self
        cascadeRightItem.isEnabled = isTrusted
        menu.addItem(cascadeRightItem)

        let cascadeLeftItem = NSMenuItem(
            title: "Cascade Down-Left",
            action: #selector(cascadeDownLeft),
            keyEquivalent: ""
        )
        cascadeLeftItem.target = self
        cascadeLeftItem.isEnabled = isTrusted
        menu.addItem(cascadeLeftItem)

        let restoreItem = NSMenuItem(
            title: "Restore Previous Layout",
            action: #selector(restoreLayout),
            keyEquivalent: ""
        )
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

        // Two retries at progressively longer delays. Apps with settling
        // logic (Chrome with DevTools, etc.) need time between attempts.
        // Pass 2 at 120ms catches transient clamps quickly; pass 3 at
        // 500ms catches slow settlers that need a full layout cycle.
        scheduleCascadePass(after: 0.12, label: "pass 2",
                            app: targetApp, name: targetAppName,
                            screen: screen, targetSize: targetSize,
                            direction: direction)
        scheduleCascadePass(after: 0.50, label: "pass 3",
                            app: targetApp, name: targetAppName,
                            screen: screen, targetSize: targetSize,
                            direction: direction)

        // Diagnostic verification at +650ms — purely reads sizes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
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
}
