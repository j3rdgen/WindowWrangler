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
//  - Fully click-through (`ignoresMouseEvents = true`). The user closes
//    duplicates with Chrome's own X; our markers only indicate which
//    tabs are the same page. Markers refresh at 1Hz while active, so a
//    close via Chrome's native X updates the display within a second.
//  - Chrome-only for MVP. Session 3 adds Brave/Edge/Vivaldi/Opera/
//    Chromium (same AX structure). Safari is Session 4.
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

    /// True while markers are visible on screen.
    private(set) var isActive: Bool = false

    /// One panel per NSScreen, keyed by screen's displayID.
    private var panelByDisplay: [CGDirectDisplayID: NSPanel] = [:]
    private var viewByDisplay: [CGDirectDisplayID: MarkerView] = [:]

    /// Fast refresh timer (60Hz). Re-enumerates AX tab POSITIONS only,
    /// using the cached AppleScript snapshot — never blocks on
    /// AppleScript. Drives smooth tracking as the user drags/resizes
    /// browser windows.
    private var fastRefreshTimer: Timer?

    /// Slow prefetch timer (every 2s). Kicks off asynchronous
    /// `BrowserScripting.prefetchAllBrowsers()` to keep the URL cache
    /// fresh. The fetch itself runs in the background; the fast tick
    /// only ever reads from the resulting cache.
    private var prefetchTimer: Timer?

    // MARK: - Public API

    /// Toggles the overlay on or off. No-op during the brief moment
    /// between activate and the first refresh.
    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate()
        }
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        Log.tabXray.info("TabMarkerOverlay activated")
        createPanelsForAllScreens()

        // Kick off the first prefetch immediately so the cache
        // populates while the user looks at the markers for the first
        // time. Everything else from here on reads the cache only.
        BrowserScripting.prefetchAllBrowsers()

        // Fast tick: 60Hz. AX enumeration is microseconds-cheap, so
        // the entire pipeline (read AX positions, re-match to cached
        // AppleScript snapshot, re-render) stays well inside a frame
        // budget. Smooth tracking during window drags/resizes.
        // Timer scheduled from MainActor context fires on main runloop
        // — assumeIsolated is the correct bridge back to MainActor
        // without the Task overhead that would run per tick.
        fastRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }

        // Slow tick: every 2s re-trigger an asynchronous prefetch so
        // the URL/title cache tracks tab add/remove/close within a
        // couple of seconds. Prefetch itself runs on a background
        // thread; this timer just kicks it off.
        prefetchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated { BrowserScripting.prefetchAllBrowsers() }
        }

        // One free render pass so markers appear immediately for
        // whatever's already in cache (common case: lasso coordinator
        // has prefetched recently).
        refreshNow()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        Log.tabXray.info("TabMarkerOverlay deactivated")
        fastRefreshTimer?.invalidate()
        fastRefreshTimer = nil
        prefetchTimer?.invalidate()
        prefetchTimer = nil
        for panel in panelByDisplay.values {
            panel.orderOut(nil)
        }
        panelByDisplay.removeAll(keepingCapacity: true)
        viewByDisplay.removeAll(keepingCapacity: true)
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

    // MARK: - Refresh pipeline

    private func refreshNow() {
        let markers = computeMarkers()
        // Distribute markers to the display they fall on.
        var markersByDisplay: [CGDirectDisplayID: [TabMarker]] = [:]
        for marker in markers {
            markersByDisplay[marker.displayID, default: []].append(marker)
        }
        for (displayID, view) in viewByDisplay {
            view.markers = markersByDisplay[displayID] ?? []
            view.needsDisplay = true
        }
    }

    /// Returns every marker (duplicate tab) that should be visible on
    /// screen right now. Pure computation — no AppKit side-effects.
    private func computeMarkers() -> [TabMarker] {
        var allMarkers: [TabMarker] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            // MVP: Chrome only. Session 3 widens to all Chromium
            // bundle IDs via BrowserScripting.chromiumBundleIDs.
            guard bundleID == "com.google.Chrome" else { continue }

            allMarkers.append(contentsOf: markersFor(app: app, bundleID: bundleID))
        }

        return allMarkers
    }

    private func markersFor(app: NSRunningApplication, bundleID: String) -> [TabMarker] {
        // Side A: AppleScript snapshot — READ FROM CACHE ONLY. The
        // blocking fetch is NEVER triggered from here; the prefetch
        // timer owns the fill-and-refresh cadence on a background
        // thread. If cache is empty on activation, we render nothing
        // for one or two 2s cycles until prefetch lands.
        guard let snapshot = BrowserScripting.cachedSnapshot(for: bundleID) else {
            return []
        }

        // Build the duplicate-URL → color map. Deterministic sort so
        // the same URL always gets the same color across refreshes.
        let colorByURL = assignColors(snapshot: snapshot)
        if colorByURL.isEmpty { return [] }  // nothing duplicated

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
            // Count equality is the sanity check — matched windows
            // must agree on tab count or we skip. Tab add/remove is
            // the one scenario this guards against; the next 2s
            // prefetch refills the cache and we recover.
            guard axWindow.tabs.count == appleScriptWindow.tabs.count else { continue }
            for (axIdx, axTab) in axWindow.tabs.enumerated() {
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
    /// window from `snapshot`. Greedy, unique assignment: once an
    /// AppleScript window is used, it can't be matched to another AX
    /// window. Candidate quality is primarily tab-count equality (a
    /// strong signature during ordinary use), tie-broken by frame
    /// center distance. Threshold is 500pt — generous enough that a
    /// window move in flight won't drop markers mid-drag.
    private func pairAXToAppleScript(
        axWindows: [AXWindowTabs],
        snapshot: [BrowserScripting.BrowserWindowSnapshot]
    ) -> [(AXWindowTabs, BrowserScripting.BrowserWindowSnapshot)] {
        var used = Set<Int>()  // indices into snapshot already matched
        var result: [(AXWindowTabs, BrowserScripting.BrowserWindowSnapshot)] = []

        for axWindow in axWindows {
            guard let axFrame = axWindow.windowFrameAX else { continue }
            let axCenter = CGPoint(x: axFrame.midX, y: axFrame.midY)
            let axTabCount = axWindow.tabs.count

            var best: (idx: Int, score: Double)? = nil
            for (idx, candidate) in snapshot.enumerated() where !used.contains(idx) {
                let b = candidate.boundsAX
                let dx = b.midX - axCenter.x
                let dy = b.midY - axCenter.y
                let distance = sqrt(dx * dx + dy * dy)
                guard distance <= 500 else { continue }
                // Score: tab-count match is worth a lot (strong signal
                // of the right window); frame distance tie-breaks.
                // Lower score is better.
                let tabCountPenalty = (candidate.tabs.count == axTabCount) ? 0.0 : 1_000.0
                let score = tabCountPenalty + distance
                if best == nil || score < best!.score {
                    best = (idx, score)
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

    /// Palette tuned for color-blind safety (Okabe-Ito-adjacent).
    /// Picked in order; groups 8+ wrap and repeat.
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.00, green: 0.45, blue: 0.70, alpha: 1.0),  // blue
        NSColor(calibratedRed: 0.84, green: 0.37, blue: 0.00, alpha: 1.0),  // vermillion
        NSColor(calibratedRed: 0.00, green: 0.62, blue: 0.45, alpha: 1.0),  // bluish green
        NSColor(calibratedRed: 0.90, green: 0.62, blue: 0.00, alpha: 1.0),  // orange
        NSColor(calibratedRed: 0.80, green: 0.47, blue: 0.65, alpha: 1.0),  // reddish purple
        NSColor(calibratedRed: 0.34, green: 0.71, blue: 0.91, alpha: 1.0),  // sky blue
        NSColor(calibratedRed: 0.94, green: 0.89, blue: 0.26, alpha: 1.0),  // yellow
    ]

    private func assignColors(snapshot: [BrowserScripting.BrowserWindowSnapshot]) -> [String: NSColor] {
        // Count occurrences of each normalized URL across all windows.
        var counts: [String: Int] = [:]
        for window in snapshot {
            for tab in window.tabs {
                let key = BrowserScripting.normalizedURL(tab.url)
                guard !key.isEmpty else { continue }
                counts[key, default: 0] += 1
            }
        }
        // Keep only URLs that appear ≥2 times.
        let duplicateURLs = counts.filter { $0.value >= 2 }.keys.sorted()
        var result: [String: NSColor] = [:]
        for (idx, url) in duplicateURLs.enumerated() {
            result[url] = Self.palette[idx % Self.palette.count]
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
private final class MarkerView: NSView {
    var markers: [TabMarker] = []
    /// This screen's origin in Cocoa coords — used by hit-testing
    /// debugging if ever added. For draw itself we work in local coords
    /// since each panel's frame equals its screen's frame.
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
