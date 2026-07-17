//
//  AXWindowEnumerator.swift
//  Window Wrangler
//
//  Wraps the Accessibility API for fetching the windows of a given
//  application. Per CLAUDE.md, this is one of the dedicated modules the
//  rest of the app calls into — the AX surface stops here.
//
//  Returns Cocoa-coordinate frames (the AX → Cocoa conversion happens
//  in this module so callers never deal with AX coordinate space).
//

import AppKit
import ApplicationServices
import os

/// A reference to one window plus its current frame in Cocoa coords.
struct EnumeratedWindow {
    let axElement: AXUIElement
    let frame: CGRect  // Cocoa coordinates (bottom-left global origin)
}

enum AXWindowEnumerator {

    /// Queries the AX windows of the given app, ordered front-to-back
    /// (z-order) per macOS. Filters out non-cascadable AX elements
    /// that the OS reports as "windows" but aren't standard user windows
    /// (popovers, PiP, notification banners, minimized windows, etc.).
    ///
    /// Logs a single summary line per call. Cascade calls this up to
    /// 8 times per invocation, so per-step logging was producing >30
    /// console lines per cascade and burying real signal.
    static func windows(of app: NSRunningApplication) -> [EnumeratedWindow] {
        let appName = app.localizedName ?? "?"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )

        guard result == .success else {
            Log.ax.error(
                "'\(appName, privacy: .public)' pid=\(app.processIdentifier, privacy: .public) kAXWindows query failed (code \(result.rawValue, privacy: .public))"
            )
            return []
        }

        guard let windows = windowsValue as? [AXUIElement] else {
            Log.ax.error(
                "'\(appName, privacy: .public)' pid=\(app.processIdentifier, privacy: .public) kAXWindows returned a non-array value"
            )
            return []
        }

        // Allowed subroles. We include the three subroles that macOS
        // apps use for their main user-facing windows:
        //
        //   AXStandardWindow  — normal titled app windows (default)
        //   AXDialog          — Zoom login, some music/podcast apps'
        //                       main window, IDE splash screens, native
        //                       "About This Mac"-style panels, etc.
        //   AXFloatingWindow  — Zoom's floating meeting window, some
        //                       music/media control windows, etc.
        //
        // We DELIBERATELY exclude AXSystemDialog and
        // AXSystemFloatingWindow: those are system-owned overlays
        // (permission prompts, spotlight-adjacent UI) not user windows.
        //
        // The size filter below (200×100 minimum) still rejects tiny
        // alerts and popup dialogs, so allowing AXDialog/AXFloatingWindow
        // here doesn't sweep in every "Are you sure?" prompt.
        let allowedSubroles: Set<String> = [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXFloatingWindowSubrole as String,
        ]

        var filteredCount = 0
        let enumerated = windows.compactMap { element -> EnumeratedWindow? in
            // Subrole filter: allow standard/dialog/floating windows.
            // If the element doesn't report a subrole, INCLUDE it —
            // some apps' main windows return nil for AXSubrole, and
            // filtering those out was excluding real windows.
            if let subrole = stringAttribute(kAXSubroleAttribute, of: element),
               !allowedSubroles.contains(subrole) {
                Log.ax.info(
                    "Filtered \(appName, privacy: .public) window — subrole '\(subrole, privacy: .public)' not in allowlist"
                )
                filteredCount += 1
                return nil
            }
            // Minimized windows aren't visible to the user.
            if let minimized = boolAttribute(kAXMinimizedAttribute, of: element), minimized {
                Log.ax.info(
                    "Filtered \(appName, privacy: .public) window — minimized"
                )
                filteredCount += 1
                return nil
            }
            guard let frameAX = currentFrame(of: element) else {
                Log.ax.info(
                    "Filtered \(appName, privacy: .public) window — no frame"
                )
                filteredCount += 1
                return nil
            }
            // Size heuristic: anything smaller than 200×100 is almost
            // certainly a system overlay or a small alert dialog, not
            // a real user-facing window.
            if frameAX.width < 200 || frameAX.height < 100 {
                Log.ax.info(
                    "Filtered \(appName, privacy: .public) window — size \(Int(frameAX.width), privacy: .public)×\(Int(frameAX.height), privacy: .public) below 200×100 minimum"
                )
                filteredCount += 1
                return nil
            }
            // Backdrop / pseudo-window filter. Historically this filter
            // caught display-sized non-settable windows in ANY app, on
            // the theory that only backdrops and fullscreen frames fit
            // that pattern. That was too broad — a zoomed / maximized
            // TextEdit (or any other regular app) window can hit the
            // "display-size + non-settable" signature transiently and
            // then falsely get filtered out of cascade / group-drag /
            // Corral capture. Scoping the filter to Finder specifically
            // keeps the original problem (invisible Finder Desktop
            // hijacking anchor slot) solved without dropping legit
            // windows from other apps.
            if app.bundleIdentifier == "com.apple.finder"
                && isBackdropOrFullscreen(frameAX: frameAX, element: element) {
                Log.ax.info(
                    "Filtered \(appName, privacy: .public) window — Finder Desktop backdrop"
                )
                filteredCount += 1
                return nil
            }
            let frameCocoa = CoordinateSpace.cocoaRect(fromAX: frameAX)
            return EnumeratedWindow(axElement: element, frame: frameCocoa)
        }

        Log.ax.info(
            "'\(appName, privacy: .public)' pid=\(app.processIdentifier, privacy: .public) → \(enumerated.count, privacy: .public) window(s) (\(filteredCount, privacy: .public) filtered, \(windows.count, privacy: .public) raw)"
        )
        return enumerated
    }

    /// True if this window is a display-spanning backdrop or fullscreen
    /// mode window. Signature: size matches a connected display's full
    /// frame within a 5pt tolerance AND `kAXSizeAttribute` is
    /// non-settable. Both are needed because a user could legitimately
    /// resize a normal window to exactly display size — but that
    /// window would still report settable=true.
    private static func isBackdropOrFullscreen(
        frameAX: CGRect,
        element: AXUIElement
    ) -> Bool {
        let matchesADisplay = NSScreen.screens.contains { screen in
            let sf = screen.frame
            return abs(frameAX.width - sf.width) < 5 &&
                   abs(frameAX.height - sf.height) < 5
        }
        guard matchesADisplay else { return false }
        // Only skip if it's also non-resizable — user-resized normal
        // windows that happen to match display size stay in the cascade.
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            element, kAXSizeAttribute as CFString, &settable
        )
        return result == .success && !settable.boolValue
    }

    // MARK: - AX attribute helpers

    private static func stringAttribute(_ key: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ key: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    /// Reads the current frame of a single window in AX (top-left global)
    /// coordinates. Returns nil if AX refuses to give us position or size.
    static func currentFrame(of axWindow: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        let posResult = AXUIElementCopyAttributeValue(
            axWindow, kAXPositionAttribute as CFString, &positionValue
        )
        let sizeResult = AXUIElementCopyAttributeValue(
            axWindow, kAXSizeAttribute as CFString, &sizeValue
        )
        guard posResult == .success, sizeResult == .success else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero

        if let posVal = positionValue,
           CFGetTypeID(posVal) == AXValueGetTypeID() {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        }
        if let sizeVal = sizeValue,
           CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }
}
