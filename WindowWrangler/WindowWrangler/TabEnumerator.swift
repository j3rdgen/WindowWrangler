//
//  TabEnumerator.swift
//  Window Wrangler
//
//  SPIKE — investigation-only module for the Tab X-Ray feature.
//
//  Goal: determine whether Chromium browsers expose per-tab geometry
//  through the Accessibility API. If they do, we can draw a transparent
//  overlay band over each tab in the tab strip (highlighting duplicates
//  by URL) without needing a browser extension or any Chrome launch
//  flags.
//
//  This module reports to the Console via os.Logger what the AX tree
//  actually exposes for a given browser process. It does not change any
//  UI, does not modify any windows, and does not send any AppleScript
//  commands beyond re-using the existing BrowserScripting snapshot
//  (which the Corral feature already uses for tab URL enumeration).
//
//  Invoked via the "Debug: Scan Browser Tabs → Console" menu item
//  (added only on the tab-duplicate-xray branch). Remove the menu item
//  + this file for easy revert.
//

import AppKit
import ApplicationServices
import os

enum TabEnumerator {

    /// One tab's AX exposure, as reported by the browser process.
    struct AXTabInfo {
        let title: String?         // kAXTitle, if the browser sets it
        let role: String?          // kAXRole — expected "AXRadioButton" for Chrome tabs, "AXTab" elsewhere
        let subrole: String?       // kAXSubrole, if any
        let frameAX: CGRect?       // top-left global AX coords
        let selected: Bool?        // kAXSelected, if exposed
    }

    /// Walks every running supported-browser process and logs what the
    /// AX tree exposes for its tab strip. Pairs that with the existing
    /// BrowserScripting snapshot (window + tab URLs via AppleScript) so
    /// the console output shows side-by-side: what AX sees vs what
    /// AppleScript sees.
    @MainActor
    static func scanAndLog() {
        let runningApps = NSWorkspace.shared.runningApplications
        var scanned = 0

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            guard BrowserScripting.chromiumBundleIDs.contains(bundleID)
                    || bundleID == BrowserScripting.safariBundleID else { continue }

            scanned += 1
            logReport(for: app, bundleID: bundleID)
        }

        if scanned == 0 {
            Log.tabXray.info("No supported browsers running.")
        } else {
            Log.tabXray.info("Finished scanning \(scanned, privacy: .public) browser(s).")
        }
    }

    // MARK: - Per-app report

    @MainActor
    private static func logReport(for app: NSRunningApplication, bundleID: String) {
        let name = app.localizedName ?? bundleID
        let pid = app.processIdentifier
        Log.tabXray.info("─── \(name, privacy: .public) (pid \(pid, privacy: .public)) ───")

        // Side A — AX tab exposure.
        let axWindows = axWindowsForTabEnumeration(pid: pid)
        Log.tabXray.info("  AX: \(axWindows.count, privacy: .public) window(s)")
        for (wIdx, window) in axWindows.enumerated() {
            let tabs = findTabs(under: window)
            Log.tabXray.info("    window[\(wIdx, privacy: .public)]: AX reports \(tabs.count, privacy: .public) tab-like element(s)")
            for (tIdx, tab) in tabs.enumerated() {
                let role = tab.role ?? "?"
                let title = tab.title ?? "(no title)"
                let frameStr: String
                if let f = tab.frameAX {
                    frameStr = "x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) w=\(Int(f.size.width)) h=\(Int(f.size.height))"
                } else {
                    frameStr = "(no frame)"
                }
                Log.tabXray.info("      tab[\(tIdx, privacy: .public)] role=\(role, privacy: .public) \(frameStr, privacy: .public) \"\(title, privacy: .public)\"")
            }
        }

        // Side B — AppleScript tab URLs (via existing BrowserScripting).
        if let snapshot = BrowserScripting.snapshotBrowserWindows(bundleID: bundleID) {
            Log.tabXray.info("  AppleScript: \(snapshot.count, privacy: .public) window(s)")
            for (wIdx, window) in snapshot.enumerated() {
                Log.tabXray.info("    window[\(wIdx, privacy: .public)]: \(window.tabs.count, privacy: .public) tab(s)")
                for (tIdx, tab) in window.tabs.enumerated() {
                    let normalized = BrowserScripting.normalizedURL(tab.url)
                    Log.tabXray.info("      tab[\(tIdx, privacy: .public)] url=\(normalized, privacy: .public) title=\"\(tab.title, privacy: .public)\"")
                }
            }

            // Side C — duplicate detection across all windows of this app.
            logDuplicateReport(bundleID: name, snapshot: snapshot)
        } else {
            Log.tabXray.info("  AppleScript: snapshot unavailable (Automation permission or app not scriptable)")
        }
    }

    // MARK: - AX walk

    @MainActor
    private static func axWindowsForTabEnumeration(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &value
        )
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// Depth-limited search for tab-like elements under a window. Chrome
    /// typically exposes tabs as AXRadioButton elements inside a tab
    /// group; Safari uses AXTab. We check both.
    @MainActor
    private static func findTabs(under element: AXUIElement, depth: Int = 0, maxDepth: Int = 8) -> [AXTabInfo] {
        guard depth < maxDepth else { return [] }
        guard let children = children(of: element) else { return [] }

        var found: [AXTabInfo] = []
        for child in children {
            let role = stringAttr(kAXRoleAttribute, of: child)
            // Chrome: AXRadioButton inside an AXTabGroup. Safari: AXTab.
            // Firefox: AXTab. Edge/Brave/Opera/Vivaldi: AXRadioButton
            // inside AXTabGroup (same as Chrome).
            let isTabLike = (role == "AXTab")
                || (role == "AXRadioButton" && isUnderTabGroup(child, depth: 0))
            if isTabLike {
                found.append(AXTabInfo(
                    title: stringAttr(kAXTitleAttribute, of: child)
                        ?? stringAttr(kAXDescriptionAttribute, of: child),
                    role: role,
                    subrole: stringAttr(kAXSubroleAttribute, of: child),
                    frameAX: frameAttr(of: child),
                    selected: boolAttr(kAXSelectedAttribute, of: child)
                ))
            } else {
                // Only recurse into non-tab containers.
                found.append(contentsOf: findTabs(under: child, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return found
    }

    /// Heuristic: a radio button that lives inside an AXTabGroup
    /// (direct parent only, since Chrome's tree is: AXTabGroup →
    /// AXRadioButton per tab). We use kAXParentAttribute to check.
    @MainActor
    private static func isUnderTabGroup(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 3 else { return false }
        var parentValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXParentAttribute as CFString, &parentValue
        )
        guard result == .success else { return false }
        guard CFGetTypeID(parentValue!) == AXUIElementGetTypeID() else { return false }
        let parent = parentValue as! AXUIElement
        if stringAttr(kAXRoleAttribute, of: parent) == "AXTabGroup" { return true }
        if stringAttr(kAXSubroleAttribute, of: parent) == "AXTabGroup" { return true }
        return isUnderTabGroup(parent, depth: depth + 1)
    }

    // MARK: - Duplicate detection

    private static func logDuplicateReport(bundleID: String, snapshot: [BrowserScripting.BrowserWindowSnapshot]) {
        // Group all (windowIdx, tabIdx, title) by normalized URL.
        var buckets: [String: [(windowIdx: Int, tabIdx: Int, title: String)]] = [:]
        for (wIdx, window) in snapshot.enumerated() {
            for (tIdx, tab) in window.tabs.enumerated() {
                let key = BrowserScripting.normalizedURL(tab.url)
                guard !key.isEmpty else { continue }
                buckets[key, default: []].append((wIdx, tIdx, tab.title))
            }
        }
        let dupeGroups = buckets.filter { $0.value.count >= 2 }
        if dupeGroups.isEmpty {
            Log.tabXray.info("  DUPES: none across \(snapshot.count, privacy: .public) window(s)")
            return
        }
        Log.tabXray.info("  DUPES: \(dupeGroups.count, privacy: .public) duplicate group(s) found")
        for (url, members) in dupeGroups.sorted(by: { $0.value.count > $1.value.count }) {
            Log.tabXray.info("    url=\(url, privacy: .public) × \(members.count, privacy: .public)")
            for m in members {
                Log.tabXray.info("      → window[\(m.windowIdx, privacy: .public)] tab[\(m.tabIdx, privacy: .public)] \"\(m.title, privacy: .public)\"")
            }
        }
    }

    // MARK: - AX attribute helpers

    @MainActor
    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        ) == .success else { return nil }
        return value as? [AXUIElement]
    }

    @MainActor
    private static func stringAttr(_ key: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    @MainActor
    private static func boolAttr(_ key: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    @MainActor
    private static func frameAttr(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let p = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let s = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard p == .success, s == .success else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        if let v = posValue, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &position)
        }
        if let v = sizeValue, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}
