//
//  CascadePlanning.swift
//  Window Wrangler
//
//  Pure planning-size resolver for the all-apps Cascade path.
//
//  Motivation:
//  Cascade slot geometry historically used each window's ACTUAL
//  current frame size when deciding narrow-window right-align and
//  when clamping the origin inside the visible frame. That made the
//  geometry sensitive to mutable dimensions — e.g. a Plot session
//  that left Chrome at 623×1084 would trigger the "narrow window"
//  branch (623 < 0.7×1168) AND drive the fitFrame y-clamp to shift
//  the slot upward (1084 > cascade area height). The next Cascade
//  invocation, after Chrome's post-cascade size had settled, saw
//  different current dimensions and generated a different plan.
//
//  Result: identical pending groups, identical direction, identical
//  display, identical settings — but different planned slot positions
//  between consecutive invocations. Iterative convergence over
//  multiple manual Cascades.
//
//  The fix: separate "actual current frame" from "planning size."
//  Normally resizable windows use the standard Cascade target size
//  deterministically. Windows whose AX contract says size is NOT
//  settable (position-only apps) preserve their current natural size
//  because the mutator will not resize them.
//
//  This module holds only the pure resolver — no AX calls, no bundle
//  checks, no application-name branches, no Plot / Corral state, no
//  mutation. Callers (CascadeOrchestrator.performCascadeAllApps)
//  invoke it once per window before FanGeometry / slot-fit logic.
//

import Foundation
import CoreGraphics

enum CascadePlanning {

    /// Resolves the SIZE that all-apps Cascade slot geometry should
    /// use for this window when deciding narrow-window branch and
    /// origin clamping.
    ///
    /// - Parameters:
    ///   - currentFrame: the window's observed AX-derived Cocoa
    ///     frame at cascade start. Its ORIGIN is not used here;
    ///     only its size is consulted, and only when the window is
    ///     not size-settable.
    ///   - standardTargetSize: the cascade's uniform target size
    ///     (70% of the padded visible-frame area, or whatever the
    ///     orchestrator computed).
    ///   - isSizeSettable: `WindowMutator.isSizeSettable` for this
    ///     AX element — the stable AX contract for whether the app
    ///     accepts kAXSizeAttribute writes.
    /// - Returns: the size to use for slot-geometry decisions.
    ///
    /// Invariant: for a size-settable window, the returned size does
    /// NOT depend on `currentFrame`. Two calls with the same
    /// `standardTargetSize` + `isSizeSettable=true` return the same
    /// value regardless of `currentFrame`. This is what makes the
    /// downstream cascade plan deterministic across invocations.
    static func resolveCascadePlanningSize(
        currentFrame: CGRect,
        standardTargetSize: CGSize,
        isSizeSettable: Bool,
        minSize: CGSize? = nil
    ) -> CGSize {
        if isSizeSettable {
            // Normally resizable window: the mutator will attempt to
            // resize it to `standardTargetSize`. BUT some apps that
            // report settable=true still clamp below an advertised
            // minimum (iMovie, Xcode, GarageBand, large pro apps).
            // When kAXMinSizeAttribute is published AND it exceeds
            // the standard target in either dimension, the actual
            // post-write window will be `max(target, min)`. Planning
            // uses that effective size so downstream slot clamping
            // keeps the window on-screen even though the write won't
            // shrink it to target.
            //
            // Pure determinism still holds: the plan depends only on
            // standardTargetSize + minSize (both stable AX contracts
            // for a given app), not on currentFrame. Two consecutive
            // cascades of iMovie produce the same plan.
            guard let min = minSize else { return standardTargetSize }
            return CGSize(
                width: Swift.max(standardTargetSize.width, min.width),
                height: Swift.max(standardTargetSize.height, min.height)
            )
        }
        // Position-only window (AX size attribute non-settable):
        // the mutator will only write position; the window keeps
        // its current natural dimensions. Slot geometry must plan
        // with the actual size so the window fits in place.
        return currentFrame.size
    }
}
