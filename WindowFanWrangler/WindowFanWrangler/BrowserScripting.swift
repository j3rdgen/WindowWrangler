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
        guard let appName = localizedNameForBundle(bundleID) else {
            Log.corral.info(
                "Browser \(bundleID, privacy: .public) not running — skipping tab capture"
            )
            return nil
        }
        guard let snapshots = fetchSnapshot(bundleID: bundleID, appName: appName) else {
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
    /// **currently running** supported browser we haven't asked
    /// about this session. Uses `AEDeterminePermissionToAutomateTarget`
    /// (the correct API — it triggers the OS's own dialog when the
    /// decision hasn't been made, and returns a clean status on
    /// subsequent calls). Runs synchronously on main; the browser
    /// prompt UI blocks the main runloop briefly while the user
    /// clicks OK/Don't Allow, which is fine because they're right
    /// there having just toggled lasso mode.
    @MainActor
    static func requestAutomationPermissions() {
        let browsers: [String] = NSWorkspace.shared.runningApplications
            .compactMap { app in
                guard let bid = app.bundleIdentifier,
                      isSupportedBrowser(bundleID: bid),
                      !permissionRequested.contains(bid) else { return nil }
                return bid
            }
        guard !browsers.isEmpty else { return }
        Log.corral.info(
            "Requesting Automation permission for \(browsers.count, privacy: .public) browser(s)"
        )
        for bundleID in browsers {
            permissionRequested.insert(bundleID)
            let status = AutomationPermission.check(bundleID: bundleID, askIfNeeded: true)
            switch status {
            case .granted:
                Log.corral.info("Automation granted: \(bundleID, privacy: .public)")
                deniedBundles.remove(bundleID)
                // Sanity-probe: run a minimal "count windows" script and
                // log its result and timing. If TCC says granted but this
                // probe hangs or returns empty, the TCC record for this
                // browser is stale (common after several rebuilds change
                // our binary signature). User can `tccutil reset
                // AppleEvents com.jmw3.WindowWrangler` to clear it.
                probeBrowserScripting(bundleID: bundleID)
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

    /// Runs the smallest possible script against the given browser and
    /// logs its result + timing. Used only to diagnose the case where
    /// TCC reports "granted" but real scripts hang and return empty
    /// (which usually means the TCC record is stale from a rebuild).
    @MainActor
    private static func probeBrowserScripting(bundleID: String) {
        guard let appName = localizedNameForBundle(bundleID) else { return }
        let source = "tell application \"\(appName)\" to return (count of windows) as string"
        let start = CFAbsoluteTimeGetCurrent()
        let result = runScript(source: source)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        Log.corral.notice(
            "Probe \(bundleID, privacy: .public): result='\(result ?? "nil", privacy: .public)' in \(elapsedMs, privacy: .public)ms"
        )
    }

    /// Same as `requestAutomationPermissions` but for the onboarding
    /// flow — checks every INSTALLED supported browser, not just the
    /// running ones. Called once from AppDelegate right after
    /// accessibility permission is granted, so the user gets all
    /// the prompts in one intentional burst instead of one at a
    /// time later when they toggle lasso.
    @MainActor
    static func requestAutomationPermissionsForInstalledBrowsers() {
        let allSupported: [String] = Array(chromiumBundleIDs) + [safariBundleID]
        let installed: [String] = allSupported.filter { bid in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil
                && !permissionRequested.contains(bid)
        }
        guard !installed.isEmpty else { return }
        Log.corral.info(
            "Onboarding: requesting Automation permission for \(installed.count, privacy: .public) installed browser(s)"
        )
        for bundleID in installed {
            permissionRequested.insert(bundleID)
            let status = AutomationPermission.check(bundleID: bundleID, askIfNeeded: true)
            switch status {
            case .granted:
                Log.corral.info("Automation granted: \(bundleID, privacy: .public)")
                deniedBundles.remove(bundleID)
            case .denied:
                Log.corral.notice("Automation DENIED: \(bundleID, privacy: .public)")
                deniedBundles.insert(bundleID)
            case .notAvailable:
                Log.corral.info("Automation not available (target not running): \(bundleID, privacy: .public)")
            case .other(let err):
                Log.corral.error("Automation check error \(err, privacy: .public) for \(bundleID, privacy: .public)")
            }
        }
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
        // Snapshot the app list on main; browser lookup + name
        // resolution needs NSWorkspace which is main-thread-preferred.
        let browsersToFetch: [(bundleID: String, appName: String)] = NSWorkspace.shared.runningApplications
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      isSupportedBrowser(bundleID: bundleID),
                      let appName = app.localizedName else { return nil }
                return (bundleID, appName)
            }
        guard !browsersToFetch.isEmpty else { return }

        Log.corral.info(
            "Prefetching \(browsersToFetch.count, privacy: .public) browser(s) in background"
        )
        for (bundleID, appName) in browsersToFetch {
            // Background thread — NSAppleScript.executeAndReturnError
            // is safe to call from any thread in practice (Chrome/
            // Safari's AX servers don't care about our thread). If we
            // ever see instability, swap to `Process` invoking
            // /usr/bin/osascript, which has strict thread-safety.
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = fetchSnapshot(bundleID: bundleID, appName: appName)
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
        guard let appName = localizedNameForBundle(bundleID) else {
            Log.corral.info(
                "openBrowserWindow: \(bundleID, privacy: .public) not running — cannot open new window"
            )
            return false
        }
        let source = openChromiumWindowScript(appName: appName, tabs: tabs, boundsAX: boundsAX)
        let ok = runScript(source: source) != nil
        if ok {
            // Invalidate the cache — a new window just appeared that
            // wasn't in any prior snapshot.
            snapshotCache.removeValue(forKey: bundleID)
        }
        return ok
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
        appName: String,
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
            tell application "\(appName)"
                activate
                set newWin to make new window
                set bounds of newWin to {\(x1), \(y1), \(x2), \(y2)}
            end tell
            """
        }

        var lines: [String] = []
        lines.append("tell application \"\(appName)\"")
        lines.append("    activate")
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
        bundleID: String,
        appName: String
    ) -> [BrowserWindowSnapshot]? {
        let source: String
        if chromiumBundleIDs.contains(bundleID) {
            source = chromiumSnapshotScript(appName: appName)
        } else if bundleID == safariBundleID {
            source = safariSnapshotScript(appName: appName)
        } else {
            return nil
        }
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
    /// The window ID (Chrome's / Safari's `id of window`) lets us
    /// re-address that specific window from a later AppleScript call
    /// without depending on a frame match against AX — which was
    /// the source of the "matched but couldn't AX-move → falsely
    /// opened a duplicate window and then reported the whole thing
    /// as 'not available'" bug in the first release-flow build.
    ///
    /// Tabs are the field separator because they almost never
    /// appear in URLs or page titles. Chromium browsers share this
    /// shape verbatim.
    private static func chromiumSnapshotScript(appName: String) -> String {
        return """
        tell application "\(appName)"
            set out to ""
            repeat with w in windows
                set b to bounds of w
                set out to out & "W" & tab & (id of w as string) & tab & ((item 1 of b) as string) & tab & ((item 2 of b) as string) & tab & ((item 3 of b) as string) & tab & ((item 4 of b) as string) & linefeed
                repeat with t in tabs of w
                    set out to out & "T" & tab & (URL of t as string) & tab & (title of t as string) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
    }

    /// Safari variant. Same output shape as Chromium; only the
    /// property names differ (`name of tab` instead of `title of
    /// tab`; Safari doesn't expose a `title` property on tabs).
    private static func safariSnapshotScript(appName: String) -> String {
        return """
        tell application "\(appName)"
            set out to ""
            repeat with w in windows
                set b to bounds of w
                set out to out & "W" & tab & (id of w as string) & tab & ((item 1 of b) as string) & tab & ((item 2 of b) as string) & tab & ((item 3 of b) as string) & tab & ((item 4 of b) as string) & linefeed
                repeat with t in tabs of w
                    set out to out & "T" & tab & (URL of t as string) & tab & (name of t as string) & linefeed
                end repeat
            end repeat
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
        guard let appName = localizedNameForBundle(bundleID) else {
            return false
        }
        let x1 = Int(boundsAX.minX.rounded())
        let y1 = Int(boundsAX.minY.rounded())
        let x2 = Int(boundsAX.maxX.rounded())
        let y2 = Int(boundsAX.maxY.rounded())
        let source = """
        tell application "\(appName)"
            set bounds of window id \(windowID) to {\(x1), \(y1), \(x2), \(y2)}
        end tell
        """
        let ok = runScript(source: source) != nil
        if ok {
            // Bounds changed — invalidate the cache so a subsequent
            // save-flow snapshot fetch doesn't see stale coordinates.
            snapshotCache.removeValue(forKey: bundleID)
        }
        return ok
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
        guard let script = NSAppleScript(source: source) else {
            Log.corral.error("NSAppleScript init returned nil")
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
        return descriptor.stringValue
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
}
