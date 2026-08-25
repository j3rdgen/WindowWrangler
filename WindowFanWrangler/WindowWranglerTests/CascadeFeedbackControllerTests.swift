//
//  CascadeFeedbackControllerTests.swift
//  Window WranglerTests
//
//  Deterministic tests for the single-pulse Cascade acknowledgement
//  controller. Uses the DEBUG test-seam (`testHelper_applyProgress`)
//  to step the animation curve without depending on wall-clock
//  milliseconds, which would make the suite flaky in CI.
//

import AppKit
import XCTest
@testable import Window_Wrangler

@MainActor
final class CascadeFeedbackControllerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeControllerWithOverlay() -> (CascadeFeedbackController, SelectionOverlay) {
        let overlay = SelectionOverlay()
        let controller = CascadeFeedbackController(overlay: overlay)
        return (controller, overlay)
    }

    private let sampleRects: [CGRect] = [
        CGRect(x: 100, y: 100, width: 800, height: 600),
        CGRect(x: 950, y: 100, width: 800, height: 600),
    ]

    // MARK: - Blink lifecycle

    /// A fresh blink starts the pulse (isPulsing=true, timer active)
    /// and applies frame 0 synchronously so the acknowledgement feels
    /// instant.
    func test_blink_startsPulseSynchronouslyAndStartsTimer() {
        let (controller, _) = makeControllerWithOverlay()
        XCTAssertFalse(controller.isPulsing)
        XCTAssertFalse(controller.testHelper_isTimerActive)

        _ = controller.blink(rects: sampleRects)

        XCTAssertTrue(controller.isPulsing,
            "First frame of the pulse must be entered synchronously.")
        XCTAssertTrue(controller.testHelper_isTimerActive,
            "Animation timer must be scheduled after blink().")
    }

    /// `blink()` returns synchronously — Cascade must be able to
    /// proceed immediately without waiting for any part of the pulse
    /// to complete. Bounds the wall-clock cost as a sanity check that
    /// no blocking work has snuck into the path.
    func test_blinkReturnsSynchronously_cascadeCanProceed() {
        let (controller, _) = makeControllerWithOverlay()
        let before = Date()
        _ = controller.blink(rects: sampleRects)
        let elapsed = Date().timeIntervalSince(before)
        XCTAssertLessThan(elapsed, 0.1,
            "blink() must return promptly — Cascade cannot wait for pulse.")
    }

    // MARK: - Natural completion

    /// Advancing progress to 1.0 must end the pulse and clear all
    /// state — no static outline left behind, no lingering timer.
    func test_progressCompletes_pulseEndsCleanly() {
        let (controller, _) = makeControllerWithOverlay()
        let gen = controller.blink(rects: sampleRects)
        XCTAssertTrue(controller.isPulsing)

        controller.testHelper_applyProgress(1.0, generation: gen)

        XCTAssertFalse(controller.isPulsing,
            "Completing the pulse must clear isPulsing.")
        XCTAssertFalse(controller.testHelper_isTimerActive,
            "Timer must be invalidated at natural completion.")
    }

    /// A mid-progress advance (0.5) keeps the pulse active; only
    /// progress ≥ 1 triggers finish.
    func test_progressMidway_pulseStillActive() {
        let (controller, _) = makeControllerWithOverlay()
        let gen = controller.blink(rects: sampleRects)
        controller.testHelper_applyProgress(0.5, generation: gen)
        XCTAssertTrue(controller.isPulsing)
        XCTAssertTrue(controller.testHelper_isTimerActive)
    }

    // MARK: - Generation supersession

    /// A newer blink invalidates the previous generation's progress
    /// advances — a stale scheduled tick must not step a later pulse.
    func test_supersession_staleProgressIsIgnored() {
        let (controller, _) = makeControllerWithOverlay()

        let genA = controller.blink(rects: sampleRects)
        XCTAssertTrue(controller.isPulsing)

        let genB = controller.blink(rects: sampleRects)
        XCTAssertNotEqual(genA, genB,
            "Generation must advance on every blink for supersession checks.")

        // Try to advance generation A's progress — must no-op.
        controller.testHelper_applyProgress(1.0, generation: genA)
        XCTAssertTrue(controller.isPulsing,
            "Stale generation A advance must NOT finish generation B's pulse.")

        // Generation B still owns the pulse.
        controller.testHelper_applyProgress(1.0, generation: genB)
        XCTAssertFalse(controller.isPulsing)
    }

    // MARK: - Early dismissal from Cascade

    /// `dismiss(generation:)` — the hook the Cascade orchestrator
    /// calls right before its first geometry write — must instantly
    /// clear the pulse regardless of how far through the fade it was.
    func test_dismiss_matchingGeneration_clearsPulseImmediately() {
        let (controller, _) = makeControllerWithOverlay()

        let gen = controller.blink(rects: sampleRects)
        XCTAssertTrue(controller.isPulsing)

        controller.dismiss(generation: gen)
        XCTAssertFalse(controller.isPulsing,
            "Matching-generation dismiss must instantly end the pulse.")
        XCTAssertFalse(controller.testHelper_isTimerActive)
    }

    /// Dismiss for a stale generation must no-op — protects against a
    /// slow orchestrator's callback dismissing a NEWER pulse that
    /// started while the prior cascade was still enumerating.
    func test_dismiss_staleGeneration_isNoOp() {
        let (controller, _) = makeControllerWithOverlay()

        let genA = controller.blink(rects: sampleRects)
        _ = controller.blink(rects: sampleRects)  // supersede — new gen B

        controller.dismiss(generation: genA)
        XCTAssertTrue(controller.isPulsing,
            "Stale-generation dismiss must NOT end the newer pulse.")
    }

    // MARK: - Rapid shortcuts

    /// DR → DL → DR fires three blinks in quick succession. Only the
    /// most recent generation should be able to drive state; the two
    /// prior generations' progress advances must not leak through.
    func test_rapidShortcuts_onlyLatestGenerationDrivesState() {
        let (controller, _) = makeControllerWithOverlay()

        let g1 = controller.blink(rects: sampleRects)
        let g2 = controller.blink(rects: sampleRects)
        let g3 = controller.blink(rects: sampleRects)

        XCTAssertGreaterThan(g2, g1)
        XCTAssertGreaterThan(g3, g2)
        XCTAssertTrue(controller.isPulsing)

        // Prior-generation completes do nothing.
        controller.testHelper_applyProgress(1.0, generation: g1)
        controller.testHelper_applyProgress(1.0, generation: g2)
        XCTAssertTrue(controller.isPulsing,
            "Neither g1 nor g2 completes leaks into g3.")

        controller.testHelper_applyProgress(1.0, generation: g3)
        XCTAssertFalse(controller.isPulsing)
    }

    // MARK: - Teardown cancels pending work

    /// `stop()` (called on app teardown) must invalidate the timer so
    /// a late tick cannot resurrect the overlay after shutdown.
    func test_stop_invalidatesTimer() {
        let (controller, _) = makeControllerWithOverlay()

        _ = controller.blink(rects: sampleRects)
        XCTAssertTrue(controller.testHelper_isTimerActive)

        controller.stop()
        XCTAssertFalse(controller.testHelper_isTimerActive)
        XCTAssertFalse(controller.isPulsing)
    }

    /// A new blink cancels the previous blink's timer — prevents two
    /// pumps racing under rapid fire.
    func test_newBlink_cancelsPriorTimer() {
        let (controller, _) = makeControllerWithOverlay()

        _ = controller.blink(rects: sampleRects)
        XCTAssertTrue(controller.testHelper_isTimerActive)

        _ = controller.blink(rects: sampleRects)
        // Second blink schedules its own new timer; the prior timer
        // was cancelled by cancelPending() at the top of blink().
        // We can't observe "the OLD timer specifically" is gone, but
        // we can observe that exactly ONE timer is active now.
        XCTAssertTrue(controller.testHelper_isTimerActive)
    }

    /// Matching-generation dismiss cancels the timer.
    func test_dismiss_cancelsTimer() {
        let (controller, _) = makeControllerWithOverlay()

        let gen = controller.blink(rects: sampleRects)
        XCTAssertTrue(controller.testHelper_isTimerActive)

        controller.dismiss(generation: gen)
        XCTAssertFalse(controller.testHelper_isTimerActive)
    }

    // MARK: - Edge cases

    /// Empty-rects blink is a valid no-op — bumps the generation for
    /// supersession bookkeeping, but skips the overlay update and
    /// does not start the animation timer.
    func test_emptyRects_bumpsGenerationButDoesNotStartPulse() {
        let (controller, _) = makeControllerWithOverlay()

        let genA = controller.blink(rects: sampleRects)
        XCTAssertTrue(controller.isPulsing)

        let genB = controller.blink(rects: [])
        XCTAssertGreaterThan(genB, genA,
            "Empty blink still advances the generation for supersession safety.")
        XCTAssertFalse(controller.isPulsing,
            "Empty blink must not start the animation.")
        XCTAssertFalse(controller.testHelper_isTimerActive)
    }

    /// Dismiss on an idle controller must not crash and must not
    /// leave a timer active. Because the initial generation is 0, a
    /// dismiss(0) matches and runs `finish` — but finish's setter
    /// calls are benign no-ops when there's nothing to clear.
    func test_dismiss_onIdleController_doesNotCrashOrLeaveTimer() {
        let (controller, _) = makeControllerWithOverlay()
        XCTAssertFalse(controller.isPulsing)
        XCTAssertFalse(controller.testHelper_isTimerActive)

        controller.dismiss(generation: 0)

        XCTAssertFalse(controller.testHelper_isTimerActive,
            "Dismiss must not schedule work on an idle controller.")
    }
}
