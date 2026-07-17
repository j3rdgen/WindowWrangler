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
    struct BrowserWindowSnapshot: Sendable {
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
        if let cached = cachedSnapshot(for: bundleID) {
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
        snapshotCache[bundleID] = (snapshot: snapshots, capturedAt: CFAbsoluteTimeGetCurrent())
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
                guard let snapshot else { return }
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
    ///     W\tx1\ty1\tx2\ty2\n         one line per window
    ///     T\turl\ttitle\n              one line per tab, following
    ///                                  the W line for its window
    ///
    /// Tabs are used as the field separator because they almost
    /// never appear in URLs or page titles. Newlines separate
    /// records. Chromium browsers share this shape verbatim.
    private static func chromiumSnapshotScript(appName: String) -> String {
        return """
        tell application "\(appName)"
            set out to ""
            repeat with w in windows
                set b to bounds of w
                set out to out & "W" & tab & ((item 1 of b) as string) & tab & ((item 2 of b) as string) & tab & ((item 3 of b) as string) & tab & ((item 4 of b) as string) & linefeed
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
                set out to out & "W" & tab & ((item 1 of b) as string) & tab & ((item 2 of b) as string) & tab & ((item 3 of b) as string) & tab & ((item 4 of b) as string) & linefeed
                repeat with t in tabs of w
                    set out to out & "T" & tab & (URL of t as string) & tab & (name of t as string) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
    }

    // MARK: - Execution

    /// Compiles and runs the given AppleScript source. Returns the
    /// script's stringValue on success, nil on any error. Errors are
    /// logged with their AppleScript error number — the important
    /// ones being −1743 / −1744 (permission denied) and −600 (target
    /// app not running).
    private static func runScript(source: String) -> String? {
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
        var currentBounds: CGRect?
        var currentTabs: [TabInfo] = []

        func flushCurrent() {
            if let bounds = currentBounds {
                results.append(BrowserWindowSnapshot(boundsAX: bounds, tabs: currentTabs))
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
                guard parts.count >= 5,
                      let x1 = Double(parts[1]),
                      let y1 = Double(parts[2]),
                      let x2 = Double(parts[3]),
                      let y2 = Double(parts[4]) else {
                    continue
                }
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
