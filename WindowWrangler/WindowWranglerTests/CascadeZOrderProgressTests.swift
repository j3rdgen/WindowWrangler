//
//  CascadeZOrderProgressTests.swift
//  Window WranglerTests
//
//  Pure tests for `CascadeZOrderDrift.postWalkMadeObservationProgress`
//  — the progress gate that decides whether a second serialized
//  reconstruction has evidence it might improve observability, or
//  whether the incomplete plateau is structural and walk #2 would
//  just re-flicker against the same unobservability.
//
//  Also covers regression scenarios that reproduce the exact
//  matched-count patterns from the user-reported cold cascades
//  (gen 11 = 5/6 plateau; gens 17/18/19/22 = 7/8 plateau; hypothetical
//  5/8 → 7/8 = coverage-improved case that keeps walk #2 available).
//
//  End-to-end orchestration (that these decisions flow into the
//  correct `handlePostWalkIncomplete` branches) requires live AX + a
//  main-actor cascade, which is out of scope for the unit test target;
//  the pure decision layer covered here is where the correctness lives.
//

import XCTest
@testable import Window_Wrangler

final class CascadeZOrderProgressTests: XCTestCase {

    // MARK: - Progress-decision unit tests

    /// Complete post-walk observation is NOT this function's decision
    /// (the caller routes complete-correct / complete-wrong via
    /// distinct branches). The function must return false when
    /// `postWalkIncomplete == false` so the caller doesn't misuse it.
    func test_completeObservation_returnsFalse_neverProgress() {
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 5,
            postWalkMatchedCount: 8,
            postWalkIncomplete: false
        ))
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 5,
            postWalkMatchedCount: 5,
            postWalkIncomplete: false
        ))
    }

    /// Strictly increased coverage means the walk moved the observer
    /// closer to a complete view. Progress = true, walk #2 permitted.
    func test_coverageIncreased_progressTrue() {
        XCTAssertTrue(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 5,
            postWalkMatchedCount: 7,
            postWalkIncomplete: true
        ))
    }

    /// Equal coverage is NOT progress. This is the primary
    /// structural-plateau case (5/6 → 5/6, 7/8 → 7/8). Walk #2 must
    /// be suppressed — that's the retry-flicker fix.
    func test_coverageEqual_progressFalse_structuralPlateau() {
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 7,
            postWalkMatchedCount: 7,
            postWalkIncomplete: true
        ))
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 5,
            postWalkMatchedCount: 5,
            postWalkIncomplete: true
        ))
    }

    /// Regressed coverage (walk #1 somehow left the observer with
    /// fewer visible windows than before). NOT progress. Do not
    /// fire walk #2 to chase further observation.
    func test_coverageRegressed_progressFalse() {
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 7,
            postWalkMatchedCount: 6,
            postWalkIncomplete: true
        ))
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 7,
            postWalkMatchedCount: 5,
            postWalkIncomplete: true
        ))
    }

    /// Baseline was zero (no observation ever landed pre-walk).
    /// Any positive post-walk coverage counts as progress.
    func test_baselineZero_anyCoverageIsProgress() {
        XCTAssertTrue(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 0,
            postWalkMatchedCount: 1,
            postWalkIncomplete: true
        ))
        XCTAssertTrue(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 0,
            postWalkMatchedCount: 7,
            postWalkIncomplete: true
        ))
    }

    /// Baseline zero + post-walk zero — no progress.
    func test_baselineZeroPostZero_notProgress() {
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 0,
            postWalkMatchedCount: 0,
            postWalkIncomplete: true
        ))
    }

    // MARK: - Regression: exact reported plateau patterns

    /// Gen 11 pattern: 6-window plan, best pre-walk matched 5, post-
    /// walk still matched 5. The user's log showed this producing a
    /// second serialized walk (retry flicker); the fix must suppress
    /// walk #2 by returning false from the progress helper.
    func test_gen11_5of6Plateau_walk2Suppressed() {
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 5,
            postWalkMatchedCount: 5,
            postWalkIncomplete: true
        ))
    }

    /// Gens 17/18/19/22 pattern: 8-window plan, best pre-walk matched
    /// 7 (Grammarly or Notes chronically unmappable), post-walk still
    /// matched 7. Walk #2 must be suppressed.
    func test_gen17_7of8Plateau_walk2Suppressed() {
        XCTAssertFalse(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 7,
            postWalkMatchedCount: 7,
            postWalkIncomplete: true
        ))
    }

    /// Hypothetical improving case: 8-window plan, best pre-walk
    /// matched 5, post-walk matched 7. Walk #2 remains available —
    /// CGWindowList is catching up and the second walk might complete
    /// verification. The fix must NOT suppress walk #2 in this case.
    func test_improvingCase_5to7_walk2Retained() {
        XCTAssertTrue(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 5,
            postWalkMatchedCount: 7,
            postWalkIncomplete: true
        ))
    }

    /// Big-jump improving case: 8-window plan, best pre-walk matched
    /// 1, post-walk matched 7. Walk #2 permitted.
    func test_improvingCase_1to7_walk2Retained() {
        XCTAssertTrue(CascadeZOrderDrift.postWalkMadeObservationProgress(
            bestPreWalkMatchedCount: 1,
            postWalkMatchedCount: 7,
            postWalkIncomplete: true
        ))
    }

    // MARK: - ZOrderMismatchRecord matched/planned fields

    /// The new matchedCount / plannedCount fields default to zero so
    /// pre-existing test call sites (SelectionCascadeSettlementTests,
    /// CascadeZOrderDriftTests, CascadeZOrderStarvationTests) that
    /// construct records via the abbreviated initializer still work.
    func test_recordDefaults_backwardsCompatible() {
        let record = ZOrderMismatchRecord(
            checkpoint: "test",
            mismatchedSlots: [],
            observationIncomplete: false
        )
        XCTAssertEqual(record.matchedCount, 0)
        XCTAssertEqual(record.plannedCount, 0)
    }

    /// When explicitly populated, the fields survive round-trip.
    /// Guards against a future refactor that accidentally drops them.
    func test_recordExplicitFields_roundTrip() {
        let record = ZOrderMismatchRecord(
            checkpoint: "post-walk #1 reobservation",
            mismatchedSlots: [],
            observationIncomplete: true,
            matchedCount: 7,
            plannedCount: 8
        )
        XCTAssertEqual(record.matchedCount, 7)
        XCTAssertEqual(record.plannedCount, 8)
        XCTAssertTrue(record.observationIncomplete)
    }

    /// Persistent-drift and starvation detectors both use
    /// `mismatchedSlots` and `observationIncomplete` — they must
    /// continue to ignore the new matched/planned fields (no
    /// accidental coupling introduced by the new schema).
    func test_persistentDriftUnaffectedByMatchedFields() {
        let record = ZOrderMismatchRecord(
            checkpoint: "pass 3",
            mismatchedSlots: [3, 5],
            observationIncomplete: false,
            matchedCount: 8,
            plannedCount: 8
        )
        let record2 = ZOrderMismatchRecord(
            checkpoint: "pass 4",
            mismatchedSlots: [5, 7],
            observationIncomplete: false,
            matchedCount: 8,
            plannedCount: 8
        )
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift([record, record2]))
    }

    func test_starvationDetectorUnaffectedByMatchedFields() {
        let history = [
            ZOrderMismatchRecord(
                checkpoint: "pass 3",
                mismatchedSlots: [],
                observationIncomplete: true,
                matchedCount: 7,
                plannedCount: 8
            ),
            ZOrderMismatchRecord(
                checkpoint: "pass 4",
                mismatchedSlots: [],
                observationIncomplete: true,
                matchedCount: 7,
                plannedCount: 8
            ),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }
}
