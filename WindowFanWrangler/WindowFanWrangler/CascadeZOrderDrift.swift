//
//  CascadeZOrderDrift.swift
//  Window Wrangler
//
//  Pure per-generation z-order settlement state + drift-detection
//  logic for the all-apps Cascade. Separated from CascadeOrchestrator
//  so the correctness-critical decisions (persistent-drift detection,
//  serialized-walk-count enforcement, final-status combination) can be
//  unit-tested without AX, NSRunningApplication, or main-actor work.
//
//  Motivation (spec §"CURRENT OBSERVED BEHAVIOR" and §"WHY A SIMPLE
//  ONE-LINE PASS-4 FULL WALK IS NOT ENOUGH"):
//  A single fixed-count metric like "5/7 raises" doesn't distinguish
//  transient drift (one auto-raise from one app that quickly settles)
//  from persistent drift (the same subset of windows keeps needing
//  correction across multiple checkpoints). Only identity-based
//  history can. Persistent drift is the signal that ordinary
//  observation-based correction is not durable and a serialized
//  full reconstruction is warranted.
//

import Foundation
import CoreGraphics

// MARK: - Checkpoint record

/// One z-order observation checkpoint's outcome, keyed by the slot
/// indices that were found out of order. Slot indices are used
/// instead of AXUIElement handles because the persistent-drift
/// comparison is purely set-theoretic and shouldn't require Core
/// Foundation reference identity across records.
struct ZOrderMismatchRecord: Equatable {
    /// Human label matching the log line: "all-apps pass 1",
    /// "+300ms re-raise", "pass 3 (converged z-recheck)", etc.
    let checkpoint: String

    /// Slot indices (into the ordered plan; 0 = anchor/frontmost,
    /// n-1 = deepest) where CGWindowList observed the wrong window.
    /// Empty set means "order correct at this checkpoint" OR
    /// "observation was incomplete" (see `observationIncomplete`).
    let mismatchedSlots: Set<Int>

    /// True when observation could not confidently map every planned
    /// window to a CGWindowList entry. When incomplete, the record
    /// is retained for diagnostics but MUST NOT be used to prove
    /// settled success in the final status.
    let observationIncomplete: Bool

    /// Coverage metric — how many of the planned windows the observer
    /// managed to confidently map to CGWindowList this checkpoint.
    /// For complete records equals `plannedCount`; for incomplete
    /// records is strictly less. Used by `postWalkMadeObservationProgress`
    /// to decide whether a serialized reconstruction actually improved
    /// observability. Defaults to 0 for pre-existing test call sites.
    var matchedCount: Int = 0

    /// Coverage denominator — the total intended windows in the plan
    /// this checkpoint was evaluating. Redundant when the record is
    /// complete (`matchedCount == plannedCount`), but the pair is what
    /// downstream diagnostics log ("matched N/M") and what the progress
    /// helper compares. Defaults to 0.
    var plannedCount: Int = 0
}

// MARK: - Final z-order status

/// Independent z-order settlement outcome for the active generation.
/// Reported alongside geometry status by the final verify — geometry
/// alone is not sufficient to prove a cascade fully settled.
enum ZOrderFinalStatus: Equatable {
    /// Every observation checkpoint reported the order correct
    /// without any raises being required.
    case settledNoCorrection

    /// One or more observation-based (partial / prefix / full-walk-
    /// via-optimizer) corrections were needed, and the last
    /// observation showed order correct.
    case settledObservationCorrection

    /// The pass-4 persistent-drift escalation ran a serialized
    /// reconstruction; subsequent settled reobservation confirmed
    /// correct order.
    case settledSerializedReconstruction

    /// The late recommit was required in addition to the first
    /// serialized reconstruction; final reobservation confirmed
    /// correct order.
    case settledLateRecommit

    /// Both serialized attempts ran and order is still wrong.
    /// No further correction will fire.
    case unresolved

    /// CGWindowList observation could not confidently map all planned
    /// windows during a checkpoint that mattered for the settlement
    /// decision. Reported distinctly so a wrong result can't hide
    /// behind a missing mapping.
    case observationIncomplete

    /// Generation advanced (Restore Previous Layout or a new Cascade)
    /// before the pipeline completed. No further action taken.
    case staleGeneration

    /// Cancelled by an explicit signal (accessibility loss, orchestrator
    /// teardown, user activation where detected).
    case cancelled

    /// Every serialized reconstruction attempt (up to the walk budget)
    /// finished, but each post-walk reobservation was itself incomplete
    /// — we cannot prove settled OR wrong. Distinct from `.unresolved`
    /// (which means we DID observe wrong order after every attempt) and
    /// from `.observationIncomplete` (which only means a single
    /// checkpoint in the observation phase was incomplete). Reserved
    /// for the terminal outcome of the observation-starvation
    /// escalation path when verification never becomes possible.
    case unresolvedObservationIncomplete
}

// MARK: - Drift-detection policy

/// Pure decisions about whether the recorded history warrants
/// escalation to a serialized full reconstruction. Set-based, so
/// order and count within a single checkpoint don't matter — only
/// which slots stayed out of order across time.
enum CascadeZOrderDrift {

    /// Considered "persistent" — i.e., worthy of pass-4 escalation
    /// to serialized reconstruction — when:
    ///   1. At least TWO checkpoints in the current generation
    ///      recorded a non-empty mismatch set, AND
    ///   2. The two most recent non-empty checkpoints share at
    ///      least one mismatched slot identity.
    ///
    /// Rationale (spec §"RECORD DRIFT HISTORY" and §"WHY A SIMPLE
    /// ONE-LINE PASS-4 FULL WALK IS NOT ENOUGH"):
    ///   - A single burst of drift that fully corrects on the next
    ///     checkpoint is not persistent — no escalation.
    ///   - Two consecutive checkpoints with the SAME slot still
    ///     mismatched means observation-based correction was not
    ///     durable for at least that slot. That's the exact
    ///     signature the cold-start Chrome/Messages/Terminal cases
    ///     produce (5/7 pattern recurring at +300ms, pass 3,
    ///     pass 4).
    ///
    /// Set overlap (not equality) is required — the second checkpoint
    /// may show a superset or subset as apps race to fire auto-raise
    /// at different times; any recurrence is meaningful.
    ///
    /// Observation-incomplete records are excluded from the "two
    /// consecutive non-empty" pair because we cannot prove their
    /// mismatch set is authoritative.
    static func isPersistentDrift(_ history: [ZOrderMismatchRecord]) -> Bool {
        let usable = history.filter { !$0.observationIncomplete && !$0.mismatchedSlots.isEmpty }
        guard usable.count >= 2 else { return false }
        let last = usable[usable.count - 1]
        let prior = usable[usable.count - 2]
        return !last.mismatchedSlots.isDisjoint(with: prior.mismatchedSlots)
    }

    /// True when the given non-empty checkpoint history indicates
    /// order is currently wrong (i.e., the most recent complete
    /// observation showed at least one mismatch). Incomplete
    /// observations are ignored — they neither prove correct nor
    /// wrong.
    static func lastObservedWrong(_ history: [ZOrderMismatchRecord]) -> Bool {
        let usable = history.filter { !$0.observationIncomplete }
        guard let last = usable.last else { return false }
        return !last.mismatchedSlots.isEmpty
    }

    /// True when the last complete observation confirmed correct
    /// order. Used to decide whether the settlement pipeline can
    /// mark itself done without further work.
    static func lastObservedCorrect(_ history: [ZOrderMismatchRecord]) -> Bool {
        let usable = history.filter { !$0.observationIncomplete }
        guard let last = usable.last else { return false }
        return last.mismatchedSlots.isEmpty
    }

    /// True when every complete observation in history showed correct
    /// order AND at least one was recorded. Used to distinguish
    /// "settled without ever needing correction" from "settled after
    /// correction."
    static func settledWithoutAnyCorrection(_ history: [ZOrderMismatchRecord]) -> Bool {
        let usable = history.filter { !$0.observationIncomplete }
        guard !usable.isEmpty else { return false }
        return usable.allSatisfy { $0.mismatchedSlots.isEmpty }
    }

    /// Progress-aware post-walk decision — did a serialized
    /// reconstruction actually improve CGWindowList observability?
    ///
    /// Called after post-walk #1 reobservation returns incomplete. If
    /// the answer is "no progress," the caller must skip walk #2 (no
    /// evidence walk #2 would help; running it would just re-flicker
    /// against the same structural unobservability). If "progress,"
    /// walk #2 remains a valid bounded attempt.
    ///
    /// Semantics:
    ///   - Complete post-walk observation is handled separately by the
    ///     caller (this function assumes `postIncomplete == true`).
    ///   - For incomplete post-walk: progress means
    ///     `postMatchedCount > bestPreWalkMatchedCount`. Equal count
    ///     is explicitly NOT progress — the same number of windows are
    ///     still unobservable, and the second walk has no basis to
    ///     believe more will resolve.
    ///   - `bestPreWalkMatchedCount` is the maximum matched count seen
    ///     across pre-walk observation checkpoints in this generation.
    ///     Zero is a legitimate baseline if no observation ever landed.
    ///
    /// This is the primary gate that prevents the "retry flicker"
    /// symptom on structural plateaus (5/6 → 5/6, 7/8 → 7/8).
    static func postWalkMadeObservationProgress(
        bestPreWalkMatchedCount: Int,
        postWalkMatchedCount: Int,
        postWalkIncomplete: Bool
    ) -> Bool {
        guard postWalkIncomplete else {
            // Complete observation is not this function's decision.
            // Caller should route via the complete-correct /
            // complete-wrong branches before consulting this helper.
            return false
        }
        return postWalkMatchedCount > bestPreWalkMatchedCount
    }

    /// Observation-starvation — repeated inability to VERIFY the
    /// planned order because CGWindowList observations keep coming
    /// back incomplete. Complementary to `isPersistentDrift`, which
    /// requires complete observations to prove the same slots keep
    /// drifting; this one triggers when we can't get complete
    /// observations at all.
    ///
    /// Semantics (spec §"OBSERVATION-STARVATION DEFINITION" + Part 4
    /// tests 1–10):
    ///   1. The latest record MUST be incomplete.
    ///   2. There MUST be at least two consecutive incomplete records
    ///      ending with the latest record (i.e., the ending incomplete
    ///      streak has length ≥ 2).
    ///   3. NO complete observation may appear inside that ending
    ///      streak — a complete observation earlier in history is
    ///      fine (it just doesn't help now).
    ///
    /// Rationale:
    ///   - Isolated single incomplete observation (case: complete →
    ///     incomplete) does NOT starve — it's one stale CGWindowList
    ///     read, not a settlement failure.
    ///   - Two consecutive incomplete observations with no complete
    ///     one in between mean the observer has been unable to
    ///     confidently map every planned window across two distinct
    ///     checkpoints — that's the exact cold-start signature the
    ///     supplied 3/7 → 3/7 → 3/7 → 5/7 → 5/7 trace produces.
    ///   - We deliberately do NOT read `mismatchedSlots` from
    ///     incomplete records — those sets are always empty (line
    ///     1858 in CascadeOrchestrator.enforceCascadeZOrder) and
    ///     using them as evidence would violate the "don't trust
    ///     incomplete mismatch identities" invariant.
    ///
    /// Independent from `isPersistentDrift` on purpose — the two
    /// detectors answer different questions and must both remain
    /// separately testable + separately callable.
    static func isObservationStarved(_ history: [ZOrderMismatchRecord]) -> Bool {
        guard let last = history.last else { return false }
        guard last.observationIncomplete else { return false }

        // Walk backward from the last record, counting the length of
        // the ending incomplete streak. Stop on the first complete
        // record. Streak length must be ≥ 2.
        var streak = 0
        for record in history.reversed() {
            if record.observationIncomplete {
                streak += 1
            } else {
                break
            }
        }
        return streak >= 2
    }
}

// MARK: - Timing constants

/// Named constants used by the serialized reconstruction and
/// settled-reobservation stages. Kept public-visible for testing +
/// so anyone tuning them can find them in one place.
enum CascadeZOrderSettlementTiming {
    /// Async spacing between consecutive AXRaise actions during a
    /// serialized reconstruction. Small enough that the user
    /// perceives the sequence as instantaneous; large enough that
    /// macOS's WindowServer processes each raise before the next.
    /// Spec §"SERIALIZED RECONSTRUCTION REQUIREMENTS": 12–20ms.
    static let raiseSpacing: TimeInterval = 0.016   // 16ms

    /// Delay between the last raise of a serialized reconstruction
    /// and the settled reobservation. Long enough for delayed app
    /// auto-raises to fire (post-write raise-on-write from Chrome /
    /// Messages / Terminal) so reobservation reflects the real final
    /// state. Spec §"SETTLED REOBSERVATION": 180–250ms.
    static let settledReobservationDelay: TimeInterval = 0.20   // 200ms

    /// Earliest wall-clock offset (from cascade generation start)
    /// at which the conditional late recommit is allowed to run.
    /// Spec §"BOUNDED LATE RECOMMIT": +1500ms to +1700ms.
    static let lateRecommitEarliestOffset: TimeInterval = 1.60   // 1600ms

    /// Absolute cap on the number of serialized reconstructions per
    /// cascade generation. Spec §"BOUNDED LATE RECOMMIT" and
    /// §"SERIALIZED RECONSTRUCTION REQUIREMENTS": at most 2 (one
    /// persistent-drift reconstruction + one exceptional late
    /// recommit).
    static let maxSerializedWalksPerGeneration: Int = 2
}
