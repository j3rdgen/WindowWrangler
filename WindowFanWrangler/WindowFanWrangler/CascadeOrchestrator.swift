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

    /// True if `actual` matches `target` within ±4pt on each of x, y,
    /// width, height. 4pt absorbs the rounding and sub-pixel noise we
    /// see from AX readback.
    private func frameMatches(_ actual: CGRect, target: CGRect) -> Bool {
        let xOff = abs(actual.minX - target.minX)
        let yOff = abs(actual.minY - target.minY)
        let wOff = abs(actual.width  - target.width)
        let hOff = abs(actual.height - target.height)
        return xOff <= 4 && yOff <= 4 && wOff <= 4 && hOff <= 4
    }
}
