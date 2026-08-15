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
    private let useExplicitCascadeZOrder = true            // Stage 3 — deterministic reverse-walk raise pass on single-app + selection cascade paths (all-apps already had `enforceCascadeZOrder`, now with rich logging).

    /// Routes any Chromium-family cascade laggard through
    /// `BrowserScripting.setBrowserWindowBoundsNearFrame` instead of
    /// the standard AX write. Chromium browsers asynchronously revert
    /// AX size writes on their next runloop tick; native AppleScript
    /// bounds writes persist. Non-Chromium laggards remain on the
    /// existing AX path, and pass-1 is always AX-only regardless of
    /// this flag. Set to `false` to restore the previous behavior
    /// exactly — Chromium laggards go through AX like everything else.
    private let useBrowserNativeBoundsForCascadeLaggards = true

    /// Uses `CascadePlanning.resolveCascadePlanningSize` to decouple
    /// slot-geometry decisions from each window's mutable current
    /// size. When true, the all-apps DR/DL path plans narrow-window
    /// right-align and origin clamping with the standard cascade
    /// target size for size-settable windows (regardless of what
    /// unusual dimensions Plot, manual resize, or another tool left
    /// them at). Set to `false` to restore the exact prior current-
    /// frame-sensitive planning behavior — every planning input goes
    /// back to `window.frame.size`, and `willStayNarrow` / `fitFrame`
    /// clamp again read mutable dimensions. Not exposed to any other
    /// cascade mode (single-app, selection, restore).
    private let useDeterministicPlanningSizesForAllAppsCascade = true

    /// Enables bounded concurrent per-app AX enumeration for All-Apps
    /// Cascade. When on (default), the pre-pass-1 planning phase
    /// enumerates windows for all eligible apps in parallel with a
    /// bounded worker pool of `maxConcurrentAXEnumerations`, cutting
    /// wall-clock time from sum-of-per-app AX round-trips to bounded
    /// waves of the slowest apps. Preserves the exact eligible-app
    /// set, deterministic ordering, and every downstream filter.
    /// Set to `false` to restore the exact prior serial enumeration
    /// behavior — useful for A/B performance comparison or rollback.
    private let useConcurrentAllAppsEnumeration = true

    /// Bounded worker pool size for concurrent AX enumeration. Started
    /// at 6, raised to 10 after a 71-app cold-cascade profile showed
    /// enumeration wall-clock at ~1.5 s with 6 workers — the slowest
    /// per-app AX round-trip (sleepy-proxy retries, helper PIDs) still
    /// serialized the tail because we ran out of workers before running
    /// out of apps. Ten is the conservative production value chosen
    /// per the reaction-time optimization spec's default guidance;
    /// higher values (12, 16) risk exhausting WindowServer's parallel
    /// cross-process AX handling without proportionate gains. In DEBUG
    /// builds, the `WW_CASCADE_AX_MAX_CONCURRENCY` environment variable
    /// overrides this value at runtime — set it in Xcode's scheme →
    /// Run → Arguments → Environment Variables to A/B alternate values
    /// against a specific 60+-app workload. Kept as a named constant so
    /// the release build has one obvious knob to profile.
    private let maxConcurrentAXEnumerations = 10

    /// DEBUG-only override for `maxConcurrentAXEnumerations`, sourced
    /// from the `WW_CASCADE_AX_MAX_CONCURRENCY` environment variable.
    /// Returns the compile-time default when the env var is absent or
    /// unparseable. Values ≤ 0 clamp to 1 inside the bounded map, so
    /// no sanitization is needed here.
    ///
    /// In release builds this collapses to the constant — the debug
    /// override cannot ship accidentally.
    private var effectiveMaxAXEnumerationConcurrency: Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["WW_CASCADE_AX_MAX_CONCURRENCY"],
           let n = Int(raw), n > 0 {
            return n
        }
        #endif
        return maxConcurrentAXEnumerations
    }

    /// Enables the accessory-app CG-negative prefilter for All-Apps
    /// Cascade. When ON, one CG window snapshot is taken at the start
    /// of planning; any `.accessory`-policy app whose PID has zero
    /// entries in that snapshot is skipped from AX enumeration. Regular
    /// apps are ALWAYS AX-enumerated regardless of CG presence
    /// (preserves the Catalyst / Notes / Podcasts / Grammarly blind-spot
    /// protection — those apps are all `.regular`). CG snapshot failure
    /// fails open — every accessory is enumerated.
    ///
    /// Reduces AX enumeration count from ~70 to ~30-40 on a typical
    /// menu-bar-heavy workload by eliminating cross-process AX round-
    /// trips to helper apps that own zero user windows (BetterTouchTool,
    /// Rectangle, 1Password Helper, sync clients, hardware monitors,
    /// etc.).
    ///
    /// Set to `false` to restore the exact pre-fix behavior (every
    /// eligible regular AND accessory app AX-enumerated). If a
    /// legitimate accessory-app window is ever observed disappearing
    /// from cascade, the fastest path is to flip this flag off; the
    /// long-term fix is to add the offending bundle ID to
    /// `accessoryAppsAlwaysAXEnumerated`.
    ///
    /// DEFAULT OFF during reaction-time-regression diagnosis. The
    /// filter's implementation, tests, and DEBUG audit remain in the
    /// tree so it can be re-enabled once (a) measurement proves
    /// enumeration is the dominant remaining pre-write cost AND
    /// (b) the differential audit confirms zero accessory false
    /// negatives on the user's real workload. Enabling it before both
    /// gates would silently change Cascade membership for the wrong
    /// reason.
    private let useAccessoryCGNegativePrefilter = false

    /// Compatibility escape hatch for accessory apps that must ALWAYS
    /// receive AX enumeration regardless of CG snapshot presence.
    /// Starts empty because no known accessory app in the audit had a
    /// CG-invisible AX-visible cascade-eligible window. Add a bundle ID
    /// here iff we ever observe such an app in the wild (loud DEBUG
    /// audit log will name it).
    ///
    /// Do NOT populate speculatively — the whole point of the prefilter
    /// is skipping zero-window accessory helpers.
    private let accessoryAppsAlwaysAXEnumerated: Set<String> = []

    /// DEBUG-only differential audit for the accessory prefilter:
    /// shadow-enumerates every app the prefilter would skip and logs a
    /// loud warning if any returns a cascade-eligible AX window.
    /// Diagnostic-only — must NEVER run in the normal Cascade hot path
    /// because the shadow AX calls contend with the real cascade's
    /// AX writes on WindowServer.
    ///
    /// OFF by default even in DEBUG. Enable explicitly via
    /// `WW_CASCADE_ENABLE_PREFILTER_AUDIT=1` when validating whether
    /// Path A can be turned back on. Never enable it while measuring
    /// reaction time — the audit's parallel AX enumeration will
    /// materially skew shortcut→firstWrite numbers.
    ///
    /// Always false in Release — the audit code path is
    /// `#if DEBUG`-guarded at the call site.
    private var isPrefilterAuditEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["WW_CASCADE_ENABLE_PREFILTER_AUDIT"] == "1"
        #else
        return false
        #endif
    }

    /// Enables the two-phase z-order correction ownership model:
    /// pass 1 = provisional correction, intermediate stages (+120ms /
    /// +300ms / +500ms / +1000ms / post-write / native-repair) =
    /// observation-only, pass 4 = authoritative final settlement
    /// (deferred until native-repair drains).
    ///
    /// Under the pre-fix design, EVERY intermediate stage called
    /// `enforceCascadeZOrder`, which fires a fallback full walk when
    /// observation is incomplete. For a cold 5-Chromium cascade with
    /// a chronically-unobservable window (Grammarly / Notes), that
    /// produced 5-11 visible AXRaise bursts per cascade (one per
    /// intermediate site × N Chromium native-repair completions).
    /// This flag routes intermediate stages through
    /// `observeCascadeZOrder` + `recordZOrderCheckpoint` instead —
    /// zero raises, same drift-history evidence for the final
    /// settlement decision. Warm cascades (complete observation)
    /// keep exactly their pre-fix behavior: pass 1 fires the
    /// front-prefix corrector at most, intermediate stages observe
    /// zero-raises regardless. Set to `false` to restore the exact
    /// prior "every stage may correct" behavior.
    private let useSingleOwnerZOrderSettlement = true

    /// Enables observation-starvation escalation in the shared z-order
    /// settlement pipeline. When true, `runPassFourZOrderCheckpoint`
    /// evaluates `CascadeZOrderDrift.isObservationStarved(history)`
    /// after `isPersistentDrift` returns false — if repeated CGWindowList
    /// observations couldn't map every planned window across ≥2
    /// consecutive incomplete checkpoints, pass 4 escalates to the
    /// existing serialized reconstruction with trigger
    /// `observation-starvation` instead of silently exiting. Also
    /// enables post-walk-incomplete → late recommit routing and
    /// idempotent final-status emission for every terminal branch.
    /// Set to `false` to restore the exact pre-fix behavior —
    /// starvation goes undetected, pass 4 returns silently when
    /// persistent-drift is false, and post-walk incomplete
    /// reobservations do not schedule the late recommit. Applies to
    /// All-Apps and Selection cascades (they share the same final-
    /// checkpoint decision layer).
    private let useObservationStarvationEscalation = true

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

    /// Chromium laggards whose native-bounds repair is currently
    /// in flight. Prevents multiple retry passes (which fire at
    /// +0.12, +0.50, +1.00s) from stacking parallel or overlapping
    /// AppleScript writes against the same window. Entry is
    /// (axElement, generation) — same axElement across generations
    /// is a different repair. Cleared per entry when the async
    /// operation completes (on any outcome, including failure).
    /// Fully reset at the start of each all-apps cascade so a stale
    /// entry from a cancelled cascade cannot block a new one.
    private var nativeRepairInFlight: [(axElement: AXUIElement, generation: UInt64)] = []

    // MARK: - Z-order settlement state
    //
    // Per-generation state for the bounded z-order settlement pipeline
    // (see CascadeZOrderDrift.swift for the pure decision logic).
    //
    // The pipeline layers on top of the existing z-order enforcement
    // checkpoints (immediate post-pass-1, +300ms re-raise, pass 2/3/4
    // rechecks). At every checkpoint, `raiseWithObservation` records
    // the observed mismatch identities into `zOrderMismatchHistory`.
    // At pass 4 specifically, if the accumulated history matches the
    // "persistent drift" pattern (spec §"RECORD DRIFT HISTORY"), the
    // pipeline escalates to a serialized full reconstruction (async,
    // 16ms-spaced raises deepest→anchor) followed by settled
    // reobservation. If that first serialized walk fails to settle
    // by wall-clock ~+1600ms, one bounded late recommit fires. Hard
    // cap: 2 serialized walks per generation, then unresolved.
    //
    // All settlement state resets at each `performCascadeAllApps`
    // start, and any pending Task or asyncAfter block re-checks the
    // captured generation before acting. Restore Previous Layout and
    // a subsequent Cascade both bump `cascadeGeneration`, cancelling
    // in-flight settlement work implicitly.

    /// Ordered history of z-order observation checkpoints for the
    /// current cascade generation. Populated by every checkpoint
    /// that flows through `raiseWithObservation`. Reset at the start
    /// of each all-apps cascade.
    private var zOrderMismatchHistory: [ZOrderMismatchRecord] = []

    /// Number of serialized full-walk reconstructions run so far for
    /// the current cascade generation. Capped at
    /// `CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration`
    /// (2 — one persistent-drift reconstruction + one late recommit).
    private var zOrderSerializedWalkCount: Int = 0

    /// True while an async serialized reconstruction (raise sequence
    /// + settled reobservation) is running. Prevents overlapping
    /// reconstructions from a rapid pass-4 fire, Chromium repair
    /// completion, or explicit retry — spec §"NO OVERLAPPING
    /// CORRECTIONS".
    private var zOrderSerializedWalkInFlight: Bool = false

    /// True after the conditional late recommit has been scheduled
    /// or run for the current generation. Prevents multiple late
    /// recommits.
    private var zOrderLateRecommitScheduled: Bool = false

    /// Wall-clock instant the current cascade generation was
    /// initiated. Used to compute the earliest-allowed late recommit
    /// time (`+lateRecommitEarliestOffset`).
    private var zOrderGenerationStart: CFAbsoluteTime = 0

    /// Terminal status of the z-order settlement pipeline for the
    /// current cascade generation. Read by `verifyAllAppsCascade`
    /// so the final log line can report geometry AND z-order
    /// independently. Set to `.pending` at cascade start; transitions
    /// to a settled/unresolved state as the pipeline runs.
    private var zOrderFinalStatus: ZOrderFinalStatus = .settledNoCorrection

    /// True once `finalizeZOrderSettlement` has emitted the
    /// terminal `Stage 3 z-order settlement: FINAL` log line for the
    /// current generation. Idempotency guard so multiple asynchronous
    /// terminal branches (pass-4 immediate settle, walk-1 reobservation,
    /// walk-2 reobservation, budget-exhaustion path) cannot emit two
    /// competing final-status lines. Reset per cascade generation.
    private var zOrderFinalStatusEmitted: Bool = false

    /// Pending final z-order settlement request, captured when pass 4
    /// wants to escalate but geometry / native-repair work is still
    /// in flight. Non-nil means: "when the last tracked native repair
    /// for this generation drains, take a FRESH pure observation and
    /// resume the final settlement decision." Nil means no pending
    /// request. Reset per generation.
    ///
    /// This is the geometry-quiescence barrier. Under the pre-fix
    /// design, serialized reconstruction could begin while native-
    /// repair callbacks were still landing, causing walk raises to
    /// interleave with native-repair fallback walks (visible in
    /// generation 24 of the reported trace). The barrier ensures
    /// the authoritative correction observes only the settled
    /// post-repair state.
    private var pendingFinalSettlement: (plans: [AppCascadePlan], generation: UInt64, context: String)? = nil

    /// Best (highest) `matchedCount` seen across pre-walk observation
    /// checkpoints for the current cascade generation. Captured just
    /// before serialized reconstruction #1 fires, so post-walk
    /// reobservations can compare their coverage against the
    /// pre-walk best to decide whether the walk actually made
    /// observational progress. `nil` means no walk has run yet in
    /// this generation. Reset per cascade generation.
    private var zOrderPreWalkBestMatchedCount: Int? = nil

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
        // Stage 3: deterministic z-order. Raise back-to-front so the
        // anchor (windows[0]) ends up on top instead of leaving stack
        // order to whatever ambient behavior the setFrame writes
        // triggered. Fires once, only if pass 1 actually moved
        // something — retry passes don't re-raise, matching the flicker
        // mitigations documented in `stableClampedWindows`.
        if useExplicitCascadeZOrder && count1 > 0 {
            raiseCascadedWindows(
                orderedFrontFirst: windows,
                context: "\(targetAppName) pass 1"
            )
        }

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

        // Selection Cascade bumps the shared `cascadeGeneration` and
        // resets the z-order settlement state — full parity with
        // `performCascadeAllApps`. Two effects:
        //   1. Any pending settlement Task from a prior All-Apps or
        //      Selection cascade sees `cascadeGeneration != generation`
        //      on its next checkpoint and bails cleanly without
        //      raising a window or clearing newer state.
        //   2. The new Selection operation starts with an empty drift
        //      history, zero walks used, and a fresh start-time
        //      timestamp so the conditional late recommit lands at
        //      approximately +1600ms from THIS Selection's start
        //      (not from some earlier operation's start).
        //
        // Also matches the invalidation pattern that Restore Previous
        // Layout uses (see `restoreLayout`): whichever cascade or
        // restore is newest owns z-order settlement.
        cascadeGeneration &+= 1
        let myGen = cascadeGeneration
        zOrderMismatchHistory.removeAll()
        zOrderSerializedWalkCount = 0
        zOrderSerializedWalkInFlight = false
        zOrderLateRecommitScheduled = false
        zOrderGenerationStart = CFAbsoluteTimeGetCurrent()
        zOrderFinalStatus = .settledNoCorrection
        zOrderFinalStatusEmitted = false
        zOrderPreWalkBestMatchedCount = nil
        pendingFinalSettlement = nil

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
        // Stage 3: deterministic z-order. Raise back-to-front so the
        // anchor (windows[0], which the caller — LassoCoordinator's
        // resize-completion — puts at index 0) ends up on top. Fires
        // once, only if writes actually happened.
        if useExplicitCascadeZOrder && moved > 0 {
            raiseCascadedWindows(
                orderedFrontFirst: windows,
                context: "selection pass 1"
            )
        }

        // Selection z-order settlement pipeline — full parity with the
        // All-Apps checkpoints. Delayed z-order-only observations at
        // approximately +120/+300/+500/+1000ms, each recording the
        // observed mismatch identities into the shared
        // `zOrderMismatchHistory`. The +1000ms final checkpoint
        // routes through the shared `runPassFourZOrderCheckpoint`,
        // which — on detected persistent drift — invokes the shared
        // serialized reconstruction, settled reobservation, and
        // conditional late recommit. No frame writes at any
        // checkpoint (the checkpoints are z-order only). No copy of
        // the settlement algorithms — everything reuses the same
        // primitives that already work for All-Apps.
        //
        // Skipped when no frames were moved (nothing to settle) and
        // when the explicit z-order flag is off (rollback safety).
        if useExplicitCascadeZOrder && moved > 0 {
            let selectionPlan = synthesizeSelectionPlanForZOrder(
                windows: windows,
                screen: screen,
                targetSize: targetSize,
                direction: direction,
                preserveWindowSizes: preserveWindowSizes
            )
            scheduleSelectionZOrderCheckpoint(
                generation: myGen, after: 0.12,
                label: "selection pass 2 (converged z-recheck)",
                plans: selectionPlan, isFinalPass: false
            )
            scheduleSelectionZOrderCheckpoint(
                generation: myGen, after: 0.30,
                label: "selection +300ms re-raise",
                plans: selectionPlan, isFinalPass: false
            )
            scheduleSelectionZOrderCheckpoint(
                generation: myGen, after: 0.50,
                label: "selection pass 3 (converged z-recheck)",
                plans: selectionPlan, isFinalPass: false
            )
            scheduleSelectionZOrderCheckpoint(
                generation: myGen, after: 1.00,
                label: "selection pass 4 (converged z-recheck)",
                plans: selectionPlan, isFinalPass: true
            )
        }
    }

    /// Builds an immutable, fan-ordered `[AppCascadePlan]` snapshot
    /// from the Selection Cascade's window list. Used by the delayed
    /// Selection z-order checkpoints so their observations use the
    /// exact plan captured at cascade start — not whatever the lasso
    /// selection may look like when the checkpoint fires.
    ///
    /// Emits ONE plan per window (rather than grouping by app) so
    /// that `plans.flatMap { ... }` in `enforceCascadeZOrder` yields
    /// the selection's exact fan order (anchor first, deepest last).
    /// Grouping by pid would reorder the slots — incorrect for a
    /// selection where two Chrome windows may sandwich a Terminal.
    ///
    /// Duplicates the target-frame computation from `applyCascadePass`
    /// (including the preserve-window-sizes edge alignment) to
    /// produce the same target frames the mutator wrote. Cost is a
    /// second FanGeometry call — pure and cheap.
    private func synthesizeSelectionPlanForZOrder(
        windows: [EnumeratedWindow],
        screen: CGRect,
        targetSize: CGSize,
        direction: CascadeDirection,
        preserveWindowSizes: Bool
    ) -> [AppCascadePlan] {
        let currentFrames = windows.map(\.frame)
        var targetFrames = FanGeometry.computeCascade(
            windows: currentFrames,
            screen: screen,
            targetSize: targetSize,
            direction: direction
        )
        if preserveWindowSizes {
            // Mirror the alignment logic in `applyCascadePass` — for
            // the post-resize auto-cascade, each window's ACTUAL size
            // is preserved and edge-aligned to its slot per direction.
            for i in 0..<targetFrames.count {
                let slot = targetFrames[i]
                let actualSize = windows[i].frame.size
                let originX: CGFloat
                switch direction {
                case .downRight: originX = slot.maxX - actualSize.width
                case .downLeft:  originX = slot.origin.x
                }
                targetFrames[i] = CGRect(
                    x: originX,
                    y: slot.origin.y,
                    width: actualSize.width,
                    height: actualSize.height
                )
            }
        }
        var plans: [AppCascadePlan] = []
        plans.reserveCapacity(windows.count)
        for (i, window) in windows.enumerated() {
            var pid: pid_t = 0
            AXUIElementGetPid(window.axElement, &pid)
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            plans.append(AppCascadePlan(
                app: app,
                expectedFrames: [(axElement: window.axElement, target: targetFrames[i])]
            ))
        }
        return plans
    }

    /// Schedules one Selection z-order-only settlement checkpoint at
    /// the given delay. Generation-guarded like every settlement
    /// step — a subsequent Selection Cascade, All-Apps Cascade, or
    /// Restore Previous Layout bumps `cascadeGeneration` and causes
    /// this checkpoint to bail without touching any window.
    ///
    /// - `isFinalPass: true` routes through the shared
    ///   `runPassFourZOrderCheckpoint`, which observes, records to
    ///   drift history, and (on persistent drift) escalates to the
    ///   shared serialized reconstruction pipeline.
    /// - `isFinalPass: false` runs an ordinary observation-based
    ///   correction via `enforceCascadeZOrder` — records a checkpoint
    ///   and applies a partial or full raise walk when order is
    ///   wrong; zero raises when correct.
    ///
    /// This scheduler performs NO frame writes — no target-size
    /// recomputation, no Chromium bounds writes, no geometry retry.
    /// Selection geometry is committed by pass 1 (`applyCascadePass`
    /// above); everything scheduled here only stabilizes stacking
    /// depth against delayed cross-app auto-raises.
    private func scheduleSelectionZOrderCheckpoint(
        generation: UInt64,
        after delay: TimeInterval,
        label: String,
        plans: [AppCascadePlan],
        isFinalPass: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == generation else {
                Log.cascade.info(
                    "Stage 3 z-order (\(label, privacy: .public)): skipped — cancelled by newer operation"
                )
                return
            }
            guard self.isTrusted() else {
                Log.cascade.error(
                    "Stage 3 z-order (\(label, privacy: .public)): skipped — AX trust lost"
                )
                return
            }
            guard self.useExplicitCascadeZOrder else { return }

            if isFinalPass {
                self.runPassFourZOrderCheckpoint(
                    plans: plans,
                    generation: generation,
                    context: label
                )
            } else {
                // Two-phase correction-owner model: Selection intermediate
                // checkpoints observe-only, matching the All-Apps shared
                // policy. Selection's "pass 1" provisional correction
                // already happened in `performCascadeOnSelection` via
                // `raiseCascadedWindows` before these delayed checkpoints
                // were scheduled.
                self.intermediateZOrderCheckpoint(
                    plans: plans,
                    context: label
                )
            }
        }
    }

    func performCascadeAllApps(
        direction: CascadeDirection,
        targetScreen: NSScreen? = nil,
        shortcutReceivedAt: CFAbsoluteTime? = nil,
        onFirstWriteWillDispatch: (@MainActor () -> Void)? = nil
    ) async {
        // Origin timestamp for the per-generation latency trace. When
        // called from a keyboard shortcut, the shortcut handler stamps
        // this at the moment it recognized the action (captures menu-
        // dismiss dispatch + Task hop as part of shortcut→entry). When
        // called from a menu, we stamp entry — the menu-dismiss delay
        // is user-perceived pre-menu and not our latency to fix.
        let trace = CascadeLatencyTrace(
            generation: cascadeGeneration &+ 1,  // matches the &+= below
            direction: String(describing: direction),
            shortcutReceived: shortcutReceivedAt ?? CascadeLatencyTrace.now()
        )
        trace.cascadeEntered = CascadeLatencyTrace.now()

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
        trace.appSnapshotStart = CascadeLatencyTrace.now()

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
        trace.appSnapshotEnd = CascadeLatencyTrace.now()
        trace.eligibleAppsCount = runningApps.count

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

        // Reset native-repair in-flight tracking. An entry from a
        // previously-cancelled cascade cannot leak into this one and
        // block a legitimate new repair on the same window.
        nativeRepairInFlight.removeAll()

        // Reset z-order settlement pipeline state (see the block-
        // comment above the field declarations). Stale mismatch
        // history from a cancelled cascade must not influence the
        // persistent-drift decision for this generation.
        zOrderMismatchHistory.removeAll()
        zOrderSerializedWalkCount = 0
        zOrderSerializedWalkInFlight = false
        zOrderLateRecommitScheduled = false
        zOrderGenerationStart = CFAbsoluteTimeGetCurrent()
        // Optimistic default — flips to a corrected state as soon as
        // any checkpoint records a non-empty mismatch, and finalizes
        // at verify time based on the accumulated history.
        zOrderFinalStatus = .settledNoCorrection
        zOrderFinalStatusEmitted = false
        zOrderPreWalkBestMatchedCount = nil
        pendingFinalSettlement = nil

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

        // Accessory-app CG-negative prefilter (see the flag block-comment
        // above `useAccessoryCGNegativePrefilter`). One CG snapshot,
        // classify by activation policy, skip accessory apps whose PID
        // is absent from the successful snapshot. Regular apps are
        // ALWAYS AX-enumerated regardless of CG (preserves Notes /
        // Podcasts / Grammarly protection — those apps are `.regular`).
        // Fails open: CG snapshot failure ⇒ every accessory enumerates
        // via AX exactly as before.
        //
        // Snapshot is bound to this cascade generation — result is
        // discarded via the stale-generation guard below if a newer
        // operation supersedes this one during enumeration.
        trace.cgSnapshotStart = CascadeLatencyTrace.now()
        let cgSnapStart = CFAbsoluteTimeGetCurrent()
        let cgSnapshot: CGWindowSnapshot = useAccessoryCGNegativePrefilter
            ? CGWindowSnapshotter.snapshot()
            : .failure   // flag off ⇒ act as if snapshot failed ⇒ enumerate everything
        let cgSnapshotMillis = Int((CFAbsoluteTimeGetCurrent() - cgSnapStart) * 1000)
        trace.cgSnapshotEnd = CascadeLatencyTrace.now()

        // Classify every eligible app into "AX-enumerate" vs "skip"
        // based on policy + CG presence + bypass set. `nil` in
        // `pidsForAXCall` at index i means "insert [] at position i in
        // the final per-app-windows array, no AX call made". The
        // parallel `pidsForAXCall` array is what the bounded concurrent
        // primitive is fed, tagged with `.some(pid)` for real work and
        // `.none` for skipped positions.
        //
        // Downstream planner behavior is unchanged: skipped apps
        // materialize as zero-window contributors and get filtered out
        // by the existing `guard !displayWindows.isEmpty else continue`.
        let appFacts: [PrefilterAppFacts] = runningApps.map { app in
            PrefilterAppFacts(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier ?? "",
                policy: app.activationPolicy
            )
        }
        let classification = Self.classifyEligibleApps(
            apps: appFacts,
            cgSnapshot: cgSnapshot,
            bypassSet: accessoryAppsAlwaysAXEnumerated
        )
        let regularCount = classification.regularCount
        let accessoryCount = classification.accessoryCount
        let accessoryCGPositiveCount = classification.accessoryCGPositiveCount
        let accessorySkippedCGNegativeCount = classification.accessorySkippedCGNegativeCount
        let accessoryBypassedCount = classification.accessoryBypassedCount
        let pidsForAXCall = classification.pidsForAXCall
        let axEnumeratedCount = classification.axEnumeratedCount

        // Bounded concurrent AX enumeration for every eligible app.
        // Skipped positions bypass the AX call entirely and return
        // `[]` — preserves array indexing so the downstream loop over
        // `runningApps.enumerated()` still reads `perAppWindows[index]`
        // correctly. Only the scheduling changes: up to
        // `maxConcurrentAXEnumerations` per-app enumerations run in
        // parallel on the cooperative concurrent executor, and results
        // are returned in the original index order so downstream
        // planning (anchor rules, alphabetical ordering, target-display
        // filtering) sees identical input to the serial path.
        //
        // Under `useConcurrentAllAppsEnumeration` off, uses the same
        // helper with concurrency=1 so we always take the concurrent
        // code path in one place.
        trace.axEnumStart = CascadeLatencyTrace.now()
        let enumStart = CFAbsoluteTimeGetCurrent()
        let effectiveConcurrency = useConcurrentAllAppsEnumeration
            ? effectiveMaxAXEnumerationConcurrency
            : 1
        let (perAppWindows, enumMetrics) = await Self.enumerateAppsBoundedConcurrentWithMetrics(
            pidsOrSkip: pidsForAXCall,
            maxConcurrency: effectiveConcurrency
        )
        let enumMillis = Int((CFAbsoluteTimeGetCurrent() - enumStart) * 1000)
        trace.axEnumEnd = CascadeLatencyTrace.now()
        trace.axEnumeratedCount = axEnumeratedCount
        trace.postEnumStart = CascadeLatencyTrace.now()

        // Stale-generation guard: while we were awaiting the async
        // enumeration, the user may have fired another cascade or a
        // Restore. If so, that newer operation has bumped
        // `cascadeGeneration`, and this operation must NOT proceed to
        // planning / frame mutation — the newer op owns the windows now.
        guard cascadeGeneration == myGen else {
            Log.cascade.info(
                "All-apps cascade: superseded during enumeration (myGen=\(myGen, privacy: .public), current=\(self.cascadeGeneration, privacy: .public)) — discarding \(runningApps.count, privacy: .public)-app enumeration result (\(enumMillis, privacy: .public)ms wasted); zero mutations performed"
            )
            trace.emit(superseded: true, supersededStage: "post-AX-enumeration")
            return
        }
        guard isTrusted() else {
            Log.cascade.error("All-apps cascade aborted after enumeration: AX permission lost")
            trace.emit(superseded: true, supersededStage: "AX-permission-lost")
            return
        }

        // Concurrency-audit line — emitted alongside the summary so a
        // single-log-grep can answer "was concurrency the bottleneck?".
        // A `peakInFlight` well below `maxConcurrency` on a workload
        // large enough to saturate it is evidence of hidden
        // serialization (an actor hop, a serial DispatchQueue, an
        // AX-per-process lock) — the primitive's own tests prove the
        // scheduler is not the source, so an anomaly here would point
        // at the transform / the AX layer.
        let peakInFlight = enumMetrics.maxObservedInFlight
        // Top-3 slowest apps by AX round-trip duration, for outlier
        // triage. Names privacy-public because they're already emitted
        // by the per-app enumeration log line and are needed to make
        // this diagnostic actionable.
        let slowest = enumMetrics.perItemDurationSeconds
            .enumerated()
            .sorted { $0.element > $1.element }
            .prefix(3)
            .map { (index, seconds) -> String in
                let name = runningApps[index].localizedName ?? "?"
                let ms = Int(seconds * 1000)
                return "\(name)=\(ms)ms"
            }
            .joined(separator: ", ")
        let cgSnapshotStatus: String = {
            switch cgSnapshot {
            case .success(let p): return "ok(\(p.count) pids)"
            case .failure: return useAccessoryCGNegativePrefilter ? "failed" : "disabled"
            }
        }()
        Log.cascade.info(
            "All-apps cascade enumeration: \(runningApps.count, privacy: .public) eligible app(s) [regular=\(regularCount, privacy: .public), accessory=\(accessoryCount, privacy: .public) (cgPos=\(accessoryCGPositiveCount, privacy: .public), cgNegSkipped=\(accessorySkippedCGNegativeCount, privacy: .public), bypassed=\(accessoryBypassedCount, privacy: .public))], axEnumerated=\(axEnumeratedCount, privacy: .public), mode=\(effectiveConcurrency > 1 ? "concurrent" : "serial", privacy: .public), maxConcurrency=\(effectiveConcurrency, privacy: .public), peakInFlight=\(peakInFlight, privacy: .public), cgSnapshot=\(cgSnapshotMillis, privacy: .public)ms(\(cgSnapshotStatus, privacy: .public)), axEnum=\(enumMillis, privacy: .public)ms, slowest=[\(slowest, privacy: .public)]"
        )

        // DEBUG differential audit: for every accessory app the
        // prefilter skipped, shadow-enumerate via AX and log a loud
        // warning if that app would have contributed a cascade-eligible
        // window. Never blocks the cascade — runs as a fire-and-forget
        // Task on the cooperative executor after the main cascade
        // proceeds. Zero effect on release builds.
        //
        // If this ever logs a violation, it means Path A's assumption
        // ("accessory + CG-negative ⇒ zero cascade windows") failed for
        // a real app on this machine — add the offending bundle ID to
        // `accessoryAppsAlwaysAXEnumerated` (or flip
        // `useAccessoryCGNegativePrefilter` off) to restore full coverage.
        #if DEBUG
        if isPrefilterAuditEnabled && accessorySkippedCGNegativeCount > 0 {
            let skippedApps: [NSRunningApplication] = zip(runningApps, pidsForAXCall)
                .filter { $0.1 == nil }
                .map { $0.0 }
            let auditPIDs = skippedApps.map { $0.processIdentifier }
            Task.detached { [weak self] in
                let (perApp, _) = await Self.enumerateAppsBoundedConcurrentWithMetrics(
                    pidsOrSkip: auditPIDs.map { .some($0) },
                    maxConcurrency: 4  // gentler than production — audit is background
                )
                await MainActor.run {
                    guard let self else { return }
                    for (i, windows) in perApp.enumerated() {
                        if !windows.isEmpty {
                            let name = skippedApps[i].localizedName ?? "?"
                            let bundle = skippedApps[i].bundleIdentifier ?? "?"
                            Log.cascade.error(
                                "ACCESSORY PREFILTER FALSE NEGATIVE: bundle=\(bundle, privacy: .public) name=\(name, privacy: .public) pid=\(auditPIDs[i], privacy: .public) returned \(windows.count, privacy: .public) AX window(s) despite CG-negative — add bundle to accessoryAppsAlwaysAXEnumerated or flip useAccessoryCGNegativePrefilter off"
                            )
                            _ = self  // silence unused-capture warning; the error above is the side effect
                        }
                    }
                }
            }
        }
        #endif

        for (index, app) in runningApps.enumerated() {
            let allWindowsForApp = perAppWindows[index]
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
        trace.totalPlannedWindows = totalWindows
        trace.planningStart = CascadeLatencyTrace.now()

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
        trace.preWriteSetupStart = CascadeLatencyTrace.now()

        var plans: [AppCascadePlan] = []
        var snapshotEntries: [LayoutSnapshot.Entry] = []
        var allMoves: [(axWindow: AXUIElement, target: CGRect)] = []
        var idx = 0
        for group in pendingGroups {
            var appPlanFrames: [(axElement: AXUIElement, target: CGRect)] = []
            for window in group.windows {
                let plannedTarget = shiftedTargets[idx]
                let isSettable = WindowMutator.isSizeSettable(window.axElement)
                let actualCurrentSize = window.frame.size
                let isAnchor = (idx == 0)

                // Planning size — decoupled from actual current size for
                // deterministic slot geometry. See `CascadePlanning` for
                // the invariant: normally resizable windows plan at
                // `targetSize`, position-only windows plan at their
                // current natural size. Prior to this decoupling, the
                // narrow-window right-align check and `fitFrame` origin
                // clamp both read `window.frame.size`, so any window
                // left at an unusual size by Plot / manual resize /
                // another tool would produce a different plan than the
                // same window at its post-cascade size — driving the
                // multi-invocation convergence the user reported.
                //
                // Flag-gated: setting `useDeterministicPlanningSizesForAllAppsCascade`
                // to false restores prior behavior exactly (planning
                // uses `actualCurrentSize`).
                let planningSize: CGSize = useDeterministicPlanningSizesForAllAppsCascade
                    ? CascadePlanning.resolveCascadePlanningSize(
                        currentFrame: window.frame,
                        standardTargetSize: targetSize,
                        isSizeSettable: isSettable
                    )
                    : actualCurrentSize

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
                //   - Settable but `planningSize.width < 70% of target`:
                //     strong signal it's a fixed-size dialog that
                //     reports settable=true but clamps at write time.
                //     With deterministic planning ON, this predicate is
                //     effectively `false` for size-settable windows —
                //     planningSize equals target size, and 1168 < 0.7*1168
                //     is false. The narrow branch fires only for genuine
                //     non-settable windows (Zoom pre-login etc.). A
                //     window that misreports settable=true but actually
                //     clamps (Get Info, About This Mac) will no longer
                //     receive automatic right-alignment via this Stage
                //     2.5 path; the trade-off is deterministic
                //     cascade planning, which was the higher-value
                //     invariant per the M-series planning-size spec.
                //
                // downLeft cascades don't need this — the LEFT edge of
                // every window aligns with the slot origin, which is
                // already the correct reveal direction.
                let anchorStaysNarrow = isAnchor
                    && (!isSettable || planningSize.width < plannedTarget.size.width * 0.7)
                    && planningSize.width < plannedTarget.size.width
                let nonAnchorStaysNarrow = useFixedSizeSlotAdjustment
                    && !isAnchor
                    && planningSize.width < plannedTarget.size.width
                    && (!isSettable || planningSize.width < plannedTarget.size.width * 0.7)
                let willStayNarrow = anchorStaysNarrow || nonAnchorStaysNarrow

                let target: CGRect
                if willStayNarrow && direction == .downRight {
                    // Right-align by shifting the origin so the
                    // window's right edge lands at the slot's right
                    // edge. Uses `planningSize` — for a genuine
                    // non-settable narrow window this is its natural
                    // size (correct right-align by narrow-natural
                    // width). For a size-settable window the branch
                    // no longer fires (see gate above), so this path
                    // is effectively non-settable-only when
                    // deterministic planning is on.
                    let shiftedOrigin = CGPoint(
                        x: plannedTarget.origin.x
                            + plannedTarget.size.width
                            - planningSize.width,
                        y: plannedTarget.origin.y
                    )
                    target = fitFrame(
                        plannedOrigin: shiftedOrigin,
                        frameSize: planningSize,
                        naturalSize: planningSize,
                        bounds: screen
                    )
                } else {
                    // Standard slot placement. `frameSize` is what the
                    // mutator will attempt to write (target size for
                    // settable, current natural for non-settable);
                    // `naturalSize` feeds the fitFrame clamp — pass
                    // `planningSize` so the clamp is deterministic
                    // (target size for settable → no oversize clamp,
                    // current for non-settable → preserves existing
                    // behavior for position-only apps).
                    let frameSize = isSettable ? plannedTarget.size : planningSize
                    target = fitFrame(
                        plannedOrigin: plannedTarget.origin,
                        frameSize: frameSize,
                        naturalSize: planningSize,
                        bounds: screen
                    )
                }
                allMoves.append((window.axElement, target))
                appPlanFrames.append((window.axElement, target))
                // Snapshot uses the ACTUAL current frame (window.frame),
                // not planning size — Restore Previous Layout must
                // return the window to its pre-cascade state, not to
                // the deterministic planning size.
                snapshotEntries.append(
                    LayoutSnapshot.Entry(axElement: window.axElement, frame: window.frame)
                )
                #if DEBUG
                Log.cascade.debug(
                    "Plan[\(idx, privacy: .public)] app=\(group.app.localizedName ?? "?", privacy: .public) settable=\(isSettable ? "yes" : "no", privacy: .public) current=\(Int(actualCurrentSize.width), privacy: .public)×\(Int(actualCurrentSize.height), privacy: .public) planning=\(Int(planningSize.width), privacy: .public)×\(Int(planningSize.height), privacy: .public) target=(\(Int(target.minX), privacy: .public),\(Int(target.minY), privacy: .public)) \(Int(target.width), privacy: .public)×\(Int(target.height), privacy: .public)"
                )
                #endif
                idx += 1
            }
            plans.append(AppCascadePlan(app: group.app, expectedFrames: appPlanFrames))
        }

        Log.cascade.info(
            "All-apps cascade target display: '\(screenLabel, privacy: .public)' — \(plans.count, privacy: .public) app group(s), \(totalWindows, privacy: .public) total windows, deterministicPlanning=\(self.useDeterministicPlanningSizesForAllAppsCascade ? "true" : "false", privacy: .public)"
        )

        guard totalWindows >= 2 else {
            Log.cascade.notice(
                "All-apps cascade no-op: \(totalWindows, privacy: .public) cascadable window(s) on '\(screenLabel, privacy: .public)' (need \u{2265}2 total)"
            )
            trace.emit(superseded: true, supersededStage: "no-op-<2-windows")
            return
        }

        // Snapshot for restore. Restore puts ALL the moved windows back,
        // across every app.
        lastSnapshot = LayoutSnapshot(entries: snapshotEntries)

        // Pass 1 — this is the FIRST external window mutation. Uses the
        // instrumented batch variant so per-window durations flow into
        // the latency trace. `firstWriteDispatch` and `initialBatchStart`
        // coincide today (applyBatch is sequential and starts writing
        // immediately). Distinct fields let a future per-PID mutation
        // scheduler decouple them without renaming existing consumers.
        let axWindowToApp: [AXUIElement: NSRunningApplication] = {
            var map: [AXUIElement: NSRunningApplication] = [:]
            for group in pendingGroups {
                for w in group.windows { map[w.axElement] = group.app }
            }
            return map
        }()

        trace.firstWriteDispatch = CascadeLatencyTrace.now()
        trace.initialBatchStart = trace.firstWriteDispatch

        // Cascade acknowledgement-pulse dismiss hook. Fired here — the
        // exact instant Cascade commits to visible external motion —
        // so the cosmetic pulse tears down instantly instead of
        // overlapping with real window movement. Not awaited: the
        // callback is a synchronous setter that flips overlay state
        // and cancels the pending phase timers. Zero latency added to
        // the write path.
        onFirstWriteWillDispatch?()

        let (count1, timings) = WindowMutator.applyBatchInstrumented(allMoves)
        trace.initialBatchComplete = CascadeLatencyTrace.now()
        trace.firstWriteReturned = trace.initialBatchComplete

        // Per-PID aggregation for the trace's `slowestPIDGroup` /
        // `pids` fields. Grouping by NSRunningApplication.pid because
        // that's what a per-PID mutation scheduler would key on.
        //
        // Slowest single write is straightforward. Slowest PID group is
        // the app with the largest SUMMED setFrame time — a proxy for
        // "if we ran each PID's writes in parallel, this app would be
        // the critical-path chain".
        var perPIDTotalMs: [pid_t: (name: String, ms: Double, count: Int)] = [:]
        var slowestSingle: (name: String, ms: Int)? = nil
        for (move, timing) in zip(allMoves, timings) {
            let ms = timing.durationSeconds * 1000
            let app = axWindowToApp[move.axWindow]
            let name = app?.localizedName ?? "?"
            if slowestSingle == nil || Int(ms) > slowestSingle!.ms {
                slowestSingle = (name, Int(ms))
            }
            if let pid = app?.processIdentifier {
                var entry = perPIDTotalMs[pid] ?? (name, 0, 0)
                entry.ms += ms
                entry.count += 1
                perPIDTotalMs[pid] = entry
            }
        }
        trace.initialWindowCount = allMoves.count
        trace.initialPIDCount = perPIDTotalMs.count
        if let s = slowestSingle {
            trace.slowestInitialWrite = (appName: s.name, ms: s.ms)
        }
        if let heaviest = perPIDTotalMs.values.max(by: { $0.ms < $1.ms }) {
            trace.slowestInitialPIDGroup = (
                appName: heaviest.name,
                ms: Int(heaviest.ms),
                windowCount: heaviest.count
            )
        }

        // Surface the AX enumeration diagnostics into the same trace
        // line so a single grep answers both "is enumeration or write
        // the bottleneck" and "which apps are the slowest sources".
        trace.axPeakInFlight = peakInFlight
        trace.axConfiguredConcurrency = effectiveConcurrency
        trace.axSlowestApps = slowest

        trace.emit()
        Log.cascade.info(
            "All-apps \(String(describing: direction), privacy: .public) pass 1: \(count1, privacy: .public)/\(allMoves.count, privacy: .public) windows moved"
        )
        if count1 > 0 { onWindowsMoved?() }

        // Enforce z-order so the visual stacking matches the cascade's
        // intent: the anchor (first window in cascade order, the most
        // recently used app's window) is FRONT-most, and successive
        // windows are layered BEHIND it.
        enforceCascadeZOrder(plans: plans, context: "all-apps pass 1")

        // STAGE 3: single delayed re-raise to defeat asynchronous
        // auto-raise from apps like Chrome and Messages, which raise
        // themselves in response to their frame set — well after our
        // synchronous pass 1 raise completes. 300ms is comfortably past
        // the auto-raise storm on typical hardware but early enough
        // that the temporary wrong z-order is barely perceptible.
        // One extra fire (2 total per cascade) means Terminal briefly
        // flashes to front twice — visible but tolerable, and the
        // trade for stable z-order at rest.
        if useExplicitCascadeZOrder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self else { return }
                guard self.cascadeGeneration == myGen else { return }
                guard self.isTrusted() else { return }
                self.intermediateZOrderCheckpoint(plans: plans, context: "all-apps +300ms re-raise")
            }
        }

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
            if count > 0 {
                self.onWindowsMoved?()
                // Stage 3: any setFrame write triggers macOS's ambient
                // raise-on-write for the touched window, which clobbers
                // the pass-1 z-order. Re-raise the FULL fan (not just
                // the laggards) in reverse order so the anchor is back
                // on top. Fires only when writes happened — mirrors the
                // all-apps retry loop's flicker mitigation.
                if self.useExplicitCascadeZOrder {
                    self.raiseCascadedWindows(
                        orderedFrontFirst: refreshed,
                        context: "\(name) \(label)"
                    )
                }
            }
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
        // Stage 3: rescue writes touch only laggards but each write's
        // ambient raise-on-write disturbs z-order for the whole fan.
        // Re-raise ALL cascade windows (`verification`, not just the
        // laggards) so the anchor lands back on top. Same reason the
        // all-apps retry loop passes full `plans` into its own
        // enforceCascadeZOrder call after any laggard write.
        if count > 0 && useExplicitCascadeZOrder {
            raiseCascadedWindows(
                orderedFrontFirst: verification,
                context: "\(name) rescue \(rescueRound)"
            )
        }

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
    /// the visual z-order matches the cascade's intent. Used by the
    /// all-apps path. Thin wrapper — the observation-based repair logic
    /// lives in `raiseWithObservation`.
    /// Observation-only alternative to `enforceCascadeZOrder`. Runs
    /// the pure observer, records the checkpoint into the drift
    /// history (so persistent-drift / observation-starvation
    /// detectors still see this data), logs the outcome, and returns.
    /// **Never** issues any AXRaise.
    ///
    /// Used by every intermediate settlement stage under the two-
    /// phase correction-owner model: +300ms re-raise, pass 2 / pass 3
    /// converged z-recheck, pass 2 / pass 3 post-write, Chromium
    /// native-repair completion, native-failure → AX fallback. Pass 1
    /// remains the provisional correction owner and still calls
    /// `enforceCascadeZOrder`. Pass 4 has its own observe-first
    /// classifier (`runPassFourZOrderCheckpoint`).
    ///
    /// The log line format mirrors `raiseWithObservation`'s
    /// "observed order already matches intent" and "correcting
    /// front-prefix" lines so a `log stream` filter picks it up, but
    /// with `[observe-only]` in the context so it's obvious the stage
    /// did not mutate.
    private func observeCascadeZOrderOnly(plans: [AppCascadePlan], context: String) {
        let observation = observeCascadeZOrder(plans: plans)
        recordZOrderCheckpoint(
            context: context,
            mismatchedSlots: observation.mismatchedSlots,
            observationIncomplete: observation.observationIncomplete,
            matchedCount: observation.matchedCount,
            plannedCount: observation.plannedCount
        )
        if observation.isCompleteCorrect {
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)) [observe-only]: observed order already matches intent — 0 raise(s), \(observation.plannedCount, privacy: .public) window(s) untouched"
            )
        } else if observation.observationIncomplete {
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)) [observe-only]: matched \(observation.matchedCount, privacy: .public)/\(observation.plannedCount, privacy: .public); recorded for final settlement — 0 raise(s)"
            )
        } else {
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)) [observe-only]: complete observation shows \(observation.mismatchedSlots.count, privacy: .public)/\(observation.plannedCount, privacy: .public) slot(s) still wrong; recorded for final settlement — 0 raise(s)"
            )
        }
    }

    /// Dispatcher: observation-only OR observation-plus-correction,
    /// per the `useSingleOwnerZOrderSettlement` flag. Intermediate
    /// stages call this instead of `enforceCascadeZOrder` directly.
    /// When the flag is on (default), all intermediate stages become
    /// observation-only. When off, behavior reverts to the pre-fix
    /// enforcement path for rollback / A-B comparison.
    private func intermediateZOrderCheckpoint(plans: [AppCascadePlan], context: String) {
        if useSingleOwnerZOrderSettlement {
            observeCascadeZOrderOnly(plans: plans, context: context)
        } else {
            enforceCascadeZOrder(plans: plans, context: context)
        }
    }

    private func enforceCascadeZOrder(plans: [AppCascadePlan], context: String) {
        // Build front-to-back slot list from the plan. Targets are in
        // Cocoa (bottom-left per-screen); convert to AX (top-left
        // global) so match keys line up with CGWindow bounds.
        let slots: [(app: NSRunningApplication, axElement: AXUIElement, axOrigin: CGPoint, target: CGRect)] =
            plans.flatMap { plan in
                plan.expectedFrames.map {
                    (plan.app, $0.axElement, CoordinateSpace.axRect(fromCocoa: $0.target).origin, $0.target)
                }
            }
        raiseWithObservation(slots, context: context)
    }

    /// Pure, read-only z-order observation. Runs the same
    /// CGWindowList query + slot-matching logic used by
    /// `raiseWithObservation`, but performs ZERO AXRaise operations,
    /// ZERO frame writes, ZERO Apple events. Returns the outcome as
    /// a value.
    ///
    /// Used by:
    ///   - Post-walk #1 and #2 reobservation (mandatory: must never
    ///     itself perform a fallback full walk).
    ///   - Pass-4 observe-first classification (mandatory: must not
    ///     immediately perform a fallback walk before deciding
    ///     escalation).
    ///
    /// Callers that need active correction (pass 1 / pass 2 / +300 /
    /// pass 3) continue to use `enforceCascadeZOrder` /
    /// `raiseWithObservation` which observes AND corrects in one call.
    ///
    /// Not called from tests directly (it needs live CGWindowList),
    /// but the shape of the returned data mirrors the pure test
    /// scenarios in `postWalkMadeObservationProgress`.
    private struct ZOrderObservation {
        /// True when at least one planned window could not be mapped
        /// to a CGWindowList entry within tolerance.
        let observationIncomplete: Bool
        /// Number of planned windows successfully mapped.
        let matchedCount: Int
        /// Total planned windows.
        let plannedCount: Int
        /// Slot indices where CGWindowList observed the wrong window.
        /// Only meaningful when `observationIncomplete == false`.
        let mismatchedSlots: Set<Int>
        /// True when observation was complete AND every slot's
        /// observed depth matched the planned depth. Convenience.
        var isCompleteCorrect: Bool { !observationIncomplete && mismatchedSlots.isEmpty }
        /// True when observation was complete AND at least one slot
        /// was out of order. Convenience.
        var isCompleteWrong: Bool { !observationIncomplete && !mismatchedSlots.isEmpty }
    }

    private func observeCascadeZOrder(plans: [AppCascadePlan]) -> ZOrderObservation {
        // Match `enforceCascadeZOrder`'s slot construction exactly so
        // pure observation gives the same result as `raiseWithObservation`
        // would have recorded — no mutation is the only difference.
        let slots: [(app: NSRunningApplication, axElement: AXUIElement, axOrigin: CGPoint, target: CGRect)] =
            plans.flatMap { plan in
                plan.expectedFrames.map {
                    (plan.app, $0.axElement, CoordinateSpace.axRect(fromCocoa: $0.target).origin, $0.target)
                }
            }
        return observeSlots(slots)
    }

    /// Slot-list variant of `observeCascadeZOrder`. Factored out so
    /// `raiseWithObservation` can call the same matching logic and
    /// avoid drift between "observe" and "observe-plus-correct."
    private func observeSlots(
        _ slots: [(app: NSRunningApplication, axElement: AXUIElement, axOrigin: CGPoint, target: CGRect)]
    ) -> ZOrderObservation {
        let n = slots.count
        guard n > 0 else {
            return ZOrderObservation(
                observationIncomplete: false,
                matchedCount: 0,
                plannedCount: 0,
                mismatchedSlots: []
            )
        }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return ZOrderObservation(
                observationIncomplete: true,
                matchedCount: 0,
                plannedCount: n,
                mismatchedSlots: []
            )
        }
        var observedIndices: [Int] = []
        observedIndices.reserveCapacity(n)
        var assigned = Set<Int>()
        for info in raw {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds) else { continue }
            for i in 0..<n where !assigned.contains(i) {
                let s = slots[i]
                if s.app.processIdentifier == pid
                    && abs(s.axOrigin.x - bounds.origin.x) <= 4
                    && abs(s.axOrigin.y - bounds.origin.y) <= 4 {
                    observedIndices.append(i)
                    assigned.insert(i)
                    break
                }
            }
        }
        if observedIndices.count != n {
            return ZOrderObservation(
                observationIncomplete: true,
                matchedCount: observedIndices.count,
                plannedCount: n,
                mismatchedSlots: []
            )
        }
        var mismatchedSlots: Set<Int> = []
        for i in 0..<n where observedIndices[i] != i {
            mismatchedSlots.insert(i)
        }
        return ZOrderObservation(
            observationIncomplete: false,
            matchedCount: n,
            plannedCount: n,
            mismatchedSlots: mismatchedSlots
        )
    }

    /// Shared helper: observation-based minimum-prefix raise, with
    /// tight-loop full-walk fallback. Used by both `enforceCascadeZOrder`
    /// (all-apps) and `raiseCascadedWindows` (single-app + selection).
    ///
    /// Strategy:
    ///   1. Read current on-screen z-order via `CGWindowListCopyWindowInfo`
    ///      (public, metadata-only — no Screen Recording permission).
    ///   2. Match observed windows to `slots` by (pid, ax-origin) with
    ///      a ±4pt tolerance (matches the codebase's standard frame
    ///      tolerance and absorbs character-grid snapping).
    ///   3. Determine the smallest front-prefix whose intended order
    ///      does NOT already match observation. Everything deeper than
    ///      that prefix is already in place and is left untouched.
    ///   4. Raise the prefix back-to-front in a tight loop. Deeper
    ///      windows are not touched — they cannot visibly flash on
    ///      this pass.
    ///   5. If observation fails or is incomplete, fall back to the
    ///      previously-approved full walk. Correctness is never
    ///      sacrificed for the optimization.
    ///
    /// `slots` is expected front-to-back: anchor first, deepest last.
    private func raiseWithObservation(
        _ slots: [(app: NSRunningApplication, axElement: AXUIElement, axOrigin: CGPoint, target: CGRect)],
        context: String
    ) {
        guard !slots.isEmpty else { return }
        let anchor = slots[0]
        let n = slots.count

        // Tight-loop full-walk fallback. Raises back-to-front, so the
        // anchor (slots[0]) lands on top.
        let fallbackFullWalk: (String) -> Void = { reason in
            for slot in slots.reversed() {
                AXUIElementPerformAction(slot.axElement, kAXRaiseAction as CFString)
            }
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)) [fallback: \(reason, privacy: .public)]: full walk — \(n, privacy: .public) raise(s), anchor='\(anchor.app.localizedName ?? "?", privacy: .public)' pid=\(anchor.app.processIdentifier, privacy: .public) origin=(\(Int(anchor.target.origin.x), privacy: .public),\(Int(anchor.target.origin.y), privacy: .public))"
            )
            for (raiseOrder, slot) in slots.reversed().enumerated() {
                let isAnchor = raiseOrder == n - 1
                Log.cascade.info(
                    "  raise[\(raiseOrder, privacy: .public)] \(slot.app.localizedName ?? "?", privacy: .public) pid=\(slot.app.processIdentifier, privacy: .public) origin=(\(Int(slot.target.origin.x), privacy: .public),\(Int(slot.target.origin.y), privacy: .public))\(isAnchor ? " ← anchor" : "", privacy: .public)"
                )
            }
        }

        // Delegate to pure observation so `raiseWithObservation` and
        // `observeCascadeZOrder` share one matching implementation.
        let observation = observeSlots(slots)

        // If observation couldn't confidently map every planned window,
        // fall back to the tight-loop full walk. Same behavior as
        // before the extraction — this is the "observe-plus-correct"
        // path used by pass 1 / pass 2 / +300 / pass 3.
        guard !observation.observationIncomplete else {
            recordZOrderCheckpoint(
                context: context,
                mismatchedSlots: [],
                observationIncomplete: true,
                matchedCount: observation.matchedCount,
                plannedCount: observation.plannedCount
            )
            fallbackFullWalk("matched \(observation.matchedCount)/\(n) planned window(s)")
            return
        }

        // Complete observation. Re-observe the slot indices only for
        // the front-prefix computation — cheap since we already have
        // the raw list matching in `observation`. To avoid a second
        // CGWindowList query, reconstruct `observedIndices` from
        // `observation.mismatchedSlots` semantics: a slot appears at
        // its correct position iff it's NOT in `mismatchedSlots`.
        //
        // For the front-prefix, we need the deepest wrong slot. If
        // there are mismatchedSlots, the deepest wrong index is
        // max(mismatchedSlots); the front-prefix runs 0 ... that.
        var correctTo = 0
        if let deepestWrong = observation.mismatchedSlots.max() {
            correctTo = deepestWrong + 1
        }
        let mismatchedSlots = observation.mismatchedSlots

        guard correctTo > 0 else {
            recordZOrderCheckpoint(
                context: context,
                mismatchedSlots: [],
                observationIncomplete: false,
                matchedCount: n,
                plannedCount: n
            )
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)): observed order already matches intent — 0 raise(s), \(n, privacy: .public) window(s) untouched"
            )
            return
        }

        recordZOrderCheckpoint(
            context: context,
            mismatchedSlots: mismatchedSlots,
            observationIncomplete: false,
            matchedCount: n,
            plannedCount: n
        )

        // Raise slots[0..correctTo-1] back-to-front. Windows deeper
        // than `correctTo` are already at rest and are not touched.
        let prefixBackToFront = Array(slots.prefix(correctTo).reversed())
        for slot in prefixBackToFront {
            AXUIElementPerformAction(slot.axElement, kAXRaiseAction as CFString)
        }

        Log.cascade.info(
            "Stage 3 z-order (\(context, privacy: .public)): correcting front-prefix — \(correctTo, privacy: .public)/\(n, privacy: .public) raise(s), \(n - correctTo, privacy: .public) deeper window(s) untouched, anchor='\(anchor.app.localizedName ?? "?", privacy: .public)' pid=\(anchor.app.processIdentifier, privacy: .public) origin=(\(Int(anchor.target.origin.x), privacy: .public),\(Int(anchor.target.origin.y), privacy: .public))"
        )
        for (raiseOrder, slot) in prefixBackToFront.enumerated() {
            let isAnchor = raiseOrder == prefixBackToFront.count - 1
            Log.cascade.info(
                "  raise[\(raiseOrder, privacy: .public)] \(slot.app.localizedName ?? "?", privacy: .public) pid=\(slot.app.processIdentifier, privacy: .public) origin=(\(Int(slot.target.origin.x), privacy: .public),\(Int(slot.target.origin.y), privacy: .public))\(isAnchor ? " ← anchor" : "", privacy: .public)"
            )
        }
    }

    /// Raises the given windows in reverse of their input order so the
    /// first element (the intended anchor) lands globally on top. Each
    /// `kAXRaiseAction` also activates the window's owning application
    /// as a side effect, so the anchor's app ends up frontmost — but
    /// that's incidental, not enforced (`NSRunningApplication.activate`
    /// would be the explicit lever; we don't call it here to avoid the
    /// Sequoia+ activation-policy edge cases).
    ///
    /// Emits a summary line plus one line per raise (in actual raise
    /// order) at `info` level so a `log stream` tail can visually
    /// confirm z-order is being enforced deterministically. The
    /// per-window lines are labeled by owner + windowID; the very last
    /// raise is marked `← anchor` so it's obvious which window ended
    /// on top.
    ///
    /// Called from the single-app and selection cascade entry points
    /// after pass 1, and from the single-app retry / rescue paths
    /// whenever writes moved something.
    ///
    /// Thin wrapper: builds a front-to-back slot list by reading each
    /// window's CURRENT frame via AX (post-write, this equals the
    /// intended target within tolerance) and delegates to the shared
    /// observation-based helper. Any window that can't be re-read is
    /// dropped from the slot list, which triggers the helper's
    /// full-walk fallback — never a partial raise on stale data.
    private func raiseCascadedWindows(orderedFrontFirst windows: [EnumeratedWindow], context: String) {
        guard !windows.isEmpty else { return }
        var appByPID: [pid_t: NSRunningApplication] = [:]
        var slots: [(app: NSRunningApplication, axElement: AXUIElement, axOrigin: CGPoint, target: CGRect)] = []
        slots.reserveCapacity(windows.count)
        for window in windows {
            var pid: pid_t = 0
            AXUIElementGetPid(window.axElement, &pid)
            let app: NSRunningApplication
            if let cached = appByPID[pid] {
                app = cached
            } else if let looked = NSRunningApplication(processIdentifier: pid) {
                app = looked
                appByPID[pid] = looked
            } else {
                continue
            }
            // Fresh AX read gives the actual current frame post-write.
            // Fall back to the input frame if AX refuses.
            let axRect = AXWindowEnumerator.currentFrame(of: window.axElement)
                ?? CoordinateSpace.axRect(fromCocoa: window.frame)
            let target = CoordinateSpace.cocoaRect(fromAX: axRect)
            slots.append((app, window.axElement, axRect.origin, target))
        }
        raiseWithObservation(slots, context: context)
    }

    // MARK: - Z-order settlement pipeline
    //
    // Called by `raiseWithObservation` at every observation checkpoint,
    // and by `runPassFourZOrderCheckpoint` / late recommit paths for
    // escalation. Together these implement the bounded persistent-
    // drift-aware pipeline (see the settlement state block-comment
    // near the state declarations, and CascadeZOrderDrift.swift for
    // the pure decisions).

    /// Appends a checkpoint record to the current-generation history.
    /// Updates the running `zOrderFinalStatus` from observation-only
    /// evidence — the escalation pipeline
    /// (`settledSerializedReconstruction` / `settledLateRecommit` /
    /// `unresolved` / `staleGeneration` / `cancelled`) owns the
    /// terminal statuses reached via serialized reconstruction, late
    /// recommit, or cancellation, and this method never overwrites
    /// those.
    ///
    /// Observation-based transitions:
    ///   - `.settledNoCorrection` + drift → `.settledObservationCorrection`
    ///   - `.settledNoCorrection` + incomplete → `.observationIncomplete`
    ///   - `.settledObservationCorrection` + incomplete → `.observationIncomplete`
    ///   - `.observationIncomplete` + complete-observation-settled →
    ///     downgrade to `.settledObservationCorrection` (or
    ///     `.settledNoCorrection` if no drift is anywhere in history)
    ///
    /// The `.observationIncomplete` downgrade rule is what makes the
    /// final verify log honest: a Pass 1 fallback whose observation
    /// couldn't map every window records `.observationIncomplete`,
    /// but subsequent complete observations that confirm settled
    /// order should be reflected — otherwise the label lies about
    /// the final visual state.
    private func recordZOrderCheckpoint(
        context: String,
        mismatchedSlots: Set<Int>,
        observationIncomplete: Bool,
        matchedCount: Int = 0,
        plannedCount: Int = 0
    ) {
        zOrderMismatchHistory.append(ZOrderMismatchRecord(
            checkpoint: context,
            mismatchedSlots: mismatchedSlots,
            observationIncomplete: observationIncomplete,
            matchedCount: matchedCount,
            plannedCount: plannedCount
        ))
        // Terminal statuses set by the escalation pipeline are never
        // touched here. Only the observation-only transitions below
        // apply.
        switch zOrderFinalStatus {
        case .settledNoCorrection:
            if observationIncomplete {
                zOrderFinalStatus = .observationIncomplete
            } else if !mismatchedSlots.isEmpty {
                zOrderFinalStatus = .settledObservationCorrection
            }
        case .settledObservationCorrection:
            if observationIncomplete {
                zOrderFinalStatus = .observationIncomplete
            }
        case .observationIncomplete:
            // A complete observation that confirms correct order
            // supersedes an earlier incomplete one — the layout
            // truly settled and the final label should reflect
            // that. Downgrade to whichever settled status matches
            // the accumulated history (any prior real drift → the
            // "observation correction" variant; nothing but
            // successful observations → "no correction").
            if !observationIncomplete && mismatchedSlots.isEmpty {
                zOrderFinalStatus =
                    CascadeZOrderDrift.settledWithoutAnyCorrection(zOrderMismatchHistory)
                    ? .settledNoCorrection
                    : .settledObservationCorrection
            }
        default:
            break
        }
    }

    /// Pass-4-specific enforcement. Called from `scheduleAllAppsRetry`
    /// when `label == "pass 4"` and from `scheduleSelectionZOrderCheckpoint`
    /// when `isFinalPass: true`. Unlike the earlier passes' plain
    /// `enforceCascadeZOrder` call, this variant:
    ///   1. Runs the normal observation-based enforcement (which
    ///      records a checkpoint via `raiseWithObservation`).
    ///   2. If the fresh history matches the persistent-drift pattern
    ///      per `CascadeZOrderDrift.isPersistentDrift`, immediately
    ///      escalates to a serialized full reconstruction rather than
    ///      trusting the front-prefix correction to be durable.
    ///   3. ELSE, if starvation escalation is enabled AND the fresh
    ///      history matches the observation-starvation pattern per
    ///      `CascadeZOrderDrift.isObservationStarved` (two consecutive
    ///      incomplete records ending at the latest checkpoint),
    ///      escalates to the SAME serialized reconstruction with a
    ///      different trigger label. This is the fix for the cold-
    ///      start silent-exit path — under the pre-fix design, both
    ///      detectors returned false when observations were repeatedly
    ///      incomplete and pass 4 exited without escalation, log line,
    ///      or final-status assignment.
    ///   4. ELSE, if pass 4 did not settle and did not escalate, emit
    ///      an explicit final status so the trace never ends
    ///      mid-pipeline.
    ///
    /// The serialized reconstruction is asynchronous and generation-
    /// guarded; overlap-safe via `zOrderSerializedWalkInFlight`.
    ///
    /// Selection Cascade shares this exact function — the decision
    /// order and escalation targets are identical for both callers.
    /// The only difference is the label prefix.
    /// Pass-4 wrapper: applies the geometry-quiescence barrier before
    /// running the settlement decision. If native repairs are still
    /// in flight for the current generation, defer the settlement
    /// until they drain — `resumePendingFinalSettlementIfQuiescent`
    /// (called from every native-repair completion) will fire the
    /// core once the count reaches zero.
    ///
    /// When quiescent OR the barrier is disabled, delegates
    /// immediately to `runPassFourZOrderCheckpointCore`.
    ///
    /// Pre-fix behavior: pass 4 could start serialized reconstruction
    /// while Chromium native-repair callbacks were still landing,
    /// which caused the reconstruction's async raise sequence to
    /// interleave with fallback full walks from the callbacks. Under
    /// the two-phase model those callbacks are already observation-
    /// only, but the barrier additionally guarantees that final
    /// serialized reconstruction observes only post-repair state —
    /// no risk of a mid-walk repair completion disturbing the stack
    /// the walk just reconstructed.
    private func runPassFourZOrderCheckpoint(
        plans: [AppCascadePlan],
        generation: UInt64,
        context: String
    ) {
        guard cascadeGeneration == generation else { return }
        guard isTrusted() else { return }
        guard useExplicitCascadeZOrder else { return }

        // Barrier: defer if geometry / native-repair work is still in
        // flight. When the last repair drains, its completion callback
        // invokes `resumePendingFinalSettlementIfQuiescent` which
        // takes a fresh pure observation and runs the core.
        if useSingleOwnerZOrderSettlement {
            let repairsInFlight = nativeRepairCountForCurrentGeneration()
            if repairsInFlight > 0 {
                Log.cascade.notice(
                    "Stage 3 z-order settlement: pass 4 arrived with geometry not yet quiescent — repairsInFlight=\(repairsInFlight, privacy: .public); deferring final settlement until drain (context='\(context, privacy: .public)')"
                )
                pendingFinalSettlement = (plans: plans, generation: generation, context: context)
                return
            }
        }

        runPassFourZOrderCheckpointCore(
            plans: plans,
            generation: generation,
            context: context
        )
    }

    /// Pass-4 core: observe-first classify + exactly one correction
    /// path. Callable directly by `runPassFourZOrderCheckpoint` when
    /// no barrier defer is needed AND by
    /// `resumePendingFinalSettlementIfQuiescent` after the barrier
    /// drains. Takes its own fresh observation regardless of which
    /// caller — pre-drain observations must not be reused, as
    /// geometry may have changed between the deferral and the resume.
    private func runPassFourZOrderCheckpointCore(
        plans: [AppCascadePlan],
        generation: UInt64,
        context: String
    ) {
        guard cascadeGeneration == generation else { return }
        guard isTrusted() else { return }
        guard useExplicitCascadeZOrder else { return }

        let observation = observeCascadeZOrder(plans: plans)
        recordZOrderCheckpoint(
            context: context,
            mismatchedSlots: observation.mismatchedSlots,
            observationIncomplete: observation.observationIncomplete,
            matchedCount: observation.matchedCount,
            plannedCount: observation.plannedCount
        )

        // Diagnostic log to mirror pre-fix visibility. This is the
        // "what pass 4 saw" line — corrective actions still log their
        // own lines below when they fire.
        if observation.isCompleteCorrect {
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)) [pure observation]: observed order already matches intent — 0 raise(s), \(observation.plannedCount, privacy: .public) window(s) untouched"
            )
        } else if observation.observationIncomplete {
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)) [pure observation]: matched \(observation.matchedCount, privacy: .public)/\(observation.plannedCount, privacy: .public) planned window(s); no fallback walk fired"
            )
        } else {
            Log.cascade.info(
                "Stage 3 z-order (\(context, privacy: .public)) [pure observation]: complete observation shows \(observation.mismatchedSlots.count, privacy: .public)/\(observation.plannedCount, privacy: .public) slot(s) still wrong"
            )
        }

        // Decision order:
        //   1. Complete + correct → settle now.
        //   2. Complete + persistent drift → serialized reconstruction.
        //   3. Observation starvation → serialized reconstruction.
        //   4. Complete + isolated wrong → one ordinary correction via
        //      enforceCascadeZOrder (its optimizer will front-prefix).
        //   5. Single trailing incomplete (not starvation) → truthful
        //      finalize; no blind fallback walk.
        //
        // Exactly one correction path fires per pass 4 invocation.

        // 1. Complete + correct.
        if observation.isCompleteCorrect {
            finalizeIfTerminal(
                generation: generation,
                reason: "pass 4 complete + correct observation"
            )
            return
        }

        // 2. Persistent drift.
        if CascadeZOrderDrift.isPersistentDrift(zOrderMismatchHistory) {
            escalateToSerializedReconstruction(
                plans: plans,
                generation: generation,
                trigger: "\(context) → persistent-drift escalation"
            )
            return
        }

        // 3. Observation starvation.
        let planWindowCount = plans.reduce(0) { $0 + $1.expectedFrames.count }
        let starvationEligible = planWindowCount > 1
        if useObservationStarvationEscalation
            && starvationEligible
            && CascadeZOrderDrift.isObservationStarved(zOrderMismatchHistory) {
            let streak = countTrailingIncomplete(zOrderMismatchHistory)
            Log.cascade.notice(
                "Stage 3 z-order settlement: pass 4 observation starvation detected — \(streak, privacy: .public) consecutive incomplete checkpoint(s), latest='\(context, privacy: .public)', planned=\(planWindowCount, privacy: .public); routing to serialized reconstruction (no immediate fallback walk fired first)"
            )
            escalateToSerializedReconstruction(
                plans: plans,
                generation: generation,
                trigger: "\(context) → observation-starvation escalation"
            )
            return
        }

        // 4. Complete + isolated wrong. Ordinary correction path (its
        // front-prefix optimizer only touches slots that need moving).
        if observation.isCompleteWrong {
            enforceCascadeZOrder(plans: plans, context: "\(context) (ordinary correction)")
            finalizeIfTerminal(
                generation: generation,
                reason: "pass 4 complete + isolated wrong order, ordinary correction applied"
            )
            return
        }

        // 5. Single trailing incomplete but not starvation. Do NOT
        // fire a fallback walk solely because pass 4's own observation
        // was incomplete; the earlier checkpoints already ran their
        // corrections. Finalize truthfully from the observation-derived
        // status. Preserves the spec's "truthfulness > cosmetic
        // optimism" requirement.
        finalizeIfTerminal(
            generation: generation,
            reason: "pass 4 incomplete but not starvation (single trailing incomplete)"
        )
    }

    /// Number of native-repair operations currently in flight for the
    /// current cascade generation. Zero means geometry has quiesced
    /// for z-order purposes: no async AppleScript `set bounds` write
    /// is going to complete and disturb the stack. Non-zero means we
    /// should defer any authoritative correction until the last
    /// repair drains.
    private func nativeRepairCountForCurrentGeneration() -> Int {
        return nativeRepairInFlight.filter { $0.generation == cascadeGeneration }.count
    }

    /// Called from every native-repair callback (success + failure
    /// paths). If a final settlement request is pending AND no more
    /// tracked repairs remain for this generation, take a FRESH pure
    /// observation and resume the settlement decision. Otherwise
    /// no-op — either no settlement is pending, or more repairs are
    /// still landing.
    private func resumePendingFinalSettlementIfQuiescent(generation: UInt64) {
        guard let pending = pendingFinalSettlement else { return }
        guard pending.generation == generation else { return }
        guard cascadeGeneration == generation else { return }
        guard isTrusted() else { return }
        guard nativeRepairCountForCurrentGeneration() == 0 else { return }

        // Consume the pending request atomically before running
        // settlement so a re-entrant native-repair completion during
        // the fresh observation can't double-fire.
        pendingFinalSettlement = nil
        Log.cascade.notice(
            "Stage 3 z-order settlement: geometry quiescent (0 native repairs in flight for gen \(generation, privacy: .public)) — running fresh final observation + settlement decision (context='\(pending.context, privacy: .public)')"
        )
        runPassFourZOrderCheckpointCore(
            plans: pending.plans,
            generation: generation,
            context: "\(pending.context) (quiescent resume)"
        )
    }

    /// Length of the ending incomplete streak in `history`. Diagnostic
    /// only — matches the decision `isObservationStarved` uses
    /// internally but exposed so the log line can report the streak
    /// length that triggered escalation.
    private func countTrailingIncomplete(_ history: [ZOrderMismatchRecord]) -> Int {
        var streak = 0
        for record in history.reversed() {
            if record.observationIncomplete {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }

    /// Idempotent finalization: emits ONE terminal `Stage 3 z-order
    /// settlement: FINAL` log line for the current generation and
    /// records that it emitted. Later terminal branches see
    /// `zOrderFinalStatusEmitted == true` and no-op — the first
    /// terminal outcome wins.
    ///
    /// Callers pass:
    ///   - `status`: the finalized `ZOrderFinalStatus` to record.
    ///     Only assigned if not already emitted this generation.
    ///   - `generation`: the generation the caller was scheduled for.
    ///     If it doesn't match `cascadeGeneration`, this is a stale
    ///     callback and the finalization is silently dropped.
    ///   - `reason`: short human label for the log line
    ///     (e.g. "pass 4 complete", "walk #1 SETTLED", "budget
    ///     exhausted"). Included verbatim in the FINAL log.
    ///
    /// Never called for generations we've already retired or that a
    /// newer cascade has superseded — the `cascadeGeneration` guard
    /// handles both cases.
    private func finalizeZOrderSettlement(
        status: ZOrderFinalStatus,
        generation: UInt64,
        reason: String
    ) {
        guard cascadeGeneration == generation else {
            // Stale callback from a superseded cascade. Do not touch
            // the current generation's status or emit a log line —
            // finalizeIfTerminal on the new cascade owns finalization.
            return
        }
        guard !zOrderFinalStatusEmitted else {
            // Another terminal branch already emitted for this
            // generation. Do not overwrite; do not log twice.
            return
        }
        zOrderFinalStatus = status
        zOrderFinalStatusEmitted = true
        Log.cascade.notice(
            "Stage 3 z-order settlement: FINAL — status=\(String(describing: status), privacy: .public), reason='\(reason, privacy: .public)', generation=\(generation, privacy: .public)"
        )
    }

    /// Finalize IF this checkpoint is a terminal branch — i.e., no
    /// serialized walk is currently in flight and no late recommit is
    /// scheduled to fire. If either is pending, leave finalization to
    /// that continuation's completion path (which owns the ownership
    /// invariant).
    ///
    /// Reads `zOrderFinalStatus` — set by observation-only transitions
    /// in `recordZOrderCheckpoint` — to decide the finalized value.
    /// The default (`.settledNoCorrection`) means "every observation
    /// showed correct order and no correction was ever needed."
    ///
    /// Used at the end of `runPassFourZOrderCheckpoint` after
    /// persistent-drift and observation-starvation escalation checks
    /// have both been evaluated and rejected.
    private func finalizeIfTerminal(
        generation: UInt64,
        reason: String
    ) {
        guard cascadeGeneration == generation else { return }
        // A walk in flight OR a late recommit scheduled means an
        // async continuation is going to reach a terminal state and
        // finalize itself. Do not finalize here — the walk's
        // reobservation completion will call this function too, and
        // the idempotency guard will let whichever gets there first
        // record the status.
        guard !zOrderSerializedWalkInFlight else { return }
        guard !zOrderLateRecommitScheduled else { return }
        finalizeZOrderSettlement(
            status: zOrderFinalStatus,
            generation: generation,
            reason: reason
        )
    }

    /// Escalation entry point: schedules one serialized full
    /// reconstruction (async, spaced raises, generation-guarded)
    /// followed by settled reobservation. If the reobservation still
    /// shows drift and the walk budget allows, schedules the
    /// conditional late recommit at approximately
    /// `+lateRecommitEarliestOffset` from cascade start.
    ///
    /// No-op if:
    ///   - A serialized walk is already in flight (overlap prevention).
    ///   - The walk budget is exhausted (max 2 per generation).
    ///   - The generation has advanced or trust was lost.
    private func escalateToSerializedReconstruction(
        plans: [AppCascadePlan],
        generation: UInt64,
        trigger: String
    ) {
        guard cascadeGeneration == generation, isTrusted() else { return }
        guard !zOrderSerializedWalkInFlight else {
            Log.cascade.info(
                "Stage 3 z-order settlement: serialized reconstruction requested by \(trigger, privacy: .public) but one is already in flight — coalescing"
            )
            return
        }
        guard zOrderSerializedWalkCount < CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration else {
            finalizeZOrderSettlement(
                status: .unresolved,
                generation: generation,
                reason: "serialized reconstruction budget exhausted (\(self.zOrderSerializedWalkCount)/\(CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration))"
            )
            return
        }

        // Build the same front-to-back slot list used by the ordinary
        // enforcer. Slots preserved from the plan; the async raise
        // sequence uses them in reverse (deepest first, anchor last).
        let slots: [(app: NSRunningApplication, axElement: AXUIElement, axOrigin: CGPoint, target: CGRect)] =
            plans.flatMap { plan in
                plan.expectedFrames.map {
                    (plan.app, $0.axElement, CoordinateSpace.axRect(fromCocoa: $0.target).origin, $0.target)
                }
            }
        guard !slots.isEmpty else { return }

        zOrderSerializedWalkInFlight = true
        zOrderSerializedWalkCount += 1
        let walkNumber = zOrderSerializedWalkCount

        // Capture pre-walk-best observation coverage exactly once per
        // generation (before walk #1 fires). Post-walk reobservation
        // compares against this baseline via
        // `CascadeZOrderDrift.postWalkMadeObservationProgress` to
        // decide whether walk #2 has any evidence it might improve
        // the observation.
        if zOrderPreWalkBestMatchedCount == nil {
            let bestMatched = zOrderMismatchHistory
                .map(\.matchedCount)
                .max() ?? 0
            zOrderPreWalkBestMatchedCount = bestMatched
            Log.cascade.info(
                "Stage 3 z-order settlement: pre-walk best observation coverage = \(bestMatched, privacy: .public)/\(slots.count, privacy: .public) (captured before walk #\(walkNumber, privacy: .public))"
            )
        }

        let walkContext = "serialized reconstruction #\(walkNumber) (trigger: \(trigger))"

        Log.cascade.notice(
            "Stage 3 z-order settlement: escalating — \(walkContext, privacy: .public), \(slots.count, privacy: .public) planned window(s), spacing=\(Int(CascadeZOrderSettlementTiming.raiseSpacing * 1000), privacy: .public)ms"
        )

        // Raise deepest first, anchor last. `slots.reversed()`
        // yields (deepest, ..., anchor) — the correct order for a
        // stack-restoring sequence of AXRaise actions.
        let raiseOrder = Array(slots.reversed())
        performSerializedRaiseStep(
            remaining: raiseOrder,
            stepIndex: 0,
            totalSteps: raiseOrder.count,
            plans: plans,
            generation: generation,
            walkNumber: walkNumber
        )
    }

    /// Recursive async step of the serialized reconstruction. One
    /// AXRaise per step, spaced by `raiseSpacing`. Every step
    /// re-verifies generation + trust before firing. When all steps
    /// complete, schedules the settled reobservation.
    private func performSerializedRaiseStep(
        remaining: [(app: NSRunningApplication, axElement: AXUIElement, axOrigin: CGPoint, target: CGRect)],
        stepIndex: Int,
        totalSteps: Int,
        plans: [AppCascadePlan],
        generation: UInt64,
        walkNumber: Int
    ) {
        // Cancellation: generation advanced OR trust lost mid-walk.
        if cascadeGeneration != generation {
            Log.cascade.info(
                "Stage 3 z-order settlement: serialized walk #\(walkNumber, privacy: .public) cancelled mid-sequence (generation advanced)"
            )
            zOrderSerializedWalkInFlight = false
            // Do NOT finalize the newer generation's status; our own
            // generation is superseded and gets no final log line
            // beyond the "cancelled mid-sequence" info line above.
            return
        }
        if !isTrusted() {
            Log.cascade.info(
                "Stage 3 z-order settlement: serialized walk #\(walkNumber, privacy: .public) cancelled mid-sequence (AX trust lost)"
            )
            zOrderSerializedWalkInFlight = false
            finalizeZOrderSettlement(
                status: .cancelled,
                generation: generation,
                reason: "AX trust lost during serialized walk #\(walkNumber)"
            )
            return
        }

        guard let slot = remaining.first else {
            // All raises fired — schedule settled reobservation.
            Log.cascade.info(
                "Stage 3 z-order settlement: serialized walk #\(walkNumber, privacy: .public) complete (\(totalSteps, privacy: .public) raise(s)); scheduling settled reobservation in \(Int(CascadeZOrderSettlementTiming.settledReobservationDelay * 1000), privacy: .public)ms"
            )
            scheduleSettledReobservation(
                plans: plans,
                generation: generation,
                walkNumber: walkNumber
            )
            return
        }

        // Skip windows whose AX element is no longer valid (window
        // closed mid-walk). AXWindowEnumerator.currentFrame reads
        // an attribute — if it returns nil, the element is gone.
        let isValid = AXWindowEnumerator.currentFrame(of: slot.axElement) != nil
        if isValid {
            AXUIElementPerformAction(slot.axElement, kAXRaiseAction as CFString)
            Log.cascade.info(
                "  serialized[\(stepIndex, privacy: .public)/\(totalSteps, privacy: .public)] \(slot.app.localizedName ?? "?", privacy: .public) pid=\(slot.app.processIdentifier, privacy: .public) origin=(\(Int(slot.target.origin.x), privacy: .public),\(Int(slot.target.origin.y), privacy: .public))\(stepIndex == totalSteps - 1 ? " ← anchor" : "", privacy: .public)"
            )
        } else {
            Log.cascade.info(
                "  serialized[\(stepIndex, privacy: .public)/\(totalSteps, privacy: .public)] SKIPPED — AX element invalid for \(slot.app.localizedName ?? "?", privacy: .public) pid=\(slot.app.processIdentifier, privacy: .public)"
            )
        }

        let rest = Array(remaining.dropFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + CascadeZOrderSettlementTiming.raiseSpacing) { [weak self] in
            self?.performSerializedRaiseStep(
                remaining: rest,
                stepIndex: stepIndex + 1,
                totalSteps: totalSteps,
                plans: plans,
                generation: generation,
                walkNumber: walkNumber
            )
        }
    }

    /// Wait `settledReobservationDelay` then re-run the observation
    /// checkpoint. Three post-walk outcomes:
    ///
    ///   1. Complete + correct → mark settled (serializedReconstruction
    ///      for walk 1, lateRecommit for walk 2) and finalize.
    ///   2. Complete + wrong (`lastObservedWrong` on the fresh record) →
    ///      schedule the existing late recommit if budget remains, or
    ///      finalize as `.unresolved` if not.
    ///   3. Incomplete (`observationIncomplete` on the fresh record) →
    ///      cannot prove settled OR wrong. Schedule the existing late
    ///      recommit if budget remains — the second walk gives
    ///      CGWindowList another chance to catch up. If no budget
    ///      remains (after walk 2), finalize as
    ///      `.unresolvedObservationIncomplete` — distinct from
    ///      `.unresolved` (which means we DID observe wrong order)
    ///      because we cannot honestly claim we verified anything.
    ///
    /// The post-walk incomplete case is the second half of the
    /// observation-starvation fix — under the pre-fix design, an
    /// incomplete reobservation was silently swallowed by
    /// `lastObservedWrong` returning false (it filters out incomplete
    /// records), causing the walk to be reported as SETTLED when it
    /// hadn't been verified. That's now impossible; the incomplete
    /// case always routes to either late recommit or a truthful
    /// unresolved-incomplete finalization.
    private func scheduleSettledReobservation(
        plans: [AppCascadePlan],
        generation: UInt64,
        walkNumber: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + CascadeZOrderSettlementTiming.settledReobservationDelay) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == generation else {
                // Stale — a newer cascade / restore superseded us.
                // Clear in-flight so the newer generation isn't
                // blocked by our leftover mutex; do NOT finalize the
                // newer generation's status here.
                self.zOrderSerializedWalkInFlight = false
                return
            }
            guard self.isTrusted() else {
                self.zOrderSerializedWalkInFlight = false
                self.finalizeZOrderSettlement(
                    status: .cancelled,
                    generation: generation,
                    reason: "AX trust lost during post-walk reobservation"
                )
                return
            }

            // PURE observation — must NOT call enforceCascadeZOrder
            // here. The pre-fix code called enforce, which fallback-
            // walked on incomplete observation, producing the "post-
            // walk reobservation … full walk" visible flicker even
            // though this stage is supposed to only verify. The fix
            // uses observeCascadeZOrder, which never raises.
            let reobsContext = "post-walk #\(walkNumber) reobservation"
            let observation = self.observeCascadeZOrder(plans: plans)
            self.recordZOrderCheckpoint(
                context: reobsContext,
                mismatchedSlots: observation.mismatchedSlots,
                observationIncomplete: observation.observationIncomplete,
                matchedCount: observation.matchedCount,
                plannedCount: observation.plannedCount
            )
            self.zOrderSerializedWalkInFlight = false

            // Diagnostic log so users can see what post-walk saw. This
            // does NOT trigger any raise regardless of outcome.
            if observation.isCompleteCorrect {
                Log.cascade.info(
                    "Stage 3 z-order (\(reobsContext, privacy: .public)) [pure observation]: observed order already matches intent — 0 raise(s), \(observation.plannedCount, privacy: .public) window(s) untouched"
                )
            } else if observation.observationIncomplete {
                Log.cascade.info(
                    "Stage 3 z-order (\(reobsContext, privacy: .public)) [pure observation]: matched \(observation.matchedCount, privacy: .public)/\(observation.plannedCount, privacy: .public) planned window(s); no fallback walk fired"
                )
            } else {
                Log.cascade.info(
                    "Stage 3 z-order (\(reobsContext, privacy: .public)) [pure observation]: complete observation shows \(observation.mismatchedSlots.count, privacy: .public)/\(observation.plannedCount, privacy: .public) slot(s) still wrong"
                )
            }

            if observation.isCompleteCorrect {
                // Case 1: complete + correct. Walk succeeded.
                let settledStatus: ZOrderFinalStatus = (walkNumber == 1)
                    ? .settledSerializedReconstruction
                    : .settledLateRecommit
                self.finalizeZOrderSettlement(
                    status: settledStatus,
                    generation: generation,
                    reason: "walk #\(walkNumber) reobservation complete and correct"
                )
                return
            }

            if observation.observationIncomplete {
                // Case 3: observation unavailable. Do NOT mark settled.
                // Progress-aware gating — skip walk #2 when the plateau
                // hasn't improved.
                Log.cascade.notice(
                    "Stage 3 z-order settlement: post-walk #\(walkNumber, privacy: .public) reobservation INCOMPLETE (matched \(observation.matchedCount, privacy: .public)/\(observation.plannedCount, privacy: .public)) — checking observation progress before late recommit"
                )
                self.handlePostWalkIncomplete(
                    plans: plans,
                    generation: generation,
                    walkNumber: walkNumber,
                    postWalkMatchedCount: observation.matchedCount
                )
                return
            }

            // Case 2: complete + wrong. Consider late recommit —
            // observation succeeded and DID prove wrong order.
            self.scheduleLateRecommitIfNeeded(plans: plans, generation: generation)
        }
    }

    /// Post-walk incomplete branch: the walk finished but we can't
    /// prove settled OR wrong. Progress-gated:
    ///
    ///   - If the post-walk observation coverage strictly improved
    ///     over `zOrderPreWalkBestMatchedCount` (e.g. 5/8 → 7/8),
    ///     walk #2 remains justified — CGWindowList is catching up
    ///     and the second walk may complete verification. Route to
    ///     late recommit if budget remains.
    ///
    ///   - If coverage did NOT improve (e.g. 5/6 → 5/6, 7/8 → 7/8),
    ///     walk #2 has no evidence it would help. The plateau is
    ///     structural: at least one planned window is unobservable
    ///     to CGWindowList regardless of raise activity. Finalize
    ///     truthfully as `.unresolvedObservationIncomplete` and skip
    ///     the second walk — this is the primary retry-flicker fix.
    ///
    ///   - If walk budget is exhausted (this WAS walk #2, or walk #1
    ///     with the late recommit already scheduled), finalize
    ///     regardless.
    ///
    /// The progress decision is delegated to the pure helper
    /// `CascadeZOrderDrift.postWalkMadeObservationProgress` so it's
    /// separately testable and the caller doesn't inline the rule.
    private func handlePostWalkIncomplete(
        plans: [AppCascadePlan],
        generation: UInt64,
        walkNumber: Int,
        postWalkMatchedCount: Int
    ) {
        guard cascadeGeneration == generation, isTrusted() else { return }

        // No budget remains → finalize truthfully.
        if zOrderSerializedWalkCount >= CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration
            || zOrderLateRecommitScheduled {
            finalizeZOrderSettlement(
                status: .unresolvedObservationIncomplete,
                generation: generation,
                reason: "walk #\(walkNumber) reobservation incomplete and walk budget exhausted"
            )
            return
        }

        // Budget remains — but do we have any evidence walk #2 would
        // help? Progress gating decides.
        let bestPre = zOrderPreWalkBestMatchedCount ?? 0
        let progress = CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: bestPre,
            postWalkMatchedCount: postWalkMatchedCount,
            postWalkIncomplete: true
        )
        if !progress {
            // No progress → structural plateau. Skip walk #2.
            Log.cascade.notice(
                "Stage 3 z-order settlement: walk #\(walkNumber, privacy: .public) reobservation incomplete with no observation progress; best pre-walk=\(bestPre, privacy: .public), post-walk=\(postWalkMatchedCount, privacy: .public); skipping redundant late recommit"
            )
            finalizeZOrderSettlement(
                status: .unresolvedObservationIncomplete,
                generation: generation,
                reason: "walk #\(walkNumber) reobservation incomplete with no observation progress (pre-walk-best=\(bestPre), post-walk=\(postWalkMatchedCount)); walk #2 suppressed"
            )
            return
        }

        // Coverage improved → walk #2 remains justified.
        Log.cascade.notice(
            "Stage 3 z-order settlement: walk #\(walkNumber, privacy: .public) reobservation incomplete but observation coverage IMPROVED (best pre-walk=\(bestPre, privacy: .public), post-walk=\(postWalkMatchedCount, privacy: .public)); scheduling late recommit"
        )
        scheduleLateRecommitIfNeeded(plans: plans, generation: generation)
    }

    /// Schedules one conditional late recommit at approximately
    /// `+lateRecommitEarliestOffset` from cascade start (or ASAP if
    /// we're already past it). Fires at most once per generation.
    /// Finalizes with `.unresolved` if budget is exhausted.
    ///
    /// Caller should have already decided that a late recommit is
    /// warranted — either because a walk's reobservation returned
    /// wrong order OR because a walk's reobservation was incomplete
    /// (the observation-starvation post-walk path). This function
    /// does not re-evaluate that decision; it only enforces budget +
    /// idempotency + timing.
    private func scheduleLateRecommitIfNeeded(
        plans: [AppCascadePlan],
        generation: UInt64
    ) {
        guard cascadeGeneration == generation, isTrusted() else { return }
        guard !zOrderLateRecommitScheduled else { return }
        guard zOrderSerializedWalkCount < CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration else {
            finalizeZOrderSettlement(
                status: .unresolved,
                generation: generation,
                reason: "reobservation showed persistent drift and walk budget exhausted"
            )
            return
        }

        zOrderLateRecommitScheduled = true

        let now = CFAbsoluteTimeGetCurrent()
        let earliest = zOrderGenerationStart + CascadeZOrderSettlementTiming.lateRecommitEarliestOffset
        let delay = max(0, earliest - now)

        Log.cascade.notice(
            "Stage 3 z-order settlement: scheduling late recommit in \(Int(delay * 1000), privacy: .public)ms (walks used: \(self.zOrderSerializedWalkCount, privacy: .public)/\(CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration, privacy: .public))"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.cascadeGeneration == generation else {
                // Generation superseded between scheduling and firing.
                // Do nothing — the new generation owns its own final
                // status; ours is superseded.
                return
            }
            guard self.isTrusted() else {
                self.finalizeZOrderSettlement(
                    status: .cancelled,
                    generation: generation,
                    reason: "AX trust lost before late recommit fired"
                )
                return
            }
            self.escalateToSerializedReconstruction(
                plans: plans,
                generation: generation,
                trigger: "late recommit"
            )
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
            //
            // Enriched with `app` + `currentFrame` for the post-collect
            // partition step (see below): Chromium laggards can route
            // through native AppleScript-bounds repair when the flag
            // is on, and the async repair needs the owning app +
            // fresh current frame in scope. Non-Chromium laggards
            // ignore these extra fields — they only ever hit the
            // existing AX applyBatch path.
            var laggardMoves: [(
                axWindow: AXUIElement,
                target: CGRect,
                app: NSRunningApplication,
                currentFrame: CGRect
            )] = []
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
                        laggardMoves.append((axElement, target, plan.app, current.frame))
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
                    laggardMoves.append((axElement, target, plan.app, current.frame))
                }
            }
            // Update baseline for the next retry pass (used by the
            // OLD path stable-clamp detection).
            self.previousRetryFrames = currentObservations

            guard !laggardMoves.isEmpty else {
                Log.cascade.info(
                    "All-apps \(label, privacy: .public): skipped — already converged (\(totalChecked, privacy: .public) windows checked)"
                )
                // Even on the converged path — where no laggards need
                // to be nudged — some apps (Chrome, Messages, Terminal
                // among the observed offenders) fire a delayed auto-
                // raise in response to our earlier pass 1 setFrame.
                // That auto-raise can arrive AFTER the +300ms re-raise
                // completes and leaves one window at the wrong z-order
                // slot with no subsequent enforcement pass to correct
                // it. Passes 3 (+500ms) and 4 (+1000ms) fire the
                // observation-based z-order enforcer here — a single
                // CGWindowList read + a possible full walk when
                // needed. The observation optimizer already returns
                // "0 raise(s)" when z-order is correct, so this is a
                // near-zero cost when nothing drifted.
                //
                // Pass 4 additionally routes through the persistent-
                // drift escalation (see `runPassFourZOrderCheckpoint`):
                // if the recorded mismatch history matches the
                // "same slots keep drifting" pattern, escalate to a
                // serialized reconstruction rather than trusting yet
                // another observation-based partial correction to be
                // durable. Warm cascades where earlier checkpoints
                // already settled the order see no escalation cost —
                // persistent-drift detection requires at least two
                // consecutive non-empty checkpoints.
                if self.useExplicitCascadeZOrder {
                    if label == "pass 4" {
                        self.runPassFourZOrderCheckpoint(
                            plans: plans,
                            generation: generation,
                            context: "all-apps \(label) (converged z-recheck)"
                        )
                    } else {
                        self.intermediateZOrderCheckpoint(
                            plans: plans,
                            context: "all-apps \(label) (converged z-recheck)"
                        )
                    }
                }
                return
            }

            // Partition. Chromium-family laggards get their own AppleScript
            // `bounds` repair (persists where AX size writes revert on
            // Chrome). Non-Chromium laggards use the existing AX batch
            // exactly as before. Skip Chromium windows that already have
            // a native repair in flight — a later retry pass will
            // observe the outcome without stacking parallel writes.
            var axLaggards: [(axWindow: AXUIElement, target: CGRect)] = []
            var chromiumLaggards: [(
                axWindow: AXUIElement,
                target: CGRect,
                bundleID: String,
                currentFrame: CGRect
            )] = []
            for laggard in laggardMoves {
                let bundleID = laggard.app.bundleIdentifier
                let canUseNative = self.useBrowserNativeBoundsForCascadeLaggards
                    && (bundleID.map { BrowserScripting.supportsNativeWindowBounds(bundleID: $0) } ?? false)
                    && !self.nativeRepairIsInFlight(laggard.axWindow)
                if canUseNative, let bundleID = bundleID {
                    chromiumLaggards.append((laggard.axWindow, laggard.target, bundleID, laggard.currentFrame))
                } else {
                    axLaggards.append((laggard.axWindow, laggard.target))
                }
            }

            // Existing AX-write path — unchanged behavior. Chromium
            // laggards are simply absent from this batch when the
            // native flag is on.
            let count = WindowMutator.applyBatch(axLaggards)
            Log.cascade.info(
                "All-apps \(label, privacy: .public): \(count, privacy: .public)/\(axLaggards.count, privacy: .public) AX laggards nudged; \(chromiumLaggards.count, privacy: .public) chromium laggard(s) queued for native repair"
            )
            if count > 0 { self.onWindowsMoved?() }

            // Some apps (Chrome, Messages) auto-raise themselves when
            // their frame is set. The retry we just did may have shoved
            // one of them in front of a window that pass 1's z-order
            // enforcement had correctly placed ahead of it — producing
            // the "Finder behind Messages" reordering the user sees
            // between cascade runs. Re-enforce z-order now so the retry
            // doesn't break the stacking pass 1 established.
            //
            // Pass 4 additionally routes through persistent-drift
            // escalation on the post-write path too — the write itself
            // may have provoked the same recurring drift pattern we're
            // watching for.
            if count > 0 {
                if label == "pass 4" {
                    self.runPassFourZOrderCheckpoint(
                        plans: plans,
                        generation: generation,
                        context: "all-apps \(label) (post-write)"
                    )
                } else {
                    self.intermediateZOrderCheckpoint(plans: plans, context: "all-apps \(label) (post-write)")
                }
            }

            // Fire native repair for each Chromium laggard. Each call
            // is per-window (safe alternative from the spec's multi-
            // Chromium-window handling) — one fresh bounds enumeration
            // per repair, so no stale positional-index reuse across
            // moves. In-flight marker prevents overlap with the next
            // retry pass on the same window.
            for laggard in chromiumLaggards {
                self.markNativeRepairInFlight(laggard.axWindow, generation: generation)
                Task { [weak self] in
                    await self?.repairChromiumCascadeLaggard(
                        bundleID: laggard.bundleID,
                        axElement: laggard.axWindow,
                        currentCocoa: laggard.currentFrame,
                        targetCocoa: laggard.target,
                        generation: generation,
                        plans: plans,
                        label: label
                    )
                }
            }
        }
    }

    // MARK: - Native repair (Chromium cascade laggards)

    /// Marks a window as having a native-bounds repair in flight for
    /// the given cascade generation. Prevents subsequent retry passes
    /// from stacking parallel writes on the same window.
    private func markNativeRepairInFlight(_ axElement: AXUIElement, generation: UInt64) {
        nativeRepairInFlight.append((axElement, generation))
    }

    /// True if a native repair is currently in flight for the given
    /// AX element (regardless of generation). Comparing AXUIElement
    /// with `CFEqual` matches the pattern used elsewhere in the file
    /// (see `axElementIsInList`).
    private func nativeRepairIsInFlight(_ axElement: AXUIElement) -> Bool {
        return nativeRepairInFlight.contains { CFEqual($0.axElement, axElement) }
    }

    /// Removes any in-flight marker(s) for the given element. Called
    /// from the Task's completion path unconditionally so a failed
    /// native repair doesn't leave a stale entry that would block
    /// the next retry.
    private func clearNativeRepairInFlight(_ axElement: AXUIElement) {
        nativeRepairInFlight.removeAll { CFEqual($0.axElement, axElement) }
    }

    /// One Chromium cascade laggard's targeted repair via AppleScript
    /// bounds. Runs off-main (BrowserScripting.setBrowserWindowBoundsNearFrame
    /// dispatches the script itself to a background queue and returns
    /// to the main actor).
    ///
    /// Contract (matches spec §"Single Chromium laggard" +
    /// §"Cascade native failure" + §"Cascade settled verification"):
    ///   - Fresh AX current frame at repair time (not the frame the
    ///     retry pass captured — that value can be several hundred
    ///     ms stale by the time the Task actually runs).
    ///   - Uses the existing expected cascade target frame verbatim.
    ///   - On native success: emit onWindowsMoved + re-enforce
    ///     z-order (matches AX-path behavior after any laggard write).
    ///     Existing later retry / verify passes observe the settled
    ///     AX frame using existing tolerance and stable-clamped logic
    ///     — we do NOT add a new verify step here.
    ///   - On any structured failure: fall back to a single AX write
    ///     for this specific laggard (matches spec §"Cascade native
    ///     failure"). Do not fail the whole cascade; do not prompt.
    ///   - Generation-guarded — a Restore or new Cascade advances
    ///     `cascadeGeneration` and this Task exits without mutation.
    private func repairChromiumCascadeLaggard(
        bundleID: String,
        axElement: AXUIElement,
        currentCocoa: CGRect,
        targetCocoa: CGRect,
        generation: UInt64,
        plans: [AppCascadePlan],
        label: String
    ) async {
        // Bail if a newer operation has taken over.
        guard cascadeGeneration == generation, isTrusted() else {
            clearNativeRepairInFlight(axElement)
            return
        }
        // Fresh AX current frame — retry timing can leave `currentCocoa`
        // hundreds of ms stale, and a stale frame would cause the
        // matcher to reject or misidentify the browser window.
        let refreshedAX = AXWindowEnumerator.currentFrame(of: axElement)
        let refreshedCocoa = refreshedAX.map { CoordinateSpace.cocoaRect(fromAX: $0) } ?? currentCocoa
        let currentAX = CoordinateSpace.axRect(fromCocoa: refreshedCocoa)
        let targetAX = CoordinateSpace.axRect(fromCocoa: targetCocoa)

        let start = CFAbsoluteTimeGetCurrent()
        let result = await BrowserScripting.setBrowserWindowBoundsNearFrame(
            bundleID: bundleID,
            currentBoundsAX: currentAX,
            targetBoundsAX: targetAX
        )
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        // Always clear in-flight, whatever the outcome.
        clearNativeRepairInFlight(axElement)

        // Post-await re-check — generation may have advanced.
        guard cascadeGeneration == generation, isTrusted() else {
            Log.cascade.info(
                "Native cascade repair dropped — generation advanced (bundle=\(bundleID, privacy: .public))"
            )
            return
        }

        switch result {
        case .success:
            Log.cascade.notice(
                "All-apps \(label, privacy: .public) native repair ok: bundle=\(bundleID, privacy: .public) in \(elapsedMs, privacy: .public)ms"
            )
            onWindowsMoved?()
            // Two-phase correction-owner model: native-repair
            // callbacks are OBSERVATION-ONLY. They record what the
            // repair produced for the settlement pipeline, but do not
            // themselves issue AXRaise. Pass 4's final settlement
            // (deferred until native-repair drains) owns the
            // authoritative correction. Under the pre-fix design,
            // each of N Chromium repairs fired its own fallback full
            // walk on incomplete observation, producing 5+ visible
            // re-stacks per cascade.
            //
            // If native-repair drain plus final settlement is pending,
            // this completion also arms the resume check below via
            // `resumePendingFinalSettlementIfQuiescent`.
            if useExplicitCascadeZOrder {
                intermediateZOrderCheckpoint(
                    plans: plans,
                    context: "all-apps \(label) (native repair)"
                )
            }
            resumePendingFinalSettlementIfQuiescent(generation: generation)
        case .unsupported, .automationDenied, .permissionUnavailable,
             .browserNotRunning, .noMatch, .ambiguousMatch, .timedOut,
             .targetDisappeared, .scriptError:
            let reason = nativeCascadeFailureReason(result)
            Log.cascade.notice(
                "All-apps \(label, privacy: .public) native repair failed: bundle=\(bundleID, privacy: .public) reason=\(reason, privacy: .public) in \(elapsedMs, privacy: .public)ms — falling back to AX for this laggard"
            )
            // Single AX write for this specific laggard. Existing
            // later retry / verify passes will observe the outcome.
            _ = WindowMutator.setFrame(targetCocoa, of: axElement)
            onWindowsMoved?()
            // Observation-only under the two-phase model (same as
            // the native-success branch above).
            if useExplicitCascadeZOrder {
                intermediateZOrderCheckpoint(
                    plans: plans,
                    context: "all-apps \(label) (native failure → AX fallback)"
                )
            }
            resumePendingFinalSettlementIfQuiescent(generation: generation)
        }
    }

    private func nativeCascadeFailureReason(_ result: BrowserScripting.BrowserBoundsMoveResult) -> String {
        switch result {
        case .success: return "success"
        case .unsupported: return "unsupported"
        case .automationDenied: return "automation-denied"
        case .permissionUnavailable: return "permission-unavailable"
        case .browserNotRunning: return "browser-not-running"
        case .noMatch: return "no-match"
        case .ambiguousMatch: return "ambiguous-match"
        case .timedOut: return "timed-out"
        case .targetDisappeared: return "target-disappeared"
        case .scriptError(let msg): return "script-error(\(msg))"
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
        // Geometry portion — unchanged tolerance / classification.
        let geometryLabel: String
        if stillFailing > 0 {
            geometryLabel = "geometry=UNSETTLED (\(stillFailing)/\(totalChecked) off)"
        } else {
            geometryLabel = "geometry=settled"
        }

        // Z-order portion — reported alongside so a caller / handoff
        // developer can see at a glance whether the front-to-back
        // stack matched intent. Spec §"SEPARATE GEOMETRY AND Z-ORDER
        // STATUS": geometry alone is not sufficient for "cascade
        // fully settled." Warm cascades that never needed correction
        // land at `.settledNoCorrection`; escalated cases land at
        // `.settledSerializedReconstruction` or `.settledLateRecommit`;
        // failing cases land at `.unresolved` or
        // `.observationIncomplete`.
        //
        // If a settlement Task is still in flight at this point, the
        // status is whatever was last recorded — a subsequent Task
        // completion may promote or downgrade it as the pipeline
        // finalizes. This log is a snapshot, not a final judgment
        // for asynchronous outcomes.
        let zOrderLabel = "zOrder=\(String(describing: zOrderFinalStatus))"

        let overallSettled = (stillFailing == 0) && Self.zOrderStatusIsSettled(zOrderFinalStatus)

        if overallSettled {
            Log.cascade.info(
                "All-apps verify: all \(totalChecked, privacy: .public) window(s) at target ✓ — \(geometryLabel, privacy: .public), \(zOrderLabel, privacy: .public)"
            )
        } else if stillFailing > 0 {
            Log.cascade.error(
                "All-apps verify: \(stillFailing, privacy: .public)/\(totalChecked, privacy: .public) window(s) STILL not at target — \(geometryLabel, privacy: .public), \(zOrderLabel, privacy: .public)"
            )
        } else {
            // Geometry settled but z-order not yet in a settled
            // status. Log at .notice so it's visible but not treated
            // as a hard error — the pipeline may still be running
            // an escalation.
            Log.cascade.notice(
                "All-apps verify: \(totalChecked, privacy: .public) window(s) at target ✓ — \(geometryLabel, privacy: .public), \(zOrderLabel, privacy: .public)"
            )
        }
    }

    /// Whether the given `ZOrderFinalStatus` represents a settled
    /// outcome. All settled variants + `.staleGeneration` (superseded
    /// is a benign non-failure) qualify. Everything else is
    /// unfinished or explicitly wrong.
    /// `nonisolated` so tests can call it without a main-actor hop.
    static nonisolated func zOrderStatusIsSettled(_ status: ZOrderFinalStatus) -> Bool {
        switch status {
        case .settledNoCorrection,
             .settledObservationCorrection,
             .settledSerializedReconstruction,
             .settledLateRecommit,
             .staleGeneration:
            return true
        case .unresolved,
             .observationIncomplete,
             .unresolvedObservationIncomplete,
             .cancelled:
            return false
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
    /// Instance shim preserved so existing callers stay unchanged.
    /// Delegates to the static implementation.
    private func fitFrame(
        plannedOrigin: CGPoint,
        frameSize: CGSize,
        naturalSize: CGSize,
        bounds: CGRect
    ) -> CGRect {
        Self.fitFrame(
            plannedOrigin: plannedOrigin,
            frameSize: frameSize,
            naturalSize: naturalSize,
            bounds: bounds
        )
    }

    /// Pure origin-clamp implementation extracted for unit-testability.
    /// Same body as before; touches no instance state. `nonisolated`
    /// so tests can invoke it without a main-actor hop.
    static nonisolated func fitFrame(
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

    // MARK: - Bounded concurrent AX enumeration
    //
    // Cold All-Apps Cascade was serially calling
    // `AXWindowEnumerator.windows(of:)` for every running
    // .regular/.accessory app (~30 on the test Mac), each round-trip
    // paying 5–50 ms of cross-process AX latency plus occasional
    // 50 ms sleepy-proxy retries. Wall-clock pre-pass-1 cost was
    // ~1.5–3 seconds — the "long to react" symptom the user reported.
    //
    // This helper preserves the exact eligible-app set — every PID
    // the serial path would have queried is still queried. Only the
    // scheduling changes: up to `maxConcurrency` per-app enumerations
    // run concurrently, and results are collected into a stable
    // index-keyed array so downstream planning consumes them in the
    // exact original order (frontmost first, then alphabetical).
    //
    // Nonisolated: the tasks run on the cooperative concurrent
    // executor, not the main actor. Each task independently calls
    // `AXWindowEnumerator.windows(of:)`, which is safe to call
    // concurrently for different apps because it creates its own
    // per-call AXUIElement handle and uses no shared mutable state.
    // Results are collected on the main actor after `await` resumes.
    //
    // We use PIDs (Sendable) rather than NSRunningApplication
    // references to cross the concurrency boundary cleanly. Each
    // task reconstructs the NSRunningApplication via the standard
    // `NSRunningApplication(processIdentifier:)` initializer, which
    // is safe from any thread. If a PID has died between the
    // main-actor capture and the worker's execution, the worker
    // returns an empty result — same as if the app had zero windows.
    /// Pure per-app facts the accessory prefilter needs — extracted
    /// from `NSRunningApplication` so the classifier is unit-testable
    /// without a live workspace. `pid` is the AX enumeration key,
    /// `bundleID` is the bypass-set key, `policy` drives the branch.
    struct PrefilterAppFacts: Equatable {
        let pid: pid_t
        let bundleID: String
        let policy: NSApplication.ActivationPolicy
    }

    /// Pure classification result. `pidsForAXCall.count == apps.count`
    /// and index-aligned — a `.some(pid)` at position i means "AX
    /// enumerate this app", `.none` means "skip and treat as []".
    /// Counts are diagnostics for the enumeration log line.
    struct PrefilterClassification: Equatable {
        let pidsForAXCall: [pid_t?]
        let regularCount: Int
        let accessoryCount: Int
        let accessoryCGPositiveCount: Int
        let accessorySkippedCGNegativeCount: Int
        let accessoryBypassedCount: Int

        var axEnumeratedCount: Int {
            pidsForAXCall.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        }
    }

    /// Pure classifier: partition eligible apps into AX-enumerate vs
    /// skip. See the block comment above `useAccessoryCGNegativePrefilter`
    /// for the decision matrix. Extracted so the branch logic can be
    /// unit-tested against fixtures (regular CG-negative, accessory
    /// CG-positive, accessory CG-negative, bypassed, CG-failure, etc.)
    /// without needing a live NSWorkspace / live AX / live CG.
    ///
    /// Preserves input order — critical because the returned array is
    /// index-aligned with the caller's `runningApps` array, which drives
    /// deterministic anchor / alphabetical ordering downstream.
    nonisolated static func classifyEligibleApps(
        apps: [PrefilterAppFacts],
        cgSnapshot: CGWindowSnapshot,
        bypassSet: Set<String>
    ) -> PrefilterClassification {
        var pidsForAXCall: [pid_t?] = []
        pidsForAXCall.reserveCapacity(apps.count)
        var regularCount = 0
        var accessoryCount = 0
        var accessoryCGPositiveCount = 0
        var accessorySkippedCGNegativeCount = 0
        var accessoryBypassedCount = 0

        for app in apps {
            switch app.policy {
            case .regular:
                // Always AX — protects Notes / Podcasts / Grammarly
                // and every other .regular app regardless of CG state.
                regularCount += 1
                pidsForAXCall.append(app.pid)

            case .accessory:
                accessoryCount += 1
                if bypassSet.contains(app.bundleID) {
                    // Escape hatch — always AX regardless of CG.
                    accessoryBypassedCount += 1
                    pidsForAXCall.append(app.pid)
                    continue
                }
                switch cgSnapshot {
                case .failure:
                    // Fail open — CG state unknown, MUST AX-enumerate.
                    pidsForAXCall.append(app.pid)
                case .success(let cgPIDs):
                    if cgPIDs.contains(app.pid) {
                        accessoryCGPositiveCount += 1
                        pidsForAXCall.append(app.pid)
                    } else {
                        accessorySkippedCGNegativeCount += 1
                        pidsForAXCall.append(nil)
                    }
                }

            default:
                // Unknown / prohibited activation policies — the outer
                // eligibility filter already restricts to .regular +
                // .accessory. Belt-and-suspenders: if a future policy
                // leaks through, AX-enumerate rather than silently drop.
                pidsForAXCall.append(app.pid)
            }
        }

        return PrefilterClassification(
            pidsForAXCall: pidsForAXCall,
            regularCount: regularCount,
            accessoryCount: accessoryCount,
            accessoryCGPositiveCount: accessoryCGPositiveCount,
            accessorySkippedCGNegativeCount: accessorySkippedCGNegativeCount,
            accessoryBypassedCount: accessoryBypassedCount
        )
    }

    /// Instrumented variant of `enumerateAppsBoundedConcurrent`. Returns
    /// the same per-app-window results plus `BoundedConcurrentMapMetrics`
    /// that the caller uses to log the actually-observed peak parallelism
    /// and the top-N slowest apps by AX round-trip duration. Purely
    /// diagnostic — never influences result ordering, filtering, or
    /// downstream cascade behavior.
    ///
    /// Accepts an optional-pid array so the accessory CG-negative
    /// prefilter can pass `.none` for skipped positions. Skipped entries
    /// return `[]` without making an AX call — the array shape is
    /// preserved so the caller's downstream `for (index, app) in
    /// runningApps.enumerated()` loop can still read
    /// `perAppWindows[index]` at the correct offset. Peak-in-flight
    /// still reflects only the real AX calls (skipped positions don't
    /// occupy worker slots meaningfully; they resolve immediately).
    nonisolated private static func enumerateAppsBoundedConcurrentWithMetrics(
        pidsOrSkip: [pid_t?],
        maxConcurrency: Int
    ) async -> (perApp: [[EnumeratedWindow]], metrics: BoundedConcurrentMapMetrics) {
        let (results, metrics) = await BoundedConcurrentMap.mapWithMetrics(
            pidsOrSkip, maxConcurrency: maxConcurrency
        ) { (maybePid: pid_t?) -> [EnumeratedWindow] in
            guard let pid = maybePid else { return [] }
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                return []
            }
            return AXWindowEnumerator.windows(of: app)
        }
        return (results, metrics)
    }
}
