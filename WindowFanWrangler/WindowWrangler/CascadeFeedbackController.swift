//
//  CascadeFeedbackController.swift
//  Window Wrangler
//
//  Immediate visual acknowledgement for Cascade All Apps shortcut
//  presses. Produces one Plot-style pulse (~300ms expand-then-shrink
//  with linear alpha fade to zero) around currently-visible windows
//  so the user sees Window Wrangler react instantly, even when an
//  external app's Accessibility latency (Zoom's Chromium helper is
//  the reference case) delays the real Cascade by ~1.5 seconds.
//
//  KEY INVARIANTS
//  --------------
//  * Purely visual. Zero AX enumeration, zero AX writes, zero AXRaise,
//    zero AppleScript, zero Cascade-membership decisions. Draws only
//    Window Wrangler-owned overlay pixels.
//  * Cascade never waits for this. The pulse runs on its own 60fps
//    timer; the real `performCascadeAllApps` proceeds in parallel.
//    The orchestrator can (and should) dismiss the pulse early via
//    `dismiss(generation:)` right before its first geometry write —
//    the dismiss is a fire-and-forget setter, not an awaited handshake.
//  * Not Lasso Mode. This controller shares the `SelectionOverlay`
//    RENDERER with `LassoCoordinator`, but it never touches Lasso's
//    behavioral state (mode entry, selection, drag, event tap).
//  * Generation-tied. Every `blink()` returns a monotonic generation
//    id; `dismiss(generation:)` and the animation timer check it and
//    no-op on mismatch. Rapid shortcut fires cleanly supersede
//    without stale phases resurrecting.
//  * Cheap CG data only. Window frames come from a fast CGWindowList
//    snapshot (not authoritative AX enumeration). CG blind spots
//    (Notes / Podcasts / Grammarly) may not blink; the actual Cascade
//    will still move them correctly via AX. That cosmetic gap is
//    deliberate.
//  * Ends invisible. Alpha fades linearly from 1 to 0 over the
//    duration; at completion the overlay's pulse rects are cleared.
//    Never leaves a static outline behind.
//

import AppKit
import Foundation
import os

/// Shape of the acknowledgement pulse. Same expand-then-shrink and
/// alpha-fade shape as `PlotOverlay`'s selection pulse.
///
/// The shortcut handler delays Cascade dispatch by exactly this
/// pulse duration, so the pulse-then-cascade sequence is:
///
///   t=0        shortcut received, pulse begins
///   t=0.25s    pulse completes, cascade dispatch begins
///   t=0.25s+E  cascade first frame write (E = enumeration/planning)
///
/// The ~250ms pulse is bounded above the "choppy" threshold (~180ms
/// was still borderline at 60fps) and below the "feels slow" threshold
/// (~300ms felt draggy in earlier tuning). At 60fps that's ~15 frames
/// — smooth to the eye — and matches Plot's selection pulse (0.28s)
/// closely enough that both feedback surfaces share pacing.
///
/// The extra pre-cascade time also gives macOS a small settling
/// window (modifier key release completes, recently-activated app's
/// AX proxy has a moment to warm up, WindowServer is idle). Whether
/// this materially improves reliability is speculative — the primary
/// motivation is animation smoothness — but if it helps at all, it's
/// free.
private enum PulseTuning {
    /// Total pulse duration in seconds. Also the delay applied before
    /// Cascade dispatch, so the pulse fully completes before window
    /// motion begins.
    static let totalDuration: TimeInterval = 0.25
    /// Peak outward expansion in points. Unchanged — visual character
    /// stays identical across duration tunings.
    static let expandPoints: CGFloat = 6
    /// Timer tick — ~60fps redraw while the pulse is on screen. Cheap
    /// because each panel only redraws its own small content region.
    static let tickInterval: TimeInterval = 1.0 / 60.0
}

@MainActor
final class CascadeFeedbackController {

    // MARK: - Dependencies

    /// Shared with `LassoCoordinator`. This controller only calls the
    /// overlay's `setPulseState(rects:opacity:)` method — never any
    /// Lasso-behavioral method. Lasso rendering and Cascade-pulse
    /// rendering coexist on the same panels but occupy different draw
    /// slots inside `OverlayView.draw(_:)`.
    private let overlay: SelectionOverlay

    // MARK: - Generation & animation state

    /// Monotonic counter. Every `blink()` bumps this and returns the
    /// new value. The animation timer captures its origin generation
    /// and no-ops if the counter has moved on. Rapid successive
    /// Cascades (DR → DL → DR) supersede each other cleanly with no
    /// stacked overlays or delayed reappearances.
    private var currentGeneration: UInt64 = 0

    /// True while a pulse is animating. Exposed for tests via
    /// `testHelper_isPulsing`. Toggled true on `blink()` (non-empty),
    /// toggled false at natural completion / dismiss / stop.
    private(set) var isPulsing: Bool = false

    /// Original (unexpanded) rects the current pulse is drawing.
    /// Retained so each animation frame re-derives the expanded rects
    /// from a stable source without allocating on the caller side.
    private var originalRects: [CGRect] = []

    /// When the current pulse started. Used to compute animation
    /// progress on each timer tick.
    private var startedAt: Date?

    /// 60fps redraw timer while the pulse is on screen. Invalidated
    /// on completion, dismiss, stop, and by every new `blink()`.
    private var pulseTimer: Timer?

    // MARK: - Init

    init(overlay: SelectionOverlay) {
        self.overlay = overlay
    }

    deinit {
        pulseTimer?.invalidate()
    }

    // MARK: - Public API

    /// Total duration of one complete pulse, in seconds. Exposed so
    /// the shortcut handler can delay Cascade dispatch by this much —
    /// ensuring the pulse fully completes and its outlines clear
    /// BEFORE any window motion begins. Without that delay, a fast
    /// warm Cascade (~100-225ms) overlaps the pulse's fade tail,
    /// leaving static outlines sitting at pre-cascade positions while
    /// windows visibly move away — the "lag" the user reported.
    var pulseDuration: TimeInterval { PulseTuning.totalDuration }

    /// Start a fresh single-pulse animation around the given rects.
    /// Returns the generation id — pass it back to `dismiss(generation:)`
    /// so an early cancel from the cascade orchestrator is safely
    /// scoped to THIS pulse and can't kill a later one.
    ///
    /// Fire-and-forget: this returns immediately after applying the
    /// first frame's overlay state; the fade + expansion animation is
    /// driven off a `Timer` on the main run loop. Never awaited by
    /// Cascade.
    ///
    /// Passing an empty `rects` array is treated as an immediate no-op
    /// (bumps the generation to invalidate any in-flight prior pulse,
    /// but skips overlay updates). Cheaper than materializing a pulse
    /// that's guaranteed to be invisible.
    @discardableResult
    func blink(rects: [CGRect]) -> UInt64 {
        // Cancel any in-flight pulse first — supersession guarantee.
        cancelPending()

        currentGeneration &+= 1
        let myGen = currentGeneration
        originalRects = rects

        guard !rects.isEmpty else {
            isPulsing = false
            // Ensure the overlay is not left in a stale visible state.
            overlay.setPulseState(rects: [], opacity: 1.0)
            return myGen
        }

        isPulsing = true
        startedAt = Date()

        // Apply the initial frame (progress 0, full opacity, no
        // expansion yet) synchronously — this is what makes the
        // acknowledgement feel instant even when the user's next
        // shortcut fire follows in <100ms.
        applyFrame(progress: 0)

        // 60fps pump. Each tick recomputes the frame; the timer stops
        // itself when progress reaches 1 OR when the captured
        // generation is superseded (guarded inside the closure).
        pulseTimer = Timer.scheduledTimer(
            withTimeInterval: PulseTuning.tickInterval,
            repeats: true
        ) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.currentGeneration == myGen, let startedAt = self.startedAt else {
                    timer.invalidate()
                    return
                }
                let elapsed = Date().timeIntervalSince(startedAt)
                let progress = min(1.0, elapsed / PulseTuning.totalDuration)
                self.applyFrame(progress: progress)
                if progress >= 1.0 {
                    self.finish(generation: myGen)
                }
            }
        }

        return myGen
    }

    /// Immediately end the pulse for the given generation. Called by
    /// the Cascade orchestrator right before its first initial
    /// geometry write dispatches — the user is about to see real
    /// window motion, so the cosmetic pulse can drop instantly
    /// regardless of how far through the fade it was.
    ///
    /// No-ops if `generation` doesn't match the current one — protects
    /// against a stale orchestrator callback dismissing a NEWER pulse
    /// that started while the prior cascade was still enumerating.
    func dismiss(generation: UInt64) {
        guard generation == currentGeneration else { return }
        finish(generation: generation)
    }

    /// Cancel everything unconditionally. Used at app teardown so a
    /// late-firing Timer tick cannot reappear the pulse after the app
    /// has committed to shutting down.
    func stop() {
        cancelPending()
        isPulsing = false
        originalRects = []
        startedAt = nil
        overlay.setPulseState(rects: [], opacity: 1.0)
    }

    // MARK: - Test seams

    #if DEBUG
    /// Test-only: apply a specific animation progress point (0…1)
    /// without waiting for the real Timer. Lets tests verify the
    /// expand-then-shrink and alpha-fade curves deterministically.
    /// Progress ≥ 1 triggers `finish` — same as natural completion.
    func testHelper_applyProgress(_ progress: Double, generation: UInt64) {
        guard generation == currentGeneration else { return }
        let clamped = max(0, min(1, progress))
        applyFrame(progress: clamped)
        if clamped >= 1.0 {
            finish(generation: generation)
        }
    }

    /// Test-only introspection — is the pulse-driving Timer still
    /// scheduled? Every teardown path (`stop`, `dismiss`, natural
    /// completion, superseding blink) should bring this to false.
    var testHelper_isTimerActive: Bool { pulseTimer != nil }
    #endif

    // MARK: - Private helpers

    /// Applies one animation frame. Called both by the Timer tick and
    /// (in tests) by the `testHelper_applyProgress` seam.
    ///
    /// Uses the Plot pulse curves so the two feedback surfaces feel
    /// consistent:
    ///   - Expansion: symmetric parabola `1 - abs(p*2 - 1)` — starts
    ///     at 0, peaks at 0.5, returns to 0. Widest halfway through.
    ///   - Alpha: linear fade `1 - p` — starts fully visible, ends
    ///     completely transparent at completion.
    private func applyFrame(progress: Double) {
        let p = CGFloat(progress)
        let symmetric = 1 - abs(p * 2 - 1)   // 0..1..0
        let expansion = PulseTuning.expandPoints * symmetric
        let alpha = max(0, 1 - p)

        let expanded: [CGRect] = originalRects.map {
            $0.insetBy(dx: -expansion, dy: -expansion)
        }
        overlay.setPulseState(rects: expanded, opacity: alpha)
    }

    private func finish(generation: UInt64) {
        guard generation == currentGeneration else { return }
        cancelPending()
        isPulsing = false
        originalRects = []
        startedAt = nil
        overlay.setPulseState(rects: [], opacity: 1.0)
    }

    private func cancelPending() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }
}
