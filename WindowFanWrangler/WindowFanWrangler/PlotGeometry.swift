//
//  PlotGeometry.swift
//  Window Wrangler
//
//  Pure geometry for Plot (Snap Window to Drawn Area). No AppKit UI,
//  no AX, no side effects — every function takes plain values and
//  returns plain values. This is the only place the 15%-zone snap
//  logic lives; the coordinator and overlay call in here for every
//  drag-update and mouse-up decision.
//
//  Coordinate space: Cocoa (bottom-left global). Every rect,
//  visibleFrame, and point in this file is Cocoa. AX conversion
//  happens outside, at WindowMutator's boundary.
//

import CoreGraphics

/// Per-edge snap latch. `true` when that edge is currently snapped
/// to its corresponding display boundary; `false` when it's honoring
/// the raw drawn coordinate.
struct PlotSnapState: Equatable {
    var west: Bool
    var east: Bool
    var south: Bool
    var north: Bool

    static let none = PlotSnapState(west: false, east: false, south: false, north: false)
}

/// Frozen snap intent captured at mouse-up. Used by the commit path
/// to preserve edge intent when an app clamps the resize.
typealias PlotSnapIntent = PlotSnapState

enum PlotGeometry {

    /// Outer-15% activation zone width.
    static let snapZoneFraction: CGFloat = 0.15

    /// Once snapped, an edge stays snapped until it moves this many
    /// logical points BEYOND its 15% activation boundary toward the
    /// interior. Prevents chatter around the threshold.
    static let hysteresisPoints: CGFloat = 10

    /// A Plot Area must be at least this wide AND this tall (in
    /// logical points) after clamping + snapping. Smaller areas
    /// render as invalid and no mutation occurs.
    static let minWidth: CGFloat = 80
    static let minHeight: CGFloat = 60

    /// Cursor movement (in logical points) required to convert a
    /// pending gesture into an active Plot draw.
    static let dragThresholdPoints: CGFloat = 6

    // MARK: - Public API

    /// Normalizes two arbitrary points (mouse-down + mouse-current)
    /// into an axis-aligned rect. Supports drags in every direction.
    static func normalize(from a: CGPoint, to b: CGPoint) -> CGRect {
        let minX = min(a.x, b.x)
        let minY = min(a.y, b.y)
        let maxX = max(a.x, b.x)
        let maxY = max(a.y, b.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Computes the final Plot Area for a raw drag rectangle on a
    /// specific display, applying independent per-edge 15% snap zones
    /// with hysteresis release.
    ///
    /// Steps:
    ///   1. Clamp raw rect to `visibleFrame`.
    ///   2. For each edge, decide whether that edge is inside its
    ///      activation zone (15% band from the corresponding display
    ///      edge). If an edge was previously snapped, apply hysteresis
    ///      release — it stays snapped until it moves at least
    ///      `hysteresisPoints` past the activation boundary toward the
    ///      interior.
    ///   3. For each snapped edge, replace that side's coordinate with
    ///      the exact display-boundary value. Unsnapped edges keep the
    ///      exact drawn coordinate.
    ///
    /// - Parameters:
    ///   - rawRect: normalized drag rectangle in Cocoa global coords.
    ///     Not yet clamped or snapped.
    ///   - visibleFrame: the target display's `NSScreen.visibleFrame`
    ///     in Cocoa global coords. Snap activation and clamping both
    ///     use this rect exclusively — never the full display frame.
    ///   - previous: the snap state from the previous drag frame.
    ///     Pass `.none` on the first frame. Enables hysteresis.
    /// - Returns: `(finalRect, snapState)` — the rect to render/commit
    ///   and the updated per-edge snap state for the next frame.
    static func computePlotArea(
        rawRect: CGRect,
        visibleFrame: CGRect,
        previous: PlotSnapState
    ) -> (rect: CGRect, snap: PlotSnapState) {
        // Step 1: clamp raw rect to visibleFrame so no coordinate
        // pokes past the display's usable area.
        let clamped = clamp(rawRect, to: visibleFrame)

        // Step 2: compute the activation-zone boundaries.
        //   West edge zone   = [minX, minX + 15% width]
        //   East edge zone   = [maxX - 15% width, maxX]
        //   South edge zone  = [minY, minY + 15% height]
        //   North edge zone  = [maxY - 15% height, maxY]
        //
        // Cocoa is bottom-left, so "south" = lower y (minY) and
        // "north" = higher y (maxY). This is the physical mapping,
        // not a screen-top mapping.
        let bounds = visibleFrame
        let westZoneMaxX  = bounds.minX + bounds.width  * snapZoneFraction
        let eastZoneMinX  = bounds.maxX - bounds.width  * snapZoneFraction
        let southZoneMaxY = bounds.minY + bounds.height * snapZoneFraction
        let northZoneMinY = bounds.maxY - bounds.height * snapZoneFraction

        // Hysteresis release boundaries — one edge-release margin
        // farther INTO the interior than the activation boundary.
        // A previously-snapped edge stays snapped until its rect
        // coordinate is past this release line, not merely past the
        // activation line.
        let westReleaseX  = westZoneMaxX  + hysteresisPoints
        let eastReleaseX  = eastZoneMinX  - hysteresisPoints
        let southReleaseY = southZoneMaxY + hysteresisPoints
        let northReleaseY = northZoneMinY - hysteresisPoints

        // Step 3: per-edge snap decision. Activate if inside the 15%
        // zone. Once activated, remain activated until past the
        // release boundary.
        //
        // Each edge is completely independent. Entering the north
        // zone never activates west/east/south — a common bug for
        // corner-snap implementations that we deliberately avoid.
        let snapWest: Bool = {
            if previous.west { return clamped.minX <= westReleaseX }
            return clamped.minX <= westZoneMaxX
        }()
        let snapEast: Bool = {
            if previous.east { return clamped.maxX >= eastReleaseX }
            return clamped.maxX >= eastZoneMinX
        }()
        let snapSouth: Bool = {
            if previous.south { return clamped.minY <= southReleaseY }
            return clamped.minY <= southZoneMaxY
        }()
        let snapNorth: Bool = {
            if previous.north { return clamped.maxY >= northReleaseY }
            return clamped.maxY >= northZoneMinY
        }()

        // Apply snaps. Snapped edges attach to the EXACT display
        // boundary. Unsnapped edges keep the clamped drawn coord.
        let finalMinX = snapWest  ? bounds.minX : clamped.minX
        let finalMaxX = snapEast  ? bounds.maxX : clamped.maxX
        let finalMinY = snapSouth ? bounds.minY : clamped.minY
        let finalMaxY = snapNorth ? bounds.maxY : clamped.maxY

        let final = CGRect(
            x: finalMinX,
            y: finalMinY,
            width:  finalMaxX - finalMinX,
            height: finalMaxY - finalMinY
        )
        let state = PlotSnapState(
            west:  snapWest,
            east:  snapEast,
            south: snapSouth,
            north: snapNorth
        )
        return (final, state)
    }

    /// True when the Plot Area meets both minimum-size thresholds.
    /// The drag threshold and this minimum are separate concerns:
    /// the drag threshold gates whether we draw at all; this
    /// minimum gates whether a completed drag becomes a mutation.
    static func isValidPlotArea(_ rect: CGRect) -> Bool {
        rect.width >= minWidth && rect.height >= minHeight
    }

    /// True when the pointer has moved far enough from mouse-down
    /// to be treated as a drag rather than a click.
    static func exceedsDragThreshold(from start: CGPoint, to current: CGPoint) -> Bool {
        let dx = current.x - start.x
        let dy = current.y - start.y
        return (dx * dx + dy * dy) >= (dragThresholdPoints * dragThresholdPoints)
    }

    /// Corrects the actual post-mutation frame back into snap intent
    /// after an app clamped the requested size. Called with the
    /// window's ACTUAL post-write frame, the display it should live
    /// on, and the snap intent captured at mouse-up.
    ///
    /// Rules per axis:
    ///   - If only west/south snapped: preserve that edge; other edge floats.
    ///   - If only east/north snapped: preserve that edge; other edge floats.
    ///   - If both edges on an axis snapped but the actual size can't
    ///     fill the display, center the natural size on that axis.
    ///   - If neither snapped: preserve the requested leading edge
    ///     (west horizontally, north vertically for "top" per spec).
    ///
    /// The resulting frame is finally clamped to the display's
    /// `visibleFrame`.
    static func correctForConstraints(
        actualSize: CGSize,
        requested: CGRect,
        intent: PlotSnapIntent,
        visibleFrame: CGRect
    ) -> CGRect {
        // Horizontal axis.
        let originX: CGFloat
        switch (intent.west, intent.east) {
        case (true, false):
            originX = visibleFrame.minX
        case (false, true):
            originX = visibleFrame.maxX - actualSize.width
        case (true, true):
            if actualSize.width >= visibleFrame.width {
                originX = visibleFrame.minX
            } else {
                originX = visibleFrame.midX - actualSize.width / 2
            }
        case (false, false):
            // Preserve requested LEFT (west) edge.
            originX = requested.minX
        }

        // Vertical axis. Cocoa is bottom-left; the spec's "top" ⇒
        // north ⇒ maxY. To preserve the top when neither is snapped,
        // we set originY = requested.maxY - actualSize.height.
        let originY: CGFloat
        switch (intent.south, intent.north) {
        case (true, false):
            originY = visibleFrame.minY
        case (false, true):
            originY = visibleFrame.maxY - actualSize.height
        case (true, true):
            if actualSize.height >= visibleFrame.height {
                originY = visibleFrame.minY
            } else {
                originY = visibleFrame.midY - actualSize.height / 2
            }
        case (false, false):
            // Preserve requested TOP (north) edge.
            originY = requested.maxY - actualSize.height
        }

        let corrected = CGRect(
            x: originX,
            y: originY,
            width:  actualSize.width,
            height: actualSize.height
        )
        return clamp(corrected, to: visibleFrame)
    }

    // MARK: - Private helpers

    /// Clamps a rect so every edge is inside `bounds`. If the rect is
    /// larger than bounds on either axis, that axis becomes the full
    /// bounds extent.
    private static func clamp(_ r: CGRect, to bounds: CGRect) -> CGRect {
        // Width/height first — larger-than-bounds rects collapse to
        // the bounds' extent on that axis.
        let w = min(r.width,  bounds.width)
        let h = min(r.height, bounds.height)
        // Position so the rect stays fully inside bounds.
        let x = max(bounds.minX, min(r.minX, bounds.maxX - w))
        let y = max(bounds.minY, min(r.minY, bounds.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
