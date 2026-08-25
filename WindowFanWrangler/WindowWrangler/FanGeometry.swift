//
//  FanGeometry.swift
//  Window Wrangler
//
//  Pure geometry for the cascade fan layout. NO AX calls, NO AppKit
//  beyond CGRect/CGPoint — this is unit-testable in isolation, per
//  CLAUDE.md's architecture principles.
//
//  Input: ordered list of window frames (front-to-back), screen bounds,
//         reveal amounts, direction.
//  Output: ordered list of target frames satisfying:
//    1) Each window i+1 is offset from window i by (±lateral, +header)
//       in Cocoa coordinates (y-up).
//    2) The frontmost window's screen position is preserved if possible.
//    3) NO window falls outside the screen bounds (firm constraint).
//
//  When the natural cascade would push windows off-screen, the
//  algorithm first tries a rigid shift of the entire cascade. If even
//  the rigid-shifted cascade exceeds screen bounds, reveal amounts are
//  proportionally reduced until it fits.
//

import Foundation
import CoreGraphics

enum CascadeDirection {
    /// Anchor (front) at bottom-left of arrangement; back windows fan
    /// up-and-right. Matches the screenshot in the M4 design review.
    case downLeft
    /// Mirror of downLeft: back windows fan up-and-left.
    case downRight
}

enum FanGeometry {

    /// Compute target frames for a cascade of windows.
    ///
    /// All coordinates are Cocoa (bottom-left global origin). Convert
    /// AX coordinates to Cocoa via `CoordinateSpace.cocoaRect(fromAX:)`
    /// at the AX module boundary before passing them in here.
    ///
    /// All windows are uniformly resized to `targetSize`. The anchor
    /// (windows[0]) provides the cascade's starting position; subsequent
    /// windows offset by (lateralReveal, headerReveal) per index.
    ///
    /// - Parameters:
    ///   - windows: window frames, ordered front-to-back. `windows[0]` is
    ///     the anchor; its current position seeds the cascade.
    ///   - screen: the visible Cocoa frame the cascade must fit within
    ///     (usually `NSScreen.visibleFrame` of the anchor's display).
    ///   - targetSize: the uniform size every cascaded window is
    ///     resized to. The caller chooses this — typically a percentage
    ///     of the screen.
    ///   - headerReveal: vertical distance each successive back window's
    ///     top extends above the next-front window's top. Default 28pt.
    ///   - lateralReveal: horizontal distance each successive back window
    ///     is offset from the next-front window's left edge. Default 60pt.
    ///   - direction: `.downLeft` or `.downRight`.
    /// - Returns: target Cocoa frames in the same order as `windows`.
    ///   `result[i]` is where `windows[i]` should be moved to.
    static func computeCascade(
        windows: [CGRect],
        screen: CGRect,
        targetSize: CGSize,
        headerReveal: CGFloat = 28,
        lateralReveal: CGFloat = 60,
        direction: CascadeDirection,
        anchorOrigin: CGPoint? = nil
    ) -> [CGRect] {
        guard !windows.isEmpty else { return [] }
        guard windows.count > 1 else {
            // Single window: just resize at current position (or at the
            // explicit anchor when provided).
            return [CGRect(origin: anchorOrigin ?? windows[0].origin, size: targetSize)]
        }

        // The cascade anchor is normally the front window's current
        // origin (single-app cascade behavior). A caller can override
        // it via `anchorOrigin` — this is how the multi-app "cascade all
        // apps" mode positions each app's pile relative to a shared
        // origin instead of each app's own front window.
        let anchor = anchorOrigin ?? windows[0].origin

        // Step 1: compute targets with natural offsets, all at targetSize,
        // anchored on `anchor`.
        let initialTargets = naturalCascade(
            windows: windows,
            anchorOrigin: anchor,
            targetSize: targetSize,
            headerReveal: headerReveal,
            lateralReveal: lateralReveal,
            direction: direction
        )

        // Step 2: compute the bounding box.
        let bounds = boundingBox(of: initialTargets)

        // Step 3: if the bounding box fits in the screen, only shift
        // enough to bring any out-of-bounds edges back in.
        if bounds.width <= screen.width && bounds.height <= screen.height {
            return shiftToFit(initialTargets, into: screen)
        }

        // Step 4: bounding box exceeds the screen. Reduce reveals
        // proportionally until the cascade fits, then re-cascade.
        let n = CGFloat(windows.count - 1)  // number of "gaps"
        let availableWidthForOffsets = max(0, screen.width - targetSize.width)
        let availableHeightForOffsets = max(0, screen.height - targetSize.height)

        let maxLateral = n > 0 ? availableWidthForOffsets / n : lateralReveal
        let maxHeader = n > 0 ? availableHeightForOffsets / n : headerReveal

        let clampedHeader = min(headerReveal, max(0, maxHeader))
        let clampedLateral = min(lateralReveal, max(0, maxLateral))

        let reducedTargets = naturalCascade(
            windows: windows,
            anchorOrigin: anchor,
            targetSize: targetSize,
            headerReveal: clampedHeader,
            lateralReveal: clampedLateral,
            direction: direction
        )

        return shiftToFit(reducedTargets, into: screen)
    }

    // MARK: - Pure helpers

    /// Lays out windows in a cascade starting from `anchorOrigin`,
    /// all resized to `targetSize`. Pure: no clamping, no shifting.
    private static func naturalCascade(
        windows: [CGRect],
        anchorOrigin: CGPoint,
        targetSize: CGSize,
        headerReveal: CGFloat,
        lateralReveal: CGFloat,
        direction: CascadeDirection
    ) -> [CGRect] {
        let lateralSign: CGFloat = (direction == .downLeft) ? 1 : -1
        return windows.enumerated().map { index, _ in
            let i = CGFloat(index)
            let dx = lateralSign * i * lateralReveal
            // Cocoa y-up: "above the anchor" means positive y offset.
            let dy = i * headerReveal
            return CGRect(
                x: anchorOrigin.x + dx,
                y: anchorOrigin.y + dy,
                width: targetSize.width,
                height: targetSize.height
            )
        }
    }

    /// Union of all rects.
    private static func boundingBox(of rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Shifts all rects by a single rigid translation so that the
    /// bounding box fits within `screen` to the extent possible.
    /// Preserves relative arrangement.
    private static func shiftToFit(_ rects: [CGRect], into screen: CGRect) -> [CGRect] {
        let bounds = boundingBox(of: rects)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if bounds.minX < screen.minX {
            dx = screen.minX - bounds.minX
        } else if bounds.maxX > screen.maxX {
            dx = screen.maxX - bounds.maxX
        }
        if bounds.minY < screen.minY {
            dy = screen.minY - bounds.minY
        } else if bounds.maxY > screen.maxY {
            dy = screen.maxY - bounds.maxY
        }
        if dx == 0 && dy == 0 { return rects }
        return rects.map { $0.offsetBy(dx: dx, dy: dy) }
    }
}
