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
import os

enum WindowMutator {

    /// True if AX reports the window's size attribute as writable.
    /// Some windows are non-resizable (Zoom pre-login, fullscreen,
    /// small fixed-size dialogs) and vend `kAXSizeAttribute` as
    /// non-settable. Callers use this to keep those windows at their
    /// natural size instead of trying to force them to the cascade's
    /// target size.
    static func isSizeSettable(_ axWindow: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            axWindow, kAXSizeAttribute as CFString, &settable
        )
        return result == .success && settable.boolValue
    }

    /// Moves the given window to the given Cocoa-coordinate frame.
    /// Both position and size are set when possible. Returns true on
    /// full success.
    ///
    /// Resizable windows: some apps (Chrome notably) clamp or partially
    /// refuse AX size changes. The fix used by Rectangle/Magnet/yabai
    /// is: set size, set position, set size again. The second size
    /// call overrides any clamping the app applied during the position
    /// update. We follow that pattern and log a warning if the final
    /// readback doesn't match the requested size.
    ///
    /// Non-resizable windows (Zoom pre-login etc.): the size dance is
    /// skipped — the app would refuse it. Only position is written.
    /// The caller (cascade orchestrator) is responsible for choosing a
    /// position that keeps the window on screen at its natural size.
    @discardableResult
    static func setFrame(_ frame: CGRect, of axWindow: AXUIElement) -> Bool {
        let axFrame = CoordinateSpace.axRect(fromCocoa: frame)

        var position = axFrame.origin
        var size = axFrame.size

        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        // Non-resizable window: skip the size dance entirely.
        guard isSizeSettable(axWindow) else {
            let p = AXUIElementSetAttributeValue(
                axWindow, kAXPositionAttribute as CFString, posValue
            )
            return p == .success
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
                Log.mutator.notice(
                    "App refused resize — asked \(wantedW, privacy: .public)×\(wantedH, privacy: .public), got \(gotW, privacy: .public)×\(gotH, privacy: .public)"
                )
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

    /// One row of per-window timing data from `applyBatchInstrumented`.
    /// Same order as the input `moves` array — the caller can zip these
    /// back to their planned identity to compute per-PID totals /
    /// slowest-write / etc. `succeeded` mirrors the plain `applyBatch`
    /// per-move result.
    struct BatchWriteTiming {
        let axWindow: AXUIElement
        let durationSeconds: Double
        let succeeded: Bool
    }

    /// Instrumented variant of `applyBatch`. Same sequential semantics —
    /// executes each `setFrame` in input order, returns the total
    /// success count — but additionally records the wall-clock duration
    /// of each individual `setFrame` call. The caller uses this to
    /// distinguish "one slow write dominates" from "sum across many
    /// windows dominates" without needing to hook into the mutator
    /// itself.
    ///
    /// Overhead: one `CFAbsoluteTimeGetCurrent()` pair per window plus
    /// one struct allocation. Negligible next to a cross-process AX
    /// write.
    static func applyBatchInstrumented(
        _ moves: [(axWindow: AXUIElement, target: CGRect)]
    ) -> (successCount: Int, timings: [BatchWriteTiming]) {
        var successes = 0
        var timings: [BatchWriteTiming] = []
        timings.reserveCapacity(moves.count)
        for move in moves {
            let t0 = CFAbsoluteTimeGetCurrent()
            let ok = setFrame(move.target, of: move.axWindow)
            let dt = CFAbsoluteTimeGetCurrent() - t0
            if ok { successes += 1 }
            timings.append(BatchWriteTiming(
                axWindow: move.axWindow,
                durationSeconds: dt,
                succeeded: ok
            ))
        }
        return (successes, timings)
    }

    /// Writes ONLY the window's position — no size dance. Faster than
    /// `setFrame` (single AX write vs. three) so it's suitable for
    /// per-frame calls during an interactive drag. `cocoaFrame` is the
    /// full target frame in Cocoa coordinates; only the origin is
    /// written, but the size is needed to perform the Y-axis flip
    /// correctly (AX uses top-left origin, Cocoa uses bottom-left).
    @discardableResult
    static func setPosition(of axWindow: AXUIElement, cocoaFrame: CGRect) -> Bool {
        let axFrame = CoordinateSpace.axRect(fromCocoa: cocoaFrame)
        var position = axFrame.origin
        guard let posValue = AXValueCreate(.cgPoint, &position) else { return false }
        let result = AXUIElementSetAttributeValue(
            axWindow, kAXPositionAttribute as CFString, posValue
        )
        return result == .success
    }
}
