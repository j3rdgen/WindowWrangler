//
//  TabMarkerOverlay.swift
//  Window Wrangler
//
//  Draws thin colored markers above each duplicate browser tab so the
//  user can see at a glance which tabs are the same URL. One marker
//  per duplicate tab, color-grouped by normalized URL.
//
//  Design intent (per project discussion):
//  - Markers sit ABOVE each duplicate tab in the title-bar whitespace,
//    not over the tab itself — favicons and tab titles stay visible.
//  - Fully click-through everywhere except the floating pill's refresh
//    button. The user closes duplicates with Chrome's own X.
//  - Chrome-only for MVP. Session 3 adds Brave/Edge/Vivaldi/Opera/
//    Chromium (same AX structure). Safari is Session 4.
//
//  Scan architecture (Round 2, tab-duplicate-xray):
//  - Scans run on demand: on toggle-on, and when the user hits
//    ⌃⌥⌘⇧D or taps the pill's refresh button.
//  - During a scan: rainbow pulse animates on the UNDERSIDE of the
//    pill (flat gradient strip) and the pill reads "scanning Chrome
//    tabs…". Chrome windows themselves are not decorated.
//  - Between scans: markers follow AX tab positions in real time via a
//    cheap 30Hz position-only tick (never fetches URLs). The pill reads
//    "Tab Markers · Xs ago" with a refresh glyph.
//  - URL fetching uses `BrowserScripting.fetchChromeTabsFast` which
//    runs collection-form AppleScript off-main and typically completes
//    in a few hundred ms (vs ~3-4s for the per-tab iteration path).
//
//  Follows the same per-NSScreen panel pattern as SelectionOverlay and
//  PlotOverlay — one panel per display, each panel's view draws every
//  marker that falls within that display's frame.
//

import AppKit
import ApplicationServices
import os

@MainActor
final class TabMarkerOverlay {

    // MARK: - State

    /// True while markers are visible on screen (overlay toggled ON).
    private(set) var isActive: Bool = false

    /// True while an AppleScript scan is in flight. Drives the rainbow
    /// pulse animation and the pill's "Scanning Chrome tabs…" text.
    private(set) var isScanning: Bool = false

    /// When the most recent successful scan completed. Pill reads
    /// "Xs ago" from this.
    private var lastScanAt: Date?

    /// One panel per NSScreen, keyed by screen's displayID.
    private var panelByDisplay: [CGDirectDisplayID: NSPanel] = [:]
    private var viewByDisplay: [CGDirectDisplayID: MarkerView] = [:]

    /// 30Hz position-only tick. Re-reads AX tab positions for the
    /// already-colored tabs and re-renders at new coordinates — never
    /// fetches URLs, never recomputes duplicate groups. Keeps markers
    /// smoothly glued to tabs as the user drags Chrome windows around.
    private var movementTimer: Timer?

    /// 60Hz pulse animation tick. Only runs while `isScanning == true`.
    private var pulseTimer: Timer?

    /// 1Hz pill-state tick. Updates the pill's "Xs ago" label while
    /// the overlay is active and not currently scanning.
    private var pillStateTimer: Timer?

    /// Floating status pill (top-right of primary display). Shows
    /// scan state + refresh button.
    private let pill = TabMarkerPill()

    /// Monotonic scan generation counter. Each scan() call bumps this;
    /// completion handlers compare against the current value and drop
    /// stale results if a newer scan superseded them.
    private var currentScanGeneration: UInt64 = 0

    // MARK: - Public API

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        Log.tabXray.info("TabMarkerOverlay activated")
        createPanelsForAllScreens()

        pill.onRefreshTapped = { [weak self] in self?.refresh() }
        pill.show(initialState: .scanning)

        // Movement tracker runs continuously while active — cheap
        // (AX frame queries are microseconds), keeps markers glued to
        // moving Chrome windows between scans.
        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMarkerPositions() }
        }

        // Pill state tick — updates "Xs ago" every second while idle.
        pillStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPillLabel() }
        }

        // Kick the first scan immediately so the rainbow pulse starts
        // + initial markers land asap.
        scan()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        isScanning = false
        Log.tabXray.info("TabMarkerOverlay deactivated")

        movementTimer?.invalidate()
        movementTimer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        pillStateTimer?.invalidate()
        pillStateTimer = nil

        pill.hide()
        // Reset the color-persistence map so the next activation starts
        // with a clean assignment (freed palette slots don't carry over
        // from a prior session).
        persistedPaletteIndexByURL.removeAll(keepingCapacity: true)

        for panel in panelByDisplay.values {
            panel.orderOut(nil)
        }
        panelByDisplay.removeAll(keepingCapacity: true)
        viewByDisplay.removeAll(keepingCapacity: true)
    }

    /// User-triggered refresh (shortcut or pill button). No-op if
    /// already scanning or if the overlay is off.
    func refresh() {
        guard isActive else { return }
        guard !isScanning else { return }
        scan()
    }

    // MARK: - Scan

    /// Kicks off asynchronous snapshots for every running supported
    /// browser (Chromium family + Safari) in parallel. During the
    /// scan the pill reads "scanning…" and the blue outline pulses
    /// around it. On completion, markers update and the pulse fades.
    ///
    /// Parallelism matters: for a user running Chrome + Brave + Safari
    /// simultaneously, a serial loop would multiply the ~500ms scan
    /// cost; parallel execution keeps total wall-clock at roughly the
    /// slowest single-browser fetch.
    private func scan() {
        currentScanGeneration &+= 1
        let generation = currentScanGeneration
        isScanning = true
        pill.update(state: .scanning)
        startPulseAnimation()

        let bundleIDs = runningSupportedBrowserBundleIDs()
        Log.tabXray.info("Scan gen=\(generation, privacy: .public) started for \(bundleIDs.count, privacy: .public) browser(s)")

        Task { [weak self] in
            let totalWindowCount = await withTaskGroup(of: Int.self) { group -> Int in
                for bundleID in bundleIDs {
                    group.addTask {
                        let result = await BrowserScripting.fetchBrowserTabsFast(bundleID: bundleID)
                        return result?.count ?? 0
                    }
                }
                var sum = 0
                for await c in group { sum += c }
                return sum
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.isActive else { return }
                guard generation == self.currentScanGeneration else {
                    Log.tabXray.info("Scan gen=\(generation, privacy: .public) superseded; dropping result")
                    return
                }
                self.applyScanResult(windowCount: totalWindowCount, generation: generation)
            }
        }
    }

    private func applyScanResult(
        windowCount: Int,
        generation: UInt64
    ) {
        isScanning = false
        stopPulseAnimation()
        lastScanAt = Date()

        if windowCount > 0 {
            Log.tabXray.info("Scan gen=\(generation, privacy: .public) returned \(windowCount, privacy: .public) window(s) across supported browsers")
            // The underlying BrowserScripting cache was updated per-
            // bundle inside fetchBrowserTabsFast; the next movement
            // tick picks up the fresh data automatically.
            updateMarkerPositions()
            logAXDiagnostic(generation: generation)
        } else {
            Log.tabXray.info("Scan gen=\(generation, privacy: .public) returned no windows (no supported browsers running, or all fetches timed out)")
            // Keep previous markers rendered rather than blanking the
            // overlay — matches the "momentary visual retention" the
            // user flagged as acceptable.
        }
        refreshPillLabel()
    }

    /// One-shot summary after each scan: for each supported browser,
    /// how many AX windows we see, how many snapshot windows arrived,
    /// how many paired, and the total markers now rendered. Low-
    /// frequency (fires on scan completion only, not every 30Hz tick)
    /// and single line per browser — safe to leave on and useful for
    /// future triage.
    private func logAXDiagnostic(generation: UInt64) {
        var totalMarkers = 0
        for (_, view) in viewByDisplay {
            totalMarkers += view.markers.count
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  BrowserScripting.isSupportedBrowser(bundleID: bundleID) else { continue }
            let axWindows = axWindowsWithTabs(pid: app.processIdentifier)
            let snapshot = BrowserScripting.cachedSnapshot(for: bundleID) ?? []
            let mapping = pairAXToAppleScript(axWindows: axWindows, snapshot: snapshot)
            Log.tabXray.info("Declutter gen=\(generation, privacy: .public) \(bundleID, privacy: .public): AX=\(axWindows.count, privacy: .public)w snapshot=\(snapshot.count, privacy: .public)w paired=\(mapping.count, privacy: .public) markers=\(totalMarkers, privacy: .public)")
        }
    }

    /// Lists bundle IDs for every running supported browser —
    /// Chromium family (Chrome, Brave, Edge, Vivaldi, Opera, Chromium)
    /// plus Safari. Order follows NSWorkspace's runningApplications,
    /// which is roughly launch order; order doesn't affect correctness.
    @MainActor
    private func runningSupportedBrowserBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  BrowserScripting.isSupportedBrowser(bundleID: bundleID)
            else { return nil }
            return bundleID
        }
    }

    private func refreshPillLabel() {
        guard isActive, !isScanning else { return }
        let secondsAgo: Int
        if let ts = lastScanAt {
            secondsAgo = max(0, Int(Date().timeIntervalSince(ts).rounded()))
        } else {
            secondsAgo = 0
        }
        pill.update(state: .idle(secondsAgo: secondsAgo))
    }

    // MARK: - Panel setup

    private func createPanelsForAllScreens() {
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let (panel, view) = makePanel(for: screen)
            panelByDisplay[displayID] = panel
            viewByDisplay[displayID] = view
            panel.orderFrontRegardless()
        }
    }

    private func makePanel(for screen: NSScreen) -> (NSPanel, MarkerView) {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Sit ABOVE the Selection/Plot overlays (which are .floating)
        // so a Lasso/Plot session doesn't visually mask the markers.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        // readOnly: visible to screen recordings. Matches the policy
        // we set for every other overlay in this codebase.
        panel.sharingType = .readOnly
        panel.animationBehavior = .none
        panel.setFrame(screen.frame, display: false)

        let view = MarkerView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        view.screenOriginInCocoa = screen.frame.origin
        panel.contentView = view
        return (panel, view)
    }

    // MARK: - Position-only refresh (30Hz movement tracking)

    /// Last-COMMITTED AX tab-count signature across Chrome's visible
    /// windows. Changing signature → tabs were added, removed, or
    /// moved between windows → trigger an auto-scan so markers reflect
    /// the new reality within a frame or two.
    private var lastAXTabSignature: String = ""

    /// Candidate replacement signature, awaiting confirmation. Chrome's
    /// AX tree briefly flaps when the hover-link status bubble shows
    /// (tab count drops by 1 for a tick or two, then recovers). We
    /// require any change to be stable for at least `signatureStableTicks`
    /// consecutive observations before committing it as a real change
    /// and triggering a scan.
    private var pendingSignature: String = ""
    private var pendingSignatureConsecutiveTicks: Int = 0
    /// Required consecutive observations of a new signature before
    /// committing it as a real change and firing a scan. 2 ticks for
    /// a DECREASE (closes are unambiguous — if the new count held for
    /// 66ms, it's a real close), 3 for anything else (filters the
    /// 1-2 tick hover-link flap that briefly drops a tab count then
    /// recovers).
    private static let signatureStableTicksDecrease: Int = 2
    private static let signatureStableTicksOther: Int = 3

    /// Timestamp of the most recent scan START, used for a short
    /// cooldown so a user rapidly opening / closing tabs doesn't
    /// trigger a scan-storm. Scans are cheap but still ~500ms of
    /// background AppleScript work; one per 300ms is plenty.
    private var lastAutoScanAt: Date?

    /// Minimum interval between auto-triggered scans. User-triggered
    /// scans (shortcut / pill button / toggle-on) bypass this.
    private static let autoScanCooldown: TimeInterval = 0.3

    /// Called by the movement timer at 30Hz and once after each
    /// successful scan. Reads AX tab positions fresh, reuses the
    /// cached AppleScript snapshot for URL/color data. Never fetches
    /// unless the AX tab-count signature changes, which signals the
    /// user closed/opened a tab via Chrome's native UI and we need a
    /// fresh URL list to recompute duplicates.
    private func updateMarkerPositions() {
        // Fast path: render markers from current AX positions + cached
        // snapshot. Pure read, no AppleScript.
        let markers = computeMarkers()
        var markersByDisplay: [CGDirectDisplayID: [TabMarker]] = [:]
        for marker in markers {
            markersByDisplay[marker.displayID, default: []].append(marker)
        }
        for (displayID, view) in viewByDisplay {
            view.markers = markersByDisplay[displayID] ?? []
            view.needsDisplay = true
        }

        // Event-free "did tabs change?" check with debounce.
        //
        // Chrome's AX tree briefly flaps when its hover-link status
        // bubble shows (and in some other transient internal UI
        // updates): tab count on an affected window drops by 1 for a
        // tick or two, then recovers. We detect the change but DO NOT
        // commit it unless the new signature is observed on 3+
        // consecutive ticks (~100ms at 30Hz). Transient flaps that
        // last 1-2 ticks are ignored; real tab add/remove, which
        // persists, triggers a scan with ~100ms added latency.
        let current = currentAXTabSignature()
        if current == lastAXTabSignature {
            // Signature stable — any pending candidate change was a
            // flap that already recovered. Clear it.
            pendingSignature = ""
            pendingSignatureConsecutiveTicks = 0
        } else if current == pendingSignature {
            pendingSignatureConsecutiveTicks += 1
            // Decrease (tab closed) commits faster — close is
            // unambiguous and users want the marker refresh ASAP.
            let required = Self.ticksRequiredForTransition(
                from: lastAXTabSignature,
                to: current
            )
            if pendingSignatureConsecutiveTicks >= required {
                lastAXTabSignature = current
                pendingSignature = ""
                pendingSignatureConsecutiveTicks = 0
                if !isScanning {
                    let now = Date()
                    let elapsed = lastAutoScanAt.map { now.timeIntervalSince($0) } ?? .infinity
                    if elapsed >= Self.autoScanCooldown {
                        lastAutoScanAt = now
                        scan()
                    }
                }
            }
        } else {
            // New candidate change. Start the stability counter.
            pendingSignature = current
            pendingSignatureConsecutiveTicks = 1
            // Seed the baseline on the very first observation after
            // activate() so the first legitimate stable reading
            // commits as the baseline without triggering a scan.
            if lastAXTabSignature.isEmpty {
                lastAXTabSignature = current
                pendingSignature = ""
                pendingSignatureConsecutiveTicks = 0
            }
        }
    }

    /// Classifies a signature transition and returns how many consecutive
    /// stable observations are required before firing a scan. Pure
    /// string comparison on the "|"-joined per-window counts; a strict
    /// decrease (every per-window count is <= and at least one is <)
    /// is treated as a tab close.
    private static func ticksRequiredForTransition(
        from old: String, to new: String
    ) -> Int {
        let oldCounts = old.split(separator: "|").compactMap { Int($0) }
        let newCounts = new.split(separator: "|").compactMap { Int($0) }
        // Different window arrangement (new/closed window): treat as
        // "other" — slower debounce so a window appearing and
        // disappearing in quick succession doesn't trigger scans.
        guard oldCounts.count == newCounts.count else { return signatureStableTicksOther }
        var sawDecrease = false
        for (o, n) in zip(oldCounts, newCounts) {
            if n > o { return signatureStableTicksOther }
            if n < o { sawDecrease = true }
        }
        return sawDecrease ? signatureStableTicksDecrease : signatureStableTicksOther
    }

    /// Fast "did tabs change?" signature. Per-window tab counts in
    /// AX order, joined. Catches add/remove/move-between-windows
    /// without needing AppleScript. Signature changes don't need to
    /// uniquely identify tabs — any delta triggers an auto-scan.
    private func currentAXTabSignature() -> String {
        var parts: [String] = []
        for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier.map({ BrowserScripting.isSupportedBrowser(bundleID: $0) }) == true {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &value
            ) == .success, let windows = value as? [AXUIElement] else {
                continue
            }
            for win in windows {
                let tabs = findTabFrames(under: win, depth: 0)
                parts.append(String(tabs.count))
            }
        }
        return parts.joined(separator: "|")
    }

    /// Called by applyScanResult after a scan commits new data to the
    /// AppleScript cache. Forces one immediate position+color refresh
    /// so markers appear right away rather than waiting up to 33ms
    /// for the next movement tick.
    private func rebuildMarkersFromSnapshot(
        _ snapshot: [BrowserScripting.BrowserWindowSnapshot]
    ) {
        updateMarkerPositions()
    }

    /// Returns every marker (duplicate tab) that should be visible on
    /// screen right now. Pure computation — no AppKit side-effects.
    ///
    /// Iterates every running supported browser. Duplicate color groups
    /// are computed across the UNION of all browsers' cached snapshots
    /// — so a URL open in both Chrome and Brave is correctly flagged
    /// as a duplicate and gets the same color in both browser's tab
    /// strips.
    private func computeMarkers() -> [TabMarker] {
        // Gather each running supported browser's cached snapshot.
        let apps = NSWorkspace.shared.runningApplications
        var browserEntries: [(app: NSRunningApplication, bundleID: String, snapshot: [BrowserScripting.BrowserWindowSnapshot])] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier,
                  BrowserScripting.isSupportedBrowser(bundleID: bundleID) else { continue }
            if let snapshot = BrowserScripting.cachedSnapshot(for: bundleID) {
                browserEntries.append((app, bundleID, snapshot))
            }
        }
        if browserEntries.isEmpty { return [] }

        // Cross-browser color map: a URL seen twice gets a color, even
        // if the two instances live in different browsers.
        let colorByURL = assignColorsAcrossBrowsers(browserEntries.map { $0.snapshot })
        if colorByURL.isEmpty { return [] }

        // Build markers per browser using the shared color map.
        var allMarkers: [TabMarker] = []
        for entry in browserEntries {
            allMarkers.append(contentsOf: markersFor(
                app: entry.app,
                bundleID: entry.bundleID,
                snapshot: entry.snapshot,
                colorByURL: colorByURL
            ))
        }
        return allMarkers
    }

    private func markersFor(
        app: NSRunningApplication,
        bundleID: String,
        snapshot: [BrowserScripting.BrowserWindowSnapshot],
        colorByURL: [String: NSColor]
    ) -> [TabMarker] {
        // Side B: AX enumeration — per-window tab frames (top-left AX
        // coords, visible-Space windows only).
        let axWindows = axWindowsWithTabs(pid: app.processIdentifier)

        // Correlate AX windows to AppleScript windows. New matcher
        // (see pairAXToAppleScript) handles the three failure modes
        // the previous version had: (a) tight 50pt threshold rejecting
        // matches during a drag, (b) double-assigning the same
        // AppleScript window to multiple AX windows, (c) treating the
        // snapshot's cross-Space windows as candidates for a visible AX
        // window on the current Space.
        let mapping = pairAXToAppleScript(axWindows: axWindows, snapshot: snapshot)

        var markers: [TabMarker] = []
        for (axWindow, appleScriptWindow) in mapping {
            // On transient count mismatch (Chrome just closed/opened a
            // tab, cache not yet refreshed), render markers for the
            // FIRST min(axCount, scriptCount) positions instead of
            // blanking the entire window. Correct for close-at-end;
            // close-at-middle may misalign one marker for ~500ms until
            // the scan refreshes the cache. Trade-off is deliberate:
            // one briefly-wrong marker beats every marker vanishing.
            let safeCount = Swift.min(axWindow.tabs.count, appleScriptWindow.tabs.count)
            for axIdx in 0..<safeCount {
                let axTab = axWindow.tabs[axIdx]
                let scriptTab = appleScriptWindow.tabs[axIdx]
                let normalized = BrowserScripting.normalizedURL(scriptTab.url)
                guard let color = colorByURL[normalized] else { continue }
                guard let marker = buildMarker(forAXTab: axTab.frameAX, color: color) else { continue }
                markers.append(marker)
            }
        }
        return markers
    }

    /// Pairs each AX window to the single best-matching AppleScript
    /// window from `snapshot`. Both sources report window frames in
    /// AX coordinate space, so **position identity is the primary
    /// signal** — a window at (x,y) is the same window regardless of
    /// how AX and AppleScript happen to count its tabs.
    ///
    /// Why tab count is NOT a hard filter: Chrome Tab Groups collapse
    /// into a single clickable chip in the tab strip. AX exposes every
    /// AXTab element inside the group (even when the group is
    /// collapsed), while Chrome's AppleScript dictionary excludes
    /// tabs inside a collapsed group from `tabs of window`. A single
    /// 20-tab window with one 7-tab group collapsed therefore reports
    /// `axTabs=20 / scriptTabs=13`. The earlier matcher required
    /// exact tab-count equality in Pass 1 and 2, which rejected the
    /// correct pairing for every window with a collapsed tab group
    /// and then let Pass 3 pair the window to a geographically-close
    /// but wrong snapshot entry — silently dropping every duplicate
    /// marker in that window.
    ///
    /// Multi-pass strategy:
    ///
    ///   Pass 1 — exact-position match (origin within 10pt). When
    ///            multiple candidates sit at the same cascaded origin
    ///            (one per Space), prefer the one with the smallest
    ///            `|tabs.count - axTabCount|` difference.
    ///   Pass 2 — close-position match (origin within 100pt). Same
    ///            tie-break.
    ///   Pass 3 — center-distance last-ditch for windows whose
    ///            positions genuinely don't line up (rare).
    ///
    /// Each pass greedily consumes snapshot candidates so later
    /// passes don't double-assign.
    /// Returns true when the AppleScript window `name` identifies the
    /// same browser window as the AX `AXTitle`. Two Chrome quirks
    /// make straight equality useless:
    ///
    ///   1. AX appends " - Google Chrome" (and optionally " - <profile>")
    ///      to the active-tab title; AppleScript's `name of window`
    ///      doesn't.
    ///   2. AppleScript ELIDES long titles with a "…" (U+2026)
    ///      ellipsis in the MIDDLE — e.g. the full title
    ///      "WALES BONNER | Official Website Online Boutique – Wales Bonner"
    ///      arrives from AppleScript as
    ///      "WALES BONNER | Official Websit…nline Boutique – Wales Bonner".
    ///      AX returns the full untruncated form.
    ///
    /// Match strategy:
    ///   - Exact equality wins immediately.
    ///   - If the script title contains "…", split on it and require
    ///     the leading half to be a prefix of AX title AND the trailing
    ///     half to appear anywhere in AX title.
    ///   - Otherwise, require AX title to start with script title
    ///     followed by " - " (the Chrome suffix separator) so
    ///     "GitHub" does NOT falsely match AX "GitHubCopilot - …".
    private static func browserWindowTitlesMatch(
        axTitle: String,
        scriptTitle: String
    ) -> Bool {
        guard !axTitle.isEmpty, !scriptTitle.isEmpty else { return false }
        if axTitle == scriptTitle { return true }
        if let elideRange = scriptTitle.range(of: "\u{2026}") {
            let scPrefix = scriptTitle[..<elideRange.lowerBound]
            let scSuffix = scriptTitle[elideRange.upperBound...]
            guard !scPrefix.isEmpty, !scSuffix.isEmpty else { return false }
            return axTitle.hasPrefix(scPrefix) && axTitle.contains(scSuffix)
        }
        guard axTitle.hasPrefix(scriptTitle) else { return false }
        let after = axTitle.index(axTitle.startIndex, offsetBy: scriptTitle.count)
        return axTitle[after...].hasPrefix(" - ")
    }

    private func pairAXToAppleScript(
        axWindows: [AXWindowTabs],
        snapshot: [BrowserScripting.BrowserWindowSnapshot]
    ) -> [(AXWindowTabs, BrowserScripting.BrowserWindowSnapshot)] {
        var used = Set<Int>()
        var result: [(AXWindowTabs, BrowserScripting.BrowserWindowSnapshot)] = []
        var unmatched: [AXWindowTabs] = []

        // Pass 1 — origin within 10pt. For Chromium browsers the same
        // cascade position is often reused across Spaces, so position
        // alone is NOT unique. The title (active-tab page title)
        // disambiguates: a candidate whose `title` matches the AX
        // window's `AXTitle` wins outright. Ties fall back to smallest
        // tab-count delta.
        for axWindow in axWindows {
            guard let axFrame = axWindow.windowFrameAX else { continue }
            let axTabCount = axWindow.tabs.count
            let axTitle = axWindow.title
            var best: (idx: Int, titleMatch: Bool, tabsDiff: Int)? = nil
            for (idx, candidate) in snapshot.enumerated() where !used.contains(idx) {
                let b = candidate.boundsAX
                guard abs(b.origin.x - axFrame.origin.x) <= 10,
                      abs(b.origin.y - axFrame.origin.y) <= 10 else { continue }
                let titleMatch = Self.browserWindowTitlesMatch(
                    axTitle: axTitle, scriptTitle: candidate.title
                )
                let diff = abs(candidate.tabs.count - axTabCount)
                if best == nil
                    || (titleMatch && !best!.titleMatch)
                    || (titleMatch == best!.titleMatch && diff < best!.tabsDiff) {
                    best = (idx, titleMatch, diff)
                }
            }
            if let b = best {
                used.insert(b.idx)
                result.append((axWindow, snapshot[b.idx]))
            } else {
                unmatched.append(axWindow)
            }
        }

        // Pass 2 — origin within 100pt. Title match still dominates
        // when present; otherwise prefer smallest tab-count delta,
        // then closest origin.
        var stillUnmatched: [AXWindowTabs] = []
        for axWindow in unmatched {
            guard let axFrame = axWindow.windowFrameAX else { continue }
            let axTabCount = axWindow.tabs.count
            let axTitle = axWindow.title
            var best: (idx: Int, titleMatch: Bool, tabsDiff: Int, distance: CGFloat)? = nil
            for (idx, candidate) in snapshot.enumerated() where !used.contains(idx) {
                let b = candidate.boundsAX
                let dx = b.origin.x - axFrame.origin.x
                let dy = b.origin.y - axFrame.origin.y
                let distance = sqrt(dx * dx + dy * dy)
                guard distance <= 100 else { continue }
                let titleMatch = Self.browserWindowTitlesMatch(
                    axTitle: axTitle, scriptTitle: candidate.title
                )
                let diff = abs(candidate.tabs.count - axTabCount)
                if best == nil
                    || (titleMatch && !best!.titleMatch)
                    || (titleMatch == best!.titleMatch
                        && (diff < best!.tabsDiff
                            || (diff == best!.tabsDiff && distance < best!.distance))) {
                    best = (idx, titleMatch, diff, distance)
                }
            }
            if let b = best {
                used.insert(b.idx)
                result.append((axWindow, snapshot[b.idx]))
            } else {
                stillUnmatched.append(axWindow)
            }
        }

        // Pass 3 — center-distance last-ditch. Position stays dominant;
        // tab-count delta only breaks ties.
        for axWindow in stillUnmatched {
            guard let axFrame = axWindow.windowFrameAX else { continue }
            let axCenter = CGPoint(x: axFrame.midX, y: axFrame.midY)
            let axTabCount = axWindow.tabs.count
            var best: (idx: Int, distance: CGFloat, tabsDiff: Int)? = nil
            for (idx, candidate) in snapshot.enumerated() where !used.contains(idx) {
                let b = candidate.boundsAX
                let dx = b.midX - axCenter.x
                let dy = b.midY - axCenter.y
                let distance = sqrt(dx * dx + dy * dy)
                guard distance <= 500 else { continue }
                let diff = abs(candidate.tabs.count - axTabCount)
                if best == nil
                    || distance < best!.distance
                    || (distance == best!.distance && diff < best!.tabsDiff) {
                    best = (idx, distance, diff)
                }
            }
            if let b = best {
                used.insert(b.idx)
                result.append((axWindow, snapshot[b.idx]))
            }
        }

        return result
    }

    // MARK: - Color assignment

    /// Palette for duplicate-group bars. First 7 are the Okabe-Ito
    /// color-blind-safe set; the last 5 extend the range for heavy
    /// sessions where 8+ duplicate groups coexist. The additions are
    /// chosen to stay reasonably distinct in protanopia/deuteranopia
    /// (teal and lime read as separate blues/yellows, magenta and
    /// purple occupy different lightnesses, brown is uniquely low-
    /// saturation warm). Order drives the "assign new groups first"
    /// path — a user with a few duplicates sees the strongest
    /// contrast; overflow (groups 13+) wraps and hash-collides.
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.00, green: 0.45, blue: 0.70, alpha: 1.0),  // blue
        NSColor(calibratedRed: 0.84, green: 0.37, blue: 0.00, alpha: 1.0),  // vermillion
        NSColor(calibratedRed: 0.00, green: 0.62, blue: 0.45, alpha: 1.0),  // bluish green
        NSColor(calibratedRed: 0.90, green: 0.62, blue: 0.00, alpha: 1.0),  // orange
        NSColor(calibratedRed: 0.80, green: 0.47, blue: 0.65, alpha: 1.0),  // reddish purple
        NSColor(calibratedRed: 0.34, green: 0.71, blue: 0.91, alpha: 1.0),  // sky blue
        NSColor(calibratedRed: 0.94, green: 0.89, blue: 0.26, alpha: 1.0),  // yellow
        NSColor(calibratedRed: 0.00, green: 0.55, blue: 0.55, alpha: 1.0),  // teal
        NSColor(calibratedRed: 0.71, green: 0.89, blue: 0.14, alpha: 1.0),  // lime
        NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.07, alpha: 1.0),  // brown
        NSColor(calibratedRed: 0.91, green: 0.11, blue: 0.45, alpha: 1.0),  // magenta
        NSColor(calibratedRed: 0.42, green: 0.24, blue: 0.60, alpha: 1.0),  // purple
    ]

    private func assignColors(snapshot: [BrowserScripting.BrowserWindowSnapshot]) -> [String: NSColor] {
        return assignColorsAcrossBrowsers([snapshot])
    }

    /// Persistent URL → palette-index map, retained across scans so
    /// a close that drops one URL from the duplicate set doesn't
    /// recolor every remaining group. Reset in `deactivate()`.
    private var persistedPaletteIndexByURL: [String: Int] = [:]

    /// Cross-browser color assignment. Counts URL occurrences across
    /// the UNION of every provided browser snapshot and gives every
    /// URL that appears ≥2 times a stable palette color. Enables the
    /// cross-browser duplicate detection scenario: open github.com in
    /// Chrome AND in Brave → both instances get the same marker color.
    ///
    /// Colors are stable across scans — a URL that was blue stays blue
    /// after another URL's duplicate pair collapses, so the user doesn't
    /// see the whole marker set recolor every time they close a tab.
    /// Palette slots are reclaimed when a URL leaves the duplicate set.
    private func assignColorsAcrossBrowsers(
        _ snapshots: [[BrowserScripting.BrowserWindowSnapshot]]
    ) -> [String: NSColor] {
        var counts: [String: Int] = [:]
        for snapshot in snapshots {
            for window in snapshot {
                for tab in window.tabs {
                    let key = BrowserScripting.normalizedURL(tab.url)
                    guard !key.isEmpty else { continue }
                    counts[key, default: 0] += 1
                }
            }
        }
        let duplicateURLs = Set(counts.filter { $0.value >= 2 }.keys)
        // Release palette slots for URLs no longer duplicated.
        persistedPaletteIndexByURL = persistedPaletteIndexByURL.filter {
            duplicateURLs.contains($0.key)
        }
        // Collect slots currently in use so new URLs don't collide.
        var usedSlots = Set(persistedPaletteIndexByURL.values)
        // Assign slots to URLs that newly became duplicates. Deterministic
        // sort means consistent slot assignment across a sequence of scans
        // that happen to introduce the same new duplicate URLs.
        let newURLs = duplicateURLs
            .subtracting(persistedPaletteIndexByURL.keys)
            .sorted()
        for url in newURLs {
            var slot = 0
            while slot < Self.palette.count, usedSlots.contains(slot) {
                slot += 1
            }
            // Palette full (more simultaneous duplicate groups than
            // `palette.count` slots) — fall back to a deterministic
            // hash-based wrap so the same URL always lands on the same
            // color even in the overflow case.
            let finalSlot = (slot < Self.palette.count)
                ? slot
                : abs(url.hashValue) % Self.palette.count
            persistedPaletteIndexByURL[url] = finalSlot
            usedSlots.insert(finalSlot)
        }
        // Materialize the URL → NSColor view the caller expects.
        var result: [String: NSColor] = [:]
        for (url, slot) in persistedPaletteIndexByURL {
            result[url] = Self.palette[slot % Self.palette.count]
        }
        return result
    }

    // MARK: - Marker geometry

    private func buildMarker(forAXTab tabFrameAX: CGRect, color: NSColor) -> TabMarker? {
        // Marker sits above the tab's top edge in a thin bar.
        // AX uses top-left origin; tab.y is the tab's top edge.
        // We want the marker just above that edge.
        let markerHeight: CGFloat = 4
        let markerGap: CGFloat = 3    // between tab top and marker bottom
        let markerWidthRatio: CGFloat = 0.6  // 60% of tab width

        let markerWidth = tabFrameAX.width * markerWidthRatio
        let markerX = tabFrameAX.origin.x + (tabFrameAX.width - markerWidth) / 2
        // In AX top-left coords, the marker's top edge is above the
        // tab's top by (markerGap + markerHeight).
        let markerYTopLeftAX = tabFrameAX.origin.y - markerGap - markerHeight

        let markerFrameAX = CGRect(
            x: markerX,
            y: markerYTopLeftAX,
            width: markerWidth,
            height: markerHeight
        )

        // Convert AX top-left → Cocoa bottom-left per-screen.
        guard let (frameCocoa, displayID) = convertAXToCocoa(markerFrameAX) else {
            return nil
        }
        return TabMarker(
            frameCocoa: frameCocoa,
            color: color,
            displayID: displayID
        )
    }

    /// Converts a rect from AX (top-left global) space to Cocoa
    /// (bottom-left per-screen) space. Returns the Cocoa rect in the
    /// coordinate system of the containing screen, plus that screen's
    /// displayID so the caller can route the marker to the right panel.
    private func convertAXToCocoa(_ frameAX: CGRect) -> (CGRect, CGDirectDisplayID)? {
        // Pick the screen that contains the marker's center.
        let centerAX = CGPoint(x: frameAX.midX, y: frameAX.midY)
        // AX y grows downward from the top of the PRIMARY display.
        // Primary = screens[0]. Convert back by:
        //   screenCocoaY = primaryHeight - axY - screenHeight?
        // Simpler: find the matching screen by comparing the AX rect
        // to each screen's AX-space rect.
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height

        for screen in NSScreen.screens {
            // Screen's AX-space origin: X unchanged, Y is primaryHeight
            // - (screen.frame.origin.y + screen.frame.height).
            let screenAxOriginY = primaryHeight - (screen.frame.origin.y + screen.frame.height)
            let screenAXFrame = CGRect(
                x: screen.frame.origin.x,
                y: screenAxOriginY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            if screenAXFrame.contains(centerAX) {
                guard let displayID = screen.displayID else { return nil }
                // Marker's Cocoa Y within THIS screen's panel.
                // Panel's local coord origin is bottom-left of its frame.
                // AX frame y relative to this screen's AX origin:
                let yOffsetFromScreenAxTop = frameAX.origin.y - screenAXFrame.origin.y
                // Flip to Cocoa (bottom-left): screenHeight - top - height
                let cocoaY = screen.frame.height - yOffsetFromScreenAxTop - frameAX.height
                let cocoaX = frameAX.origin.x - screen.frame.origin.x
                let cocoaRect = CGRect(
                    x: cocoaX,
                    y: cocoaY,
                    width: frameAX.width,
                    height: frameAX.height
                )
                return (cocoaRect, displayID)
            }
        }
        return nil
    }

    // MARK: - AX enumeration (local — spike's TabEnumerator is for logging only)

    /// Per-AX-window tab records used only for marker rendering.
    private struct AXWindowTabs {
        let axWindow: AXUIElement
        let windowFrameAX: CGRect?
        /// Window title from `kAXTitleAttribute` — for Chrome / Safari
        /// this is the active tab's page title. Used by the matcher to
        /// disambiguate same-position windows (Chrome cascade reuses
        /// identical bounds across Spaces so position alone can't
        /// uniquely identify a window). Empty string if AX doesn't
        /// expose one.
        let title: String
        let tabs: [AXTabFrame]
    }
    private struct AXTabFrame {
        let frameAX: CGRect
    }

    private func axWindowsWithTabs(pid: pid_t) -> [AXWindowTabs] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return [] }
        return axWindows.map { win in
            AXWindowTabs(
                axWindow: win,
                windowFrameAX: frameOf(win),
                title: stringAttrOf(kAXTitleAttribute, win) ?? "",
                tabs: findTabFrames(under: win, depth: 0)
            )
        }
    }

    private func findTabFrames(under element: AXUIElement, depth: Int) -> [AXTabFrame] {
        guard depth < 8 else { return [] }
        guard let children = childrenOf(element) else { return [] }
        var out: [AXTabFrame] = []
        for child in children {
            let role = stringAttrOf(kAXRoleAttribute, child)
            let isTabLike = (role == "AXTab")
                || (role == "AXRadioButton" && hasTabGroupAncestor(child, depth: 0))
            if isTabLike {
                if let frame = frameOf(child) {
                    out.append(AXTabFrame(frameAX: frame))
                }
            } else {
                out.append(contentsOf: findTabFrames(under: child, depth: depth + 1))
            }
        }
        return out
    }


    private func hasTabGroupAncestor(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 3 else { return false }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let pv = parent, CFGetTypeID(pv) == AXUIElementGetTypeID() else { return false }
        let p = pv as! AXUIElement
        if stringAttrOf(kAXRoleAttribute, p) == "AXTabGroup" { return true }
        if stringAttrOf(kAXSubroleAttribute, p) == "AXTabGroup" { return true }
        return hasTabGroupAncestor(p, depth: depth + 1)
    }

    private func childrenOf(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func stringAttrOf(_ key: String, _ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func frameOf(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?
        var s: CFTypeRef?
        let pr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p)
        let sr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s)
        guard pr == .success, sr == .success else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let v = p, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &pos)
        }
        if let v = s, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    // MARK: - Window matching (AX ↔ AppleScript)

    /// Pairs an AX window to its AppleScript BrowserWindowSnapshot.
    /// Uses frame proximity: AX returns top-left-origin AX coords, so
    /// we convert the AppleScript bounds (also AX space per the
    /// BrowserScripting convention) and compare by center distance.
    private func matchAppleScriptWindow(
        axWindow: AXWindowTabs,
        in snapshot: [BrowserScripting.BrowserWindowSnapshot]
    ) -> BrowserScripting.BrowserWindowSnapshot? {
        guard let axFrame = axWindow.windowFrameAX else { return nil }
        // Pick the AppleScript window whose bounds center is closest to
        // the AX window's center. Reject matches more than 50pt off
        // (prevents cross-window collisions when AX and AppleScript
        // transiently disagree during a tab add/remove animation).
        let axCenter = CGPoint(x: axFrame.midX, y: axFrame.midY)
        var best: (window: BrowserScripting.BrowserWindowSnapshot, distance: CGFloat)? = nil
        for window in snapshot {
            let b = window.boundsAX
            let center = CGPoint(x: b.midX, y: b.midY)
            let dx = center.x - axCenter.x
            let dy = center.y - axCenter.y
            let d = sqrt(dx * dx + dy * dy)
            if best == nil || d < best!.distance {
                best = (window, d)
            }
        }
        guard let b = best, b.distance <= 50 else { return nil }
        return b.window
    }

    // MARK: - Scan pulse (routes to pill's underside gradient strip)

    private var pulseStartedAt: Date?

    private func startPulseAnimation() {
        pulseStartedAt = Date()
        pill.setScanning(true, phase: 0)
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPulseAnimation() }
        }
    }

    private func stopPulseAnimation() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseStartedAt = nil
        pill.setScanning(false)
    }

    private func tickPulseAnimation() {
        guard let started = pulseStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        // Phase cycles 0→1 every 1.5s — drives the hue shift along the
        // pill's underside gradient strip.
        let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.5) / 1.5)
        pill.setScanning(true, phase: phase)
    }
}

// MARK: - Model

/// One colored marker to draw. Pure data — no AppKit references here
/// so marker computation can be reasoned about in isolation.
struct TabMarker {
    let frameCocoa: CGRect
    let color: NSColor
    let displayID: CGDirectDisplayID
}

// MARK: - View

/// The actual drawing surface. One per NSScreen.
///
/// Renders the thin colored bars above duplicate tabs. The rainbow
/// scanning indicator lives on the pill's underside, not here.
private final class MarkerView: NSView {
    var markers: [TabMarker] = []
    /// This screen's origin in Cocoa coords — reserved for hit-testing
    /// / debug diagnostics.
    var screenOriginInCocoa: CGPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for marker in markers {
            let r = marker.frameCocoa
            let radius: CGFloat = min(2, r.height / 2)
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(marker.color.cgColor)
            ctx.fillPath()
        }
    }

    override var isFlipped: Bool { false }  // Cocoa coords (bottom-left)
}

// MARK: - NSScreen helper

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
