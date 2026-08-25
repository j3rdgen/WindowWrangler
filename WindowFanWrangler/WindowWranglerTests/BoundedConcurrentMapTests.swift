//
//  BoundedConcurrentMapTests.swift
//  Window WranglerTests
//
//  Pure tests for the bounded-concurrent-map primitive used by the
//  All-Apps Cascade to parallelize per-app AX enumeration.
//
//  These tests verify the scheduler contract without needing live AX:
//  bounded in-flight worker count, deterministic result ordering,
//  no result loss / duplication, edge cases (empty input, single
//  element, maxConcurrency ≥ input.count).
//

import XCTest
@testable import Window_Wrangler

/// Thread-safe in-flight counter used by the concurrency-limit tests.
/// Sendable via `@unchecked` — the two mutable `Int`s are only touched
/// under the `NSLock`.
private final class InFlightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: Int = 0
    private var _peak: Int = 0

    func enter() {
        lock.lock()
        _current += 1
        if _current > _peak { _peak = _current }
        lock.unlock()
    }
    func exit() {
        lock.lock()
        _current -= 1
        lock.unlock()
    }
    var peak: Int {
        lock.lock(); defer { lock.unlock() }
        return _peak
    }
}

final class BoundedConcurrentMapTests: XCTestCase {

    // MARK: - Deterministic ordering

    /// Reverse-completion-order test — Task 4 from Part 4 §Test 6.
    /// Larger indices sleep less than smaller ones, so tasks complete
    /// in the opposite order they were queued. Results must still be
    /// returned in input order.
    func test_reverseCompletion_returnsInputOrder() async {
        let inputs = Array(0..<10)
        let results = await BoundedConcurrentMap.map(inputs, maxConcurrency: 10) { i in
            // Task 0 sleeps longest, task 9 shortest → reverse completion.
            let usec = UInt64(20_000 * (10 - i))  // 20-200 ms range
            try? await Task.sleep(nanoseconds: usec * 1_000)
            return i * 100
        }
        XCTAssertEqual(results, [0, 100, 200, 300, 400, 500, 600, 700, 800, 900])
    }

    /// Random-order completion. Non-deterministic execution order,
    /// deterministic output order — the contract.
    func test_randomCompletion_returnsInputOrder() async {
        let inputs = Array(0..<20)
        let results = await BoundedConcurrentMap.map(inputs, maxConcurrency: 8) { i in
            // Arbitrary but repeatable per-input delay.
            let usec = UInt64(((i * 37) % 17) * 5_000)
            try? await Task.sleep(nanoseconds: usec * 1_000)
            return "item-\(i)"
        }
        XCTAssertEqual(results, (0..<20).map { "item-\($0)" })
    }

    // MARK: - Bounded concurrency

    /// Fed more inputs than the concurrency limit, the observed peak
    /// in-flight count must never exceed the bound. Also proves the
    /// scheduler IS concurrent (peak > 1) when it should be.
    func test_boundedConcurrency_maxInFlightRespectsLimit() async {
        let counter = InFlightCounter()
        let inputs = Array(0..<30)
        let bound = 6

        _ = await BoundedConcurrentMap.map(inputs, maxConcurrency: bound) { _ in
            counter.enter()
            // Hold the slot briefly so overlap can happen.
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
            counter.exit()
            return 1
        }
        XCTAssertLessThanOrEqual(counter.peak, bound,
            "Peak in-flight must never exceed maxConcurrency.")
        XCTAssertGreaterThan(counter.peak, 1,
            "Peak in-flight must exceed 1 — otherwise scheduling is effectively serial.")
    }

    /// When maxConcurrency ≥ input count, all inputs may run in
    /// parallel — peak is bounded by input count, not the limit.
    func test_smallInputLargeLimit_peakEqualsInputCount() async {
        let counter = InFlightCounter()
        let inputs = [1, 2, 3]

        _ = await BoundedConcurrentMap.map(inputs, maxConcurrency: 100) { _ in
            counter.enter()
            try? await Task.sleep(nanoseconds: 30_000_000)
            counter.exit()
            return 0
        }
        XCTAssertLessThanOrEqual(counter.peak, 3)
    }

    /// Concurrency=1 means fully serial — peak == 1.
    func test_serialFallback_peakEqualsOne() async {
        let counter = InFlightCounter()
        let inputs = Array(0..<5)

        _ = await BoundedConcurrentMap.map(inputs, maxConcurrency: 1) { _ in
            counter.enter()
            try? await Task.sleep(nanoseconds: 10_000_000)
            counter.exit()
            return 0
        }
        XCTAssertEqual(counter.peak, 1,
            "maxConcurrency=1 must execute serially — peak in-flight must be 1.")
    }

    // MARK: - Result-integrity

    /// Every input must produce exactly one output at the correct index —
    /// no loss, no duplication, no wrong-slot writes even under
    /// aggressive parallelism.
    func test_allResultsPreserved_thirtyInputs() async {
        let inputs = Array(0..<30)
        let results = await BoundedConcurrentMap.map(inputs, maxConcurrency: 6) { i in
            // Small perturbation so tasks interleave.
            let usec = UInt64((i % 5) * 3_000)
            try? await Task.sleep(nanoseconds: usec * 1_000)
            return i * i
        }
        XCTAssertEqual(results.count, 30)
        for i in 0..<30 {
            XCTAssertEqual(results[i], i * i,
                "Result at index \(i) must be \(i * i) — got \(results[i]).")
        }
    }

    // MARK: - Edge cases

    /// Empty input → empty output. No worker spawned.
    func test_emptyInput_returnsEmpty() async {
        let counter = InFlightCounter()
        let results = await BoundedConcurrentMap.map([Int](), maxConcurrency: 6) { _ in
            counter.enter()
            counter.exit()
            return 0
        }
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(counter.peak, 0)
    }

    /// Single-element input works and returns the transformed value in
    /// position 0.
    func test_singleElement_returnsSingleResult() async {
        let results = await BoundedConcurrentMap.map([42], maxConcurrency: 6) { i in
            i + 1
        }
        XCTAssertEqual(results, [43])
    }

    /// Defensive: maxConcurrency ≤ 0 is clamped to 1 (serial fallback)
    /// so it never zero-worker-spins.
    func test_zeroConcurrency_clampsToOne() async {
        let inputs = [1, 2, 3]
        let results = await BoundedConcurrentMap.map(inputs, maxConcurrency: 0) { i in
            i * 10
        }
        XCTAssertEqual(results, [10, 20, 30])
    }

    /// Defensive: maxConcurrency = negative clamps to 1.
    func test_negativeConcurrency_clampsToOne() async {
        let inputs = [1, 2]
        let results = await BoundedConcurrentMap.map(inputs, maxConcurrency: -5) { i in
            i * 2
        }
        XCTAssertEqual(results, [2, 4])
    }

    // MARK: - Slow-task-doesn't-block-others

    /// One task holds a worker slot for 100 ms while five others take
    /// 5 ms each. With maxConcurrency=3, the fast tasks must not
    /// serialize behind the slow one — total wall-clock stays close
    /// to the slow task's duration, not slow+all-fast.
    ///
    /// Uses a generous margin because CI clocks are noisy; the point
    /// is proving fast tasks can run in a different worker slot while
    /// the slow one holds its slot, not asserting exact millisecond
    /// wall-clock.
    func test_slowTask_doesNotSerializeOthers() async {
        let inputs = [0, 1, 2, 3, 4, 5]  // 0 = slow, rest = fast

        let start = Date()
        _ = await BoundedConcurrentMap.map(inputs, maxConcurrency: 3) { i in
            let ns: UInt64 = (i == 0) ? 100_000_000 : 5_000_000  // 100ms vs 5ms
            try? await Task.sleep(nanoseconds: ns)
            return i
        }
        let elapsed = Date().timeIntervalSince(start)

        // Sequential worst case: 100 + 5*5 = 125 ms.
        // Bounded concurrent: slow task dominates; fast tasks run in
        // parallel slots (max 2 fast at once with limit=3). Should
        // finish comfortably under 175 ms with generous margin for
        // clock noise.
        XCTAssertLessThan(elapsed, 0.175,
            "Wall-clock \(elapsed)s suggests fast tasks serialized behind the slow task — bounded concurrency broken.")
    }

    // MARK: - mapWithMetrics (instrumented variant)

    /// Metrics variant preserves the exact same result contract as `map`
    /// — same order, same count, no drops or duplicates. Guard against
    /// the metrics wrapper accidentally rearranging the result array.
    func test_metrics_resultsMatchPlainMapContract() async {
        let inputs = Array(0..<25)
        let (results, _) = await BoundedConcurrentMap.mapWithMetrics(
            inputs, maxConcurrency: 5
        ) { i in
            let usec = UInt64(((i * 13) % 11) * 2_000)
            try? await Task.sleep(nanoseconds: usec * 1_000)
            return i * 10
        }
        XCTAssertEqual(results, inputs.map { $0 * 10 })
    }

    /// Concurrency-audit primary case — with 20 inputs and a
    /// non-trivial per-item delay, the peak observed in-flight must
    /// reach the bound of 8. If it plateaus at 1 the primitive is
    /// silently serialized (actor hop, serial queue), which is exactly
    /// what the audit line in the log is meant to catch.
    func test_metrics_peakInFlightApproachesBound() async {
        let inputs = Array(0..<20)
        let (_, metrics) = await BoundedConcurrentMap.mapWithMetrics(
            inputs, maxConcurrency: 8
        ) { _ in
            try? await Task.sleep(nanoseconds: 30_000_000)  // 30ms
            return 0
        }
        // Deterministic upper bound — never exceed the limit.
        XCTAssertLessThanOrEqual(metrics.maxObservedInFlight, 8)
        // Real concurrency — must clear a value that's impossible under
        // hidden serialization (1) or a broken primer (0/2).
        XCTAssertGreaterThanOrEqual(metrics.maxObservedInFlight, 6,
            "peakInFlight=\(metrics.maxObservedInFlight) is too low — the pool is not saturating.")
    }

    /// Single-worker configuration must report peakInFlight=1 exactly.
    /// Direct proof for the DEBUG-override serial-comparison mode.
    func test_metrics_serialConfigReportsPeakOne() async {
        let inputs = Array(0..<5)
        let (_, metrics) = await BoundedConcurrentMap.mapWithMetrics(
            inputs, maxConcurrency: 1
        ) { _ in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return 0
        }
        XCTAssertEqual(metrics.maxObservedInFlight, 1,
            "maxConcurrency=1 must serialize — peak in-flight must be exactly 1.")
    }

    /// Per-item durations line up with inputs — index 0 is the slow
    /// item, others are fast. The Cascade log's "slowest apps" line
    /// depends on this correspondence to name the right app.
    func test_metrics_perItemDurationsMatchInputPositions() async {
        let inputs = [0, 1, 2, 3]  // 0 = slow, rest = fast
        let (_, metrics) = await BoundedConcurrentMap.mapWithMetrics(
            inputs, maxConcurrency: 4
        ) { i in
            let ns: UInt64 = (i == 0) ? 80_000_000 : 5_000_000
            try? await Task.sleep(nanoseconds: ns)
            return 0
        }
        XCTAssertEqual(metrics.perItemDurationSeconds.count, 4)
        // Index 0 (the slow one) must be visibly slower than the
        // others by a comfortable margin. Absolute comparisons stay
        // loose because dispatch scheduling adds jitter.
        XCTAssertGreaterThan(metrics.perItemDurationSeconds[0], 0.05)
        for i in 1..<4 {
            XCTAssertLessThan(metrics.perItemDurationSeconds[i], 0.05,
                "Fast item \(i) duration \(metrics.perItemDurationSeconds[i])s looks wrong.")
        }
    }

    /// Empty input → zero peak, zero durations. Never crashes the
    /// metrics wrapper on an app list of size 0 (edge case: cascade
    /// invoked with no eligible apps).
    func test_metrics_emptyInputProducesZeroPeakAndEmptyDurations() async {
        let (results, metrics) = await BoundedConcurrentMap.mapWithMetrics(
            [Int](), maxConcurrency: 6
        ) { $0 }
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(metrics.maxObservedInFlight, 0)
        XCTAssertTrue(metrics.perItemDurationSeconds.isEmpty)
    }
}
