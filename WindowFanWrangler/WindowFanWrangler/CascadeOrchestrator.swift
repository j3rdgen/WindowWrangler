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

    /// Cascades the resolved target app's windows in the given direction.
    /// See file-level doc comment for the reliability stack.
    func performCascade(direction: CascadeDirection) {
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

        let windows = AXWindowEnumerator.windows(of: targetApp)

        guard !windows.isEmpty else {
            Log.cascade.notice("No-op: no windows found in '\(targetAppName, privacy: .public)'")
            return
        }
        guard windows.count > 1 else {
            Log.cascade.notice("No-op: only 1 window in '\(targetAppName, privacy: .public)'")
            return
        }

        // Bump the generation so any pending passes from a prior op
        // know to bail.
        cascadeGeneration &+= 1
        let myGen = cascadeGeneration

        // Snapshot current state BEFORE moving anything, so Restore works.
        lastSnapshot = LayoutSnapshot(from: windows)

        let screen = computeScreenFrame(anchoredOn: windows[0].frame)
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
                            screen: screen, targetSize: targetSize,
                            direction: direction)
        scheduleCascadePass(generation: myGen, after: 0.50, label: "pass 3",
                            app: targetApp, name: targetAppName,
                            screen: screen, targetSize: targetSize,
                            direction: direction)
        scheduleCascadePass(generation: myGen, after: 1.00, label: "pass 4",
                            app: targetApp, name: targetAppName,
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

    /// Computes the cascade's available frame on whichever display
    /// contains the anchor window's center, then applies the configured
    /// margins so the layout has breathing room from the edges.
    private func computeScreenFrame(anchoredOn anchorFrame: CGRect) -> CGRect {
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        let rawScreen = CoordinateSpace.visibleScreenFrame(containing: anchorCenter)
        return CGRect(
            x: rawScreen.minX + cascadeMarginLeft,
            y: rawScreen.minY + cascadeMarginBottom,
            width: rawScreen.width - cascadeMarginLeft - cascadeMarginRight,
            height: rawScreen.height - cascadeMarginTop - cascadeMarginBottom
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
    /// Early-exits if all windows are already at the target frame —
    /// most apps accept the cascade fully on pass 1, so re-poking them
    /// is wasteful and produces visible jitter.
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
            let refreshed = AXWindowEnumerator.windows(of: app)
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
    /// target size (a "laggard"), and re-applies the cascade only to
    /// those windows. Then schedules a post-rescue verification at
    /// +0.4s purely for diagnostic logging.
    ///
    /// Important: we re-pose only the laggards (not every window) so
    /// already-converged windows don't get a redundant size-position-
    /// size dance, which can produce a tiny but visible wiggle.
    private func verifyAndRescueIfNeeded(
        generation: UInt64,
        app: NSRunningApplication,
        name: String,
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection
    ) {
        let verification = AXWindowEnumerator.windows(of: app)
        // Compute the FULL expected target frame per window (position
        // + size), not just the size. Earlier convergence check only
        // compared sizes — a window that came out at the right size
        // but wrong position was being marked "stuck" and silently
        // excluded from the rescue. Real bug: lasso-tested cascade
        // would sometimes finish with windows scattered to the wrong
        // positions while reporting "✓ stuck" in the logs.
        let allFrames = verification.map(\.frame)
        let targetFrames = FanGeometry.computeCascade(
            windows: allFrames,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        let wantedW = Int(targetSize.width.rounded())
        let wantedH = Int(targetSize.height.rounded())
        Log.cascade.info("Verify: target size \(wantedW, privacy: .public)×\(wantedH, privacy: .public)")

        var laggardIndices: [Int] = []
        for (i, w) in verification.enumerated() {
            let target = targetFrames[i]
            let stuck = frameMatches(w.frame, target: target)
            let gotW = Int(w.frame.width.rounded())
            let gotH = Int(w.frame.height.rounded())
            let gotX = Int(w.frame.minX.rounded())
            let gotY = Int(w.frame.minY.rounded())
            let wantedX = Int(target.minX.rounded())
            let wantedY = Int(target.minY.rounded())
            Log.cascade.info(
                "Verify[\(i, privacy: .public)]: @(\(gotX, privacy: .public),\(gotY, privacy: .public)) \(gotW, privacy: .public)×\(gotH, privacy: .public) vs target @(\(wantedX, privacy: .public),\(wantedY, privacy: .public))  \(stuck ? "✓ stuck" : "✗ REVERTED", privacy: .public)"
            )
            if !stuck { laggardIndices.append(i) }
        }

        guard !laggardIndices.isEmpty else { return }

        Log.cascade.notice(
            "Rescue on '\(name, privacy: .public)': re-poking \(laggardIndices.count, privacy: .public) laggard window(s)"
        )

        let rescueMoves: [(axWindow: AXUIElement, target: CGRect)] = laggardIndices.map { i in
            (axWindow: verification[i].axElement, target: targetFrames[i])
        }
        let count = WindowMutator.applyBatch(rescueMoves)
        Log.cascade.info(
            "Rescue: \(count, privacy: .public)/\(rescueMoves.count, privacy: .public) laggards nudged"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == generation else { return }
            guard self.isTrusted() else { return }
            let post = AXWindowEnumerator.windows(of: app)
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
                    "Post-rescue: \(stillFailing, privacy: .public) window(s) STILL not at target on '\(name, privacy: .public)'"
                )
            } else {
                Log.cascade.info("Post-rescue: all windows at target ✓")
            }
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
