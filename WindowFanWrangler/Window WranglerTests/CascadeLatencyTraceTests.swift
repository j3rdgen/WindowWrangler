//
//  CascadeLatencyTraceTests.swift
//  Window WranglerTests
//
//  Tests the pure per-generation reaction-time trace. Uses controllable
//  timestamps (constructed CFAbsoluteTime values) so tests don't depend
//  on real wall-clock milliseconds. Covers Part 4 §Test 1 (stage
//  accounting), §Test 3 (first-write marker only settable once), §Test
//  4 (superseded generation), §Test 5 (audit not present in normal
//  trace), and edge cases around unaccounted-time math.
//

import XCTest
@testable import Window_Wrangler

final class CascadeLatencyTraceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Base epoch used for readable timing math in these tests. The
    /// trace only uses relative durations, so any monotonic-ish value
    /// works — we pick 1000.0 so ms offsets are unambiguous.
    private let t0: CFAbsoluteTime = 1000.0

    /// Convenience: build a trace with all stages populated in order,
    /// offsets in milliseconds relative to t0.
    private func fullyPopulatedTrace(
        entry: Int, appSnap: Int, cg: Int, ax: Int,
        postEnum: Int, planning: Int, writeSetup: Int,
        firstWriteReturnedDelta: Int = 5
    ) -> CascadeLatencyTrace {
        let ms = { (n: Int) -> CFAbsoluteTime in Double(n) / 1000.0 }
        let trace = CascadeLatencyTrace(
            generation: 42, direction: "downRight",
            shortcutReceived: t0
        )
        var cursor = t0
        cursor += ms(entry);      trace.cascadeEntered      = cursor
        trace.appSnapshotStart = cursor
        cursor += ms(appSnap);    trace.appSnapshotEnd      = cursor
        trace.cgSnapshotStart  = cursor
        cursor += ms(cg);         trace.cgSnapshotEnd       = cursor
        trace.axEnumStart      = cursor
        cursor += ms(ax);         trace.axEnumEnd           = cursor
        trace.postEnumStart    = cursor
        cursor += ms(postEnum);   trace.planningStart       = cursor
        cursor += ms(planning);   trace.preWriteSetupStart  = cursor
        cursor += ms(writeSetup); trace.firstWriteDispatch  = cursor
        cursor += ms(firstWriteReturnedDelta)
        trace.firstWriteReturned = cursor
        return trace
    }

    // MARK: - Test 1 (Part 4): Stage accounting

    /// The trace must record every stage boundary independently so the
    /// caller can attribute where time went. Verify by round-tripping
    /// synthetic timestamps and reading them back.
    func test_traceStageBoundaries_areRoundTrippable() {
        let trace = fullyPopulatedTrace(
            entry: 10, appSnap: 20, cg: 5, ax: 800,
            postEnum: 100, planning: 15, writeSetup: 50
        )
        // Sanity: every optional is populated.
        XCTAssertNotNil(trace.cascadeEntered)
        XCTAssertNotNil(trace.appSnapshotStart)
        XCTAssertNotNil(trace.appSnapshotEnd)
        XCTAssertNotNil(trace.cgSnapshotStart)
        XCTAssertNotNil(trace.cgSnapshotEnd)
        XCTAssertNotNil(trace.axEnumStart)
        XCTAssertNotNil(trace.axEnumEnd)
        XCTAssertNotNil(trace.postEnumStart)
        XCTAssertNotNil(trace.planningStart)
        XCTAssertNotNil(trace.preWriteSetupStart)
        XCTAssertNotNil(trace.firstWriteDispatch)
        // The shortcut→firstWrite total must equal the sum of stages
        // when all stages are contiguous — proves the trace models the
        // pre-write span faithfully.
        let expectedTotalMs = 10 + 20 + 5 + 800 + 100 + 15 + 50
        let actualTotalMs = Int(
            ((trace.firstWriteDispatch! - trace.shortcutReceived) * 1000).rounded()
        )
        XCTAssertEqual(actualTotalMs, expectedTotalMs)
    }

    // MARK: - Test 3 (Part 4): Emit is idempotent

    /// `emit()` must be safe to call multiple times — the second call
    /// is a no-op so the log doesn't get duplicate lines when the
    /// orchestrator's control flow enters two emission paths (e.g.
    /// superseded finalization after firstWrite already fired).
    func test_emitIdempotent_secondCallIsNoOp() {
        let trace = fullyPopulatedTrace(
            entry: 1, appSnap: 1, cg: 1, ax: 1,
            postEnum: 1, planning: 1, writeSetup: 1
        )
        XCTAssertFalse(trace.emitted)
        trace.emit()
        XCTAssertTrue(trace.emitted)
        trace.emit()  // second call must not crash / must be no-op
        XCTAssertTrue(trace.emitted)
    }

    // MARK: - Test 4 (Part 4): Superseded generation

    /// A superseded trace records the stage it died at and does NOT
    /// require firstWriteDispatch to be set. It must still emit
    /// exactly once.
    func test_supersededTrace_emitsWithoutFirstWrite() {
        let trace = CascadeLatencyTrace(
            generation: 7, direction: "downLeft", shortcutReceived: t0
        )
        trace.cascadeEntered = t0 + 0.010
        trace.axEnumStart    = t0 + 0.030
        trace.axEnumEnd      = t0 + 1.200
        trace.emit(superseded: true, supersededStage: "post-AX-enumeration")
        XCTAssertTrue(trace.emitted)
        XCTAssertNil(trace.firstWriteDispatch,
            "Superseded trace must not fabricate a first-write timestamp.")
    }

    // MARK: - Unaccounted-time math

    /// When every stage is contiguous, the unaccounted gap is 0 — the
    /// helper rounds anything ≤5ms to "0" to swallow float noise.
    func test_unaccountedTime_isZeroWhenStagesAreContiguous() {
        let unaccounted = CascadeLatencyTrace.testHelper_computeUnaccounted(
            shortcutReceived: 1000.0,
            cascadeEntered: 1000.010,          // 10ms
            appSnapshotStart: 1000.010, appSnapshotEnd: 1000.030,   // 20ms
            cgSnapshotStart: 1000.030, cgSnapshotEnd: 1000.035,     //  5ms
            axEnumStart: 1000.035, axEnumEnd: 1000.835,             // 800ms
            postEnumStart: 1000.835, planningStart: 1000.935,       // 100ms
            preWriteSetupStart: 1000.950,                            //  15ms planning
            firstWriteDispatch: 1001.000                             //  50ms writeSetup
        )
        XCTAssertEqual(unaccounted, "0")
    }

    /// When a stage boundary is nil, its interval is genuinely
    /// unmeasured. The helper reports the difference between the
    /// total pre-write span and the sum of stages that COULD be
    /// measured — this is the diagnostic signal that some unmeasured
    /// work sits on the critical path.
    func test_unaccountedTime_reportsLargeGapWhenStageBoundaryMissing() {
        let unaccounted = CascadeLatencyTrace.testHelper_computeUnaccounted(
            shortcutReceived: 1000.0,
            cascadeEntered: 1000.010,          // 10ms measured
            appSnapshotStart: 1000.010, appSnapshotEnd: 1000.020,  // 10ms
            cgSnapshotStart: nil, cgSnapshotEnd: nil,   // unmeasured
            axEnumStart: 1000.020, axEnumEnd: 1000.320, // 300ms
            postEnumStart: nil, planningStart: nil,     // unmeasured
            preWriteSetupStart: nil,                    // unmeasured
            firstWriteDispatch: 1001.325                // total: 1325ms
        )
        // Total pre-write = 1325ms; known = 10 + 10 + 300 = 320ms;
        // unaccounted gap = 1005ms.
        XCTAssertEqual(unaccounted, "1005")
    }

    // MARK: - applyBatchInstrumented shape (Part 4 §D6)

    /// Empty input → zero successes, zero timings, no crash. The
    /// instrumented variant preserves the plain `applyBatch` contract
    /// for the degenerate case (no windows to move).
    func test_applyBatchInstrumented_emptyInputProducesEmptyResult() {
        let (successes, timings) = WindowMutator.applyBatchInstrumented([])
        XCTAssertEqual(successes, 0)
        XCTAssertTrue(timings.isEmpty)
    }

    // MARK: - Initial-batch semantics (Part 4 §A3, §A5)

    /// The new `initialBatchStart` / `initialBatchComplete` fields are
    /// distinct from `firstWriteDispatch` / `firstWriteReturned` in
    /// name and role, even though the sequential `applyBatch`
    /// architecture makes them coincide today. Verify both pairs are
    /// independently settable and readable.
    func test_initialBatchBoundaries_areIndependentFields() {
        let trace = CascadeLatencyTrace(
            generation: 1, direction: "downRight", shortcutReceived: t0
        )
        trace.firstWriteDispatch = t0 + 0.100
        trace.initialBatchStart = t0 + 0.100
        trace.initialBatchComplete = t0 + 0.750
        trace.firstWriteReturned = t0 + 0.750

        XCTAssertNotNil(trace.initialBatchStart)
        XCTAssertNotNil(trace.initialBatchComplete)
        XCTAssertEqual(trace.initialBatchStart, trace.firstWriteDispatch,
            "Under the current sequential architecture these coincide.")
        XCTAssertEqual(trace.initialBatchComplete, trace.firstWriteReturned)
    }

    /// Slowest-write and slowest-PID-group diagnostics survive a
    /// round-trip through the trace's public fields — the orchestrator
    /// populates these after `applyBatchInstrumented` returns.
    func test_slowestWriteAndPIDGroupDiagnostics_areStored() {
        let trace = CascadeLatencyTrace(
            generation: 1, direction: "downLeft", shortcutReceived: t0
        )
        trace.slowestInitialWrite = (appName: "Chrome", ms: 320)
        trace.slowestInitialPIDGroup = (appName: "Chrome", ms: 780, windowCount: 5)
        trace.initialPIDCount = 8
        trace.initialWindowCount = 12

        XCTAssertEqual(trace.slowestInitialWrite?.appName, "Chrome")
        XCTAssertEqual(trace.slowestInitialWrite?.ms, 320)
        XCTAssertEqual(trace.slowestInitialPIDGroup?.appName, "Chrome")
        XCTAssertEqual(trace.slowestInitialPIDGroup?.ms, 780)
        XCTAssertEqual(trace.slowestInitialPIDGroup?.windowCount, 5)
        XCTAssertEqual(trace.initialPIDCount, 8)
        XCTAssertEqual(trace.initialWindowCount, 12)
    }

    // MARK: - AX enumeration enrichment fields

    /// peakInFlight / configuredConcurrency / slowestApps are surfaced
    /// on the trace so a single grep for `Cascade latency:` shows both
    /// the pre-write breakdown AND the enumeration diagnostics needed
    /// to classify the ~1.5s pattern (broad sleepy cost vs one
    /// straggler vs hidden serialization).
    func test_axEnrichmentFields_areStored() {
        let trace = CascadeLatencyTrace(
            generation: 1, direction: "downRight", shortcutReceived: t0
        )
        trace.axPeakInFlight = 10
        trace.axConfiguredConcurrency = 10
        trace.axSlowestApps = "Chrome=850ms, Xcode=440ms, Notes=210ms"

        XCTAssertEqual(trace.axPeakInFlight, 10)
        XCTAssertEqual(trace.axConfiguredConcurrency, 10)
        XCTAssertEqual(trace.axSlowestApps, "Chrome=850ms, Xcode=440ms, Notes=210ms")
    }

    /// firstWriteDispatch nil → unaccounted returns "-" so the log
    /// doesn't spuriously show huge numbers for superseded traces.
    func test_unaccountedTime_isDashWhenFirstWriteMissing() {
        let unaccounted = CascadeLatencyTrace.testHelper_computeUnaccounted(
            shortcutReceived: 1000.0,
            cascadeEntered: 1000.010,
            appSnapshotStart: nil, appSnapshotEnd: nil,
            cgSnapshotStart: nil, cgSnapshotEnd: nil,
            axEnumStart: nil, axEnumEnd: nil,
            postEnumStart: nil, planningStart: nil,
            preWriteSetupStart: nil, firstWriteDispatch: nil
        )
        XCTAssertEqual(unaccounted, "-")
    }
}

// MARK: - Test seam
// Thin passthrough to the production helper. Kept so the tests above
// stay readable — they don't need to construct a whole trace just to
// verify the unaccounted-time math.
extension CascadeLatencyTrace {
    static func testHelper_computeUnaccounted(
        shortcutReceived: CFAbsoluteTime,
        cascadeEntered: CFAbsoluteTime?,
        appSnapshotStart: CFAbsoluteTime?, appSnapshotEnd: CFAbsoluteTime?,
        cgSnapshotStart: CFAbsoluteTime?, cgSnapshotEnd: CFAbsoluteTime?,
        axEnumStart: CFAbsoluteTime?, axEnumEnd: CFAbsoluteTime?,
        postEnumStart: CFAbsoluteTime?, planningStart: CFAbsoluteTime?,
        preWriteSetupStart: CFAbsoluteTime?,
        firstWriteDispatch: CFAbsoluteTime?
    ) -> String {
        return CascadeLatencyTrace.computeUnaccountedMillis(
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
    }
}
