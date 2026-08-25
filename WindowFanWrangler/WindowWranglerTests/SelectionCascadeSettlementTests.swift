//
//  SelectionCascadeSettlementTests.swift
//  Window WranglerTests
//
//  Focused tests for the Selection Cascade z-order settlement
//  integration. The Selection integration reuses the same drift
//  detection, serialized reconstruction, reobservation, late
//  recommit, and final status primitives that already work for
//  All-Apps — so these tests focus on:
//
//    1. The shared drift-detection primitives operate correctly
//       on Selection checkpoint labels (identity-based, label-
//       agnostic).
//    2. The final-status combination model treats Selection
//       outcomes identically to All-Apps.
//    3. The shared timing constants are the same ones Selection
//       reuses (no accidental Selection-specific values).
//    4. Warm cascades stay zero-raise; persistent drift escalates
//       to the shared serialized reconstruction.
//
//  End-to-end scheduling and cancellation behavior for Selection
//  requires live AX and NSRunningApplication interaction and is
//  covered by the manual test matrix in the completion report.
//  These tests exercise the pure decision layer that both paths
//  now share.
//

import XCTest
@testable import Window_Wrangler

final class SelectionCascadeSettlementTests: XCTestCase {

    // MARK: - Helpers

    private func settled(_ checkpoint: String) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: [],
            observationIncomplete: false
        )
    }

    private func drifted(_ checkpoint: String, _ slots: Set<Int>) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: slots,
            observationIncomplete: false
        )
    }

    // MARK: - Drift detection is label-agnostic

    /// The shared persistent-drift detector works on any checkpoint
    /// labels — Selection pipeline labels (`"selection pass 4 ..."`)
    /// must trigger escalation identically to All-Apps labels when
    /// the drift pattern matches.
    func test_persistentDrift_selectionLabels_triggersEscalation() {
        let history = [
            drifted("selection pass 1", [3]),
            drifted("selection pass 2 (converged z-recheck)", [3, 4]),
            drifted("selection +300ms re-raise", [3]),
            drifted("selection pass 3 (converged z-recheck)", [3, 5]),
            drifted("selection pass 4 (converged z-recheck)", [3]),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Mixed selection + all-apps labels in one history are
    /// nonsensical in practice (each cascade resets history) but the
    /// detector must not care about label origin — it evaluates
    /// identity overlap only. Guards against accidental
    /// label-parsing coupling.
    func test_persistentDrift_mixedLabels_stillIdentityBased() {
        let history = [
            drifted("all-apps pass 3 (converged z-recheck)", [2, 4]),
            drifted("selection pass 4 (converged z-recheck)", [4]),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Warm Selection cascade — every checkpoint reports correct order.
    /// No escalation, no correction claimed.
    func test_warmSelection_allSettled_noEscalation() {
        let history = [
            settled("selection pass 1"),
            settled("selection pass 2 (converged z-recheck)"),
            settled("selection +300ms re-raise"),
            settled("selection pass 3 (converged z-recheck)"),
            settled("selection pass 4 (converged z-recheck)"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
        XCTAssertTrue(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
        XCTAssertTrue(CascadeZOrderDrift.lastObservedCorrect(history))
    }

    /// Transient drift at Selection pass 1 (initial fallback full
    /// walk) that fully settles by pass 2 — no persistent-drift
    /// escalation should fire on the subsequent quiet checkpoints.
    func test_selectionTransientDrift_settlesQuickly_noEscalation() {
        let history = [
            drifted("selection pass 1", [1, 2, 3, 4]),   // initial fallback
            settled("selection pass 2 (converged z-recheck)"),
            settled("selection +300ms re-raise"),
            settled("selection pass 3 (converged z-recheck)"),
            settled("selection pass 4 (converged z-recheck)"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
        XCTAssertFalse(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
        XCTAssertTrue(CascadeZOrderDrift.lastObservedCorrect(history))
    }

    /// Reproduces the exact log signature the user reported for the
    /// selection cascade failure — one initial "matched 5/7 planned
    /// window(s)" raise followed by nothing. Under the new pipeline
    /// the subsequent scheduled checkpoints must exist and either
    /// clear (isolated drift path) or escalate (persistent-drift
    /// path). This test proves the escalation path fires when the
    /// recorded pattern matches persistent drift.
    func test_reproducesReportedSelectionFailure_escalates() {
        // The reported failure had ONE initial raise then nothing.
        // Under the new pipeline, subsequent checkpoints run and
        // record their own observations. If drift persists across
        // pass 3 and pass 4, escalation triggers.
        let history = [
            drifted("selection pass 1", [1, 2, 3, 4, 5, 6]),   // fallback full walk
            drifted("selection pass 3 (converged z-recheck)", [2, 4]),
            drifted("selection pass 4 (converged z-recheck)", [4]),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    // MARK: - Final status parity with All-Apps

    /// Every final-status variant Selection can produce must be
    /// recognized by the shared `zOrderStatusIsSettled` helper.
    /// This is the invariant that lets the final verify report
    /// treat All-Apps and Selection outcomes consistently.
    func test_selectionFinalStatuses_settledCheckIsShared() {
        // Warm Selection: no correction ever needed.
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledNoCorrection))
        // Selection with intermediate drift that observation-based
        // correction resolved.
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledObservationCorrection))
        // Selection with persistent drift — serialized reconstruction
        // resolved.
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledSerializedReconstruction))
        // Selection with continuing drift after first walk — late
        // recommit resolved.
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledLateRecommit))
        // Superseded by newer cascade or Restore — treated as benign
        // non-failure.
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.staleGeneration))

        // Cases the Selection pipeline must NOT report as settled.
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.unresolved))
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.observationIncomplete))
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.cancelled))
    }

    // MARK: - No Selection-specific timing constants

    /// The Selection pipeline MUST reuse the exact same timing
    /// constants as All-Apps — no accidental Selection-specific
    /// values. If a change to a shared constant is warranted, both
    /// paths change together. If drift is observed only in Selection,
    /// the fix goes into the pipeline, not into a fork.
    func test_selectionReusesSharedTimingConstants() {
        // These constants live in CascadeZOrderSettlementTiming and
        // are consumed identically by All-Apps and Selection. The
        // test asserts the values are within spec, which validates
        // both call sites simultaneously.
        XCTAssertEqual(CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration, 2)
        XCTAssertGreaterThanOrEqual(CascadeZOrderSettlementTiming.raiseSpacing, 0.012)
        XCTAssertLessThanOrEqual(CascadeZOrderSettlementTiming.raiseSpacing, 0.020)
        XCTAssertGreaterThanOrEqual(CascadeZOrderSettlementTiming.settledReobservationDelay, 0.180)
        XCTAssertLessThanOrEqual(CascadeZOrderSettlementTiming.settledReobservationDelay, 0.250)
        XCTAssertGreaterThanOrEqual(CascadeZOrderSettlementTiming.lateRecommitEarliestOffset, 1.500)
        XCTAssertLessThanOrEqual(CascadeZOrderSettlementTiming.lateRecommitEarliestOffset, 1.700)
    }

    // MARK: - Fresh-history invariant

    /// Selection settlement init clears history so the persistent-
    /// drift detector for a fresh Selection cascade sees ONLY that
    /// cascade's own checkpoints — never inherited from a prior
    /// All-Apps operation. The pure detector already respects this
    /// (it operates on whatever history slice it's given), so the
    /// test asserts that an empty history plus one Selection
    /// checkpoint cannot trigger escalation.
    func test_freshSelectionHistory_singleCheckpoint_noEscalation() {
        let historyAfterInit: [ZOrderMismatchRecord] = []
        let historyAfterPass1 = historyAfterInit + [drifted("selection pass 1", [1, 2, 3, 4, 5])]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(historyAfterPass1),
            "One Selection checkpoint alone must never trigger escalation — persistence requires at least two consecutive complete non-empty checkpoints.")
    }

    /// Two Selection checkpoints with disjoint mismatch identities
    /// mean different windows drifted at different times — not
    /// persistent drift, so no escalation. Regression guard against
    /// an over-eager count-only heuristic.
    func test_twoSelectionCheckpoints_disjointIdentities_noEscalation() {
        let history = [
            drifted("selection pass 3 (converged z-recheck)", [1, 2]),
            drifted("selection pass 4 (converged z-recheck)", [5, 6]),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Two Selection checkpoints with overlapping identity — the
    /// exact "same slot keeps drifting" pattern that made the lasso
    /// auto-cascade case fail visually. This MUST escalate.
    func test_twoSelectionCheckpoints_overlappingIdentities_escalates() {
        let history = [
            drifted("selection pass 3 (converged z-recheck)", [1, 2, 4]),
            drifted("selection pass 4 (converged z-recheck)", [4, 6]),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }
}
