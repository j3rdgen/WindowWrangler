//
//  CascadeZOrderDriftTests.swift
//  Window WranglerTests
//
//  Pure tests for the persistent-drift detection policy in
//  `CascadeZOrderDrift`. These verify the exact rule that governs
//  pass-4 escalation: two consecutive non-empty complete-observation
//  checkpoints with overlapping mismatched slot identities.
//
//  Covers the spec matrix:
//   - Order observation (matches, drift, missing mapping)
//   - Persistent-drift detection (identity-based, not count-based)
//   - Settled-status combination
//   - Isolated vs recurring drift
//   - Ignoring observation-incomplete records
//
//  No AX, no NSRunningApplication, no scheduler — the drift-detection
//  logic is pure value-in/value-out.
//

import XCTest
@testable import Window_Wrangler

final class CascadeZOrderDriftTests: XCTestCase {

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

    private func incomplete(_ checkpoint: String) -> ZOrderMismatchRecord {
        ZOrderMismatchRecord(
            checkpoint: checkpoint,
            mismatchedSlots: [],
            observationIncomplete: true
        )
    }

    // MARK: - isPersistentDrift — negative cases

    /// Empty history — nothing to detect.
    func test_isPersistentDrift_empty_false() {
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift([]))
    }

    /// Only settled records — nothing wrong ever.
    func test_isPersistentDrift_allSettled_false() {
        let history = [
            settled("pass 1"),
            settled("+300ms"),
            settled("pass 3"),
            settled("pass 4"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// One drift, then settled — transient, no escalation.
    func test_isPersistentDrift_transientBurst_false() {
        let history = [
            drifted("pass 1", [2, 4]),
            settled("+300ms"),
            settled("pass 3"),
            settled("pass 4"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Only ONE non-empty checkpoint in history — need at least 2.
    func test_isPersistentDrift_singleDrift_false() {
        let history = [
            settled("pass 1"),
            settled("+300ms"),
            drifted("pass 3", [2, 4]),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Two drifts with DISJOINT identity sets — different windows
    /// drifted at different times; no persistence pattern.
    func test_isPersistentDrift_disjointDrifts_false() {
        let history = [
            drifted("pass 3", [1, 2]),
            drifted("pass 4", [5, 6]),
        ]
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    // MARK: - isPersistentDrift — positive cases (the reported bug)

    /// The exact pattern reported in the user's cold-start Cascade
    /// log: same 5 slots keep drifting across +300ms, pass 3, and
    /// pass 4. Escalation MUST trigger.
    func test_isPersistentDrift_exactColdStartPattern_true() {
        let recurringSlots: Set<Int> = [0, 1, 2, 3, 4]
        let history = [
            drifted("pass 1", recurringSlots.union([5, 6])),  // full fallback
            drifted("+300ms", recurringSlots),
            drifted("pass 3", recurringSlots),
            drifted("pass 4", recurringSlots),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Overlap (not equality) of the two most recent non-empty
    /// checkpoints is sufficient. This handles the case where the
    /// mismatch set expands or contracts as apps race their auto-
    /// raises.
    func test_isPersistentDrift_overlappingIdentities_true() {
        let history = [
            drifted("pass 3", [2, 3, 4]),
            drifted("pass 4", [3, 5]),  // shares slot 3
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Single-slot recurrence still counts — even one window that
    /// keeps drifting means observation-based correction wasn't
    /// durable for it.
    func test_isPersistentDrift_singleSlotRecurrence_true() {
        let history = [
            drifted("+300ms", [4]),
            drifted("pass 3", [4]),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Non-adjacent checkpoints separated by a settled one should
    /// NOT count. If drift fully cleared at some point and then
    /// re-emerged, that's not the "same drift never got fixed"
    /// signature — it's fresh drift. Use the two most recent
    /// non-empty checkpoints only.
    func test_isPersistentDrift_driftSettledDrift_dependsOnMostRecentPair() {
        let history = [
            drifted("pass 1", [2, 4]),
            settled("+300ms"),
            drifted("pass 4", [5]),
        ]
        // Most recent non-empty pair: pass 1 (slots {2, 4}) vs
        // pass 4 (slots {5}). Disjoint → NOT persistent.
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Same as above but the second recurrence overlaps the first.
    /// Persistent by policy: the last two non-empty checkpoints
    /// share identities.
    func test_isPersistentDrift_driftSettledSameDriftReturns_true() {
        let history = [
            drifted("pass 1", [2, 4]),
            settled("+300ms"),
            drifted("pass 4", [2, 4]),
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    // MARK: - isPersistentDrift — observation-incomplete handling

    /// Incomplete-observation records must not be treated as either
    /// mismatch or settled — they contribute nothing to the
    /// persistence decision.
    func test_isPersistentDrift_incompleteRecordsIgnored() {
        let history = [
            drifted("pass 3", [2, 4]),
            incomplete("pass 4 (mapping failed)"),
        ]
        // Only one usable non-empty record → false.
        XCTAssertFalse(CascadeZOrderDrift.isPersistentDrift(history))
    }

    /// Two real drifts sandwiching an incomplete observation still
    /// count if the two REAL ones overlap.
    func test_isPersistentDrift_realDriftsWithIncompleteBetween_true() {
        let history = [
            drifted("pass 3", [2, 4]),
            incomplete("mid-pass check"),
            drifted("pass 4", [4, 6]),  // overlaps at slot 4
        ]
        XCTAssertTrue(CascadeZOrderDrift.isPersistentDrift(history))
    }

    // MARK: - lastObservedWrong / lastObservedCorrect

    func test_lastObservedWrong_matchesFinalNonIncompleteRecord() {
        XCTAssertFalse(CascadeZOrderDrift.lastObservedWrong([]))
        XCTAssertFalse(CascadeZOrderDrift.lastObservedWrong([settled("pass 4")]))
        XCTAssertTrue(CascadeZOrderDrift.lastObservedWrong([drifted("pass 4", [1])]))

        // Trailing incomplete should be ignored — use the last
        // complete observation.
        let history = [
            drifted("pass 3", [1, 2]),
            incomplete("pass 4"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.lastObservedWrong(history))
    }

    func test_lastObservedCorrect_symmetric() {
        XCTAssertFalse(CascadeZOrderDrift.lastObservedCorrect([]))
        XCTAssertTrue(CascadeZOrderDrift.lastObservedCorrect([settled("pass 4")]))
        XCTAssertFalse(CascadeZOrderDrift.lastObservedCorrect([drifted("pass 4", [1])]))

        // Drift followed by settled → last complete observation
        // says correct.
        let history = [
            drifted("pass 3", [1, 2]),
            settled("pass 4"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.lastObservedCorrect(history))
    }

    // MARK: - settledWithoutAnyCorrection

    /// The pure "warm cascade — never needed a raise" case.
    func test_settledWithoutAnyCorrection_allSettled_true() {
        let history = [
            settled("pass 1"),
            settled("+300ms"),
            settled("pass 3"),
            settled("pass 4"),
        ]
        XCTAssertTrue(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
    }

    /// Any drift in the history means correction was needed.
    func test_settledWithoutAnyCorrection_anyDrift_false() {
        let history = [
            settled("pass 1"),
            drifted("+300ms", [4]),
            settled("pass 3"),
            settled("pass 4"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
    }

    /// Empty history is NOT "settled without correction" — nothing
    /// was observed, so we can't claim it.
    func test_settledWithoutAnyCorrection_empty_false() {
        XCTAssertFalse(CascadeZOrderDrift.settledWithoutAnyCorrection([]))
    }

    /// Incomplete-only history is not proof of settled.
    func test_settledWithoutAnyCorrection_onlyIncomplete_false() {
        let history = [
            incomplete("pass 3"),
            incomplete("pass 4"),
        ]
        XCTAssertFalse(CascadeZOrderDrift.settledWithoutAnyCorrection(history))
    }

    // MARK: - Timing constants sanity

    /// Spec §"SERIALIZED RECONSTRUCTION REQUIREMENTS": raise spacing
    /// 12–20ms.
    func test_raiseSpacing_withinSpecRange() {
        let spacing = CascadeZOrderSettlementTiming.raiseSpacing
        XCTAssertGreaterThanOrEqual(spacing, 0.012)
        XCTAssertLessThanOrEqual(spacing, 0.020)
    }

    /// Spec §"SETTLED REOBSERVATION": 180–250ms.
    func test_settledReobservationDelay_withinSpecRange() {
        let delay = CascadeZOrderSettlementTiming.settledReobservationDelay
        XCTAssertGreaterThanOrEqual(delay, 0.180)
        XCTAssertLessThanOrEqual(delay, 0.250)
    }

    /// Spec §"BOUNDED LATE RECOMMIT": +1500–1700ms from cascade start.
    func test_lateRecommitEarliestOffset_withinSpecRange() {
        let offset = CascadeZOrderSettlementTiming.lateRecommitEarliestOffset
        XCTAssertGreaterThanOrEqual(offset, 1.500)
        XCTAssertLessThanOrEqual(offset, 1.700)
    }

    /// Spec §"SERIALIZED RECONSTRUCTION REQUIREMENTS": max 2 walks
    /// per generation (one persistent-drift + one late recommit).
    func test_maxSerializedWalks_isExactlyTwo() {
        XCTAssertEqual(CascadeZOrderSettlementTiming.maxSerializedWalksPerGeneration, 2)
    }

    // MARK: - ZOrderFinalStatus is-settled helper

    /// Every settled variant must qualify as settled.
    func test_zOrderStatusIsSettled_positiveCases() {
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledNoCorrection))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledObservationCorrection))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledSerializedReconstruction))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.settledLateRecommit))
        XCTAssertTrue(CascadeOrchestrator.zOrderStatusIsSettled(.staleGeneration))
    }

    /// Unresolved and incomplete-observation cases are NOT settled —
    /// they must not be reported as overall success.
    func test_zOrderStatusIsSettled_negativeCases() {
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.unresolved))
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.observationIncomplete))
        XCTAssertFalse(CascadeOrchestrator.zOrderStatusIsSettled(.cancelled))
    }
}
