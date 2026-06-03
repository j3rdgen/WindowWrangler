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

    /// Returns all visible user-facing windows across every app, EXCEPT
    /// our own. Filters out system overlays, the Dock, the desktop, and
    /// anything too small to be a real window.
    static func allVisibleWindows() -> [VisibleWindow] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier

        return raw.compactMap { dict -> VisibleWindow? in
            // Layer 0 = normal user windows. Higher layers are
            // system overlays (status menus, screen savers, etc.).
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { return nil }

            guard let windowNumber = dict[kCGWindowNumber as String] as? CGWindowID else { return nil }
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ourPID else { return nil }

            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? "?"

            // Bounds in AX-style (top-left global) coordinates.
            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let axRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return nil
            }

            // Size sanity: reject anything smaller than 200x100 as
            // probably-not-a-real-window. Matches the AXWindowEnumerator
            // filter for consistency.
            if axRect.width < 200 || axRect.height < 100 { return nil }

            let cocoaRect = CoordinateSpace.cocoaRect(fromAX: axRect)
            return VisibleWindow(
                windowID: windowNumber,
                ownerPID: pid,
                ownerName: ownerName,
                frame: cocoaRect
            )
        }
    }
}
