//
//  CascadePlanningTests.swift
//  Window WranglerTests
//
//  Pure tests for `CascadePlanning.resolveCascadePlanningSize`.
//  The resolver's contract is: for size-settable windows, the
//  planning size is always the standard target size regardless of
//  the window's actual current frame size — that is the determinism
//  guarantee that makes All-apps Cascade slot geometry stable across
//  invocations. For non-settable windows, the planning size is the
//  current natural size (position-only apps keep their dimensions).
//
//  No AX, no NSRunningApplication, no browser scripting — pure
//  value-in/value-out.
//

import XCTest
import CoreGraphics
@testable import Window_Wrangler

final class CascadePlanningTests: XCTestCase {

    private let standardTarget = CGSize(width: 1168, height: 738)

    // MARK: - Size-settable (normally resizable) windows

    /// Narrow-and-tall current size (matches plotted Chrome shape:
    /// ~623×1084). Planning must equal target — not currentFrame.
    func test_resizableNarrowTall_planningEqualsTarget() {
        let current = CGRect(x: 1105, y: 0, width: 623, height: 1084)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: standardTarget,
            isSizeSettable: true
        )
        XCTAssertEqual(planning, standardTarget)
    }

    /// Wide-and-short current size. Planning must equal target.
    func test_resizableWideShort_planningEqualsTarget() {
        let current = CGRect(x: 0, y: 800, width: 1600, height: 300)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: standardTarget,
            isSizeSettable: true
        )
        XCTAssertEqual(planning, standardTarget)
    }

    /// Current already at standard size. Planning stays at standard.
    func test_resizableAtStandardSize_planningEqualsTarget() {
        let current = CGRect(x: 30, y: 30, width: 1168, height: 738)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: standardTarget,
            isSizeSettable: true
        )
        XCTAssertEqual(planning, standardTarget)
    }

    // MARK: - Non-settable (position-only) windows

    /// Fixed / position-only window with a narrow current size —
    /// e.g. a Zoom pre-login modal. Planning must equal current, so
    /// slot geometry (fitFrame clamp + willStayNarrow branch) uses
    /// the actual small dimensions.
    func test_nonSettableNarrow_planningEqualsCurrent() {
        let current = CGRect(x: 100, y: 200, width: 400, height: 300)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: standardTarget,
            isSizeSettable: false
        )
        XCTAssertEqual(planning, current.size)
    }

    /// Fixed / position-only window that happens to be wider than
    /// target. Planning still equals current (the mutator won't
    /// resize it, so slot geometry must accommodate the oversize
    /// width via existing fitFrame clamp).
    func test_nonSettableOversize_planningEqualsCurrent() {
        let current = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: standardTarget,
            isSizeSettable: false
        )
        XCTAssertEqual(planning, current.size)
    }

    // MARK: - Determinism invariant

    /// The core determinism guarantee: for two size-settable windows
    /// with different current sizes but the same target size, the
    /// resolver returns the same planning size. This is what makes
    /// downstream cascade slot geometry stable across invocations.
    func test_determinism_settableSameTargetSameOutput_regardlessOfCurrent() {
        let currentA = CGRect(x: 0, y: 0, width: 623, height: 1084)     // plotted narrow-tall
        let currentB = CGRect(x: 0, y: 0, width: 1168, height: 738)     // post-cascade standard
        let currentC = CGRect(x: 0, y: 0, width: 300, height: 200)      // arbitrary small
        let currentD = CGRect(x: -500, y: -300, width: 1600, height: 1200) // arbitrary large

        let planningA = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentA, standardTargetSize: standardTarget, isSizeSettable: true)
        let planningB = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentB, standardTargetSize: standardTarget, isSizeSettable: true)
        let planningC = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentC, standardTargetSize: standardTarget, isSizeSettable: true)
        let planningD = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentD, standardTargetSize: standardTarget, isSizeSettable: true)

        XCTAssertEqual(planningA, planningB)
        XCTAssertEqual(planningB, planningC)
        XCTAssertEqual(planningC, planningD)
        XCTAssertEqual(planningA, standardTarget)
    }

    // MARK: - Origin independence

    /// Origin (including negative-coordinate secondary displays and
    /// vertically offset displays) does not affect planning size.
    func test_originIndependence_negativeCoords() {
        // Secondary display to the left of primary — negative X.
        let currentLeftDisplay = CGRect(x: -1440, y: 100, width: 623, height: 1084)
        // Secondary display below primary — large positive Y.
        let currentBottomDisplay = CGRect(x: 200, y: 1200, width: 623, height: 1084)
        // Primary display.
        let currentPrimary = CGRect(x: 100, y: 100, width: 623, height: 1084)

        let planningLeft = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentLeftDisplay,
            standardTargetSize: standardTarget,
            isSizeSettable: true
        )
        let planningBottom = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentBottomDisplay,
            standardTargetSize: standardTarget,
            isSizeSettable: true
        )
        let planningPrimary = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentPrimary,
            standardTargetSize: standardTarget,
            isSizeSettable: true
        )

        XCTAssertEqual(planningLeft, standardTarget)
        XCTAssertEqual(planningBottom, standardTarget)
        XCTAssertEqual(planningPrimary, standardTarget)
    }

    // MARK: - Zero / degenerate inputs

    /// Zero-size current frame with settable=true should still
    /// return target size (defensive against transient AX reads).
    func test_zeroSizeCurrent_settable_returnsTarget() {
        let current = CGRect(x: 500, y: 500, width: 0, height: 0)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: standardTarget,
            isSizeSettable: true
        )
        XCTAssertEqual(planning, standardTarget)
    }

    /// Zero-size current frame with settable=false returns
    /// currentFrame.size (which is zero). Caller (all-apps loop)
    /// already handles zero-size elsewhere; the resolver stays
    /// pure and doesn't invent a size.
    func test_zeroSizeCurrent_nonSettable_returnsZero() {
        let current = CGRect(x: 500, y: 500, width: 0, height: 0)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: standardTarget,
            isSizeSettable: false
        )
        XCTAssertEqual(planning, .zero)
    }

    // MARK: - Multiple targets

    /// Different standard target sizes (as would happen on displays
    /// with different visible-frame dimensions) produce different
    /// planning sizes, but the mapping remains deterministic per
    /// target.
    func test_multipleTargets_perTargetDeterministic() {
        let currentPlotted = CGRect(x: 0, y: 0, width: 623, height: 1084)
        let target1 = CGSize(width: 1168, height: 738)      // Retina
        let target2 = CGSize(width: 2400, height: 1500)     // 4K external
        let target3 = CGSize(width: 800, height: 500)       // small display

        XCTAssertEqual(
            CascadePlanning.resolveCascadePlanningSize(
                currentFrame: currentPlotted, standardTargetSize: target1, isSizeSettable: true),
            target1
        )
        XCTAssertEqual(
            CascadePlanning.resolveCascadePlanningSize(
                currentFrame: currentPlotted, standardTargetSize: target2, isSizeSettable: true),
            target2
        )
        XCTAssertEqual(
            CascadePlanning.resolveCascadePlanningSize(
                currentFrame: currentPlotted, standardTargetSize: target3, isSizeSettable: true),
            target3
        )
    }

    // MARK: - End-to-end fitFrame determinism

    /// The resolver + `CascadeOrchestrator.fitFrame` combo is the
    /// full slot-geometry pipeline for a single window. This test
    /// replays it with two current-size sets ("Set A" — plotted
    /// narrow-tall; "Set B" — standard target) and asserts the final
    /// target frame is identical for size-settable windows. This is
    /// the direct proof that changing only currentSize does not
    /// change the planned Cascade slot for a normally resizable
    /// window — the exact invariant that Attempt 3 vs Attempt 4
    /// in the reported bug violated.
    func test_fitFrameEndToEnd_settableWindow_invariantAcrossCurrentSizes() {
        // Screen setup approximating the reported Retina display:
        // visibleFrame ≈ 1728×1084 (menu bar off top); cascade area
        // after 30pt L/R/bottom margins is ≈ 1668 wide × 1057 tall.
        let cascadeArea = CGRect(x: 30, y: 30, width: 1668, height: 1027)
        let targetSize = CGSize(width: 1168, height: 738)
        // Slot #4 in a DL fan — the Chrome slot the user's Attempt 4
        // log recorded at (304, 142). Any planned slot works as long
        // as it's identical for both sets.
        let plannedSlot = CGRect(x: 304, y: 142, width: 1168, height: 738)

        // Set A: Chrome-shaped plotted window (623×1084 — narrow and
        // ~57pt taller than the cascade area is tall).
        let currentA = CGRect(x: 1105, y: 0, width: 623, height: 1084)
        // Set B: same window at post-cascade standard size.
        let currentB = CGRect(x: 304, y: 142, width: 1168, height: 738)

        let planningA = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentA, standardTargetSize: targetSize, isSizeSettable: true)
        let planningB = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: currentB, standardTargetSize: targetSize, isSizeSettable: true)

        // Sanity: both resolve to targetSize.
        XCTAssertEqual(planningA, targetSize)
        XCTAssertEqual(planningB, targetSize)

        // Simulate the "else branch" path (size-settable, non-narrow):
        //   frameSize = plannedSlot.size (target for settable)
        //   naturalSize = planningSize (deterministic)
        let targetA = CascadeOrchestrator.fitFrame(
            plannedOrigin: plannedSlot.origin,
            frameSize: plannedSlot.size,
            naturalSize: planningA,
            bounds: cascadeArea
        )
        let targetB = CascadeOrchestrator.fitFrame(
            plannedOrigin: plannedSlot.origin,
            frameSize: plannedSlot.size,
            naturalSize: planningB,
            bounds: cascadeArea
        )

        XCTAssertEqual(targetA, targetB,
            "Size-settable window's planned target must not depend on current size — this is the deterministic-planning invariant that fixes the multi-invocation Cascade convergence.")
        XCTAssertEqual(targetA, plannedSlot,
            "With deterministic planning, the settable-window path should place the window exactly at its planned slot when the slot fits the cascade area.")
    }

    /// Regression proof: with the OLD (pre-fix) behavior — passing
    /// `currentFrame.size` directly as `naturalSize` — the two sets
    /// produce DIFFERENT targets. This shows what the bug was and
    /// why the deterministic fix matters.
    func test_fitFrameEndToEnd_oldBehavior_showsInstability() {
        let cascadeArea = CGRect(x: 30, y: 30, width: 1668, height: 1027)
        let plannedSlot = CGRect(x: 304, y: 142, width: 1168, height: 738)

        let currentA = CGRect(x: 1105, y: 0, width: 623, height: 1084)
        let currentB = CGRect(x: 304, y: 142, width: 1168, height: 738)

        // OLD behavior: naturalSize = currentFrame.size directly.
        let targetA_old = CascadeOrchestrator.fitFrame(
            plannedOrigin: plannedSlot.origin,
            frameSize: plannedSlot.size,
            naturalSize: currentA.size,   // 623×1084 — TALL
            bounds: cascadeArea
        )
        let targetB_old = CascadeOrchestrator.fitFrame(
            plannedOrigin: plannedSlot.origin,
            frameSize: plannedSlot.size,
            naturalSize: currentB.size,   // 1168×738 — target
            bounds: cascadeArea
        )

        // 1084 tall exceeds cascade area's 1027 tall → fitFrame's
        // clampHeight (max(738, 1084) = 1084) triggers y-clamp:
        //   y + 1084 > bounds.maxY (1057) → y = 1057 - 1084 = -27
        //   y < bounds.minY (30) → y = 30
        // vs Set B: clampHeight = max(738, 738) = 738, no clamp,
        // y stays at plannedSlot.y = 142.
        //
        // Assert the two DIFFER — the exact instability observed in
        // Attempts 3 (y=30) vs 4 (y=142) in the user's cascade log.
        XCTAssertNotEqual(targetA_old, targetB_old,
            "The OLD (pre-fix) behavior demonstrably produces different plans for the same window at different current sizes — this is the bug the deterministic-planning fix resolves.")
        XCTAssertEqual(targetA_old.minY, 30,
            "Old behavior clamps y=142 to y=30 for the taller plotted current size — matches the (304,30) origin the user reported for Attempt 3.")
        XCTAssertEqual(targetB_old.minY, 142,
            "Old behavior keeps y=142 for the target-sized current — matches the (304,142) origin the user reported for Attempt 4.")
    }

    /// Non-settable window (Zoom pre-login style) must preserve
    /// existing narrow right-align behavior — the fix must not
    /// regress position-only apps.
    func test_fitFrameEndToEnd_nonSettableNarrow_preservesNaturalSize() {
        let cascadeArea = CGRect(x: 30, y: 30, width: 1668, height: 1027)
        let targetSize = CGSize(width: 1168, height: 738)
        let plannedSlot = CGRect(x: 500, y: 200, width: 1168, height: 738)

        // Non-settable narrow window (Zoom pre-login: 400×600).
        let current = CGRect(x: 100, y: 100, width: 400, height: 600)
        let planning = CascadePlanning.resolveCascadePlanningSize(
            currentFrame: current,
            standardTargetSize: targetSize,
            isSizeSettable: false
        )
        XCTAssertEqual(planning, current.size,
            "Non-settable window must plan at its actual current size.")

        // Simulate the narrow-branch path (willStayNarrow=true for
        // this DR case): shifted origin uses planningSize.width.
        let shiftedOrigin = CGPoint(
            x: plannedSlot.origin.x + plannedSlot.size.width - planning.width,
            y: plannedSlot.origin.y
        )
        let result = CascadeOrchestrator.fitFrame(
            plannedOrigin: shiftedOrigin,
            frameSize: planning,       // send natural size (mutator won't resize)
            naturalSize: planning,     // clamp on natural size
            bounds: cascadeArea
        )
        // Window ends at (500+1168-400, 200) = (1268, 200) with its
        // original 400×600. Right-aligned inside the slot as intended.
        XCTAssertEqual(result.minX, 500 + 1168 - 400)
        XCTAssertEqual(result.minY, 200)
        XCTAssertEqual(result.size, current.size)
    }
}
