//
//  CascadeLatencyTrace.swift
//  Window Wrangler
//
//  Per-generation end-to-end reaction-time trace for All-Apps Cascade.
//  Captures the exact shortcut → first-external-window-write span,
//  broken into every stage between them so the dominant pre-write
//  bottleneck can be attributed without guesswork.
//
//  KEY PRINCIPLES
//  --------------
//  * Monotonic clock — uses `CFAbsoluteTimeGetCurrent()`, not `Date`.
//    Wall-clock jumps (NTP nudge, DST) do not corrupt duration math.
//  * Per generation — each Cascade owns its own trace instance. Rapid
//    supersession (Cascade A superseded by B) produces two separate
//    traces; A finalizes as `superseded`, B measures cleanly.
//  * Low overhead — one struct allocation + one log line per Cascade.
//    Does NOT add AX calls, does NOT enumerate anything, does NOT
//    print per-app lines at normal log level.
//  * The "first write" marker is set at the moment
//    `WindowMutator.applyBatch(allMoves)` returns non-zero — the exact
//    boundary where the first external window frame has been dispatched
//    to WindowServer. This is the primary reaction-time metric.
//

import Foundation
import os

/// One Cascade generation's timing record. Ownership: constructed on
/// the main actor at Cascade entry, mutated only on the main actor,
/// and emitted exactly once when either the first-write marker fires
/// or the generation is superseded. Never held across cascades.
///
/// Field naming mirrors the spec's stage vocabulary:
///     shortcut → entry → appSnapshot → cgSnapshot → axEnum
///                → postEnum → planning → preWriteSetup → firstWrite
final class CascadeLatencyTrace {

    let generation: UInt64
    let direction: String
    /// `CFAbsoluteTimeGetCurrent()` at each boundary. Nil until reached.
    /// A stage's duration is `boundaryEnd - boundaryStart`, computed at
    /// emit time.
    let shortcutReceived: CFAbsoluteTime

    var cascadeEntered: CFAbsoluteTime?
    var appSnapshotStart: CFAbsoluteTime?
    var appSnapshotEnd: CFAbsoluteTime?
    var cgSnapshotStart: CFAbsoluteTime?
    var cgSnapshotEnd: CFAbsoluteTime?
    var axEnumStart: CFAbsoluteTime?
    var axEnumEnd: CFAbsoluteTime?
    var postEnumStart: CFAbsoluteTime?
    var planningStart: CFAbsoluteTime?
    var preWriteSetupStart: CFAbsoluteTime?
    /// Right before the first initial-geometry AX write is issued.
    /// Same instant as `initialBatchStart` under the current sequential
    /// `applyBatch` architecture — kept as a distinct field because
    /// downstream consumers grep by name and the pair semantically
    /// answers different questions ("when did the first write start?"
    /// vs "when did the whole batch start?").
    var firstWriteDispatch: CFAbsoluteTime?
    /// Right after `applyBatch` returns — i.e. after ALL initial
    /// geometry writes complete, not after the first. Named for its
    /// pairing with `firstWriteDispatch`, but the actual semantics are
    /// captured more precisely by `initialBatchComplete` below.
    /// Retained for backward compatibility with the prior log format.
    var firstWriteReturned: CFAbsoluteTime?

    // MARK: - Initial-batch boundary (Part 2 §"ADD THE MISSING INITIAL-BATCH BOUNDARY")
    //
    // Distinct from firstWriteDispatch / firstWriteReturned so the
    // grep-friendly log line explicitly answers Metric 2 from the spec
    // ("shortcut → all authoritative initial geometry writes complete").
    // Under the current sequential applyBatch these coincide with
    // firstWriteDispatch/Returned; if per-PID mutation concurrency is
    // ever added, the batch boundary is the barrier that downstream
    // settlement (Chromium repair, z-order) waits on.
    var initialBatchStart: CFAbsoluteTime?
    var initialBatchComplete: CFAbsoluteTime?

    /// Slowest individual `WindowMutator.setFrame` call observed in
    /// this batch. Captured as `(appName, milliseconds)`. Nil when
    /// per-write diagnostics weren't collected.
    var slowestInitialWrite: (appName: String, ms: Int)?
    /// Slowest per-PID group total (sum of all setFrame calls for one
    /// app) — surfaces "one app dominates the batch" vs "sum across
    /// apps dominates" without a separate log line.
    var slowestInitialPIDGroup: (appName: String, ms: Int, windowCount: Int)?
    /// Distinct PIDs represented in the initial batch — proxy for the
    /// number of parallel groups a per-PID mutation scheduler could
    /// exploit. `initialWindowCount / initialPIDCount` roughly bounds
    /// the sequential critical path a per-PID scheduler could reach.
    var initialPIDCount: Int = 0
    var initialWindowCount: Int = 0

    // MARK: - Enrichment surfaced from bounded AX enumeration
    // Merged into the single latency log line so a user grepping
    // `Cascade latency:` sees everything needed to classify the ~1.5s
    // pattern (broad sleepy cost vs one straggler vs hidden
    // serialization) without joining two log lines by hand.
    var axPeakInFlight: Int = 0
    var axConfiguredConcurrency: Int = 0
    var axSlowestApps: String = ""   // "AppA=850ms, AppB=440ms, AppC=210ms"

    /// Populated on emit. `emitted == true` guarantees no double-log.
    private(set) var emitted: Bool = false

    /// Diagnostic counters filled by the orchestrator — not timing.
    var eligibleAppsCount: Int = 0
    var axEnumeratedCount: Int = 0
    var totalPlannedWindows: Int = 0

    init(generation: UInt64, direction: String, shortcutReceived: CFAbsoluteTime) {
        self.generation = generation
        self.direction = direction
        self.shortcutReceived = shortcutReceived
    }

    /// Convenience — call from the shortcut handler at the very first
    /// line so we capture the actual keyboard-event boundary rather
    /// than something later.
    static func now() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    /// Emits the finalized trace as one log line. Idempotent — if
    /// called twice (e.g. supersession after first-write already fired),
    /// the second call is a no-op. Missing boundaries render as `-`.
    ///
    /// The output has one purpose: let a human grep for
    /// `Cascade latency:` and see exactly where time went for this
    /// generation.
    func emit(superseded: Bool = false, supersededStage: String? = nil) {
        guard !emitted else { return }
        emitted = true

        let ms = { (start: CFAbsoluteTime?, end: CFAbsoluteTime?) -> String in
            guard let start, let end else { return "-" }
            return "\(Int((end - start) * 1000))"
        }
        let shortcutTo = { (target: CFAbsoluteTime?) -> String in
            guard let target else { return "-" }
            return "\(Int((target - self.shortcutReceived) * 1000))"
        }

        let entry = ms(shortcutReceived, cascadeEntered)
        let appSnap = ms(appSnapshotStart, appSnapshotEnd)
        let cg = ms(cgSnapshotStart, cgSnapshotEnd)
        let ax = ms(axEnumStart, axEnumEnd)
        let postEnum = ms(postEnumStart, planningStart)
        let planning = ms(planningStart, preWriteSetupStart)
        let writeSetup = ms(preWriteSetupStart, firstWriteDispatch)
        let firstWriteMs = shortcutTo(firstWriteDispatch)
        let firstWriteReturnedMs = shortcutTo(firstWriteReturned)

        // Unaccounted pre-write time — anything between the last
        // instrumented stage and firstWriteDispatch that we didn't
        // measure. If large, it's itself a diagnostic result.
        let unaccounted = Self.computeUnaccountedMillis(
            shortcutReceived: shortcutReceived,
            cascadeEntered: cascadeEntered,
            appSnapshotStart: appSnapshotStart,
            appSnapshotEnd: appSnapshotEnd,
            cgSnapshotStart: cgSnapshotStart,
            cgSnapshotEnd: cgSnapshotEnd,
            axEnumStart: axEnumStart,
            axEnumEnd: axEnumEnd,
            postEnumStart: postEnumStart,
            planningStart: planningStart,
            preWriteSetupStart: preWriteSetupStart,
            firstWriteDispatch: firstWriteDispatch
        )

        let initialBatchMs = ms(initialBatchStart, initialBatchComplete)
        let shortcutToInitialBatchComplete = shortcutTo(initialBatchComplete)
        let slowestWriteStr: String = {
            guard let sw = slowestInitialWrite else { return "-" }
            return "\(sw.appName)=\(sw.ms)ms"
        }()
        let slowestPIDGroupStr: String = {
            guard let g = slowestInitialPIDGroup else { return "-" }
            return "\(g.appName)×\(g.windowCount)=\(g.ms)ms"
        }()
        let peakInFlight = self.axPeakInFlight
        let concurrency = self.axConfiguredConcurrency
        let slowestApps = self.axSlowestApps.isEmpty ? "-" : self.axSlowestApps

        if superseded {
            let stage = supersededStage ?? "?"
            Log.cascade.info(
                "Cascade latency: gen=\(self.generation, privacy: .public) dir=\(self.direction, privacy: .public) superseded=true stage=\(stage, privacy: .public) apps=\(self.eligibleAppsCount, privacy: .public) axEnumerated=\(self.axEnumeratedCount, privacy: .public) shortcut→entry=\(entry, privacy: .public)ms appSnap=\(appSnap, privacy: .public)ms cg=\(cg, privacy: .public)ms ax=\(ax, privacy: .public)ms peakInFlight=\(peakInFlight, privacy: .public)/\(concurrency, privacy: .public) slowestAXApps=[\(slowestApps, privacy: .public)]"
            )
        } else {
            Log.cascade.info(
                "Cascade latency: gen=\(self.generation, privacy: .public) dir=\(self.direction, privacy: .public) apps=\(self.eligibleAppsCount, privacy: .public) axEnumerated=\(self.axEnumeratedCount, privacy: .public) windows=\(self.totalPlannedWindows, privacy: .public) shortcut→entry=\(entry, privacy: .public)ms appSnap=\(appSnap, privacy: .public)ms cg=\(cg, privacy: .public)ms ax=\(ax, privacy: .public)ms peakInFlight=\(peakInFlight, privacy: .public)/\(concurrency, privacy: .public) slowestAXApps=[\(slowestApps, privacy: .public)] postEnum=\(postEnum, privacy: .public)ms planning=\(planning, privacy: .public)ms writeSetup=\(writeSetup, privacy: .public)ms other=\(unaccounted, privacy: .public)ms shortcut→firstWrite=\(firstWriteMs, privacy: .public)ms initialBatch=\(initialBatchMs, privacy: .public)ms pids=\(self.initialPIDCount, privacy: .public) shortcut→initialBatchComplete=\(shortcutToInitialBatchComplete, privacy: .public)ms slowestWrite=\(slowestWriteStr, privacy: .public) slowestPIDGroup=\(slowestPIDGroupStr, privacy: .public)"
            )
        }
    }
}

// MARK: - Helpers

extension CascadeLatencyTrace {
    /// Isolates the unaccounted-time math into a plain-old-Swift
    /// function so the compiler doesn't hit "unable to type-check in
    /// reasonable time" on the array-of-optionals + compactMap +
    /// reduce chain that broke when written inline. `internal` so
    /// unit tests can reach it via `@testable import`; no production
    /// call site outside this file.
    static func computeUnaccountedMillis(
        shortcutReceived: CFAbsoluteTime,
        cascadeEntered: CFAbsoluteTime?,
        appSnapshotStart: CFAbsoluteTime?,
        appSnapshotEnd: CFAbsoluteTime?,
        cgSnapshotStart: CFAbsoluteTime?,
        cgSnapshotEnd: CFAbsoluteTime?,
        axEnumStart: CFAbsoluteTime?,
        axEnumEnd: CFAbsoluteTime?,
        postEnumStart: CFAbsoluteTime?,
        planningStart: CFAbsoluteTime?,
        preWriteSetupStart: CFAbsoluteTime?,
        firstWriteDispatch: CFAbsoluteTime?
    ) -> String {
        guard let firstWrite = firstWriteDispatch else { return "-" }
        let totalPreWriteMs = (firstWrite - shortcutReceived) * 1000

        var knownMs: Double = 0
        if let cascadeEntered {
            knownMs += (cascadeEntered - shortcutReceived) * 1000
        }
        if let s = appSnapshotStart, let e = appSnapshotEnd {
            knownMs += (e - s) * 1000
        }
        if let s = cgSnapshotStart, let e = cgSnapshotEnd {
            knownMs += (e - s) * 1000
        }
        if let s = axEnumStart, let e = axEnumEnd {
            knownMs += (e - s) * 1000
        }
        if let s = postEnumStart, let e = planningStart {
            knownMs += (e - s) * 1000
        }
        if let s = planningStart, let e = preWriteSetupStart {
            knownMs += (e - s) * 1000
        }
        if let s = preWriteSetupStart, let e = firstWriteDispatch {
            knownMs += (e - s) * 1000
        }

        let gap = totalPreWriteMs - knownMs
        return gap > 5 ? "\(Int(gap.rounded()))" : "0"
    }
}
