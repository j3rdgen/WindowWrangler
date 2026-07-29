//
//  CascadeOrchestrator.swift
//  Window Wrangler
//
//  Owns the cascade + restore flows. Lifted out of AppDelegate so:
//   - The orchestrator is unit-testable in isolation by injecting
//     mock target-app resolution and permission-status closures.
//   - AppDelegate is freed up to focus on app lifecycle, permissions,
//     menu rebuild, and active-app tracking.
//
//  Reliability stack — see `performCascade(direction:)` doc for full
//  description. Summary: pre-cascade AX warmup, 4 retry passes, verify
//  + laggards-only rescue, post-rescue diagnostic, generation-based
//  cancellation for race-safety with Restore.
//

import AppKit
import ApplicationServices
import os

@MainActor
final class CascadeOrchestrator {

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

    /// Horizontal offset between consecutive apps' cascade anchors in the
    /// "all apps" multi-app cascade. Larger than the per-window lateral
    /// reveal (60pt) so each app's pile is visibly distinct from its
    /// neighbors — when you look at the result you can clearly tell
    /// "this column is Chrome, that column is Finder." Tuned for the
    /// typical 1200pt-wide cascade window.
    private let interAppLateralOffset: CGFloat = 220

    // MARK: - Cascade behavior feature flags
    //
    // Independently switchable knobs for the three-stage cascade
    // improvement (see brief 2026-07-27). Each defaults to `true`
    // (new behavior). Set to `false` to fall back to the exact
    // previous behavior — no additional AX calls, no additional
    // logging, no reordering that didn't happen before.
    //
    // Stage 1 (this session): intent-based anchor selection +
    // auxiliary-window handling for the all-apps cascade. When
    // `false`, the old Rule 1 (non-resizable auto-anchor + A→Z
    // tail sort) runs unchanged.

    private let useIntentBasedCascadeAnchor = true
    private let useObservedCascadeResizeCapability = true
    private let useFixedSizeSlotAdjustment = true          // Stage 2.5 — right-align narrow non-anchor windows (matches anchor treatment)
    private let useAccessoryAppCascade = true              // Stage 2.6
    private let useExplicitCascadeZOrder = true            // Stage 3 (not yet implemented)

    // MARK: - State

    /// Pre-cascade snapshot for Restore Previous Layout. nil until the
    /// user has cascaded at least once.
    private(set) var lastSnapshot: LayoutSnapshot?

    /// True when there's a snapshot available to restore.
    var hasSnapshot: Bool { lastSnapshot != nil }

    /// Monotonic counter incremented every time a cascade or restore is
    /// invoked. Pending retry / verify / rescue closures capture the
    /// value at scheduling time and bail out if it no longer matches.
    /// This is how Restore (or a follow-up Cascade in another direction)
    /// cleanly cancels in-flight passes from the prior operation.
    private var cascadeGeneration: UInt64 = 0

    /// Per-cascade cache for the all-apps retry loop. Windows added
    /// here are excluded from further retry writes — their app has
    /// clamped them to a natural size that doesn't match the cascade
    /// target, and additional writes would just re-trigger z-order
    /// enforcement (which re-raises every window and produces the
    /// visible flicker the user reported for Get Info / About boxes).
    /// Populated when a retry pass observes a window whose current
    /// frame is unchanged from the previous retry — evidence the app
    /// has settled at its size constraint. Reset at the start of
    /// each all-apps cascade.
    private var stableClampedWindows: [(axElement: AXUIElement, frame: CGRect)] = []

    /// Per-cascade cache of each tracked window's frame at the
    /// PREVIOUS retry pass. The next retry pass compares against
    /// this to detect stable-clamped windows. Reset at the start of
    /// each all-apps cascade.
    private var previousRetryFrames: [(axElement: AXUIElement, frame: CGRect)] = []

    // MARK: - Stage 2 cascade-local resize capability
    //
    // Per-cascade classification of what each window's resize
    // actually did, observed from the frame it ended up at after
    // pass 1's write. Distinct from the project-wide
    // `WindowMutator.isSizeSettable` (single boolean) — this is a
    // richer four-state model that lets us:
    //   - accept Terminal's character-grid snap without treating it
    //     as a laggard (constrainedResizable)
    //   - stop retrying Get Info / About This Mac size writes
    //     (fixedSize)
    //   - keep the fast path for normal windows (resizable)
    //   - fall back safely when AX gives us garbage (unknown)
    //
    // Feature-flagged behind `useObservedCascadeResizeCapability`.
    // When the flag is off, all Stage 2 logic is bypassed and the
    // Stage 1 stable-clamp tracking handles retry suppression on
    // its own.

    /// One window's classified resize behavior for the current
    /// cascade. Never cached across cascades — an app can change
    /// its resize policy between cascades (Xcode with different
    /// documents open, Chrome with DevTools attached, etc.).
    private enum CascadeResizeCapability {
        /// App accepted the write exactly (within ±4pt rounding).
        case resizable
        /// App snapped or clamped to a nearby size — Terminal
        /// character grid, Xcode minimum size, etc. Verify with a
        /// larger tolerance and don't retry.
        case constrainedResizable
        /// Size unchanged from the pre-cascade natural size. The
        /// app rejected the resize entirely — Get Info, About This
        /// Mac, most alert-style panels.
        case fixedSize
        /// AX error, transient failure, or classification hasn't
        /// happened yet. Treated conservatively (uses the tight
        /// tolerance, still retries).
        case unknown
    }

    /// Per-cascade capability lookup keyed by AX element. Populated
    /// during retry passes by comparing the observed frame against
    /// the requested target and the pre-cascade size. Reset at the
    /// start of each all-apps cascade.
    private var cascadeCapabilityByElement: [(axElement: AXUIElement, capability: CascadeResizeCapability)] = []

    /// Per-cascade cache of each window's size BEFORE pass 1
    /// wrote to it. Needed for classification: to distinguish
    /// "app snapped to a nearby constrained size" (returned size
    /// differs from BOTH requested and original) from "app rejected
    /// the resize entirely" (returned size equals original).
    /// Reset at the start of each all-apps cascade.
    private var preCascadeSizeByElement: [(axElement: AXUIElement, size: CGSize)] = []

    // MARK: - Injected dependencies

    /// Resolves the current target app for cascade/restore. Injected so
    /// AppDelegate retains ownership of the menuBarOwningApplication /
    /// lastUserApp logic, and so tests can inject a fixed app.
    private let resolveTargetApp: () -> NSRunningApplication?

    /// Live read of the AX trust state. Used to bail out cleanly when
    /// permission is revoked mid-flight (after passes are already scheduled).
    private let isTrusted: () -> Bool

    /// Fires when the snapshot availability changes (cascade creates one,
    /// restore consumes one). AppDelegate uses this to rebuild the menu
    /// so the Restore item's enabled state stays accurate.
    var onSnapshotChanged: (() -> Void)?

    /// Fires after each cascade pass moves windows. LassoCoordinator
    /// wires this to refresh the selection outlines so they follow
    /// the windows to their new positions.
    var onWindowsMoved: (() -> Void)?

    /// Last cascade direction the user triggered (via any path — DR
    /// menu item, DL shortcut, all-apps DR, etc.). Multi-window
    /// resize reads this to auto-cascade the resized windows in the
    /// same direction so a fan stays a fan after the size change.
    /// Defaults to `.downRight` at launch — matches the primary
    /// menu item's ordering.
    private(set) var lastCascadeDirection: CascadeDirection = .downRight

    init(
        resolveTargetApp: @escaping () -> NSRunningApplication?,
        isTrusted: @escaping () -> Bool
    ) {
        self.resolveTargetApp = resolveTargetApp
        self.isTrusted = isTrusted
    }

    // MARK: - Public API

    /// Cascades the resolved target app's windows in the given direction
    /// on the given display.
    ///
    /// `targetScreen` decides which display the cascade operates on.
    /// When provided (typically the mouse-cursor's display for a
    /// shortcut-triggered cascade), the cascade only touches windows
    /// whose midpoint is on that display — windows on other displays
    /// are left untouched. When nil (typically a menu trigger, where
    /// the mouse is over our menu and not a useful intent signal), the
    /// cascade falls back to the display containing the app's front
    /// window's midpoint.
    ///
    /// On a single-display setup the filter collapses to "all windows"
    /// (every window's midpoint is on the only display), so behavior
    /// is unchanged from before.
    ///
    /// See file-level doc comment for the reliability stack.
    func performCascade(direction: CascadeDirection, targetScreen: NSScreen? = nil) {
        guard isTrusted() else {
            Log.cascade.error("Aborted: AX permission not granted")
            return
        }
        lastCascadeDirection = direction

        guard let targetApp = resolveTargetApp() else {
            Log.cascade.error("Aborted: no user app could be resolved")
            return
        }
        let targetAppName = targetApp.localizedName ?? "?"
        Log.cascade.info("Resolved target app: '\(targetAppName, privacy: .public)'")

        // Pre-cascade warmup — read once so AX is hot. Result discarded;
        // the real enumeration on the next line is what we operate on.
        // After idle periods the AX framework / target app's
        // accessibility tree can go cold; first read has higher latency.
        _ = AXWindowEnumerator.windows(of: targetApp)

        let allWindows = AXWindowEnumerator.windows(of: targetApp)

        guard !allWindows.isEmpty else {
            Log.cascade.notice("No-op: no windows found in '\(targetAppName, privacy: .public)'")
            return
        }

        // Pick the display the cascade operates on. Caller-provided
        // wins; otherwise default to the front window's display.
        guard let chosenScreen = targetScreen
                ?? CoordinateSpace.screen(containing: allWindows[0].frame) else {
            Log.cascade.error("Aborted: no display available")
            return
        }
        let screenLabel = chosenScreen.localizedName

        // Filter to only the windows whose midpoint is on the chosen
        // display. On a single-display setup this is a no-op; on
        // multi-display setups it prevents cascade from "pulling"
        // windows from the other display into this one.
        let windows = allWindows.filter { window in
            CoordinateSpace.screen(containing: window.frame)?.frame == chosenScreen.frame
        }
        Log.cascade.info(
            "Target display: '\(screenLabel, privacy: .public)' — \(windows.count, privacy: .public)/\(allWindows.count, privacy: .public) windows on this display"
        )

        guard windows.count > 1 else {
            Log.cascade.notice(
                "No-op: \(windows.count, privacy: .public) cascadable window(s) on target display '\(screenLabel, privacy: .public)'"
            )
            return
        }

        // Bump the generation so any pending passes from a prior op
        // know to bail.
        cascadeGeneration &+= 1
        let myGen = cascadeGeneration

        // Snapshot current state BEFORE moving anything, so Restore works.
        // Only includes windows on the target display — windows on other
        // displays weren't touched and don't need to be restored.
        lastSnapshot = LayoutSnapshot(from: windows)

        let screen = computeScreenFrame(visibleFrame: chosenScreen.visibleFrame)
        let targetSize = CGSize(
            width: screen.width * cascadeWindowSizeFraction,
            height: screen.height * cascadeWindowSizeFraction
        )

        let count1 = applyCascadePass(
            windows: windows,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        Log.cascade.info(
            "\(String(describing: direction), privacy: .public) on '\(targetAppName, privacy: .public)' pass 1: \(count1, privacy: .public)/\(windows.count, privacy: .public) windows moved"
        )
        if count1 > 0 { onWindowsMoved?() }

        scheduleCascadePass(generation: myGen, after: 0.12, label: "pass 2",
                            app: targetApp, name: targetAppName,
                            display: chosenScreen,
                            screen: screen, targetSize: targetSize,
                            direction: direction)
        scheduleCascadePass(generation: myGen, after: 0.50, label: "pass 3",
                            app: targetApp, name: targetAppName,
                            display: chosenScreen,
                            screen: screen, targetSize: targetSize,
                            direction: direction)
        scheduleCascadePass(generation: myGen, after: 1.00, label: "pass 4",
                            app: targetApp, name: targetAppName,
                            display: chosenScreen,
                            screen: screen, targetSize: targetSize,
                            direction: direction)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == myGen else {
                Log.cascade.info("Verify/rescue: skipped (cancelled by newer operation)")
                return
            }
            guard self.isTrusted() else {
                Log.cascade.error("Verify/rescue: skipped (AX permission no longer granted)")
                return
            }
            self.verifyAndRescueIfNeeded(
                generation: myGen,
                app: targetApp,
                name: targetAppName,
                display: chosenScreen,
                screen: screen,
                targetSize: targetSize,
                direction: direction
            )
        }

        // Notify so the menu rebuild reflects the new snapshot.
        onSnapshotChanged?()
    }

    /// Cascades windows of EVERY visible app on the target display,
    /// grouped by application. Each app's windows form their own normal
    /// cascade (same per-window size and reveals as single-app cascade);
    /// each subsequent app's anchor is offset horizontally by
    /// `interAppLateralOffset` so each app's title-bar column remains
    /// visible — a "cascade of cascades."
    ///
    /// Apps with no windows on the target display are skipped.
    ///
    /// Reliability: pass 1 fires immediately, then 3 retry passes at
    /// 120ms / 500ms / 1000ms that re-check each window against its
    /// expected target and re-apply any that drifted. Verify at +1.2s
    /// is diagnostic only.
    /// Cascades a caller-supplied set of AX windows (typically the
    /// lasso selection) in the given direction on the given display.
    /// The window size passed to the cascade math is taken from the
    /// FIRST window in the list — for the post-resize flow this is
    /// the frontmost (target) size that every other selected window
    /// already matches, so cascading with that size lays out a fan
    /// with uniform, correct dimensions.
    ///
    /// Unlike `performCascade` / `performCascadeAllApps`, this does
    /// NOT snapshot for Restore, does NOT run retry passes, and does
    /// NOT re-enumerate — the caller has already resolved the AX
    /// elements and the operation is intended to feel snappy right
    /// after another interactive gesture (multi-window resize).
    ///
    /// No-op if the window list has fewer than 2 windows (cascade
    /// needs at least 2 to make sense as a fan).
    func performCascadeOnSelection(
        _ windows: [EnumeratedWindow],
        direction: CascadeDirection,
        targetScreen: NSScreen,
        overrideTargetSize: CGSize? = nil,
        preserveWindowSizes: Bool = false
    ) {
        guard isTrusted() else {
            Log.cascade.error("Selection cascade aborted: AX permission not granted")
            return
        }
        guard windows.count > 1 else {
            Log.cascade.info(
                "Selection cascade no-op: \(windows.count, privacy: .public) window(s) — need at least 2"
            )
            return
        }
        lastCascadeDirection = direction
        let screen = computeScreenFrame(visibleFrame: targetScreen.visibleFrame)
        // Slot width defaults to the frontmost's current size (used by
        // the normal path where sizes are being written to match the
        // anchor). The auto-cascade after multi-window resize passes
        // `overrideTargetSize` = the user's drag target, so slot width
        // reflects intent rather than the frontmost's post-clamp size.
        let targetSize = overrideTargetSize ?? windows[0].frame.size
        let moved = applyCascadePass(
            windows: windows,
            screen: screen,
            targetSize: targetSize,
            direction: direction,
            preserveWindowSizes: preserveWindowSizes
        )
        Log.cascade.info(
            "Selection cascade \(String(describing: direction), privacy: .public): \(moved, privacy: .public)/\(windows.count, privacy: .public) moved at size \(Int(targetSize.width), privacy: .public)×\(Int(targetSize.height), privacy: .public)\(preserveWindowSizes ? " (positions only)" : "")"
        )
        if moved > 0 { onWindowsMoved?() }
    }

    func performCascadeAllApps(direction: CascadeDirection, targetScreen: NSScreen? = nil) {
        guard isTrusted() else {
            Log.cascade.error("All-apps cascade aborted: AX permission not granted")
            return
        }
        lastCascadeDirection = direction

        // Pick target display — caller-provided (mouse cursor's display
        // from shortcutCascade), then mouse cursor, then primary.
        guard let chosenScreen = targetScreen
                ?? CoordinateSpace.screen(containing: NSEvent.mouseLocation)
                ?? NSScreen.main else {
            Log.cascade.error("All-apps cascade aborted: no display available")
            return
        }
        let screenLabel = chosenScreen.localizedName

        // Enumerate every "regular" app's windows on the target display.
        // Skip ourselves (.accessory anyway, but the bundle-ID check is
        // belt-and-suspenders). Skip apps with <2 windows on the display
        // — cascade math requires ≥2, and a single window shouldn't be
        // arbitrarily moved.
        let myBundle = Bundle.main.bundleIdentifier
        // ANCHOR RULES for the all-apps cascade
        // ------------------------------------
        //   1. If any window is AX-non-resizable (Zoom pre-login,
        //      fixed-size login dialog, etc.), its app becomes the
        //      AUTO-ANCHOR. Non-resizable windows can't participate
        //      cleanly as mid-cascade windows, so they take slot 0.
        //      When multiple apps have non-resizable windows, they're
        //      ordered A→Z among themselves.
        //   2. Otherwise the frontmost user app is the anchor (the
        //      "app you were just using" is at the visible front).
        //   3. Every non-anchor app follows in ALPHABETICAL order.
        //   4. Within each app group, windows stay in AX z-order
        //      (frontmost window of that app first).
        //
        // The runningApps sort below implements rule 2 (frontmost
        // first) as the initial pass. Rules 1 and 3 are applied later,
        // after we know which apps have non-resizable windows.
        //
        // NSWorkspace.shared.runningApplications is "no particular
        // order" per Apple docs — without this sort the cascade would
        // reshuffle on every run.
        let alphabeticalByAppName: (NSRunningApplication, NSRunningApplication) -> Bool = { lhs, rhs in
            let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
            let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
        let frontApp = resolveTargetApp()
        let frontPID = frontApp?.processIdentifier
        // STAGE 2.6: also include `.accessory` (LSUIElement=YES) apps.
        // The default filter (.regular only) drops About This Mac,
        // which is owned by System Information (com.apple.SystemProfiler)
        // — an accessory app that never appears in the cascade even
        // though its window is clearly visible. Blocklist known system
        // accessory apps whose "windows" aren't real user windows:
        // Dock (Mission Control panels), SystemUIServer, Control Center,
        // Notification Center, Stage Manager (WindowManager), wallpaper
        // agents, Spotlight, loginwindow, screencapture overlay.
        //
        // Downstream filters (window count > 0, subrole in allowlist,
        // size >= 200×100) drop anything the blocklist misses. If some
        // other system app leaks through with unwanted windows, add
        // its bundleID here.
        let systemAccessoryBlocklist: Set<String> = [
            "com.apple.dock",
            "com.apple.systemuiserver",
            "com.apple.controlcenter",
            "com.apple.notificationcenterui",
            "com.apple.WindowManager",
            "com.apple.wallpaper.WallpaperAgent",
            "com.apple.Spotlight",
            "com.apple.loginwindow",
            "com.apple.screencaptureui",
        ]
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.bundleIdentifier != myBundle else { return false }
            let policy = app.activationPolicy
            if useAccessoryAppCascade {
                let allowed = policy == .regular || policy == .accessory
                return allowed && !systemAccessoryBlocklist.contains(app.bundleIdentifier ?? "")
            } else {
                return policy == .regular
            }
        }.sorted { lhs, rhs in
            // Rule 2: frontmost app wins the anchor position.
            if let frontPID {
                if lhs.processIdentifier == frontPID { return true }
                if rhs.processIdentifier == frontPID { return false }
            }
            // Rule 3: everyone else A→Z.
            return alphabeticalByAppName(lhs, rhs)
        }

        cascadeGeneration &+= 1
        let myGen = cascadeGeneration

        // Reset per-cascade retry state — fixes the "1-2 seconds of
        // flicker" issue where fixed-size windows (Get Info, About
        // This Mac) would trip retry-pass laggard detection on every
        // pass and each retry would re-fire enforceCascadeZOrder →
        // every window raised again → visible flash.
        stableClampedWindows.removeAll()
        previousRetryFrames.removeAll()

        // Stage 2: reset per-cascade capability classification.
        // preCascadeSizeByElement gets populated below during the
        // pendingGroups loop (from each window's pre-cascade
        // frame). cascadeCapabilityByElement starts empty and gets
        // filled in as retry passes observe post-write frames.
        cascadeCapabilityByElement.removeAll()
        preCascadeSizeByElement.removeAll()

        let screen = computeScreenFrame(visibleFrame: chosenScreen.visibleFrame)
        let targetSize = CGSize(
            width: screen.width * cascadeWindowSizeFraction,
            height: screen.height * cascadeWindowSizeFraction
        )

        // Enumerate every visible app's windows on the target display.
        // INCLUDE single-window apps — every visible window participates
        // in the all-apps cascade, even if an app only has one window.
        struct PendingGroup {
            let app: NSRunningApplication
            let windows: [EnumeratedWindow]
        }
        var pendingGroups: [PendingGroup] = []
        for app in runningApps {
            // Pre-warm AX once per app so cold-start latency doesn't
            // distort the first pass.
            _ = AXWindowEnumerator.windows(of: app)
            let allWindowsForApp = AXWindowEnumerator.windows(of: app)
            let displayWindows = windowsOnDisplay(allWindowsForApp, display: chosenScreen)
            guard !displayWindows.isEmpty else { continue }

            // Stage 2: record every window's pre-cascade size so
            // the retry loop can classify each window's resize
            // behavior. Populated regardless of the anchor flag —
            // it's a lookup table, not a behavior change.
            if useObservedCascadeResizeCapability {
                for w in displayWindows {
                    recordPreCascadeSize(w.frame.size, for: w.axElement)
                }
            }

            if useIntentBasedCascadeAnchor {
                // NEW PATH: preserve AX z-order within each group.
                // No non-resizable promotion — a stray Finder Get Info
                // (or similar auxiliary that reports non-settable size)
                // must not jump ahead of the app's real main window,
                // and must not steal the global anchor slot. The
                // intent-based reorder below picks the anchor within
                // the frontmost app's group; other apps keep AX order.
                pendingGroups.append(PendingGroup(app: app, windows: displayWindows))
            } else {
                // OLD PATH: within each app's window list, promote
                // non-resizable windows to the front. Combined with the
                // group-level promotion below, this makes any
                // non-resizable window the AUTO-ANCHOR of the cascade —
                // flush against the anchor corner at its natural size,
                // frontmost in z-order.
                let nonResizable = displayWindows.filter { !WindowMutator.isSizeSettable($0.axElement) }
                let resizable = displayWindows.filter { WindowMutator.isSizeSettable($0.axElement) }
                pendingGroups.append(PendingGroup(app: app, windows: nonResizable + resizable))
            }
        }

        if useIntentBasedCascadeAnchor {
            // NEW PATH: intent-based anchor selection.
            //
            // 1. Find the frontmost app's group (already sorted first
            //    by the runningApps sort above via Rule 2).
            // 2. Within it, pick the intended anchor window using AX
            //    metadata: main → focused → first non-auxiliary →
            //    largest. Auxiliaries (dialogs, modals, floating
            //    panels) are demoted regardless of z-order — a Get
            //    Info panel that's currently frontmost still doesn't
            //    steal the anchor from its parent folder browser.
            // 3. Move that window to index 0 within the frontmost
            //    group so the cascade's slot 0 (the anchor position)
            //    receives it.
            // 4. Frontmost group stays at pendingGroups index 0 (the
            //    runningApps sort already put it there).
            // 5. Other apps keep enumeration order (frontmost-priority
            //    was the input; retaining that order preserves visual
            //    stability across cascade runs). No A→Z reshuffling.
            //
            // Additional AX reads scoped to the frontmost app's
            // windows only (4 attrs × N frontmost-app windows,
            // typically <10 windows). All other apps take zero extra
            // AX calls — the fast path is preserved.
            if let frontPID,
               let frontmostGroupIdx = pendingGroups.firstIndex(where: { $0.app.processIdentifier == frontPID }) {
                let frontmostGroup = pendingGroups[frontmostGroupIdx]
                let pick = pickAnchorWindow(from: frontmostGroup.windows)
                var reorderedWindows = frontmostGroup.windows
                if pick.index != 0 {
                    let anchor = reorderedWindows.remove(at: pick.index)
                    reorderedWindows.insert(anchor, at: 0)
                }
                pendingGroups[frontmostGroupIdx] = PendingGroup(
                    app: frontmostGroup.app,
                    windows: reorderedWindows
                )
                if frontmostGroupIdx != 0 {
                    let moved = pendingGroups.remove(at: frontmostGroupIdx)
                    pendingGroups.insert(moved, at: 0)
                }
                let anchorTitle = axTitle(of: reorderedWindows[0].axElement) ?? "?"
                let appName = frontmostGroup.app.localizedName ?? "?"
                Log.cascade.info(
                    "Cascade anchor: [\(appName, privacy: .public)] / [\(anchorTitle, privacy: .public)] — reason: \(pick.reason, privacy: .public)"
                )
            } else {
                // No frontmost app resolvable — leave enumeration
                // order, log for diagnostics.
                Log.cascade.info(
                    "Cascade anchor: no frontmost app resolved — using enumeration order"
                )
            }
        } else {
            // OLD PATH: Rule 1 — promote non-resizable app groups to
            // the front. When any auto-anchor is present, drop the
            // frontmost priority for the tail — everything (both
            // promoted and non-promoted groups) sorts A→Z. The anchor
            // came from non-resizability, not from user attention, so
            // users expect Acrobat before Google Chrome regardless of
            // which app they last clicked.
            var withNonResizable: [PendingGroup] = []
            var withoutNonResizable: [PendingGroup] = []
            for group in pendingGroups {
                if group.windows.contains(where: { !WindowMutator.isSizeSettable($0.axElement) }) {
                    withNonResizable.append(group)
                } else {
                    withoutNonResizable.append(group)
                }
            }
            if !withNonResizable.isEmpty {
                withNonResizable.sort { alphabeticalByAppName($0.app, $1.app) }
                withoutNonResizable.sort { alphabeticalByAppName($0.app, $1.app) }
            }
            pendingGroups = withNonResizable + withoutNonResizable
            if !withNonResizable.isEmpty {
                let names = withNonResizable.map { $0.app.localizedName ?? "?" }.joined(separator: ", ")
                Log.cascade.info(
                    "All-apps cascade: auto-anchoring non-resizable window group(s) — apps: [\(names, privacy: .public)]"
                )
            }
        }

        // Diagnostic: cascade order so we can spot ordering bugs when
        // the layout looks wrong. Each entry is `App(nWindows)`.
        let frontLabel = frontApp?.localizedName ?? "?"
        let orderSummary = pendingGroups.map {
            "\($0.app.localizedName ?? "?")(\($0.windows.count))"
        }.joined(separator: " → ")
        Log.cascade.info(
            "All-apps cascade: frontmost='\(frontLabel, privacy: .public)' pendingGroups: \(orderSummary, privacy: .public)"
        )

        let totalWindows = pendingGroups.reduce(0) { $0 + $1.windows.count }

        // Build targets as ONE continuous cascade across all apps:
        //   - Within an app, each successive window steps by the normal
        //     (lateralReveal, headerReveal) — same look as single-app
        //     cascade.
        //   - At the boundary between two apps, an EXTRA horizontal
        //     offset (interAppLateralOffset) is added on top of the
        //     normal lateral step — the "sticking out further"
        //     horizontal jump that visually separates each app's
        //     title-bar column from the next.
        //   - The vertical step stays uniform — windows continue
        //     marching diagonally without a "stutter" between apps.
        let lateralReveal: CGFloat = 60
        let headerReveal: CGFloat = 28
        let lateralSign: CGFloat = direction == .downLeft ? 1 : -1

        // Keep windows at full target size (70% of cascade area). Only
        // the REVEAL spacing (lateral, interApp, header) shrinks to fit
        // when there are many windows.
        let numBoundaries = max(0, pendingGroups.count - 1)
        let totalLateralSteps =
            CGFloat(max(0, totalWindows - 1) - numBoundaries) * lateralReveal
            + CGFloat(numBoundaries) * (lateralReveal + interAppLateralOffset)
        let totalVerticalSteps = CGFloat(max(0, totalWindows - 1)) * headerReveal

        let availableLateral = max(0, screen.width - targetSize.width)
        let availableVertical = max(0, screen.height - targetSize.height)

        let lateralScale: CGFloat = totalLateralSteps > availableLateral && totalLateralSteps > 0
            ? availableLateral / totalLateralSteps
            : 1.0
        let verticalScale: CGFloat = totalVerticalSteps > availableVertical && totalVerticalSteps > 0
            ? availableVertical / totalVerticalSteps
            : 1.0

        let scaledLateral = lateralReveal * lateralScale
        let scaledInterApp = interAppLateralOffset * lateralScale
        let scaledHeader = headerReveal * verticalScale

        if lateralScale < 1.0 || verticalScale < 1.0 {
            Log.cascade.info(
                "All-apps: tightening reveals to fit \(totalWindows, privacy: .public) windows at full size — window \(Int(targetSize.width.rounded()), privacy: .public)×\(Int(targetSize.height.rounded()), privacy: .public), lateral \(Int(scaledLateral.rounded()), privacy: .public)pt, interApp \(Int(scaledInterApp.rounded()), privacy: .public)pt, header \(Int(scaledHeader.rounded()), privacy: .public)pt"
            )
        }

        // Master anchor position. Slots are computed as if EVERY window
        // is `targetSize.width` wide — that keeps the right-edge cascade
        // math consistent for subsequent windows (each slot's right edge
        // sits `lateralStep` pt inside the previous slot's right edge).
        //
        // A narrow anchor (System Settings About = 723pt, Get Info = 400pt,
        // Zoom pre-login) that doesn't fill its 1168pt slot is right-
        // aligned within that slot down in the per-window loop below,
        // so its right edge still lands flush at `screen.maxX` in DR.
        //
        // Earlier attempt: use the anchor's natural width for `masterAnchorX`
        // itself so the anchor slot is narrower. That desynced the
        // subsequent-slot cascade — slot 1's `targetSize.width` rect then
        // extended past `screen.maxX`, and Phase 2's rigid shift pulled
        // the whole fan left by (targetWidth - naturalWidth), reintroducing
        // the same gap on the right that the change was meant to remove.
        let masterAnchorX: CGFloat = (direction == .downLeft)
            ? screen.minX
            : screen.maxX - targetSize.width
        let masterAnchorY = screen.minY

        var naturalTargets: [CGRect] = []
        var currentX = masterAnchorX
        var currentY = masterAnchorY
        var isFirstWindow = true

        for group in pendingGroups {
            for (windowIndex, _) in group.windows.enumerated() {
                if isFirstWindow {
                    isFirstWindow = false
                } else {
                    let isAppBoundary = (windowIndex == 0)
                    let lateralStep = scaledLateral + (isAppBoundary ? scaledInterApp : 0)
                    currentX += lateralSign * lateralStep
                    currentY += scaledHeader
                }
                naturalTargets.append(CGRect(
                    x: currentX,
                    y: currentY,
                    width: targetSize.width,
                    height: targetSize.height
                ))
            }
        }

        // Phase 2: global rigid shift so the union fits in `screen`.
        let shiftedTargets: [CGRect]
        if let first = naturalTargets.first {
            let union = naturalTargets.dropFirst().reduce(first) { $0.union($1) }
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            if union.minX < screen.minX {
                dx = screen.minX - union.minX
            } else if union.maxX > screen.maxX {
                dx = screen.maxX - union.maxX
            }
            if union.minY < screen.minY {
                dy = screen.minY - union.minY
            } else if union.maxY > screen.maxY {
                dy = screen.maxY - union.maxY
            }
            if dx != 0 || dy != 0 {
                shiftedTargets = naturalTargets.map { $0.offsetBy(dx: dx, dy: dy) }
            } else {
                shiftedTargets = naturalTargets
            }
        } else {
            shiftedTargets = []
        }

        // Stitch the targets back to their app + AX element.
        //
        // Two things happen per window:
        //
        // 1. Frame SIZE we send to WindowMutator:
        //    - Non-resizable (AX says settable=false): use the window's
        //      natural size. WindowMutator will skip the size write.
        //    - Resizable: use the cascade-computed target size. That
        //      matches the approved cascade look when the app complies.
        //
        // 2. Frame ORIGIN clamp:
        //    - We clamp the origin so the window's NATURAL size fits
        //      inside `screen` (the padded cascade area). This handles
        //      three cases at once:
        //         * True non-resizable (Zoom pre-login) — pinned
        //           inside the buffer.
        //         * Resizable-but-refuses-to-shrink (Zoom Workplace
        //           signed-in, some Photos states) — even though AX
        //           reports settable, the app may keep its natural
        //           size after our size write. Pre-clamping for
        //           natural keeps it on-screen either way.
        //         * Compliant resizable — natural size at the slot
        //           usually fits already, so the clamp is a no-op and
        //           the ideal cascade slot is preserved. If the natural
        //           size is very oversized and would overflow, the
        //           clamp shifts the origin slightly and the window
        //           still ends up on-screen at target size after the
        //           mutator's resize dance.
        //
        // This is what the user described as "non-resizable window
        // influencing the anchor from the back" — the fact that a
        // window CAN'T fit at natural size at the slot forces the
        // slot origin to be adjusted so it still fits.
        var plans: [AppCascadePlan] = []
        var snapshotEntries: [LayoutSnapshot.Entry] = []
        var allMoves: [(axWindow: AXUIElement, target: CGRect)] = []
        var idx = 0
        for group in pendingGroups {
            var appPlanFrames: [(axElement: AXUIElement, target: CGRect)] = []
            for window in group.windows {
                let plannedTarget = shiftedTargets[idx]
                let isSettable = WindowMutator.isSizeSettable(window.axElement)
                let naturalSize = window.frame.size
                let isAnchor = (idx == 0)

                // STAGE 2.5: right-edge alignment for narrow fixed-size
                // windows in downRight cascades. Currently gated to the
                // ANCHOR only — non-anchor narrow windows (e.g. the small
                // "About This Mac" system dialog at 280pt) stay left-
                // aligned in their slot because right-aligning them
                // detaches them visually from the fan.
                //
                // Gate — only when we're confident the window will stay
                // narrower than the slot:
                //   - `!isSettable`: definitely won't resize (Zoom
                //     pre-login).
                //   - Settable but `naturalWidth < 70% of target`:
                //     strong signal it's a fixed-size dialog that
                //     reports settable=true but clamps at write time
                //     (Get Info at 34% of target, System Settings About
                //     panel at 62% of target).
                // A settable window at 70–99% of target is probably a
                // normal window the user shrunk — it'll grow back to
                // target after cascade, so left-alignment is correct.
                //
                // downLeft cascades don't need this — the LEFT edge of
                // every window aligns with the slot origin, which is
                // already the correct reveal direction.
                let anchorStaysNarrow = isAnchor
                    && (!isSettable || naturalSize.width < plannedTarget.size.width * 0.7)
                    && naturalSize.width < plannedTarget.size.width
                let nonAnchorStaysNarrow = useFixedSizeSlotAdjustment
                    && !isAnchor
                    && naturalSize.width < plannedTarget.size.width
                    && (!isSettable || naturalSize.width < plannedTarget.size.width * 0.7)
                let willStayNarrow = anchorStaysNarrow || nonAnchorStaysNarrow

                let target: CGRect
                if willStayNarrow && direction == .downRight {
                    // Right-align by shifting the origin so the
                    // window's right edge lands at the slot's right
                    // edge. CRITICAL: pass `naturalSize` as fitFrame's
                    // frameSize argument so its clamp uses the actual
                    // narrow width — otherwise fitFrame's default
                    // clamp (max(frameSize, naturalSize) = the wide
                    // planned width) would drag x back to the anchor
                    // position and undo the shift entirely.
                    let shiftedOrigin = CGPoint(
                        x: plannedTarget.origin.x
                            + plannedTarget.size.width
                            - naturalSize.width,
                        y: plannedTarget.origin.y
                    )
                    target = fitFrame(
                        plannedOrigin: shiftedOrigin,
                        frameSize: naturalSize,
                        naturalSize: naturalSize,
                        bounds: screen
                    )
                } else {
                    let frameSize = isSettable ? plannedTarget.size : naturalSize
                    target = fitFrame(
                        plannedOrigin: plannedTarget.origin,
                        frameSize: frameSize,
                        naturalSize: naturalSize,
                        bounds: screen
                    )
                }
                allMoves.append((window.axElement, target))
                appPlanFrames.append((window.axElement, target))
                snapshotEntries.append(
                    LayoutSnapshot.Entry(axElement: window.axElement, frame: window.frame)
                )
                idx += 1
            }
            plans.append(AppCascadePlan(app: group.app, expectedFrames: appPlanFrames))
        }

        Log.cascade.info(
            "All-apps cascade target display: '\(screenLabel, privacy: .public)' — \(plans.count, privacy: .public) app group(s), \(totalWindows, privacy: .public) total windows"
        )

        guard totalWindows >= 2 else {
            Log.cascade.notice(
                "All-apps cascade no-op: \(totalWindows, privacy: .public) cascadable window(s) on '\(screenLabel, privacy: .public)' (need \u{2265}2 total)"
            )
            return
        }

        // Snapshot for restore. Restore puts ALL the moved windows back,
        // across every app.
        lastSnapshot = LayoutSnapshot(entries: snapshotEntries)

        // Pass 1.
        let count1 = WindowMutator.applyBatch(allMoves)
        Log.cascade.info(
            "All-apps \(String(describing: direction), privacy: .public) pass 1: \(count1, privacy: .public)/\(allMoves.count, privacy: .public) windows moved"
        )
        if count1 > 0 { onWindowsMoved?() }

        // Enforce z-order so the visual stacking matches the cascade's
        // intent: the anchor (first window in cascade order, the most
        // recently used app's window) is FRONT-most, and successive
        // windows are layered BEHIND it.
        enforceCascadeZOrder(plans: plans)

        // Retry passes.
        scheduleAllAppsRetry(generation: myGen, after: 0.12, label: "pass 2", direction: direction, plans: plans)
        scheduleAllAppsRetry(generation: myGen, after: 0.50, label: "pass 3", direction: direction, plans: plans)
        scheduleAllAppsRetry(generation: myGen, after: 1.00, label: "pass 4", direction: direction, plans: plans)

        // Verify at +1.2s — purely diagnostic for the all-apps path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == myGen else { return }
            guard self.isTrusted() else { return }
            self.verifyAllAppsCascade(plans: plans)
        }

        onSnapshotChanged?()
    }

    /// Restores the windows to their pre-cascade frames.
    func restoreLayout() {
        guard isTrusted() else {
            Log.cascade.error("Restore aborted: AX permission not granted")
            return
        }
        guard let snapshot = lastSnapshot, !snapshot.isEmpty else {
            Log.cascade.notice("Restore no-op: no previous layout to restore")
            return
        }

        // Cancel any in-flight cascade retry / verify / rescue work so
        // a pass scheduled a few hundred ms ago can't fire AFTER the
        // restore and undo it.
        cascadeGeneration &+= 1

        let moves = snapshot.entries.map { entry in
            (axWindow: entry.axElement, target: entry.frame)
        }
        let successCount = WindowMutator.applyBatch(moves)

        Log.cascade.notice(
            "Restore: \(successCount, privacy: .public)/\(moves.count, privacy: .public) windows restored"
        )

        // One-shot: drop the snapshot so the user doesn't restore stale
        // state on a subsequent cascade.
        lastSnapshot = nil
        onSnapshotChanged?()
    }

    /// Issues a throw-away AX enumeration shortly after launch so the
    /// framework's cold-start latency happens BEFORE the user's first
    /// cascade attempt. Without this, the first cascade tends to have
    /// slight sizing inconsistencies because AX writes don't fully
    /// settle within our pass windows on cold start. Delays 0.8s so the
    /// user's foreground app at launch has time to be detected and
    /// load its AX tree.
    func warmUpAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard let app = self.resolveTargetApp() else { return }
            // Just enumerate — don't mutate. Triggers AX to fully
            // initialize and the target app to build its accessibility
            // tree.
            _ = AXWindowEnumerator.windows(of: app)
        }
    }

    // MARK: - Internal

    /// Applies the configured margins to an `NSScreen.visibleFrame`,
    /// producing the cascade's available area on that display.
    /// Visible frame already excludes menu bar + Dock; we add a little
    /// extra padding on the sides + bottom so the layout has breathing
    /// room from the screen edges.
    private func computeScreenFrame(visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.minX + cascadeMarginLeft,
            y: visibleFrame.minY + cascadeMarginBottom,
            width: visibleFrame.width - cascadeMarginLeft - cascadeMarginRight,
            height: visibleFrame.height - cascadeMarginTop - cascadeMarginBottom
        )
    }

    /// Applies one cascade computation + mutation pass. Returns the
    /// number of windows successfully moved.
    private func applyCascadePass(
        windows: [EnumeratedWindow],
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection,
        preserveWindowSizes: Bool = false
    ) -> Int {
        let currentFrames = windows.map(\.frame)
        var targetFrames = FanGeometry.computeCascade(
            windows: currentFrames,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        if preserveWindowSizes {
            // Each write becomes position-only: keep each window's
            // ACTUAL current size (from the fresh AX read the caller
            // passed in) and reposition into the fan slot.
            //
            // Fan-direction edge alignment:
            //   DR — right edge of the window matches slot.right, so
            //        wider-than-slot windows extend leftward, narrower
            //        ones sit against the fan's reveal edge. Preserves
            //        the right-edge cascade the direction implies.
            //   DL — left edge matches slot.left (FanGeometry's default).
            //
            // Writing the SAME size the window already has (vs writing
            // targetSize and letting the app clamp) also eliminates the
            // visible post-release "extra shrink" — the cascade phase
            // was chasing a rounded target size and re-forcing the write.
            for i in 0..<targetFrames.count {
                let slot = targetFrames[i]
                let actualSize = windows[i].frame.size
                let originX: CGFloat
                switch direction {
                case .downRight:
                    originX = slot.maxX - actualSize.width
                case .downLeft:
                    originX = slot.origin.x
                }
                targetFrames[i] = CGRect(
                    x: originX,
                    y: slot.origin.y,
                    width: actualSize.width,
                    height: actualSize.height
                )
            }
        }
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
    /// Critically, the re-enumeration is filtered to the SAME display
    /// `performCascade` selected at cascade start. Without this, the
    /// retry would pull in windows from other displays — the app's
    /// full window set is enumerated each pass, so a cascade targeting
    /// "extended display only" would still drag in windows from
    /// the built-in display once the retry's recomputed targets
    /// included them.
    ///
    /// Early-exits if all (display-filtered) windows are already at
    /// their target frames — most apps accept the cascade fully on
    /// pass 1, so re-poking them is wasteful and produces visible
    /// jitter.
    ///
    /// Also bails if `cascadeGeneration` has advanced past `generation`
    /// — meaning a Restore or a follow-up Cascade has superseded the
    /// operation that scheduled us.
    private func scheduleCascadePass(
        generation: UInt64,
        after delay: TimeInterval,
        label: String,
        app: NSRunningApplication,
        name: String,
        display: NSScreen,
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == generation else {
                Log.cascade.info(
                    "\(String(describing: direction), privacy: .public) on '\(name, privacy: .public)' \(label, privacy: .public): skipped (cancelled by newer operation)"
                )
                return
            }
            guard self.isTrusted() else {
                Log.cascade.error(
                    "\(String(describing: direction), privacy: .public) on '\(name, privacy: .public)' \(label, privacy: .public): skipped (AX permission no longer granted)"
                )
                return
            }
            let refreshedAll = AXWindowEnumerator.windows(of: app)
            let refreshed = self.windowsOnDisplay(refreshedAll, display: display)
            guard refreshed.count > 1 else { return }

            if self.allWindowsAtExpectedFrames(
                refreshed,
                screen: screen,
                targetSize: targetSize,
                direction: direction
            ) {
                Log.cascade.info(
                    "\(String(describing: direction), privacy: .public) on '\(name, privacy: .public)' \(label, privacy: .public): skipped — already converged"
                )
                return
            }

            let count = self.applyCascadePass(
                windows: refreshed,
                screen: screen,
                targetSize: targetSize,
                direction: direction
            )
            Log.cascade.info(
                "\(String(describing: direction), privacy: .public) on '\(name, privacy: .public)' \(label, privacy: .public): \(count, privacy: .public)/\(refreshed.count, privacy: .public) windows moved"
            )
            if count > 0 { self.onWindowsMoved?() }
        }
    }

    /// Reads each window's frame, identifies any that didn't reach the
    /// target size + position (a "laggard"), re-applies the cascade only
    /// to those windows, then waits +0.4s and re-checks. If laggards
    /// remain AND we haven't exhausted the rescue budget, it recurses
    /// for another rescue round. After the final round it logs a
    /// "still failing" diagnostic so failures are visible in Console.
    ///
    /// Why multiple rounds: in a real failure case captured from logs,
    /// Chrome refused multiple windows' resize/move writes during the
    /// first rescue. A single rescue round got 5 of 8 laggards; 3 were
    /// still off. With one extra round most of those 3 take, because
    /// whatever transient state was blocking Chrome (a layout pass, a
    /// devtools constraint settling, etc.) has cleared by then. Up to
    /// `maxRescueRounds` rounds, ~400ms between each.
    ///
    /// Important: we re-pose only the laggards (not every window) so
    /// already-converged windows don't get a redundant size-position-
    /// size dance, which can produce a tiny but visible wiggle.
    private func verifyAndRescueIfNeeded(
        generation: UInt64,
        app: NSRunningApplication,
        name: String,
        display: NSScreen,
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection,
        rescueRound: Int = 1
    ) {
        let maxRescueRounds = 2

        // Re-enumerate AND filter to the cascade's target display, same
        // contract as scheduleCascadePass. Without the display filter
        // the verify step would consider all of the app's windows
        // (including ones on other displays) as cascade laggards, and
        // the rescue would drag them in to fill the recomputed targets.
        let verificationAll = AXWindowEnumerator.windows(of: app)
        let verification = windowsOnDisplay(verificationAll, display: display)
        // Compute the FULL expected target frame per window (position
        // + size), not just the size.
        let allFrames = verification.map(\.frame)
        let targetFrames = FanGeometry.computeCascade(
            windows: allFrames,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )

        // Verbose per-window verify lines only on the first round,
        // to keep Console output readable. Later rounds log only a
        // summary count.
        if rescueRound == 1 {
            let wantedW = Int(targetSize.width.rounded())
            let wantedH = Int(targetSize.height.rounded())
            Log.cascade.info("Verify: target size \(wantedW, privacy: .public)×\(wantedH, privacy: .public)")
        }

        var laggardIndices: [Int] = []
        for (i, w) in verification.enumerated() {
            let target = targetFrames[i]
            let stuck = frameMatches(w.frame, target: target)
            if rescueRound == 1 {
                let gotW = Int(w.frame.width.rounded())
                let gotH = Int(w.frame.height.rounded())
                let gotX = Int(w.frame.minX.rounded())
                let gotY = Int(w.frame.minY.rounded())
                let wantedX = Int(target.minX.rounded())
                let wantedY = Int(target.minY.rounded())
                Log.cascade.info(
                    "Verify[\(i, privacy: .public)]: @(\(gotX, privacy: .public),\(gotY, privacy: .public)) \(gotW, privacy: .public)×\(gotH, privacy: .public) vs target @(\(wantedX, privacy: .public),\(wantedY, privacy: .public))  \(stuck ? "✓ stuck" : "✗ REVERTED", privacy: .public)"
                )
            }
            if !stuck { laggardIndices.append(i) }
        }

        guard !laggardIndices.isEmpty else {
            if rescueRound > 1 {
                Log.cascade.info(
                    "Rescue round \(rescueRound, privacy: .public): no laggards remain ✓"
                )
            }
            return
        }

        Log.cascade.notice(
            "Rescue round \(rescueRound, privacy: .public) on '\(name, privacy: .public)': re-poking \(laggardIndices.count, privacy: .public) laggard window(s)"
        )

        let rescueMoves: [(axWindow: AXUIElement, target: CGRect)] = laggardIndices.map { i in
            (axWindow: verification[i].axElement, target: targetFrames[i])
        }
        let count = WindowMutator.applyBatch(rescueMoves)
        Log.cascade.info(
            "Rescue round \(rescueRound, privacy: .public): \(count, privacy: .public)/\(rescueMoves.count, privacy: .public) laggards nudged"
        )

        // After this round's rescue: wait 0.4s, then either start
        // another rescue round (if budget remains) or log the final
        // diagnostic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == generation else { return }
            guard self.isTrusted() else { return }

            if rescueRound < maxRescueRounds {
                // Recurse for another rescue. The recursive call's
                // verify step will both detect any remaining laggards
                // AND act as the "post-rescue" check for this round.
                self.verifyAndRescueIfNeeded(
                    generation: generation,
                    app: app,
                    name: name,
                    display: display,
                    screen: screen,
                    targetSize: targetSize,
                    direction: direction,
                    rescueRound: rescueRound + 1
                )
            } else {
                // Final round — log the surviving failures (or success).
                self.logFinalRescueOutcome(
                    app: app,
                    name: name,
                    display: display,
                    screen: screen,
                    targetSize: targetSize,
                    direction: direction,
                    totalRounds: rescueRound
                )
            }
        }
    }

    /// Read-only final diagnostic after the last rescue round. Logs
    /// whether the cascade fully converged. If anything is still off
    /// after all rescues, the user can re-cascade — we don't loop
    /// indefinitely (could be a window with a hard minimum-size
    /// constraint that genuinely can't shrink to the cascade target).
    private func logFinalRescueOutcome(
        app: NSRunningApplication,
        name: String,
        display: NSScreen,
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection,
        totalRounds: Int
    ) {
        let postAll = AXWindowEnumerator.windows(of: app)
        let post = windowsOnDisplay(postAll, display: display)
        let postTargets = FanGeometry.computeCascade(
            windows: post.map(\.frame),
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        var stillFailing = 0
        for (i, w) in post.enumerated() where i < postTargets.count {
            if !self.frameMatches(w.frame, target: postTargets[i]) {
                stillFailing += 1
            }
        }
        if stillFailing > 0 {
            Log.cascade.error(
                "Post-all-rescues (\(totalRounds, privacy: .public) round(s)): \(stillFailing, privacy: .public) window(s) STILL not at target on '\(name, privacy: .public)'"
            )
        } else {
            Log.cascade.info(
                "Post-all-rescues (\(totalRounds, privacy: .public) round(s)): all windows at target ✓"
            )
        }
    }

    /// True if every window's current frame matches its expected
    /// cascade target frame — POSITION and SIZE both — within a 4pt
    /// tolerance for rounding noise.
    ///
    /// Replaces the earlier size-only check. The size-only version had
    /// a real bug: a window that came out at the right size but the
    /// wrong position was being marked as "at target," causing the
    /// retry passes to skip and the verify+rescue to mark it as stuck.
    /// User-visible symptom: cascade would finish with some windows at
    /// the correct dimensions but scattered to wrong positions.
    private func allWindowsAtExpectedFrames(
        _ windows: [EnumeratedWindow],
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection
    ) -> Bool {
        let allFrames = windows.map(\.frame)
        let targetFrames = FanGeometry.computeCascade(
            windows: allFrames,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        return zip(windows, targetFrames).allSatisfy { w, target in
            frameMatches(w.frame, target: target)
        }
    }

    /// After cascading, raises each window via AX `kAXRaiseAction` so
    /// the visual z-order matches the cascade's intent. Without this,
    /// macOS keeps the pre-cascade z-order and windows positioned at
    /// the back of the cascade can render visually in front of the
    /// anchor windows they're supposed to be peeking out from behind.
    ///
    /// Iteration order is reverse-of-reverse: last app first, last
    /// window within each app first. Each raise brings that window
    /// to the front of the current stack; the very last raise (anchor
    /// window of the first app) ends up globally on top.
    private func enforceCascadeZOrder(plans: [AppCascadePlan]) {
        for plan in plans.reversed() {
            for (axElement, _) in plan.expectedFrames.reversed() {
                AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
            }
        }
    }

    /// One app's planned cascade as part of an all-apps cascade. Captures
    /// the per-window AX element and its target frame so retry passes can
    /// match windows by identity across re-enumerations.
    private struct AppCascadePlan {
        let app: NSRunningApplication
        let expectedFrames: [(axElement: AXUIElement, target: CGRect)]
    }

    /// Schedules an all-apps cascade retry pass.
    ///
    /// Each pass re-enumerates each app's windows, matches them to the
    /// original plan by AXUIElement identity (CFEqual), and re-applies
    /// any whose current frame doesn't match the expected target frame
    /// within the standard 4pt tolerance. Bails entirely if all windows
    /// have already converged — the common case after pass 1 succeeds.
    private func scheduleAllAppsRetry(
        generation: UInt64,
        after delay: TimeInterval,
        label: String,
        direction: CascadeDirection,
        plans: [AppCascadePlan]
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == generation else {
                Log.cascade.info(
                    "All-apps \(label, privacy: .public): skipped (cancelled by newer operation)"
                )
                return
            }
            guard self.isTrusted() else {
                Log.cascade.error(
                    "All-apps \(label, privacy: .public): skipped (AX permission no longer granted)"
                )
                return
            }

            // Walk every app's plan, collect laggards. Skip windows
            // we've already confirmed as stable-clamped (e.g. Get
            // Info, About This Mac) — retrying them wastes AX writes
            // AND triggers the enforceCascadeZOrder pass below, which
            // re-raises every window and produces visible flicker.
            //
            // Stable-clamped detection: if a window's current frame
            // is identical (within tolerance) to what it was at the
            // previous retry pass, and it still doesn't match target,
            // the app has settled at its size constraint — further
            // writes won't change anything.
            var laggardMoves: [(axWindow: AXUIElement, target: CGRect)] = []
            var totalChecked = 0
            var currentObservations: [(axElement: AXUIElement, frame: CGRect)] = []
            for plan in plans {
                let refreshed = AXWindowEnumerator.windows(of: plan.app)
                for (axElement, target) in plan.expectedFrames {
                    totalChecked += 1
                    guard let current = refreshed.first(where: { CFEqual($0.axElement, axElement) }) else {
                        // Window disappeared (closed, minimized, etc.) — skip.
                        continue
                    }
                    currentObservations.append((axElement, current.frame))

                    if self.useObservedCascadeResizeCapability {
                        // STAGE 2 PATH: classify observed capability
                        // once (from the readback of pass 1's write),
                        // then apply capability-aware tolerance.
                        //
                        // - resizable / unknown → tight tolerance
                        //   (±4pt size) — must reach target exactly.
                        // - constrainedResizable → loose tolerance
                        //   (±10pt size) — Terminal's grid snap is
                        //   fine, not a laggard.
                        // - fixedSize → size ignored entirely;
                        //   position must still match (a fixed-size
                        //   window at the wrong slot IS a laggard).
                        //
                        // Position and size verify independently so a
                        // constrained-size accept doesn't hide a
                        // real position error.
                        if self.cascadeCapability(for: axElement) == .unknown,
                           let originalSize = self.preCascadeSize(for: axElement) {
                            let cap = self.classifyResizeOutcome(
                                originalSize: originalSize,
                                requestedSize: target.size,
                                returnedSize: current.frame.size
                            )
                            self.setCascadeCapability(cap, for: axElement)
                        }
                        let cap = self.cascadeCapability(for: axElement)
                        let posOK = self.positionMatches(current.frame, target: target)
                        let sizeOK = self.sizeMatches(
                            current.frame.size,
                            target: target.size,
                            capability: cap
                        )
                        if posOK && sizeOK {
                            continue
                        }

                        // Belt-and-suspenders backstop from Stage 1:
                        // even when the capability-aware check says
                        // "still not at target," don't keep hammering
                        // the same doomed write. If a window's frame
                        // is unchanged from the previous retry pass,
                        // the app has settled at what it's willing to
                        // give us — mark stable and stop nudging. This
                        // is what prevents the Terminal-flicker case:
                        // repeated laggard writes each fire
                        // enforceCascadeZOrder below, re-raising every
                        // window and producing visible flash.
                        if self.axElementIsInList(self.stableClampedWindows, axElement) {
                            continue
                        }
                        if let previousFrame = self.axElementFrame(in: self.previousRetryFrames, for: axElement),
                           self.frameMatches(current.frame, target: previousFrame) {
                            self.stableClampedWindows.append((axElement, current.frame))
                            continue
                        }

                        // Real laggard — frame changed since last
                        // observation AND still doesn't meet the
                        // capability tolerance. Worth one more nudge.
                        laggardMoves.append((axElement, target))
                        continue
                    }

                    // OLD PATH (flag off): Stage 1 stable-clamp
                    // detection only. Kept intact for rollback.
                    if self.axElementIsInList(self.stableClampedWindows, axElement) {
                        continue
                    }
                    if self.frameMatches(current.frame, target: target) {
                        continue
                    }
                    if let previousFrame = self.axElementFrame(in: self.previousRetryFrames, for: axElement),
                       self.frameMatches(current.frame, target: previousFrame) {
                        self.stableClampedWindows.append((axElement, current.frame))
                        continue
                    }
                    laggardMoves.append((axElement, target))
                }
            }
            // Update baseline for the next retry pass (used by the
            // OLD path stable-clamp detection).
            self.previousRetryFrames = currentObservations

            guard !laggardMoves.isEmpty else {
                Log.cascade.info(
                    "All-apps \(label, privacy: .public): skipped — already converged (\(totalChecked, privacy: .public) windows checked)"
                )
                return
            }

            let count = WindowMutator.applyBatch(laggardMoves)
            Log.cascade.info(
                "All-apps \(label, privacy: .public): \(count, privacy: .public)/\(laggardMoves.count, privacy: .public) laggards nudged"
            )
            if count > 0 { self.onWindowsMoved?() }

            // Some apps (Chrome, Messages) auto-raise themselves when
            // their frame is set. The retry we just did may have shoved
            // one of them in front of a window that pass 1's z-order
            // enforcement had correctly placed ahead of it — producing
            // the "Finder behind Messages" reordering the user sees
            // between cascade runs. Re-enforce z-order now so the retry
            // doesn't break the stacking pass 1 established.
            if count > 0 {
                self.enforceCascadeZOrder(plans: plans)
            }
        }
    }

    /// Final diagnostic for the all-apps cascade. Re-checks every
    /// window against its expected target and logs success or failure.
    /// Purely informational — no rescue round.
    ///
    /// Excludes windows confirmed as stable-clamped from the failure
    /// count. Those windows never reached target size because their
    /// app enforces a fixed size (Get Info, About This Mac, etc.) —
    /// not a cascade failure, just an app-imposed constraint.
    private func verifyAllAppsCascade(plans: [AppCascadePlan]) {
        var stillFailing = 0
        var totalChecked = 0
        for plan in plans {
            let refreshed = AXWindowEnumerator.windows(of: plan.app)
            for (axElement, target) in plan.expectedFrames {
                totalChecked += 1
                guard let current = refreshed.first(where: { CFEqual($0.axElement, axElement) }) else {
                    continue
                }
                if self.useObservedCascadeResizeCapability {
                    // Capability-aware verify: fixed-size windows
                    // never count as size failures; constrained-
                    // resizable use ±10pt for size; position always
                    // uses the tight ±4pt.
                    //
                    // Also exclude windows the retry loop marked as
                    // stable-clamped — they never reached the
                    // capability-aware target either, but the app
                    // has settled and we chose to stop nudging.
                    // Counting them as "STILL not at target" would
                    // log a false failure.
                    if self.axElementIsInList(self.stableClampedWindows, axElement) {
                        continue
                    }
                    let cap = self.cascadeCapability(for: axElement)
                    let posOK = self.positionMatches(current.frame, target: target)
                    let sizeOK = self.sizeMatches(
                        current.frame.size,
                        target: target.size,
                        capability: cap
                    )
                    if !posOK || !sizeOK {
                        stillFailing += 1
                    }
                    continue
                }
                // OLD PATH: Stage 1 stable-clamp exclusion only.
                if self.axElementIsInList(self.stableClampedWindows, axElement) {
                    continue
                }
                if !self.frameMatches(current.frame, target: target) {
                    stillFailing += 1
                }
            }
        }
        if stillFailing > 0 {
            Log.cascade.error(
                "All-apps verify: \(stillFailing, privacy: .public)/\(totalChecked, privacy: .public) window(s) STILL not at target"
            )
        } else {
            Log.cascade.info(
                "All-apps verify: all \(totalChecked, privacy: .public) window(s) at target ✓"
            )
        }
    }

    /// Filters a list of enumerated windows down to just the ones whose
    /// midpoint is on the given display. The same rule used at cascade
    /// initiation in `performCascade` — applied here so retry passes
    /// and the verify/rescue cycle keep the cascade scoped to the
    /// chosen display for the full duration, not just on pass 1.
    private func windowsOnDisplay(
        _ windows: [EnumeratedWindow],
        display: NSScreen
    ) -> [EnumeratedWindow] {
        windows.filter { window in
            CoordinateSpace.screen(containing: window.frame)?.frame == display.frame
        }
    }

    /// Returns a frame for a cascaded window, clamping the origin so
    /// the window fits inside `bounds` (the padded cascade area)
    /// EVEN IF it ends up at its natural size instead of the size we
    /// requested.
    ///
    /// `frameSize` is what gets written to AX (target size for
    /// resizable windows, natural size for non-resizable).
    /// `naturalSize` is what the window is right now — used only for
    /// the clamp, since a resizable window might refuse our size write
    /// and stay at its natural size.
    ///
    /// The clamp size is `max(frameSize, naturalSize)`. For truly
    /// compliant windows where the cascade slot already fits, the
    /// clamp is a no-op. For windows that refuse to shrink (Photos,
    /// Zoom Workplace signed-in), the origin is shifted so the natural
    /// size fits inside the padded screen. If the natural size is
    /// larger than `bounds`, the origin pins to minX/minY — better to
    /// bleed off one edge than be entirely off-screen.
    private func fitFrame(
        plannedOrigin: CGPoint,
        frameSize: CGSize,
        naturalSize: CGSize,
        bounds: CGRect
    ) -> CGRect {
        let clampWidth = max(frameSize.width, naturalSize.width)
        let clampHeight = max(frameSize.height, naturalSize.height)
        var x = plannedOrigin.x
        var y = plannedOrigin.y
        if x + clampWidth > bounds.maxX {
            x = bounds.maxX - clampWidth
        }
        if x < bounds.minX {
            x = bounds.minX
        }
        if y + clampHeight > bounds.maxY {
            y = bounds.maxY - clampHeight
        }
        if y < bounds.minY {
            y = bounds.minY
        }
        return CGRect(x: x, y: y, width: frameSize.width, height: frameSize.height)
    }

    // MARK: - Intent-based anchor helpers (Stage 1)
    //
    // These helpers are cascade-local. They read a small set of AX
    // attributes ONLY for the windows of the frontmost app during
    // anchor picking. Other apps take zero additional AX calls.
    // No caching across cascades — every helper is called at most
    // once per window per cascade invocation.

    /// AX metadata subset needed to pick a sensible anchor. Reads
    /// four attributes on one window (subrole, main, focused, modal).
    /// Missing attributes default to a conservative "not a signal"
    /// value — a nil subrole is treated as standard (matches the
    /// existing AXWindowEnumerator convention), missing bools as
    /// false.
    private struct WindowMeta {
        let subrole: String?
        let isMain: Bool
        let isFocused: Bool
        let isModal: Bool
    }

    /// Fetches WindowMeta for a single window. Four AX reads per call.
    /// Called only during anchor picking for the frontmost app's
    /// windows — <10 windows in the typical case, so <40 AX reads
    /// total added to a cascade. Not called for other apps.
    private func fetchWindowMeta(for element: AXUIElement) -> WindowMeta {
        var subroleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        let subrole = subroleValue as? String

        func readBool(_ attr: String) -> Bool {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
            return (value as? Bool) ?? false
        }

        return WindowMeta(
            subrole: subrole,
            isMain: readBool(kAXMainAttribute as String),
            isFocused: readBool(kAXFocusedAttribute as String),
            isModal: readBool(kAXModalAttribute as String)
        )
    }

    /// True if this window should be considered an auxiliary for
    /// ANCHOR-SELECTION purposes only. Auxiliary windows are still
    /// cascade participants — they just don't get the anchor slot
    /// unless they're the only candidate.
    ///
    /// Modal → always auxiliary.
    /// Subrole:
    ///   nil                    → standard (some real main windows
    ///                            return nil; do not exclude).
    ///   AXStandardWindow       → standard.
    ///   AXDialog               → auxiliary (Get Info, Preferences,
    ///                            most alert-style panels).
    ///   AXFloatingWindow       → auxiliary (utility panels).
    ///   AXSystemDialog / other → auxiliary.
    private func isAuxiliaryForAnchoring(_ meta: WindowMeta) -> Bool {
        if meta.isModal { return true }
        guard let sub = meta.subrole else { return false }
        if sub == (kAXStandardWindowSubrole as String) { return false }
        return true
    }

    /// Picks the intended anchor window from an app's window list.
    ///
    /// Two-tier scan. The first tier requires the candidate to be
    /// resizable in addition to standard+non-auxiliary. This uses
    /// resizability as a TIEBREAKER only — not a global determinant.
    /// Rationale: Finder Get Info reports `AXStandardWindow` +
    /// `isMain=true` when it's the frontmost Finder window, so the
    /// subrole+main filter alone can't distinguish it from a folder
    /// browser. Preferring resizable main lets a real folder browser
    /// win the anchor when both are present. A fixed-size main window
    /// still anchors when it's the only standard candidate — the
    /// second tier catches Zoom pre-login and similar apps that
    /// legitimately have only a fixed-size window.
    ///
    /// Priority (first match wins):
    ///   Tier 1 — prefers resizable standard windows:
    ///     1a. Main + non-auxiliary + resizable
    ///     1b. Focused + non-auxiliary + resizable
    ///     1c. First non-auxiliary + resizable (AX z-order fallback)
    ///   Tier 2 — accept fixed-size standard when nothing else fits:
    ///     2a. Main + non-auxiliary
    ///     2b. Focused + non-auxiliary
    ///     2c. First non-auxiliary
    ///   Tier 3 — final fallback: largest window (only when every
    ///     candidate is an auxiliary).
    ///
    /// Reads AX metadata (4 attrs) + one `isSizeSettable` per window
    /// in the group. Kept local to the frontmost app's group; caller
    /// does not invoke this per-app.
    private func pickAnchorWindow(
        from windows: [EnumeratedWindow]
    ) -> (index: Int, reason: String) {
        let metas = windows.map { fetchWindowMeta(for: $0.axElement) }
        let resizable = windows.map { WindowMutator.isSizeSettable($0.axElement) }

        // Tier 1: prefer resizable candidates.
        for (i, m) in metas.enumerated()
            where m.isMain && !isAuxiliaryForAnchoring(m) && resizable[i] {
            return (i, "main frontmost")
        }
        for (i, m) in metas.enumerated()
            where m.isFocused && !isAuxiliaryForAnchoring(m) && resizable[i] {
            return (i, "focused frontmost")
        }
        for (i, m) in metas.enumerated()
            where !isAuxiliaryForAnchoring(m) && resizable[i] {
            return (i, "visual-order fallback")
        }

        // Tier 2: accept fixed-size main/standard windows (Zoom
        // pre-login, About This Mac, etc. — genuine fixed-size apps).
        for (i, m) in metas.enumerated()
            where m.isMain && !isAuxiliaryForAnchoring(m) {
            return (i, "main frontmost (fixed-size)")
        }
        for (i, m) in metas.enumerated()
            where m.isFocused && !isAuxiliaryForAnchoring(m) {
            return (i, "focused frontmost (fixed-size)")
        }
        for (i, m) in metas.enumerated()
            where !isAuxiliaryForAnchoring(m) {
            return (i, "visual-order fallback (fixed-size)")
        }

        // Tier 3: largest window (all candidates are auxiliaries).
        var largestIdx = 0
        var largestArea: CGFloat = -1
        for (i, w) in windows.enumerated() {
            let area = w.frame.width * w.frame.height
            if area > largestArea {
                largestArea = area
                largestIdx = i
            }
        }
        return (largestIdx, "largest window fallback")
    }

    /// Reads the AX title of a window. Used only for the debug
    /// anchor-selection log line. One AX read per call.
    private func axTitle(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    /// AXUIElement isn't Hashable, so cascade-local caches keyed by
    /// element use a linear-scan pair-list. Small n (<20 in typical
    /// cascades), so O(n) per lookup is fine.
    private func axElementIsInList(
        _ list: [(axElement: AXUIElement, frame: CGRect)],
        _ element: AXUIElement
    ) -> Bool {
        for entry in list where CFEqual(entry.axElement, element) { return true }
        return false
    }

    private func axElementFrame(
        in list: [(axElement: AXUIElement, frame: CGRect)],
        for element: AXUIElement
    ) -> CGRect? {
        for entry in list where CFEqual(entry.axElement, element) { return entry.frame }
        return nil
    }

    // MARK: - Stage 2 capability helpers

    /// Records the pre-cascade size of a window. Called during
    /// pendingGroups construction so retry passes have a baseline
    /// to compare returned sizes against.
    private func recordPreCascadeSize(_ size: CGSize, for element: AXUIElement) {
        for i in preCascadeSizeByElement.indices where CFEqual(preCascadeSizeByElement[i].axElement, element) {
            preCascadeSizeByElement[i].size = size
            return
        }
        preCascadeSizeByElement.append((element, size))
    }

    /// Looks up the pre-cascade size for a window. Returns nil for
    /// windows we've never seen (defensive — every cascade member
    /// should have been recorded in performCascadeAllApps).
    private func preCascadeSize(for element: AXUIElement) -> CGSize? {
        for entry in preCascadeSizeByElement where CFEqual(entry.axElement, element) {
            return entry.size
        }
        return nil
    }

    /// Stores a window's classified resize capability. Called once
    /// per window on the first retry pass that observes it.
    private func setCascadeCapability(
        _ capability: CascadeResizeCapability,
        for element: AXUIElement
    ) {
        for i in cascadeCapabilityByElement.indices where CFEqual(cascadeCapabilityByElement[i].axElement, element) {
            cascadeCapabilityByElement[i].capability = capability
            return
        }
        cascadeCapabilityByElement.append((element, capability))
    }

    /// Returns the classified capability for a window. `.unknown`
    /// if we haven't classified it yet (retry pass hasn't
    /// observed it) or the element isn't in the cache.
    private func cascadeCapability(for element: AXUIElement) -> CascadeResizeCapability {
        for entry in cascadeCapabilityByElement where CFEqual(entry.axElement, element) {
            return entry.capability
        }
        return .unknown
    }

    /// Classifies the observed resize outcome from three
    /// measurements: what the window was before, what we asked
    /// for, and what we got back. See CascadeResizeCapability
    /// docs for the case semantics.
    ///
    /// Tolerances:
    ///   - normal: ±4pt (sub-pixel AX readback noise)
    ///   - meaningful delta: ±2pt (below this we consider size
    ///     unchanged for the "moved from original" test)
    private func classifyResizeOutcome(
        originalSize: CGSize,
        requestedSize: CGSize,
        returnedSize: CGSize
    ) -> CascadeResizeCapability {
        let normalTolerance: CGFloat = 4
        let meaningfulDelta: CGFloat = 2

        // Reached target within tight tolerance → resizable.
        let matchesRequest =
            abs(returnedSize.width - requestedSize.width) <= normalTolerance &&
            abs(returnedSize.height - requestedSize.height) <= normalTolerance
        if matchesRequest { return .resizable }

        // Didn't reach target — did it move meaningfully from the
        // pre-cascade size? If yes, the app took the write and
        // clamped it (Terminal's grid snap, Xcode's minimum size).
        // If no, the app rejected the write entirely (Get Info).
        let movedFromOriginal =
            abs(returnedSize.width - originalSize.width) > meaningfulDelta ||
            abs(returnedSize.height - originalSize.height) > meaningfulDelta
        return movedFromOriginal ? .constrainedResizable : .fixedSize
    }

    /// Capability-aware size comparison. Fixed-size windows always
    /// "match" — their actual size IS their correct size. Constrained
    /// windows accept ±10pt (Terminal-class snap). Resizable and
    /// unknown windows require the tight ±4pt.
    private func sizeMatches(
        _ current: CGSize,
        target: CGSize,
        capability: CascadeResizeCapability
    ) -> Bool {
        switch capability {
        case .fixedSize:
            return true
        case .constrainedResizable:
            let tol: CGFloat = 10
            return abs(current.width - target.width) <= tol &&
                   abs(current.height - target.height) <= tol
        case .resizable, .unknown:
            let tol: CGFloat = 4
            return abs(current.width - target.width) <= tol &&
                   abs(current.height - target.height) <= tol
        }
    }

    /// Position comparison, capability-independent. Fixed-size
    /// windows still need to land at the correct origin — being
    /// non-resizable doesn't mean position doesn't matter.
    private func positionMatches(_ current: CGRect, target: CGRect) -> Bool {
        let tol: CGFloat = 4
        return abs(current.minX - target.minX) <= tol &&
               abs(current.minY - target.minY) <= tol
    }

    /// True if `actual` matches `target` within ±10pt on each of x, y,
    /// width, height. 10pt absorbs:
    ///   - sub-pixel readback rounding (~1-2pt)
    ///   - apps that snap to a character/row grid — Terminal has been
    ///     observed clamping a requested 1302×798 to 1301×791 (7pt
    ///     height offset = one row on its default font)
    ///   - Xcode, IDEs, and other apps with hard minimum sizes that
    ///     slightly exceed our requested size
    /// The purpose of verify is to catch windows that failed to move
    /// at all (dozens to hundreds of pixels off), not to detect
    /// sub-window pixel drift. A tighter tolerance triggered false
    /// "STILL not at target" errors + wasted rescue passes on every
    /// cascade that included Terminal.
    private func frameMatches(_ actual: CGRect, target: CGRect) -> Bool {
        let xOff = abs(actual.minX - target.minX)
        let yOff = abs(actual.minY - target.minY)
        let wOff = abs(actual.width  - target.width)
        let hOff = abs(actual.height - target.height)
        return xOff <= 10 && yOff <= 10 && wOff <= 10 && hOff <= 10
    }
}
