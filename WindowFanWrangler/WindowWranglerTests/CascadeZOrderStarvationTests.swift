//
//  CascadeZOrderStarvationTests.swift
//  Window WranglerTests
//
//  Pure tests for `CascadeZOrderDrift.isObservationStarved`.
//
//  This detector is the second half of the settlement decision layer
//  — the identity-based `isPersistentDrift` covers the case where
//  complete observations prove the same slots keep drifting; this
//  one covers the case where CGWindowList observations remain
//  incomplete across multiple consecutive checkpoints and the
//  system therefore cannot verify z-order at all.
//
//  These tests exercise the pure primitive only; end-to-end
//  behavior (pipeline integration, serialized reconstruction reuse,
//  post-walk incomplete handling, late recommit routing, final-
//  status emission) is covered by the manual test matrix and by
//  the shared settlement-behavior tests in the sibling files.
//

import XCTest
@testable import Window_Wrangler

final class CascadeZOrderStarvationTests: XCTestCase {

    // MARK: - Helpers

    private func settled(_ checkpoint: String) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: [],
            observationIncomplete: false
        )
    }

    private func wrong(_ checkpoint: String, _ slots: Set<Int>) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: slots,
            observationIncomplete: false
        )
    }

    /// Incomplete records ALWAYS carry an empty mismatchedSlots set
    /// — that's the invariant `enforceCascadeZOrder` maintains at
    /// the record-append site (line 1856). The detector must NOT
    /// look at those slots because they are not meaningful evidence.
    private func incomplete(_ checkpoint: String) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: [],
            observationIncomplete: true
        )
    }

    // MARK: - Basic negative cases

    func test_emptyHistory_notStarved() {
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved([]))
    }

    func test_oneIncompleteRecord_notStarved() {
        // One record alone can never satisfy the "consecutive ≥ 2"
        // requirement. A single stale CGWindowList read should NOT
        // trigger corrective serialized reconstruction.
        let history = [incomplete("pass 4 (converged z-recheck)")]
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
    }

    func test_oneCompleteRecord_notStarved() {
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved([settled("pass 4")]))
    }

    func test_completeCorrectThenOneIncomplete_notStarved() {
        // The most recent record is incomplete, but there is no
        // second incomplete before it — one incomplete alone is not
        // starvation. This is the "isolated transient" case.
        let history = [
            settled("pass 3"),
            incomplete("pass 4 (converged z-recheck)"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
    }

    // MARK: - Basic positive cases

    func test_twoConsecutiveIncomplete_starved() {
        let history = [
            incomplete("pass 3"),
            incomplete("pass 4 (converged z-recheck)"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }

    func test_threeConsecutiveIncomplete_starved() {
        let history = [
            incomplete("pass 2"),
            incomplete("pass 3"),
            incomplete("pass 4 (converged z-recheck)"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }

    func test_manyConsecutiveIncomplete_starved() {
        let history = [
            incomplete("pass 1"),
            incomplete("+120ms"),
            incomplete("+300ms re-raise"),
            incomplete("pass 3"),
            incomplete("pass 4 (converged z-recheck)"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }

    // MARK: - Streak-must-END-at-latest cases

    func test_incompleteThenCompleteCorrect_notStarved() {
        // Latest record is complete — cannot be starved. The prior
        // incomplete is irrelevant to the current decision.
        let history = [
            incomplete("pass 3"),
            settled("pass 4 (converged z-recheck)"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
    }

    func test_incompleteCompleteWrongIncomplete_notStarved() {
        // The middle complete record breaks the ending streak; we
        // have exactly one trailing incomplete, not two consecutive.
        let history = [
            incomplete("pass 2"),
            wrong("pass 3", [2, 4]),
            incomplete("pass 4 (converged z-recheck)"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
    }

    func test_completeThenTwoConsecutiveIncomplete_starved() {
        // Even when a complete correct record exists earlier, if the
        // most recent two checkpoints have both been unable to
        // verify, we ARE starved at the final checkpoint. The prior
        // complete observation does not guarantee anything about the
        // current state — apps may have auto-raised since then.
        let history = [
            settled("pass 3"),
            incomplete("pass 4 first re-observation"),
            incomplete("pass 4 (converged z-recheck)"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }

    // MARK: - Independence from persistent-drift

    /// Persistent-drift and observation-starvation must be
    /// independently answerable — the two detectors mustn't interfere.
    /// When both could theoretically fire (a run with earlier
    /// persistent drift AND a trailing incomplete streak), each
    /// returns its own truthful answer; the caller decides precedence
    /// (spec §"FINAL-CHECKPOINT DECISION ORDER" — persistent-drift
    /// takes priority when both hold, but that's a caller policy,
    /// not a detector policy).
    func test_persistentDriftHistoryPlusTrailingIncomplete_bothTrue() {
        let history = [
            wrong("pass 2", [3, 4]),
            wrong("pass 3", [3, 5]),   // persistent drift by identity: slot 3 recurs
            incomplete("pass 4 first"),
            incomplete("pass 4 (converged z-recheck)"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }

    func test_warmComplete_neitherFires() {
        let history = [
            settled("pass 1"),
            settled("+120ms"),
            settled("+300ms"),
            settled("pass 3"),
            settled("pass 4 (converged z-recheck)"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
        XCTAssertTrue(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
    }

    // MARK: - Regression: exact reported cold-start trace

    /// Reproduces the exact log signature from the user-reported
    /// cold-start All-Apps DR failure (see Part 1 of the spec):
    ///
    ///     pass 1:            fallback matched 3/7  → incomplete
    ///     +120ms:            fallback matched 3/7  → incomplete
    ///     +300ms re-raise:   fallback matched 3/7  → incomplete
    ///     +500ms:            fallback matched 5/7  → incomplete
    ///     pass 4:            fallback matched 5/7  → incomplete
    ///
    /// Under the pre-fix pipeline, `isPersistentDrift` returned false
    /// (no complete records to compare) and pass 4 silently exited.
    /// Under the fix, this pattern must classify as observation
    /// starvation so the shared serialized reconstruction fires.
    ///
    /// The match ratios (3/7, 5/7) are stored in the checkpoint
    /// LABEL only for diagnostics — the detector must not depend on
    /// them (spec §"OBSERVATION-STARVATION DEFINITION").
    func test_exactColdStartTrace_isStarved_notPersistentDrift() {
        let history = [
            incomplete("all-apps pass 1 [fallback: matched 3/7]"),
            incomplete("all-apps pass 2 (converged z-recheck) [fallback: matched 3/7]"),
            incomplete("all-apps +300ms re-raise [fallback: matched 3/7]"),
            incomplete("all-apps pass 3 (converged z-recheck) [fallback: matched 5/7]"),
            incomplete("all-apps pass 4 (converged z-recheck) [fallback: matched 5/7]"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history),
            "Persistent-drift detector must NOT be reinterpreted to fire on incomplete records — its purpose is identity-based drift, not availability-of-observation.")
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history),
            "Exact reported cold-start pattern MUST be classified as observation starvation so the shared serialized reconstruction fires at pass 4.")
    }

    // MARK: - Match-ratio independence

    /// The detector MUST NOT read matched/N ratios. Even a
    /// hypothetically high-match incomplete run (e.g. 6/7 across
    /// two consecutive checkpoints) still means we haven't verified
    /// the full plan, and the detector must escalate.
    func test_highMatchRatioStillIncomplete_starved() {
        // Both records carry EMPTY mismatchedSlots (the invariant
        // for incomplete records). Ratio information doesn't exist
        // in the record — proving the detector cannot possibly read
        // it. Two consecutive incomplete + latest incomplete = starved.
        let history = [
            incomplete("pass 3 [fallback: matched 6/7]"),
            incomplete("pass 4 (converged z-recheck) [fallback: matched 6/7]"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }

    // MARK: - Single-window plan safety

    /// A single-window plan cannot really be "wrong" — there's no
    /// order to verify. This test asserts detector behavior in the
    /// degenerate case: the caller is responsible for skipping the
    /// escalation entirely when plan.count ≤ 1 (spec Part 3
    /// §"PURE OBSERVATION-STARVATION DECISION" bullet 5), but the
    /// detector itself doesn't know plan size and answers the
    /// history question honestly.
    func test_detectorIsHistoryOnly_ignoresPlanSize() {
        // Two consecutive incomplete: detector says starved.
        // The caller's guard on plan.count is what protects the
        // degenerate case, not the detector.
        let history = [
            incomplete("pass 3"),
            incomplete("pass 4"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
    }

    // MARK: - Boundary sanity: complete-wrong followed by complete-correct

    /// Guards against a bug where the detector might inadvertently
    /// treat any non-empty history + final incomplete as starved.
    /// Here the ending streak is 0 (last record is complete correct),
    /// so not starved.
    func test_completeWrongThenCompleteCorrect_notStarved() {
        let history = [
            wrong("pass 3", [1, 3]),
            settled("pass 4 (converged z-recheck)"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isObservationStarved(history))
    }

    // MARK: - New final-status handling

    /// The new `.unresolvedObservationIncomplete` case must NOT be
    /// classified as settled. It represents "we could not verify" —
    /// distinct from settled outcomes and distinct from `.unresolved`
    /// (which represents "we DID verify and it was wrong").
    func test_unresolvedObservationIncomplete_isNotSettled() {
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.unresolvedObservationIncomplete))
    }

    /// Existing settled statuses stay settled — sanity check that the
    /// new case did not disturb the existing matrix.
    func test_existingSettledStatuses_stillSettled() {
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledNoCorrection))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledObservationCorrection))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledSerializedReconstruction))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledLateRecommit))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.staleGeneration))
    }

    /// Existing unsettled statuses stay unsettled.
    func test_existingUnsettledStatuses_stillUnsettled() {
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.unresolved))
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.observationIncomplete))
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.cancelled))
    }

    // MARK: - Persistent-drift semantics unchanged

    /// The persistent-drift detector must NOT have been modified as
    /// part of the observation-starvation fix. This test locks in
    /// the exact behavior: complete records with overlapping mismatched
    /// slots still escalate, incomplete records still do not count.
    func test_persistentDrift_unchanged_incompleteRecordsStillExcluded() {
        // Two consecutive INCOMPLETE records with overlapping (empty)
        // mismatch sets — must NOT be treated as persistent drift.
        let history = [
            incomplete("pass 3"),
            incomplete("pass 4"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history),
            "Persistent-drift detector must continue to exclude incomplete records. If this test fails, the persistent-drift semantics were changed by the starvation fix — that's a regression.")
    }

    /// Two complete records with overlapping mismatched slots still
    /// escalate as persistent drift, exactly as before.
    func test_persistentDrift_unchanged_completeOverlappingStillEscalates() {
        let history = [
            wrong("pass 3", [2, 4]),
            wrong("pass 4", [4, 6]),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    // MARK: - Final-checkpoint decision-order intent (via history patterns)

    /// This test encodes the decision-order intent from the spec:
    /// when BOTH detectors would fire, persistent-drift takes precedence
    /// (caller policy at `runPassFourZOrderCheckpoint`). Both detectors
    /// answer TRUE independently — the caller must check persistent
    /// drift FIRST.
    func test_decisionOrder_persistentDriftHasPrecedenceWhenBothFire() {
        let history = [
            wrong("pass 2", [3]),
            wrong("pass 3", [3, 5]),        // persistent drift by identity
            incomplete("pass 4 first re-observation"),
            incomplete("pass 4 (converged z-recheck)"),   // starvation-eligible
        ]
        // Both detectors independently see their signal:
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
        XCTAssertTrue(CascadeZOrderDrift.isObservationStarved(history))
        // The caller (runPassFourZOrderCheckpoint) evaluates persistent
        // drift first — this is documented in the function's Doc-
        // comment as the spec-required decision order. Both detectors
        // remain independently queryable so tests + future callers
        // aren't locked into one specific precedence.
    }
}
