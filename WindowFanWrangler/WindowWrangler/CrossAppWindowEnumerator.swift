//
//  CrossAppWindowEnumerator.swift
//  Window Wrangler
//
//  Enumerates ALL visible windows across ALL applications, not just
//  the frontmost app (which is what AXWindowEnumerator handles).
//  Used by the lasso selection flow to hit-test mouse-drag rectangles
//  against every user-facing window on the system.
//
//  Backing API: CGWindowListCopyWindowInfo (no AX needed for this
//  read-only enumeration; AX is required only when we later mutate
//  the selected windows in M6).
//
//  Coordinates: CGWindowList returns bounds in AX-style top-left
//  global origin. We convert to Cocoa (bottom-left global) at this
//  module boundary, per CLAUDE.md.
//

import AppKit
import CoreGraphics
import os

/// A window owned by some app, suitable for hit-testing and selection.
struct VisibleWindow {
    /// CGWindowID is stable for the window's lifetime (not across
    /// app restarts). We use this as the selection key.
    let windowID: CGWindowID
    /// Owning application's process ID.
    let ownerPID: pid_t
    /// Owning application's localized name ("Google Chrome", etc.).
    let ownerName: String
    /// Window frame in Cocoa coordinates (bottom-left global origin).
    let frame: CGRect
}

enum CrossAppWindowEnumerator {

    /// System processes whose windows are never something the user
    /// would want to lasso/move. `.excludeDesktopElements` is supposed
    /// to filter most of these out, but it's incomplete on recent
    /// macOS releases (notably Sequoia/Tahoe with Stage Manager,
    /// WindowManager, and an expanded Control Center). Belt-and-
    /// suspenders blocklist by owner name.
    ///
    /// Conservative list: only well-known system *services* that don't
    /// own user-facing app windows. Real apps (Finder, Mail, Safari,
    /// etc.) are NOT in here — they own legitimate windows. The Finder
    /// *desktop* window is handled separately below via a screen-bounds
    /// match, since blocking all Finder windows would break real Finder
    /// file-browser windows.
    private static let systemOwnerBlocklist: Set<String> = [
        "Window Server",
        "WindowServer",
        "Dock",
        "SystemUIServer",
        "Notification Center",
        "NotificationCenter",
        "Control Center",
        "ControlCenter",
        "Spotlight",
        "WindowManager",        // Stage Manager
        "Wallpaper",
        "loginwindow",
        "ScreenSaverEngine",
        "screencaptureui",      // floating screenshot preview thumbnail
        "Universal Control",
        "TextInputMenuAgent",
        "TextInputSwitcher",
    ]

    /// Returns all visible user-facing windows across every app, EXCEPT
    /// our own. Filters out system overlays, the Dock, the desktop, and
    /// anything too small / invisible to be a real interactive window.
    static func allVisibleWindows() -> [VisibleWindow] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        let referenceFrames = displayReferenceFrames()
        let largestDisplayArea = NSScreen.screens
            .map { $0.frame.width * $0.frame.height }
            .max() ?? 0

        return raw.compactMap { dict -> VisibleWindow? in
            // Layer 0 = normal user windows. Higher layers are
            // system overlays (status menus, screen savers, etc.).
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { return nil }

            guard let windowNumber = dict[kCGWindowNumber as String] as? CGWindowID else { return nil }
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ourPID else { return nil }

            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? "?"
            if systemOwnerBlocklist.contains(ownerName) { return nil }

            // Effectively-invisible windows aren't user-interactive.
            let alpha = (dict[kCGWindowAlpha as String] as? CGFloat) ?? 1.0
            guard alpha >= 0.05 else { return nil }

            // Bounds in AX-style (top-left global) coordinates.
            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let axRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return nil
            }

            // Size sanity: reject anything smaller than 200x100.
            if axRect.width < 200 || axRect.height < 100 { return nil }

            // Reject windows whose frame matches any reference rect
            // (full display, visible display, or union-of-all-displays).
            // Tolerance is generous because some menu-bar-area math
            // varies by 1-2pt between APIs.
            if referenceFrames.contains(where: { rectsApproximatelyEqual($0, axRect, tolerance: 4) }) {
                return nil
            }

            // Catch-all for the Finder desktop window even when its
            // bounds don't exactly match any computed reference (which
            // happens with multi-display setups and Stage Manager). The
            // Finder desktop window is always huge: if Finder owns a
            // layer-0 window whose area is at least half of the largest
            // display, it can only be the desktop. Real Finder file-
            // browser windows top out at well under that.
            if ownerName == "Finder" {
                let area = axRect.width * axRect.height
                if largestDisplayArea > 0, area >= largestDisplayArea * 0.5 {
                    return nil
                }
            }

            let cocoaRect = CoordinateSpace.cocoaRect(fromAX: axRect)
            return VisibleWindow(
                windowID: windowNumber,
                ownerPID: pid,
                ownerName: ownerName,
                frame: cocoaRect
            )
        }
    }

    /// Reference rectangles for "this is a full-display window, not a
    /// real user window." Includes each display's full frame, each
    /// display's visible frame (which excludes menu bar / Dock), and
    /// the union of all displays — covers the various shapes the
    /// Finder desktop / wallpaper window can take.
    private static func displayReferenceFrames() -> [CGRect] {
        var frames: [CGRect] = []
        for screen in NSScreen.screens {
            frames.append(CoordinateSpace.axRect(fromCocoa: screen.frame))
            frames.append(CoordinateSpace.axRect(fromCocoa: screen.visibleFrame))
        }
        if let first = NSScreen.screens.first {
            let unionCocoa = NSScreen.screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
            frames.append(CoordinateSpace.axRect(fromCocoa: unionCocoa))
        }
        return frames
    }

    private static func rectsApproximatelyEqual(
        _ a: CGRect,
        _ b: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(a.minX - b.minX) <= tolerance &&
        abs(a.minY - b.minY) <= tolerance &&
        abs(a.width  - b.width)  <= tolerance &&
        abs(a.height - b.height) <= tolerance
    }

    // MARK: - Diagnostics

    /// Logs every layer-0 window CGWindowList returns, alongside the
    /// reference frames we compare against. Not wired to any caller in
    /// the current build — kept as an ad-hoc tool to drop into a lasso
    /// or cascade flow when the filter needs investigation. To use it,
    /// add a single `CrossAppWindowEnumerator.diagnosticDump()` line at
    /// the point of interest and read the Console output.
    static func diagnosticDump() {
        Log.lasso.debug("=== CrossApp candidate dump (\(Date(), privacy: .public)) ===")

        for (i, screen) in NSScreen.screens.enumerated() {
            let f = screen.frame
            let axf = CoordinateSpace.axRect(fromCocoa: f)
            let cocoaStr = "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
            let axStr = "(\(Int(axf.minX)),\(Int(axf.minY)) \(Int(axf.width))×\(Int(axf.height)))"
            Log.lasso.debug("Display[\(i, privacy: .public)] cocoa=\(cocoaStr, privacy: .public) ax=\(axStr, privacy: .public)")
        }

        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            Log.lasso.debug("=== end dump (no window info available) ===")
            return
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        for dict in raw {
            let layer = dict[kCGWindowLayer as String] as? Int ?? -999
            let owner = dict[kCGWindowOwnerName as String] as? String ?? "?"
            let pid = dict[kCGWindowOwnerPID as String] as? pid_t ?? -1
            let alpha = (dict[kCGWindowAlpha as String] as? CGFloat) ?? -1
            let winID = dict[kCGWindowNumber as String] as? CGWindowID ?? 0
            var boundsStr = "?"
            if let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                boundsStr = "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
            }
            let me = (pid == ourPID) ? " [OURS]" : ""
            let alphaStr = String(format: "%.2f", alpha)
            Log.lasso.debug(
                "  L\(layer, privacy: .public) #\(winID, privacy: .public) α\(alphaStr, privacy: .public) [\(owner, privacy: .public)] \(boundsStr, privacy: .public)\(me, privacy: .public)"
            )
        }
        Log.lasso.debug("=== end dump ===")
    }
}
