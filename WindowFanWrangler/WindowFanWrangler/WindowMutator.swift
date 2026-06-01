//
//  WindowMutator.swift
//  Window Wrangler
//
//  Wraps the AX calls for moving and resizing windows. Per CLAUDE.md,
//  this is the dedicated mutation module — the rest of the app calls
//  into here rather than touching AX directly.
//
//  All input frames are expected in Cocoa coordinates. Conversion to
//  AX (top-left global) happens here at the module boundary.
//

import AppKit
import ApplicationServices

enum WindowMutator {

    /// Moves the given window to the given Cocoa-coordinate frame.
    /// Both position and size are set. Returns true on full success.
    ///
    /// Some apps (Chrome notably) clamp or partially refuse AX size
    /// changes. The fix used by Rectangle/Magnet/yabai is: set size,
    /// set position, set size again. The second size call overrides
    /// any clamping the app applied during the position update. We
    /// follow that pattern and log a warning if the final readback
    /// doesn't match the requested size.
    @discardableResult
    static func setFrame(_ frame: CGRect, of axWindow: AXUIElement) -> Bool {
        let axFrame = CoordinateSpace.axRect(fromCocoa: frame)

        var position = axFrame.origin
        var size = axFrame.size

        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        // Size → Position → Size again. The double-size dance defeats
        // most app-side clamping on macOS.
        let s1 = AXUIElementSetAttributeValue(
            axWindow, kAXSizeAttribute as CFString, sizeValue
        )
        let p = AXUIElementSetAttributeValue(
            axWindow, kAXPositionAttribute as CFString, posValue
        )
        let s2 = AXUIElementSetAttributeValue(
            axWindow, kAXSizeAttribute as CFString, sizeValue
        )

        // Read back the actual frame so we can log discrepancies.
        if let actualAX = AXWindowEnumerator.currentFrame(of: axWindow) {
            let actual = CoordinateSpace.cocoaRect(fromAX: actualAX)
            let wantedW = Int(frame.width.rounded())
            let wantedH = Int(frame.height.rounded())
            let gotW = Int(actual.width.rounded())
            let gotH = Int(actual.height.rounded())
            if abs(gotW - wantedW) > 4 || abs(gotH - wantedH) > 4 {
                NSLog("[\(AppInfo.displayName)] Mutator: app refused resize — " +
                      "asked \(wantedW)×\(wantedH), got \(gotW)×\(gotH)")
            }
        }

        return s1 == .success && p == .success && s2 == .success
    }

    /// Applies a batch of (window, target frame) pairs in front-to-back
    /// order. Returns the number of successful mutations.
    @discardableResult
    static func applyBatch(_ moves: [(axWindow: AXUIElement, target: CGRect)]) -> Int {
        var successes = 0
        for move in moves {
            if setFrame(move.target, of: move.axWindow) {
                successes += 1
            }
        }
        return successes
    }
}
