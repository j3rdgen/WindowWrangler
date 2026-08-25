//
//  BrowserScripting.swift
//  Window Wrangler
//
//  Reads (and later, restores) browser tabs via AppleScript. The
//  Corral save flow calls into this module for each selected window
//  whose owning app is a supported browser; the module returns the
//  list of tabs (URL + title) if the browser is running and the
//  window bounds match, or nil otherwise.
//
//  Two browser families are supported directly:
//
//  - The Chromium family (Chrome, Brave, Edge, Opera, Vivaldi,
//    Chromium itself) all share the same AppleScript vocabulary:
//    `windows`, `tabs of window`, `URL of tab`, `title of tab`,
//    `bounds of window`. One code path serves them all; the only
//    thing that varies is the app name we `tell` to.
//
//  - Safari has its own dictionary. Similar shape but uses `name of
//    tab` instead of `title of tab` and `name of window` instead of
//    `title of window`. Handled with a separate script string.
//
//  Arc and other niche browsers aren't supported here — if their
//  bundle-ID isn't in the recognized set, `captureTabs` returns nil
//  and the Corral is saved without tab data for those members. That
//  window will still be restored to its saved frame; only the
//  reopen-with-tabs path is unavailable.
//
//  Permission model: the first call to any AppleScript that targets
//  a foreign app triggers macOS's Automation-permission prompt. We
//  don't pre-request; the prompt fires exactly when the user first
//  saves a corral that includes a browser window, so the context is
//  obvious. On denial we log and return nil — the save proceeds
//  without tab data rather than failing.
//

import AppKit
import CoreGraphics
import Foundation
import os

enum BrowserScripting {

    // MARK: - Public API

    /// One browser window's contents, as returned by AppleScript.
    /// `boundsAX` is in AX top-left global coordinates (matches what
    /// AppleScript's `bounds of window` returns) so callers convert
    /// once when they want to compare against Cocoa selection frames.
    /// `internalID` is Chrome's / Safari's `id of window` — stable
    /// across enumerations, used by `moveBrowserWindow` to reposition
    /// this specific window without depending on frame-match against
    /// the AX proxy (which can disagree with AppleScript bounds by
    /// several points and cause false-negative matches).
    struct BrowserWindowSnapshot: Sendable {
        let internalID: Int
        let boundsAX: CGRect
        let tabs: [TabInfo]
    }

    // MARK: - Snapshot cache (main-actor-guarded)

    /// Per-bundle-ID snapshot cache. Populated by `prefetchAllBrowsers`
    /// on a background thread and read on main by
    /// `snapshotBrowserWindows`. Keeps main-thread saves fast: if the
    /// user just toggled lasso mode on, the browser data is ready
    /// before they hit ⌃⌥⌘S, so save doesn't wait on AppleScript.
    @MainActor
    private static var snapshotCache: [String: (snapshot: [BrowserWindowSnapshot], capturedAt: CFAbsoluteTime)] = [:]

    /// How long a cached snapshot is considered fresh. 15s covers the
    /// typical "toggle lasso → drag-select → hit save" window with
    /// margin. Stale entries fall back to a synchronous fetch.
    private static let cacheMaxAge: CFAbsoluteTime = 15

    /// Bundle IDs currently being prefetched. Prevents duplicate
    /// concurrent AppleScript fetches for the same browser when the
    /// coordinator reschedules a prefetch back-to-back.
    @MainActor
    private static var prefetchesInFlight: Set<String> = []

    /// When true, prefetch completions stash their results in
    /// `pendingPrefetchResults` rather than writing directly to the
    /// snapshot cache. Set by LassoCoordinator during an active
    /// interaction so the completion's main-thread cache write can't
    /// stall an in-progress drag redraw. Cleared (and pending
    /// results flushed) by `flushPendingPrefetchResults()` at
    /// interaction end.
    @MainActor
    static var deferPrefetchCommits: Bool = false

    /// Prefetch completions that arrived while `deferPrefetchCommits`
    /// was true. Committed via `flushPendingPrefetchResults()`.
    @MainActor
    private static var pendingPrefetchResults: [String: [BrowserWindowSnapshot]] = [:]

    /// Bundle IDs that respond to the standard Chromium AppleScript
    /// dictionary. All five commercial Chromium-based browsers use
    /// the same command set, so one script serves them all.
    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    /// Safari bundle ID.
    static let safariBundleID: String = "com.apple.Safari"

    /// True if this app is a browser we know how to script.
    static func isSupportedBrowser(bundleID: String) -> Bool {
        return chromiumBundleIDs.contains(bundleID) || bundleID == safariBundleID
    }

    // MARK: - Native window-bounds transport (Plot + Cascade)
    //
    // Public entry points used by PlotCoordinator and CascadeOrchestrator
    // to set a Chromium-family browser window's frame via AppleScript
    // `set bounds` instead of AX. Rationale: Chrome (and other Chromium
    // browsers) asynchronously revert AX size writes on their next
    // runloop tick, restoring their persisted preferred size. The
    // AppleScript `bounds` write goes through the browser's Apple
    // Event handler and — per the codebase's production usage in
    // Corral restore (see `moveBrowserWindow`) — is not subject to
    // the same revert loop.
    //
    // This is a TRANSPORT — not a geometry decision, not a rewrite of
    // Plot or Cascade. Callers pass the target frame they already
    // computed; this module handles browser identification and the
    // AppleScript round-trip. Callers must gate on
    // `supportsNativeWindowBounds` first and be prepared to fall back
    // to AX on any structured failure.

    /// Interactive timeout for a Plot / Cascade native-bounds call.
    /// Shorter than Corral's 5s: these paths are interactive and a
    /// hung script must not stall the user's next action. Callers
    /// may pass a smaller value when nested inside a tighter budget.
    /// `nonisolated` so it can be used as a default parameter value
    /// on @MainActor methods without an isolation-inheritance warning.
    nonisolated static let nativeBoundsTimeout: TimeInterval = 1.5

    /// Center-distance tolerance used by the pure matcher. Matches
    /// `snapshotBrowserWindowNearFrame`'s tolerance (12pt); consistent
    /// AX-vs-AppleScript rounding drift absorption. Multiplied by 4
    /// to derive the accept threshold (~48pt center distance =
    /// ~34pt per axis at 45°).
    nonisolated static let nativeBoundsMatchTolerance: CGFloat = 12

    /// If the second-best candidate is within this margin of the
    /// best, the match is rejected as ambiguous. Prevents moving
    /// the wrong Chrome window when two are close together.
    nonisolated static let nativeBoundsAmbiguityMargin: CGFloat = 6

    /// Centralized supported-browser check. PlotCoordinator and
    /// CascadeOrchestrator MUST NOT duplicate `chromiumBundleIDs` —
    /// call this instead. Safari intentionally excluded: Safari's
    /// AX writes are already reliable, so no native fallback is
    /// needed and the same behavior would only add code paths.
    static func supportsNativeWindowBounds(bundleID: String) -> Bool {
        return chromiumBundleIDs.contains(bundleID)
    }

    /// Outcome of a single-window native bounds write. Callers switch
    /// on this rather than parse log strings.
    enum BrowserBoundsMoveResult: Sendable, Equatable {
        case success(elapsed: TimeInterval)
        case unsupported
        case automationDenied
        case permissionUnavailable
        case browserNotRunning
        case noMatch
        case ambiguousMatch
        case timedOut
        case targetDisappeared
        case scriptError(String)
    }

    /// Pure-matcher outcome — separate from BrowserBoundsMoveResult
    /// so the matcher stays unit-testable without the async transport
    /// surface. Kept internal to the module.
    enum BrowserBoundsMatch: Equatable {
        case confident(index: Int)
        case noMatch
        case ambiguous
    }

    /// PURE matcher — no AX calls, no AppleScript, no I/O. Given a
    /// requested AX frame and the browser's fresh bounds list, returns
    /// a confident single match, ambiguous, or noMatch. Testable in
    /// isolation.
    ///
    /// Rules (all four must pass for a confident match):
    ///   1. At least one candidate exists.
    ///   2. The best (nearest center-distance) candidate is within
    ///      `nativeBoundsMatchTolerance * 4` of the request.
    ///   3. The second-best candidate is either absent, beyond
    ///      threshold, OR farther than the best by at least
    ///      `nativeBoundsAmbiguityMargin`.
    ///   4. No two candidates within threshold have indistinguishable
    ///      bounds — if they do, we cannot tell them apart even by
    ///      index and MUST reject as ambiguous.
    ///
    /// Duplicate-detection is scoped to "candidates within accept
    /// threshold" — two identical windows far from the request don't
    /// contaminate a clear single match closer to it.
    static func matchBrowserWindow(
        requestedAX: CGRect,
        candidates: [(index: Int, boundsAX: CGRect)]
    ) -> BrowserBoundsMatch {
        guard !candidates.isEmpty else { return .noMatch }
        let threshold = max(nativeBoundsMatchTolerance * 4, 50)
        // Score every candidate.
        let scored = candidates
            .map { (index: $0.index, bounds: $0.boundsAX,
                    distance: nativeBoundsCenterDistance($0.boundsAX, requestedAX)) }
            .sorted { $0.distance < $1.distance }
        let withinThreshold = scored.filter { $0.distance <= threshold }
        // Rule 4: duplicate bounds inside the accept set → ambiguous.
        for i in 0..<withinThreshold.count {
            for j in (i+1)..<withinThreshold.count {
                if nativeBoundsRectsIndistinguishable(withinThreshold[i].bounds,
                                                     withinThreshold[j].bounds) {
                    return .ambiguous
                }
            }
        }
        guard let best = scored.first, best.distance <= threshold else {
            return .noMatch
        }
        if scored.count >= 2 {
            let second = scored[1]
            if second.distance <= threshold
                && (second.distance - best.distance) < nativeBoundsAmbiguityMargin {
                return .ambiguous
            }
        }
        return .confident(index: best.index)
    }

    /// One requested move for a batch native-bounds call. Kept
    /// deliberately narrow — callers pass AX frames, not AX elements,
    /// so the transport layer never touches AX.
    struct BrowserBoundsMove: Sendable {
        /// Fresh AX-space current frame of the AX window to move.
        /// MUST be captured just before the batch call; a stale frame
        /// will match the wrong browser window or nothing at all.
        let currentBoundsAX: CGRect
        /// AX-space target frame to write.
        let targetBoundsAX: CGRect
        /// Opaque caller-owned tag returned in the per-move outcome
        /// so the caller correlates results back to their planned
        /// target without depending on our matching internals.
        let clientTag: Int
    }

    /// Per-move outcome for a batch call.
    struct BrowserBoundsMoveOutcome: Sendable {
        let clientTag: Int
        let result: BrowserBoundsMoveResult
    }

    /// Sets a single Chromium browser window's bounds via AppleScript.
    /// Non-blocking (dispatches AppleScript to a background thread via
    /// `runScriptAsync`). Returns a structured result — callers must
    /// NOT parse the diagnostic logs.
    ///
    /// Contract (each guard fails-safe, returning a distinct result):
    ///   1. Bundle must be supported (chromiumBundleIDs).
    ///   2. Automation permission must be `granted` (checked with
    ///      askIfNeeded=false — will NOT prompt).
    ///   3. Browser must be running.
    ///   4. Fresh bounds-only enumeration (bypasses the 15s snapshot
    ///      cache used by Corral) matches the caller's current AX
    ///      frame to exactly one browser window (rejects ambiguity).
    ///   5. Confident match → apply bounds via AppleScript in the
    ///      same contained operation. The positional browser index
    ///      is used within THIS call only — never retained across
    ///      delays or exposed as a durable identity.
    ///
    /// Does NOT:
    ///   - Fetch tabs (bounds only).
    ///   - Read from or write to the snapshot cache.
    ///   - Mutate AX.
    ///   - Block the main thread.
    ///   - Prompt for permission.
    @MainActor
    static func setBrowserWindowBoundsNearFrame(
        bundleID: String,
        currentBoundsAX: CGRect,
        targetBoundsAX: CGRect,
        timeout: TimeInterval = nativeBoundsTimeout
    ) async -> BrowserBoundsMoveResult {
        let start = CFAbsoluteTimeGetCurrent()

        // Guard 1: bundle support.
        guard supportsNativeWindowBounds(bundleID: bundleID) else {
            return .unsupported
        }

        // Guard 2: Automation permission — do NOT prompt at Plot /
        // Cascade time. Onboarding requests permission for every
        // installed browser; if the user denied then, we degrade
        // gracefully instead of surfacing a modal mid-interaction.
        switch AutomationPermission.check(bundleID: bundleID, askIfNeeded: false) {
        case .granted:
            break
        case .denied:
            return .automationDenied
        case .notAvailable, .other:
            return .permissionUnavailable
        }

        // Guard 3: browser process running.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            return .browserNotRunning
        }

        // Enumerate. Try the whose-filter shortcut first (evaluated
        // server-side in the browser — no client-side iteration). Fall
        // back to a bounds-only walk if the shortcut misses. Both
        // scripts fetch NO tabs and NO cache is consulted.
        let candidates = await freshBoundsEnumeration(
            bundleID: bundleID,
            targetAX: currentBoundsAX,
            deadline: start + timeout
        )
        let elapsedAfterEnum = CFAbsoluteTimeGetCurrent() - start
        if elapsedAfterEnum >= timeout {
            return .timedOut
        }
        guard let list = candidates else {
            return .scriptError("bounds enumeration returned nil")
        }
        guard !list.isEmpty else {
            return .noMatch
        }

        // Pure match — rejects ambiguous.
        let match = matchBrowserWindow(
            requestedAX: currentBoundsAX,
            candidates: list
        )
        let windowIndex: Int
        switch match {
        case .confident(let idx):
            windowIndex = idx
        case .noMatch:
            #if DEBUG
            Log.corral.debug("Native bounds match=noMatch bundle=\(bundleID, privacy: .public) requested=(\(Int(currentBoundsAX.minX)),\(Int(currentBoundsAX.minY)) \(Int(currentBoundsAX.width))×\(Int(currentBoundsAX.height))) candidates=\(list.count, privacy: .public)")
            #endif
            return .noMatch
        case .ambiguous:
            #if DEBUG
            Log.corral.debug("Native bounds match=ambiguous bundle=\(bundleID, privacy: .public) requested=(\(Int(currentBoundsAX.minX)),\(Int(currentBoundsAX.minY)) \(Int(currentBoundsAX.width))×\(Int(currentBoundsAX.height))) candidates=\(list.count, privacy: .public)")
            #endif
            return .ambiguousMatch
        }

        // Write bounds. Positional index scoped to this call only.
        let writeSource = nativeBoundsWriteScript(
            bundleID: bundleID,
            windowIndex: windowIndex,
            targetAX: targetBoundsAX
        )
        let elapsedBeforeWrite = CFAbsoluteTimeGetCurrent() - start
        let writeBudget = max(0.2, timeout - elapsedBeforeWrite)
        let writeResult = await runScriptAsync(
            source: writeSource,
            timeoutSeconds: writeBudget
        )
        let totalElapsed = CFAbsoluteTimeGetCurrent() - start
        if writeResult == nil {
            return totalElapsed >= timeout ? .timedOut : .scriptError("bounds write returned nil")
        }
        Log.corral.info("Native bounds write ok bundle=\(bundleID, privacy: .public) windowIndex=\(windowIndex, privacy: .public) in \(Int(totalElapsed * 1000), privacy: .public)ms")
        return .success(elapsed: totalElapsed)
    }

    /// Convenience batch entry point. Per the spec's "safe alternative"
    /// for multi-Chromium-window Cascade repair: sequential per-move
    /// fresh enumeration + write. Each move is independent — a stale
    /// or ambiguous match on one window does NOT contaminate other
    /// confident matches. Each move's outcome is returned so the caller
    /// can AX-fallback per-window.
    ///
    /// Sequential rather than concurrent: AppleScript against the same
    /// browser is inherently serialized by the target's event handler,
    /// so parallel calls buy nothing and can trip the browser's own
    /// script-execution ordering.
    @MainActor
    static func setBrowserWindowBoundsBatch(
        bundleID: String,
        moves: [BrowserBoundsMove],
        timeout: TimeInterval = nativeBoundsTimeout
    ) async -> [BrowserBoundsMoveOutcome] {
        var outcomes: [BrowserBoundsMoveOutcome] = []
        outcomes.reserveCapacity(moves.count)
        for move in moves {
            let result = await setBrowserWindowBoundsNearFrame(
                bundleID: bundleID,
                currentBoundsAX: move.currentBoundsAX,
                targetBoundsAX: move.targetBoundsAX,
                timeout: timeout
            )
            outcomes.append(BrowserBoundsMoveOutcome(clientTag: move.clientTag, result: result))
        }
        return outcomes
    }

    /// Runs a bounds-only enumeration and returns `[(index, boundsAX)]`
    /// or nil on script failure. Empty result (browser has no windows)
    /// returns empty array — not nil. NEVER touches the snapshot cache.
    private static func freshBoundsEnumeration(
        bundleID: String,
        targetAX: CGRect,
        deadline: CFAbsoluteTime
    ) async -> [(index: Int, boundsAX: CGRect)]? {
        let remainingA = max(0.2, deadline - CFAbsoluteTimeGetCurrent())
        // Whose-filter shortcut — one line back on match, empty on miss.
        if let text = await runScriptAsync(
            source: boundsByFilterScript(bundleID: bundleID, targetAX: targetAX),
            timeoutSeconds: remainingA
        ), !text.isEmpty {
            let parsed = parseBoundsOnly(text)
            if !parsed.isEmpty {
                return parsed.map { (index: $0.index, boundsAX: $0.bounds) }
            }
        }
        // Fallback: bounds-only walk (capped at 8 per Chromium quirk).
        let remainingB = deadline - CFAbsoluteTimeGetCurrent()
        if remainingB <= 0 { return nil }
        guard let text = await runScriptAsync(
            source: boundsOnlyScript(bundleID: bundleID),
            timeoutSeconds: max(0.2, remainingB)
        ) else {
            return nil
        }
        // Empty is a valid enumeration (browser genuinely has no
        // scriptable windows). Return [] rather than nil so the caller
        // distinguishes "script failed" (nil) from "no windows" ([]).
        return parseBoundsOnly(text).map { (index: $0.index, boundsAX: $0.bounds) }
    }

    private static func nativeBoundsWriteScript(
        bundleID: String,
        windowIndex: Int,
        targetAX: CGRect
    ) -> String {
        let x1 = Int(targetAX.minX.rounded())
        let y1 = Int(targetAX.minY.rounded())
        let x2 = Int(targetAX.maxX.rounded())
        let y2 = Int(targetAX.maxY.rounded())
        return """
        tell application id "\(bundleID)"
            set bounds of window \(windowIndex) to {\(x1), \(y1), \(x2), \(y2)}
        end tell
        """
    }

    private static func nativeBoundsCenterDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func nativeBoundsRectsIndistinguishable(_ a: CGRect, _ b: CGRect) -> Bool {
        return abs(a.minX - b.minX) < 2
            && abs(a.minY - b.minY) < 2
            && abs(a.width  - b.width)  < 2
            && abs(a.height - b.height) < 2
    }

    /// Returns every window (bounds + tabs) reported by the browser
    /// with the given bundle ID, or nil if the browser isn't
    /// supported, isn't running, or Automation permission was denied.
    ///
    /// Fast path: if `prefetchAllBrowsers` has recently populated the
    /// cache for this bundle-ID (< 15s old), we return the cached
    /// snapshot without touching AppleScript. That's what makes the
    /// Corral save flow feel instant — the AppleScript round-trip
    /// (200–800ms on Chrome) already happened in the background when
    /// the user toggled lasso mode.
    ///
    /// Slow path: no cache / stale cache → synchronous fetch on the
    /// caller's thread. Result is written to the cache for the next
    /// call.
    @MainActor
    static func snapshotBrowserWindows(bundleID: String) -> [BrowserWindowSnapshot]? {
        // Only trust a NON-empty cache entry. An empty result — whether
        // from a genuinely-window-less browser or a background-thread
        // AppleScript quirk that returned nothing — should never be
        // treated as authoritative; we re-fetch instead. This costs a
        // small overhead in the rare "browser is legitimately empty"
        // case but prevents the poisoned-cache failure mode where an
        // early bad call blocks all subsequent tab captures for 15s.
        if let cached = cachedSnapshot(for: bundleID), !cached.isEmpty {
            Log.corral.info(
                "Browser \(bundleID, privacy: .public) tabs from cache (\(cached.count, privacy: .public) window(s))"
            )
            return cached
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            Log.corral.info(
                "Browser \(bundleID, privacy: .public) not running — skipping tab capture"
            )
            return nil
        }
        guard let snapshots = fetchSnapshot(bundleID: bundleID) else {
            return nil
        }
        // Same rule for writes: only cache a meaningful result.
        if !snapshots.isEmpty {
            snapshotCache[bundleID] = (
                snapshot: snapshots,
                capturedAt: CFAbsoluteTimeGetCurrent()
            )
        }
        return snapshots
    }

    /// Returns the cached snapshot if it's still fresh (< 15s old);
    /// nil if the cache is empty or stale. Main-actor since the cache
    /// is main-actor-guarded.
    @MainActor
    private static func cachedSnapshot(for bundleID: String) -> [BrowserWindowSnapshot]? {
        guard let entry = snapshotCache[bundleID] else { return nil }
        guard CFAbsoluteTimeGetCurrent() - entry.capturedAt < cacheMaxAge else { return nil }
        return entry.snapshot
    }

    /// Targeted snapshot — returns the single browser window whose
    /// bounds match `targetBoundsAX` (within tolerance), populated
    /// with its tabs. Two-step under the hood: (1) bounds-only
    /// enumeration (fast: no per-window tab access on Chrome's 33
    /// helper windows), (2) tabs script for just the matched index.
    ///
    /// This is the save-time entrypoint. Preferred over
    /// `snapshotBrowserWindows` for capture because it scales O(1)
    /// with tab-access cost regardless of how many total windows
    /// the browser has open.
    ///
    /// Returns nil if the browser isn't supported/running, if bounds
    /// enumeration returns empty, or if no window matches the target
    /// frame within tolerance.
    @MainActor
    static func snapshotBrowserWindowNearFrame(
        bundleID: String,
        targetBoundsAX: CGRect,
        tolerance: CGFloat = 12
    ) -> BrowserWindowSnapshot? {
        guard isSupportedBrowser(bundleID: bundleID) else { return nil }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            Log.corral.info(
                "Browser \(bundleID, privacy: .public) not running — skipping targeted snapshot"
            )
            return nil
        }

        // Step 1a: whose-filter shortcut. Ask the browser for the ONE
        // window whose bounds equals the target — evaluated server-
        // side, no client-side iteration.
        let shortcutSource = boundsByFilterScript(bundleID: bundleID, targetAX: targetBoundsAX)
        let shortStart = CFAbsoluteTimeGetCurrent()
        if let text = runScript(source: shortcutSource), !text.isEmpty {
            let list = parseBoundsOnly(text)
            let shortMs = Int((CFAbsoluteTimeGetCurrent() - shortStart) * 1000)
            if let entry = list.first {
                Log.corral.notice(
                    "Targeted snapshot: whose-filter matched window \(entry.index, privacy: .public) in \(shortMs, privacy: .public)ms"
                )
                return fetchTabsForMatch(
                    bundleID: bundleID,
                    matchIndex: entry.index,
                    matchBounds: entry.bounds
                )
            }
        }

        // Step 1b: bounds-only enumeration fallback (capped at 8).
        let start = CFAbsoluteTimeGetCurrent()
        guard let boundsText = runScript(source: boundsOnlyScript(bundleID: bundleID)), !boundsText.isEmpty else {
            Log.corral.info(
                "Targeted snapshot: bounds-only script returned empty for \(bundleID, privacy: .public)"
            )
            return nil
        }
        let boundsMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let boundsList = parseBoundsOnly(boundsText)
        Log.corral.notice(
            "Targeted snapshot: bounds-only got \(boundsList.count, privacy: .public) window(s) in \(boundsMs, privacy: .public)ms for \(bundleID, privacy: .public)"
        )

        // Step 2: find best-matching bounds. Tolerance is generous
        // because AX vs AppleScript bounds can differ by a few
        // points (title-bar coordinate conventions, subpixel
        // rounding). Score by center distance; require center within
        // `tolerance` OR corners within `tolerance` of each other.
        let target = targetBoundsAX
        var bestIndex: Int?
        var bestDistance: CGFloat = .infinity
        for entry in boundsList {
            let dx = entry.bounds.midX - target.midX
            let dy = entry.bounds.midY - target.midY
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = entry.index
            }
        }
        // Center-distance threshold: half the diagonal of the
        // target, capped — the matching window can be a few pixels
        // off but shouldn't be halfway across the screen.
        let maxDistance = max(tolerance * 4, 50)
        guard let matchIndex = bestIndex, bestDistance <= maxDistance,
              let matchBounds = boundsList.first(where: { $0.index == matchIndex })?.bounds else {
            Log.corral.info(
                "Targeted snapshot: no bounds match for target=(\(Int(target.minX), privacy: .public),\(Int(target.minY), privacy: .public) \(Int(target.width), privacy: .public)×\(Int(target.height), privacy: .public)) — best distance \(Int(bestDistance), privacy: .public)"
            )
            return nil
        }

        // Step 3: fetch tabs for the matched window only.
        return fetchTabsForMatch(
            bundleID: bundleID,
            matchIndex: matchIndex,
            matchBounds: matchBounds
        )
    }

    /// Shared step 3 for both the whose-filter shortcut and the
    /// enumeration path: run the per-window tabs script for a
    /// specific matched index, return the resulting
    /// BrowserWindowSnapshot.
    @MainActor
    private static func fetchTabsForMatch(
        bundleID: String,
        matchIndex: Int,
        matchBounds: CGRect
    ) -> BrowserWindowSnapshot? {
        let tabsSource = tabsForWindowScript(bundleID: bundleID, windowIndex: matchIndex)
        let tabStart = CFAbsoluteTimeGetCurrent()
        let tabs: [TabInfo]
        if let tabsText = runScript(source: tabsSource) {
            tabs = parseTabsForWindow(tabsText)
        } else {
            tabs = []
        }
        let tabsMs = Int((CFAbsoluteTimeGetCurrent() - tabStart) * 1000)
        Log.corral.notice(
            "Targeted snapshot: got \(tabs.count, privacy: .public) tab(s) for window \(matchIndex, privacy: .public) in \(tabsMs, privacy: .public)ms"
        )
        return BrowserWindowSnapshot(
            internalID: matchIndex,
            boundsAX: matchBounds,
            tabs: tabs
        )
    }

    /// Parses the bounds-only tab-delimited output. One line per
    /// window: `i\tx1\ty1\tx2\ty2`. Malformed lines are skipped.
    private static func parseBoundsOnly(_ text: String) -> [(index: Int, bounds: CGRect)] {
        var results: [(Int, CGRect)] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5,
                  let i = Int(parts[0]),
                  let x1 = Double(parts[1]),
                  let y1 = Double(parts[2]),
                  let x2 = Double(parts[3]),
                  let y2 = Double(parts[4]) else {
                continue
            }
            results.append((
                i,
                CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
            ))
        }
        return results
    }

    /// Parses the per-window tabs output. One line per tab:
    /// `url\ttitle` (title may include tabs if the page put one
    /// in its title, so re-join fields past index 1).
    private static func parseTabsForWindow(_ text: String) -> [TabInfo] {
        var results: [TabInfo] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let url = parts[0]
            let title = parts.dropFirst().joined(separator: "\t")
            results.append(TabInfo(url: url, title: title))
        }
        return results
    }

    /// Bundle-IDs we've explicitly checked automation permission for
    /// this session. Idempotence guard so we don't spam
    /// `AEDeterminePermissionToAutomateTarget` on every lasso toggle
    /// (macOS caches the answer but the syscall isn't free).
    @MainActor
    private static var permissionRequested: Set<String> = []

    /// Bundle-IDs the user has explicitly denied automation for.
    /// Populated when a permission check returns `.denied`. The
    /// AppDelegate reads this to decide whether to surface an alert
    /// pointing the user at System Settings.
    @MainActor
    private(set) static var deniedBundles: Set<String> = []

    /// Surfaces the macOS Automation-permission prompt for every
    /// **currently running** supported browser we haven't asked about
    /// this session. Runs synchronously on main; the browser prompt UI
    /// blocks the main runloop briefly while the user clicks OK/Don't
    /// Allow, which is fine because they're right there having just
    /// toggled lasso mode.
    @MainActor
    static func requestAutomationPermissions() {
        let running = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier }
            .filter { isSupportedBrowser(bundleID: $0) }
        requestPermissions(for: running, logPrefix: "Requesting")
    }

    /// Onboarding variant: checks every INSTALLED supported browser,
    /// not just the running ones. Called once from AppDelegate right
    /// after accessibility permission is granted, so the user gets all
    /// the prompts in one intentional burst instead of one at a time
    /// later when they toggle lasso.
    @MainActor
    static func requestAutomationPermissionsForInstalledBrowsers() {
        let installed = (Array(chromiumBundleIDs) + [safariBundleID])
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        requestPermissions(for: installed, logPrefix: "Onboarding: requesting")
    }

    /// Shared body of the two public entry points above. Filters out
    /// bundles we've already asked about this session, runs the
    /// AutomationPermission check for each remaining one, updates the
    /// denied set, and probes any granted-and-running browser to
    /// surface the "TCC says granted but scripts hang" case in the log.
    @MainActor
    private static func requestPermissions(for bundleIDs: [String], logPrefix: String) {
        let pending = bundleIDs.filter { !permissionRequested.contains($0) }
        guard !pending.isEmpty else { return }
        Log.corral.info(
            "\(logPrefix, privacy: .public) Automation permission for \(pending.count, privacy: .public) browser(s)"
        )
        for bundleID in pending {
            permissionRequested.insert(bundleID)
            switch AutomationPermission.check(bundleID: bundleID, askIfNeeded: true) {
            case .granted:
                Log.corral.info("Automation granted: \(bundleID, privacy: .public)")
                deniedBundles.remove(bundleID)
                // Only probe running browsers — a `count of windows`
                // against a non-running browser would trigger a cold
                // launch (bad UX during onboarding).
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil {
                    probeBrowserScripting(bundleID: bundleID)
                }
            case .denied:
                Log.corral.notice("Automation DENIED: \(bundleID, privacy: .public) — user must enable in System Settings")
                deniedBundles.insert(bundleID)
            case .notAvailable:
                Log.corral.info("Automation not available: \(bundleID, privacy: .public)")
            case .other(let err):
                Log.corral.error("Automation permission check error \(err, privacy: .public) for \(bundleID, privacy: .public)")
            }
        }
    }

    /// Runs `count of windows` against the browser and logs the
    /// result + timing. Diagnoses the "TCC reports granted but real
    /// scripts hang or return empty" state (usually a stale TCC record
    /// from repeated dev-build resigning).
    @MainActor
    private static func probeBrowserScripting(bundleID: String) {
        let source = "tell application id \"\(bundleID)\" to return (count of windows) as string"
        let start = CFAbsoluteTimeGetCurrent()
        let result = runScript(source: source)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        Log.corral.notice(
            "Probe \(bundleID, privacy: .public): result='\(result ?? "nil", privacy: .public)' in \(elapsedMs, privacy: .public)ms"
        )
    }

    /// Fires off a background snapshot for every running supported
    /// browser, populating the cache when each completes. The Corral
    /// save flow's frontend cache read (`snapshotBrowserWindows`) will
    /// then hit the fresh data instead of blocking on AppleScript.
    ///
    /// Fire-and-forget. Returns immediately. Called from
    /// `LassoCoordinator.toggleLassoMode` when lasso mode turns on —
    /// by the time the user finishes drag-selecting and hits ⌃⌥⌘S,
    /// the browser snapshots are already sitting in the cache.
    @MainActor
    static func prefetchAllBrowsers() {
        // Ensure macOS has decided about our permission to script each
        // browser BEFORE we try to snapshot anything. Without this the
        // background prefetch silently returns empty (undecided
        // permission looks the same as "no windows"), we don't cache,
        // save falls back to sync, sync ALSO silently returns empty,
        // and Chrome ends up in the corral without any tabs.
        requestAutomationPermissions()
        // Snapshot the running-browser bundle IDs on main; NSWorkspace
        // is main-thread-preferred. Background thread does the fetch.
        let browsersToFetch: [String] = NSWorkspace.shared.runningApplications
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      isSupportedBrowser(bundleID: bundleID) else { return nil }
                return bundleID
            }
        guard !browsersToFetch.isEmpty else { return }

        Log.corral.info(
            "Prefetching \(browsersToFetch.count, privacy: .public) browser(s) in background"
        )
        for bundleID in browsersToFetch {
            // NSAppleScript.executeAndReturnError on a background
            // thread is not officially supported but works in practice
            // for Chrome/Safari — empty results (which we don't cache)
            // are the observed failure mode, not crashes.
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = fetchSnapshot(bundleID: bundleID)
                guard let snapshot, !snapshot.isEmpty else {
                    // Never cache an empty prefetch result. The save
                    // path will re-fetch synchronously and get real
                    // data even if this background call misfired.
                    Log.corral.info(
                        "Prefetch \(bundleID, privacy: .public) returned empty — not cached"
                    )
                    return
                }
                DispatchQueue.main.async {
                    snapshotCache[bundleID] = (
                        snapshot: snapshot,
                        capturedAt: CFAbsoluteTimeGetCurrent()
                    )
                    Log.corral.info(
                        "Prefetched \(bundleID, privacy: .public) — \(snapshot.count, privacy: .public) window(s)"
                    )
                }
            }
        }
    }

    /// Targeted prefetch — only the given bundle IDs. Skips browsers
    /// that are (a) unsupported, (b) not running, (c) already fresh
    /// in the cache, or (d) already in-flight.
    ///
    /// Never requests Automation permission — assumes onboarding
    /// handled it. Callers pass this from the LassoCoordinator's
    /// idle-aware scheduler; it fires shortly after a lasso
    /// interaction ends and only for browsers whose windows are
    /// actually in the current selection.
    ///
    /// Why not just call `prefetchAllBrowsers`: that function
    /// prefetches every running browser AND runs the automation-
    /// permission prompt path, which can prompt macOS to display a
    /// TCC dialog. Neither is appropriate for the mid-lasso idle
    /// scheduler.
    @MainActor
    static func prefetchBrowsers(bundleIDs: Set<String>) {
        var toFetch: [String] = []
        for bundleID in bundleIDs {
            guard isSupportedBrowser(bundleID: bundleID) else { continue }
            if prefetchesInFlight.contains(bundleID) { continue }
            if let cached = cachedSnapshot(for: bundleID), !cached.isEmpty { continue }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { continue }
            toFetch.append(bundleID)
        }
        guard !toFetch.isEmpty else { return }
        Log.corral.info(
            "Targeted prefetch: \(toFetch.count, privacy: .public) browser(s)"
        )
        for bundleID in toFetch {
            prefetchesInFlight.insert(bundleID)
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = fetchSnapshot(bundleID: bundleID)
                DispatchQueue.main.async {
                    prefetchesInFlight.remove(bundleID)
                    guard let snapshot, !snapshot.isEmpty else {
                        Log.corral.info(
                            "Targeted prefetch \(bundleID, privacy: .public) returned empty — not cached"
                        )
                        return
                    }
                    // Defer cache write during active interactions —
                    // a main-thread dictionary write here can stall
                    // an in-progress drag redraw (this is exactly
                    // the class of "AppleScript completion touches
                    // main mid-drag" jitter we're avoiding).
                    if deferPrefetchCommits {
                        pendingPrefetchResults[bundleID] = snapshot
                        Log.corral.info(
                            "Prefetch \(bundleID, privacy: .public) deferred (interaction in progress) — \(snapshot.count, privacy: .public) window(s)"
                        )
                    } else {
                        snapshotCache[bundleID] = (
                            snapshot: snapshot,
                            capturedAt: CFAbsoluteTimeGetCurrent()
                        )
                        Log.corral.info(
                            "Prefetched \(bundleID, privacy: .public) — \(snapshot.count, privacy: .public) window(s)"
                        )
                    }
                }
            }
        }
    }

    /// Commits any prefetch results that arrived while
    /// `deferPrefetchCommits` was true. Called by the coordinator at
    /// interaction end (after clearing `deferPrefetchCommits`).
    /// Unconditional — safe to call even with nothing pending.
    @MainActor
    static func flushPendingPrefetchResults() {
        guard !pendingPrefetchResults.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        for (bundleID, snapshot) in pendingPrefetchResults {
            snapshotCache[bundleID] = (snapshot: snapshot, capturedAt: now)
        }
        Log.corral.info(
            "Flushed \(pendingPrefetchResults.count, privacy: .public) deferred prefetch(es) to cache"
        )
        pendingPrefetchResults.removeAll(keepingCapacity: true)
    }

    // MARK: - Restore

    /// Opens a new browser window with the given tabs at the given
    /// AX-space bounds. Used by the Corral restore path when no
    /// existing browser window matches the saved tab set (either
    /// because the user closed it or because the browser wasn't
    /// running at save time and has now been launched fresh).
    ///
    /// Returns true on success. The window is created AND positioned
    /// entirely via AppleScript in one round-trip — Chromium
    /// browsers' scripting dictionary exposes `set bounds of window`
    /// which is more reliable than trying to hunt down the new
    /// window via AX afterwards and mutate it that way (Chrome's AX
    /// proxy can lag behind the newly-created window).
    ///
    /// Chromium-only for now. Safari and Arc get "position matched
    /// or nothing" behavior — safe fallback.
    @MainActor
    static func openBrowserWindow(
        bundleID: String,
        tabs: [TabInfo],
        boundsAX: CGRect
    ) -> Bool {
        guard chromiumBundleIDs.contains(bundleID) else {
            Log.corral.info(
                "openBrowserWindow: \(bundleID, privacy: .public) not supported for tab restore — skipping"
            )
            return false
        }
        let source = openChromiumWindowScript(bundleID: bundleID, tabs: tabs, boundsAX: boundsAX)
        return runScript(source: source) != nil
    }

    /// Chromium AppleScript that creates a new window, ensures it
    /// contains exactly the saved tabs (dropping any auto-restored
    /// tabs that would otherwise sneak in), and positions it via
    /// `set bounds of window`.
    ///
    /// Chromium's `make new window` typically creates a window with
    /// one "New Tab Page" tab, but some user settings (e.g.
    /// "restore last session") can produce a window with several
    /// tabs. The `close` loop below trims down to a single tab
    /// before we replace its URL with the first saved tab, then
    /// appends the rest.
    nonisolated private static func openChromiumWindowScript(
        bundleID: String,
        tabs: [TabInfo],
        boundsAX: CGRect
    ) -> String {
        let x1 = Int(boundsAX.minX.rounded())
        let y1 = Int(boundsAX.minY.rounded())
        let x2 = Int(boundsAX.maxX.rounded())
        let y2 = Int(boundsAX.maxY.rounded())

        // No-tabs fallback: just create a blank window at the target
        // bounds. Rare — a browser member should almost always have
        // tabs — but defensive.
        guard let firstTab = tabs.first else {
            return """
            tell application id "\(bundleID)"
                set newWin to make new window
                set bounds of newWin to {\(x1), \(y1), \(x2), \(y2)}
            end tell
            """
        }

        // No `activate` — activating Chrome when its front window is
        // on another Space causes a visible Space flip before the new
        // window lands.
        var lines: [String] = []
        lines.append("tell application id \"\(bundleID)\"")
        lines.append("    set newWin to make new window")
        // Trim down to a single tab in case Chrome opened with more.
        lines.append("    repeat while (count of tabs of newWin) > 1")
        lines.append("        close tab 2 of newWin")
        lines.append("    end repeat")
        lines.append("    set URL of active tab of newWin to \"\(escapeForAppleScript(firstTab.url))\"")
        for tab in tabs.dropFirst() {
            lines.append("    tell newWin")
            lines.append("        make new tab at end of tabs with properties {URL:\"\(escapeForAppleScript(tab.url))\"}")
            lines.append("    end tell")
        }
        lines.append("    set bounds of newWin to {\(x1), \(y1), \(x2), \(y2)}")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Escapes a string for safe inclusion inside AppleScript
    /// double-quoted string literals. Backslashes first (so we
    /// don't double-escape the ones we introduce for quotes).
    nonisolated private static func escapeForAppleScript(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Snapshot fetch

    /// Nonisolated core of the AppleScript fetch. Called from both the
    /// synchronous main-thread path (cache miss on save) and the
    /// background prefetch path. Doesn't touch main-actor state.
    nonisolated private static func fetchSnapshot(
        bundleID: String
    ) -> [BrowserWindowSnapshot]? {
        guard isSupportedBrowser(bundleID: bundleID) else { return nil }
        let source = fullSnapshotScript(bundleID: bundleID)
        guard let text = runScript(source: source) else { return nil }
        return parseSnapshot(text)
    }

    // MARK: - Script sources

    /// AppleScript that walks the browser's windows and tabs, emits
    /// a tab-delimited text stream, and returns it as one string.
    /// Format:
    ///
    ///     W\tID\tx1\ty1\tx2\ty2\n     one line per window
    ///     T\turl\ttitle\n              one line per tab, following
    ///                                  the W line for its window
    ///
    /// Addresses the target by **bundle ID** (`application id "…"`)
    /// rather than name (`application "…"`). Bundle-ID addressing
    /// bypasses AppleScript's name-lookup step, which some Chrome
    /// installs have been observed to hang inside for 7–8 seconds
    /// before silently returning empty. It's also more precise
    /// when multiple Chromium browsers of the same family are
    /// installed side-by-side.
    ///
    /// Uses index-based iteration (`repeat with i from 1 to count
    /// of windows`) rather than `repeat with w in windows` so we
    /// never call `id of w` — that property returned unusual values
    /// on some Chrome versions and caused the whole script to error
    /// out silently, indistinguishable from "no windows" downstream.
    // MARK: Script builders
    //
    // Chromium and Safari share the same AppleScript vocabulary for
    // windows, tabs, and bounds; they differ only in the tab-title
    // property name — Chromium uses `title of tab`, Safari uses
    // `name of tab`. All builders below take a `tabTitleProperty`
    // and route through the same template.
    //
    // Every script declares `tabCh` (ASCII 9) and `lf` (ASCII 10)
    // OUTSIDE the tell block. Inside a Chromium/Safari tell, the
    // identifier `tab` refers to the browser's `tab` class object
    // (browsers model tabs as first-class AppleScript objects), NOT
    // AppleScript's built-in tab-character constant. Writing bare
    // `tab` as a separator would coerce to the literal string "tab"
    // and break parsing — see CLAUDE.md's parking-lot entry.
    //
    // The 8-window cap exists because Chromium's `windows` collection
    // includes 25+ hidden helper windows (extensions popups, devtools,
    // PWA hosts) that reliably hang the scripting handler when walked
    // via bounds/tabs access. Chromium's `windows` is z-ordered
    // (frontmost first), so top-8 always covers user-visible browser
    // windows. The `whose bounds is {…}` shortcut has no such cap.

    private static func tabTitleProperty(for bundleID: String) -> String {
        bundleID == safariBundleID ? "name" : "title"
    }

    private static func fullSnapshotScript(bundleID: String) -> String {
        let tabTitle = tabTitleProperty(for: bundleID)
        return """
        set tabCh to (ASCII character 9)
        set lf to (ASCII character 10)
        tell application id "\(bundleID)"
            set out to ""
            set winCount to count of windows
            if winCount > 8 then set winCount to 8
            repeat with i from 1 to winCount
                try
                    set w to window i
                    set b to bounds of w
                    set out to out & "W" & tabCh & (i as string) & tabCh & ((item 1 of b) as string) & tabCh & ((item 2 of b) as string) & tabCh & ((item 3 of b) as string) & tabCh & ((item 4 of b) as string) & lf
                    try
                        set tabCount to count of tabs of w
                        repeat with j from 1 to tabCount
                            try
                                set aTab to tab j of w
                                set out to out & "T" & tabCh & (URL of aTab as string) & tabCh & (\(tabTitle) of aTab as string) & lf
                            end try
                        end repeat
                    end try
                end try
            end repeat
            return out
        end tell
        """
    }

    /// Bounds-only enumeration — one line per window, index + bounds,
    /// **no tab access**. Fast half of the targeted snapshot: a user
    /// with 33 Chrome windows pays the full walking cost only once
    /// per lassoed window here, and skips per-window tab access on
    /// windows we don't care about.
    ///
    /// Format: `i\tx1\ty1\tx2\ty2\n` per window (no leading tag).
    private static func boundsOnlyScript(bundleID: String) -> String {
        return """
        set tabCh to (ASCII character 9)
        set lf to (ASCII character 10)
        tell application id "\(bundleID)"
            set out to ""
            set winCount to count of windows
            if winCount > 8 then set winCount to 8
            repeat with i from 1 to winCount
                try
                    set b to bounds of window i
                    set out to out & (i as string) & tabCh & ((item 1 of b) as string) & tabCh & ((item 2 of b) as string) & tabCh & ((item 3 of b) as string) & tabCh & ((item 4 of b) as string) & lf
                end try
            end repeat
            return out
        end tell
        """
    }

    /// Surgical alternative: asks the browser for the ONE window
    /// whose bounds match `targetAX`. AppleScript evaluates the
    /// `whose` predicate server-side — no client-side iteration, no
    /// walking hidden helper windows. Returns one bounds line on
    /// match, empty on miss (caller falls back to `boundsOnlyScript`).
    private static func boundsByFilterScript(bundleID: String, targetAX: CGRect) -> String {
        let x1 = Int(targetAX.minX.rounded())
        let y1 = Int(targetAX.minY.rounded())
        let x2 = Int(targetAX.maxX.rounded())
        let y2 = Int(targetAX.maxY.rounded())
        return """
        set tabCh to (ASCII character 9)
        set lf to (ASCII character 10)
        tell application id "\(bundleID)"
            set out to ""
            try
                set matched to first window whose bounds is {\(x1), \(y1), \(x2), \(y2)}
                set idx to index of matched
                set b to bounds of matched
                set out to (idx as string) & tabCh & ((item 1 of b) as string) & tabCh & ((item 2 of b) as string) & tabCh & ((item 3 of b) as string) & tabCh & ((item 4 of b) as string) & lf
            end try
            return out
        end tell
        """
    }

    /// Fetches tabs for the single window at `windowIndex`. Format:
    /// `url\ttitle\n` per tab.
    private static func tabsForWindowScript(bundleID: String, windowIndex: Int) -> String {
        let tabTitle = tabTitleProperty(for: bundleID)
        return """
        set tabCh to (ASCII character 9)
        set lf to (ASCII character 10)
        tell application id "\(bundleID)"
            set out to ""
            try
                set w to window \(windowIndex)
                set tabCount to count of tabs of w
                repeat with j from 1 to tabCount
                    try
                        set aTab to tab j of w
                        set out to out & (URL of aTab as string) & tabCh & (\(tabTitle) of aTab as string) & lf
                    end try
                end repeat
            end try
            return out
        end tell
        """
    }

    /// Moves an already-open browser window (matched by its
    /// scripting-dictionary `id`, captured at snapshot time) to
    /// the given AX-space bounds. Used by the Corral restore path
    /// when a URL-overlap match found a Chrome window we want to
    /// reposition — no need to hunt for the corresponding AX
    /// element and go through WindowMutator, which was flaky
    /// because Chrome's AX bounds drift from its AppleScript
    /// bounds by a few points and often failed a frame match.
    @MainActor
    static func moveBrowserWindow(
        bundleID: String,
        windowID: Int,
        boundsAX: CGRect
    ) -> Bool {
        guard chromiumBundleIDs.contains(bundleID) || bundleID == safariBundleID else {
            return false
        }
        let x1 = Int(boundsAX.minX.rounded())
        let y1 = Int(boundsAX.minY.rounded())
        let x2 = Int(boundsAX.maxX.rounded())
        let y2 = Int(boundsAX.maxY.rounded())
        // `windowID` here carries the window's INDEX within the
        // fresh snapshot the restore path just took. We use `window
        // \(i)` (positional) instead of `window id \(X)` (identity)
        // because our snapshot script no longer captures the real
        // scripting-dictionary `id` — accessing that property was
        // observed causing some Chrome installs' AppleScript
        // handler to error out silently and return "" from an
        // otherwise-valid script. Positional addressing works here
        // because the snapshot-then-move pair happens within a few
        // hundred milliseconds; user-driven window reordering in
        // that window is vanishingly unlikely.
        let source = """
        tell application id "\(bundleID)"
            set bounds of window \(windowID) to {\(x1), \(y1), \(x2), \(y2)}
        end tell
        """
        return runScript(source: source) != nil
    }

    // MARK: - Execution

    /// Compiles and runs the given AppleScript source via
    /// `NSAppleScript`. Returns the script's stringValue on success,
    /// nil on any error.
    ///
    /// Runs in-process so macOS's TCC (Automation) permission is
    /// evaluated against Window Wrangler's own binary — which has
    /// `NSAppleEventsUsageDescription` in Info.plist and gets the
    /// "control Chrome?" prompt on first use. We tried spawning
    /// `/usr/bin/osascript` for background-thread safety, but osascript
    /// is a separate binary and its TCC record is separate from ours:
    /// even with all the right Info.plist keys, spawned osascript
    /// silently hangs when it tries to talk to Chrome because *it*
    /// doesn't have the permission the user granted to Window Wrangler.
    /// In-process NSAppleScript is the correct path.
    ///
    /// NSAppleScript is documented as main-thread-only. Callers on
    /// background threads (`prefetchAllBrowsers` in particular) may
    /// see empty output that we defensively don't cache — the next
    /// synchronous call from the main-thread save flow will fetch
    /// real data.
    nonisolated private static func runScript(source: String) -> String? {
        return runScriptWithTimeout(source: source, timeoutSeconds: 5)
    }

    /// Runs an AppleScript with a hard wall-clock timeout enforced
    /// via a dispatched background execution + semaphore wait. Returns
    /// nil if the script hasn't produced a result within
    /// `timeoutSeconds`.
    ///
    /// Rationale: `NSAppleScript.executeAndReturnError` blocks the
    /// calling thread until the target app responds. Chrome (and other
    /// scripting targets in an unhappy TCC state) has been observed
    /// hanging indefinitely on save-time scripts, freezing our whole
    /// app because the caller is on the main thread. This wrapper
    /// caps the freeze at `timeoutSeconds` regardless of what Chrome
    /// does, so the save flow can gracefully degrade to "no tabs
    /// captured" instead of "app has to be killed."
    ///
    /// NSAppleScript is officially documented as main-thread-only,
    /// but the failure mode of running it on a background dispatch
    /// queue is "may return empty" — which we already tolerate (empty
    /// results are rejected by the callers' filters). That's a better
    /// failure mode than freezing the app.
    nonisolated private static func runScriptWithTimeout(source: String, timeoutSeconds: Int) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runScriptCore(source: source)
            resultBox.value = result
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
        if waitResult == .timedOut {
            Log.corral.notice(
                "AppleScript TIMED OUT after \(timeoutSeconds, privacy: .public)s — target app not responding"
            )
            return nil
        }
        return resultBox.value
    }

    /// Thread-safe result holder for the timeout wrapper. NSObject
    /// wrapper because Swift's inout-across-threads isn't legal.
    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }

    /// Async wrapper around `runScriptCore` for the native-bounds
    /// transport. Unlike `runScriptWithTimeout` (which uses
    /// semaphore.wait on the CALLING thread — blocks main), this
    /// variant returns via async continuation and dispatches
    /// AppleScript to a background QoS-userInitiated queue.
    ///
    /// Timeout races the AppleScript against `Task.sleep`. If the
    /// script wins, we return its result. If the timeout wins, we
    /// return nil — the AppleScript keeps executing in its background
    /// thread (NSAppleScript has no cancellation API) but its result
    /// is abandoned. Same behavior as `runScriptWithTimeout`'s
    /// timeout path; leaked threads clear on session end.
    ///
    /// Callable from any actor context. The AppleScript runs off-main
    /// unconditionally, so awaiting this from `@MainActor` releases
    /// main for other work during the wall-clock wait.
    nonisolated static func runScriptAsync(
        source: String,
        timeoutSeconds: TimeInterval
    ) async -> String? {
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: runScriptCore(source: source))
                    }
                }
            }
            group.addTask {
                let nanos = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The actual compile + execute + parse work. Split out from
    /// `runScript` so `runScriptWithTimeout` can call it on a
    /// background thread while the main thread waits with a cap.
    nonisolated private static func runScriptCore(source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            Log.corral.error("NSAppleScript init returned nil")
            return nil
        }
        var compileError: NSDictionary?
        if !script.compileAndReturnError(&compileError) {
            if let error = compileError {
                let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (error[NSAppleScript.errorMessage] as? String) ?? "?"
                Log.corral.error(
                    "AppleScript compile failed (\(number, privacy: .public)): \(message, privacy: .public)"
                )
            } else {
                Log.corral.error("AppleScript compile failed (no error dict)")
            }
            return nil
        }
        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let error = errorDict {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "?"
            Log.corral.error(
                "AppleScript failed (\(number, privacy: .public)): \(message, privacy: .public)"
            )
            return nil
        }
        let output = descriptor.stringValue ?? ""
        let previewLen = min(output.count, 200)
        let preview = String(output.prefix(previewLen))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        Log.corral.notice(
            "AppleScript ok: \(output.count, privacy: .public) chars, descType=\(descriptor.descriptorType, privacy: .public), preview=\(preview, privacy: .public)"
        )
        return output
    }

    /// Parses the tab-delimited snapshot format emitted by the
    /// Chromium/Safari scripts. Windows without any tabs are still
    /// returned (empty `tabs` array) so the caller can distinguish
    /// "window exists but has no tabs" from "no matching window."
    private static func parseSnapshot(_ text: String) -> [BrowserWindowSnapshot] {
        var results: [BrowserWindowSnapshot] = []
        var currentID: Int?
        var currentBounds: CGRect?
        var currentTabs: [TabInfo] = []

        func flushCurrent() {
            if let id = currentID, let bounds = currentBounds {
                results.append(BrowserWindowSnapshot(
                    internalID: id,
                    boundsAX: bounds,
                    tabs: currentTabs
                ))
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "\t")
            guard let kind = parts.first else { continue }
            switch kind {
            case "W":
                // Flush any accumulated window before starting a new one.
                flushCurrent()
                currentTabs = []
                currentBounds = nil
                currentID = nil
                // Expected: W \t id \t x1 \t y1 \t x2 \t y2 (6 fields).
                guard parts.count >= 6,
                      let id = Int(parts[1]),
                      let x1 = Double(parts[2]),
                      let y1 = Double(parts[3]),
                      let x2 = Double(parts[4]),
                      let y2 = Double(parts[5]) else {
                    continue
                }
                currentID = id
                currentBounds = CGRect(
                    x: x1,
                    y: y1,
                    width: x2 - x1,
                    height: y2 - y1
                )
            case "T":
                // parts is [T, url, title, ...maybe more tokens if the
                // title itself contained a tab character]. Rejoin
                // anything past index 2 so we don't drop title suffixes
                // that happen to include tabs.
                guard parts.count >= 3 else { continue }
                let url = parts[1]
                let title = parts.dropFirst(2).joined(separator: "\t")
                currentTabs.append(TabInfo(url: url, title: title))
            default:
                continue
            }
        }
        flushCurrent()
        return results
    }

    // MARK: - App name lookup

    /// Returns the running app's localized name for the given bundle
    /// ID, or nil if the app isn't running. AppleScript addresses
    /// apps by their localized name in the `tell` clause; the bundle
    /// ID isn't accepted by every browser's scripting bridge.
    ///
    /// Main-actor because `NSWorkspace.shared.runningApplications` is
    /// documented as main-thread-preferred. The nonisolated
    /// `fetchSnapshot` path avoids calling this — its caller passes
    /// the resolved appName in as a parameter.
    @MainActor
    private static func localizedNameForBundle(_ bundleID: String) -> String? {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == bundleID {
            if let name = app.localizedName {
                return name
            }
        }
        return nil
    }

    // MARK: - URL normalization

    /// Canonical form of a URL used for tab-set comparisons in the
    /// Corral browser restore matcher. Two URLs that render the same
    /// page should normalize to the same string.
    ///
    /// Rules:
    /// - Lowercase the scheme + host (case-insensitive per RFC 3986).
    /// - Drop the URL fragment (`#anchor`) — client-side navigation
    ///   inside a tab, not part of the destination page identity.
    /// - Preserve the path AND query — those DO change the page.
    /// - Normalize a bare-domain trailing slash: `example.com` and
    ///   `example.com/` compare equal.
    /// - Leave weak-signal URLs (`about:blank`, `chrome://newtab/`)
    ///   as their canonical string so the scorer can downweight them
    ///   via a shared-empty check.
    ///
    /// Failure mode: if URLComponents can't parse the input, return
    /// the original string lowercased — better than crashing or
    /// returning nil.
    static func normalizedURL(_ raw: String) -> String {
        // Fast path for the two common blank-page cases so the caller
        // can spot them without re-parsing.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTrim = trimmed.lowercased()
        if lowerTrim == "about:blank" { return "about:blank" }
        if lowerTrim.hasPrefix("chrome://newtab") { return "chrome://newtab/" }

        guard var components = URLComponents(string: trimmed) else {
            return lowerTrim
        }
        components.fragment = nil
        if let scheme = components.scheme {
            components.scheme = scheme.lowercased()
        }
        if let host = components.host {
            components.host = host.lowercased()
        }
        // Normalize a lone trailing slash on the path (empty path or
        // "/"). Deeper paths like "/foo/" are meaningful — leave alone.
        if components.path.isEmpty {
            // no-op: URLComponents will render "https://example.com"
        } else if components.path == "/" {
            components.path = ""
        }
        return components.string ?? lowerTrim
    }

    /// True if the URL is a weak page-identity signal (blank/newtab)
    /// that shouldn't drive matching by itself. The scorer treats
    /// these as "match padding" rather than distinctive URLs.
    static func isWeakSignalURL(_ normalized: String) -> Bool {
        return normalized == "about:blank"
            || normalized.hasPrefix("chrome://newtab")
            || normalized.hasPrefix("chrome://new-tab-page")
            || normalized.hasPrefix("edge://newtab")
    }
}

