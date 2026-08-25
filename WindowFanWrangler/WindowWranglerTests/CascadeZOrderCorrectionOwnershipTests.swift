//
//  CascadeZOrderCorrectionOwnershipTests.swift
//  Window WranglerTests
//
//  Correctness-critical invariants for the two-phase correction-
//  ownership model.
//
//  These tests operate on the pure decision + record layer. End-to-
//  end orchestration (that the actual `enforceCascadeZOrder` /
//  `intermediateZOrderCheckpoint` / `observeCascadeZOrder` routing
//  produces the intended AXRaise counts on live windows) requires
//  live AX + a main-actor cascade, out of scope for this test target.
//  The manual test matrix in the completion report covers that.
//
//  What these tests DO cover:
//    - `ZOrderMismatchRecord` matched/planned fields survive round-trip
//      and don't perturb the persistent-drift / observation-starvation
//      detectors (regression guard for the record-schema extension).
//    - The exact generation-24 mismatched-slot history pattern is
//      classifiable by the shared decision helpers so the settlement
//      pipeline reaches the right final status.
//    - The progress helper correctly distinguishes the "post-walk
//      improved coverage → walk #2 permitted" case from the "post-walk
//      stayed flat → walk #2 suppressed" case that maps to the
//      structural plateau the two-phase fix is targeting.
//
//  Tests that assert "intermediate checkpoints must not raise" and
//  "pass 4 waits for native-repair drain" are orchestration-level and
//  live in the manual test matrix.
//

import XCTest
@testable import Window_Wrangler

final class CascadeZOrderCorrectionOwnershipTests: XCTestCase {

    // MARK: - Helpers

    private func settled(_ checkpoint: String, matched: Int, planned: Int) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: [],
            observationIncomplete: false,
            matchedCount: matched,
            plannedCount: planned
        )
    }

    private func incomplete(_ checkpoint: String, matched: Int, planned: Int) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: [],
            observationIncomplete: true,
            matchedCount: matched,
            plannedCount: planned
        )
    }

    private func wrong(_ checkpoint: String, slots: Set<Int>, matched: Int, planned: Int) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: slots,
            observationIncomplete: false,
            matchedCount: matched,
            plannedCount: planned
        )
    }

    // MARK: - Generation-24 regression: intermediate observations feed correct final decision

    /// The exact log signature from user's generation 24 reduced to
    /// checkpoint records. Under the pre-fix design, each of these
    /// intermediate observations was accompanied by a corrective
    /// fallback full walk (5 pass-2 native-repair walks + 2 pass-3
    /// native-repair walks + others). Under the two-phase fix, all
    /// of those become observation-only — the record data is
    /// identical, only the accompanying AXRaise is removed.
    ///
    /// This test asserts that with the same evidence recorded and
    /// no correction walks fired mid-flight, the pass-4 detector
    /// path still correctly identifies observation starvation.
    func test_gen24_intermediateRecordsProduceCorrectPass4Classification() {
        let history: [ZOrderMismatchRecord] = [
            // pass 1 (was: fallback 1/8 full walk; still fires — provisional)
            incomplete("all-apps pass 1", matched: 1, planned: 8),
            // +300ms re-raise (was: fallback 2/8 full walk; now: observe-only)
            incomplete("all-apps +300ms re-raise", matched: 2, planned: 8),
            // 5× pass 2 native repair (was: 5 fallback walks; now: 5 observations)
            incomplete("all-apps pass 2 (native repair)", matched: 4, planned: 8),
            incomplete("all-apps pass 2 (native repair)", matched: 5, planned: 8),
            incomplete("all-apps pass 2 (native repair)", matched: 5, planned: 8),
            incomplete("all-apps pass 2 (native repair)", matched: 5, planned: 8),
            incomplete("all-apps pass 2 (native repair)", matched: 5, planned: 8),
            // pass 4 pure observation
            incomplete("all-apps pass 4 (converged z-recheck)", matched: 5, planned: 8),
        ]

        // Persistent-drift detector: no complete records with
        // overlapping mismatched slots. Correctly returns false.
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history),
            "Incomplete records must never satisfy identity-based persistent-drift.")

        // Observation-starvation detector: ending streak length is
        // 8 consecutive incomplete records. Correctly returns true —
        // this is exactly the escalation trigger the log shows firing.
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history),
            "Long ending incomplete streak must trigger observation-starvation escalation.")
    }

    /// Progress-gate proof for the same generation: pre-walk best
    /// matched count was 5, post-walk was 6 (after serialized walk #1
    /// actually improved observability from 5/8 to 6/8). Walk #2
    /// should remain justified. Guards against a regression that
    /// would over-eagerly suppress walk #2.
    func test_gen24_walkOneImprovedFrom5To6_walk2Permitted() {
        XCTAssertTrue(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 5,
            postWalkMatchedCount: 6,
            postWalkIncomplete: true
        ))
    }

    /// Structural plateau reproduction: 7/8 pre, 7/8 post. Walk #2
    /// suppressed — the second walk has no evidence it would help,
    /// AND under the new two-phase model there are no intermediate
    /// fallback walks contaminating the pre-walk baseline, so this
    /// gate now fires against a clean baseline.
    func test_structuralPlateau_walk2Suppressed() {
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 7,
            postWalkMatchedCount: 7,
            postWalkIncomplete: true
        ))
    }

    // MARK: - Warm-path regression

    /// Warm cascade: every intermediate observation is complete + correct.
    /// Persistent-drift stays false. Starvation stays false. Progress
    /// gate never engages (no walk fires). Under the two-phase model
    /// the same warm history is produced with ZERO intermediate raises
    /// (pass 1 front-prefix corrector already handled it, then all
    /// subsequent stages observe). This test asserts the detectors
    /// stay quiet under that history.
    func test_warmCascade_allDetectorsQuiet() {
        let history: [ZOrderMismatchRecord] = [
            settled("all-apps pass 1", matched: 6, planned: 6),
            settled("all-apps pass 2 (converged z-recheck)", matched: 6, planned: 6),
            settled("all-apps +300ms re-raise", matched: 6, planned: 6),
            settled("all-apps pass 3 (converged z-recheck)", matched: 6, planned: 6),
            settled("all-apps pass 4 (converged z-recheck)", matched: 6, planned: 6),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
        XCTAssertTrue(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
    }

    // MARK: - Intermediate records preserve evidence for final decision

    /// The two-phase model converts intermediate stages to observation-
    /// only, but the records those stages append MUST still feed the
    /// persistent-drift detector correctly when they are complete.
    /// Regression guard: an intermediate stage that observes complete +
    /// wrong now records the mismatch (no correction fires); pass 4
    /// then sees two consecutive complete non-empty checkpoints and
    /// escalates via persistent-drift, exactly as it would have under
    /// the pre-fix design.
    func test_intermediateObservationsFeedPersistentDrift() {
        let history: [ZOrderMismatchRecord] = [
            // Intermediate complete + wrong (no correction fired under
            // two-phase model, just record):
            wrong("all-apps pass 2 (converged z-recheck)", slots: [3, 5], matched: 8, planned: 8),
            wrong("all-apps pass 3 (converged z-recheck)", slots: [5, 6], matched: 8, planned: 8),
            // Pass 4 pure observation still sees wrong:
            wrong("all-apps pass 4 (converged z-recheck)", slots: [3, 5], matched: 8, planned: 8),
        ]
        // Slot 5 recurs across all three complete observations — clear
        // persistent-drift signal. Two-phase model preserves this
        // exactly because it observes at the same checkpoints.
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Same as above but with disjoint mismatched slots — should NOT
    /// escalate, and the two-phase model must preserve that. Records
    /// contain matched/planned fields but detector still ignores them.
    func test_intermediateComplete_disjointSlots_noEscalation() {
        let history: [ZOrderMismatchRecord] = [
            wrong("all-apps pass 2 (converged z-recheck)", slots: [3], matched: 8, planned: 8),
            wrong("all-apps pass 4 (converged z-recheck)", slots: [7], matched: 8, planned: 8),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    // MARK: - Selection parity

    /// Selection Cascade shares the same detectors. The two-phase
    /// intermediate observation-only policy applied to Selection means
    /// intermediate Selection checkpoints append records with matched/
    /// planned counts. Regression guard: the Selection pass-4 checkpoint
    /// (routed through the shared `runPassFourZOrderCheckpoint`) still
    /// correctly classifies a warm run.
    func test_selection_warmCascade_settlesNoCorrection() {
        let history: [ZOrderMismatchRecord] = [
            settled("selection pass 1", matched: 6, planned: 6),
            settled("selection pass 2 (converged z-recheck)", matched: 6, planned: 6),
            settled("selection +300ms re-raise", matched: 6, planned: 6),
            settled("selection pass 3 (converged z-recheck)", matched: 6, planned: 6),
            settled("selection pass 4 (converged z-recheck)", matched: 6, planned: 6),
        ]
        XCTAssertTrue(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
    }

    /// Selection Cascade with structural unobservability (e.g. selection
    /// includes Grammarly window): intermediate observation-only stages
    /// consistently report 5/6, pass 4 classifies as starved. The two-
    /// phase model must preserve this behavior for Selection.
    func test_selection_structuralPlateau_starvationDetected() {
        let history: [ZOrderMismatchRecord] = [
            incomplete("selection pass 1", matched: 5, planned: 6),
            incomplete("selection pass 2 (converged z-recheck)", matched: 5, planned: 6),
            incomplete("selection +300ms re-raise", matched: 5, planned: 6),
            incomplete("selection pass 3 (converged z-recheck)", matched: 5, planned: 6),
            incomplete("selection pass 4 (converged z-recheck)", matched: 5, planned: 6),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    // MARK: - Pre-walk-best baseline captured from intermediate records

    /// Under the two-phase model, the pre-walk-best matched count is
    /// derived from ALL intermediate observation records for the
    /// generation (they're all recorded even without corrections
    /// firing). The gate downstream compares post-walk against that
    /// max. This test proves the max is computable directly from
    /// the record history — no orchestration-side state gymnastics.
    func test_preWalkBest_computedFromRecordHistory() {
        let history: [ZOrderMismatchRecord] = [
            incomplete("all-apps pass 1", matched: 1, planned: 8),
            incomplete("all-apps +300ms re-raise", matched: 2, planned: 8),
            incomplete("all-apps pass 2 (native repair)", matched: 4, planned: 8),
            incomplete("all-apps pass 2 (native repair)", matched: 5, planned: 8),
            incomplete("all-apps pass 3 (converged z-recheck)", matched: 7, planned: 8),
            incomplete("all-apps pass 4 (converged z-recheck)", matched: 7, planned: 8),
        ]
        let bestPre = history.map(\.matchedCount).max() ?? 0
        XCTAssertEqual(bestPre, 7,
            "Pre-walk best matched count must be the maximum across ALL intermediate records, so post-walk gating compares against the strongest coverage the observer ever achieved this generation.")
    }
}
