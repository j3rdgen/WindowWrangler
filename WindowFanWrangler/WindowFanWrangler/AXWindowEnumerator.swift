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
    /// Logs diagnostics at each pipeline step.
    static func windows(of app: NSRunningApplication) -> [EnumeratedWindow] {
        let appName = app.localizedName ?? "?"
        NSLog("[\(AppInfo.displayName)] AX: querying windows of '\(appName)' pid=\(app.processIdentifier)")

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )

        guard result == .success else {
            NSLog("[\(AppInfo.displayName)] AX: kAXWindowsAttribute query failed " +
                  "(code \(result.rawValue))")
            return []
        }

        guard let windows = windowsValue as? [AXUIElement] else {
            NSLog("[\(AppInfo.displayName)] AX: query succeeded but value isn't [AXUIElement]")
            return []
        }

        NSLog("[\(AppInfo.displayName)] AX: '\(appName)' reported \(windows.count) raw window(s)")

        var filteredCount = 0
        let enumerated = windows.compactMap { element -> EnumeratedWindow? in
            // Subrole filter: only standard windows (skip popovers, dialogs,
            // system panels, floating windows, etc.).
            if let subrole = stringAttribute(.subrole, of: element),
               subrole != kAXStandardWindowSubrole as String {
                filteredCount += 1
                return nil
            }
            // Minimized windows aren't visible to the user.
            if let minimized = boolAttribute(.minimized, of: element), minimized {
                filteredCount += 1
                return nil
            }
            guard let frameAX = currentFrame(of: element) else {
                NSLog("[\(AppInfo.displayName)] AX: skipping window with no readable frame")
                return nil
            }
            // Size heuristic: anything smaller than 200×100 is almost
            // certainly a system overlay, not a real window.
            if frameAX.width < 200 || frameAX.height < 100 {
                filteredCount += 1
                return nil
            }
            let frameCocoa = CoordinateSpace.cocoaRect(fromAX: frameAX)
            return EnumeratedWindow(axElement: element, frame: frameCocoa)
        }

        if filteredCount > 0 {
            NSLog("[\(AppInfo.displayName)] AX: filtered out \(filteredCount) non-cascadable element(s)")
        }
        NSLog("[\(AppInfo.displayName)] AX: returning \(enumerated.count) enumerated window(s)")
        return enumerated
    }

    // MARK: - AX attribute helpers

    private enum Attribute {
        case subrole, minimized

        var key: CFString {
            switch self {
            case .subrole:   return kAXSubroleAttribute as CFString
            case .minimized: return kAXMinimizedAttribute as CFString
            }
        }
    }

    private static func stringAttribute(_ attr: Attribute, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr.key, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ attr: Attribute, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr.key, &value) == .success else { return nil }
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
