//
//  CoordinateSpace.swift
//  Window Wrangler
//
//  Per CLAUDE.md: AX (Accessibility) APIs use top-left global origin.
//  Cocoa uses bottom-left per-screen origin. ALWAYS convert at module
//  boundaries via this utility — never mix the two in the same function.
//
//  The "global" coordinate space spans all connected displays as a
//  single extended plane.
//

import AppKit

enum CoordinateSpace {

    /// Converts an AX rect (top-left global origin) to a Cocoa rect
    /// (bottom-left global origin).
    static func cocoaRect(fromAX axRect: CGRect) -> CGRect {
        // AX measures from the top of the primary display, growing
        // downward. Cocoa measures from the bottom of the primary
        // display, growing upward. Flip y around the primary display's
        // top edge.
        let primaryFrame = NSScreen.screens.first?.frame ?? .zero
        let primaryTop = primaryFrame.maxY  // Cocoa y of the primary display's top edge
        let cocoaY = primaryTop - axRect.origin.y - axRect.height
        return CGRect(x: axRect.origin.x,
                      y: cocoaY,
                      width: axRect.width,
                      height: axRect.height)
    }

    /// Converts a Cocoa rect (bottom-left global) to an AX rect
    /// (top-left global). Inverse of `cocoaRect(fromAX:)`.
    static func axRect(fromCocoa cocoaRect: CGRect) -> CGRect {
        let primaryFrame = NSScreen.screens.first?.frame ?? .zero
        let primaryTop = primaryFrame.maxY
        let axY = primaryTop - cocoaRect.origin.y - cocoaRect.height
        return CGRect(x: cocoaRect.origin.x,
                      y: axY,
                      width: cocoaRect.width,
                      height: cocoaRect.height)
    }

    /// The Cocoa-coordinate frame of the display containing `point`,
    /// or the primary display if no display contains the point.
    static func screenFrame(containing point: CGPoint) -> CGRect {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen.frame
            }
        }
        return NSScreen.screens.first?.frame ?? .zero
    }

    /// The Cocoa-coordinate VISIBLE frame (excluding menu bar + Dock)
    /// of the display containing `point`, or primary if none.
    static func visibleScreenFrame(containing point: CGPoint) -> CGRect {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen.visibleFrame
            }
        }
        return NSScreen.screens.first?.visibleFrame ?? .zero
    }
}
